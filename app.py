from flask import Flask, render_template, request, redirect, url_for, session, flash
from werkzeug.middleware.proxy_fix import ProxyFix
from functools import wraps
import os
import subprocess
import logging
from ldap3 import Server, Connection, ALL
import paramiko
import threading
import time
import json
import uuid
import requests
from datetime import datetime
from dotenv import load_dotenv

load_dotenv()

app = Flask(__name__)
# If NGINX is on a separate host, ProxyFix is critical for correct redirects and session behavior.
# We apply it to handle X-Forwarded-* headers from the remote proxy.
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_port=1, x_prefix=1)
app.config['TEMPLATES_AUTO_RELOAD'] = True
app.secret_key = os.getenv('SECRET_KEY')
if not app.secret_key:
    raise RuntimeError("SECRET_KEY must be set in environment or .env")

LOGOUT_REDIRECT_URL = os.getenv('LOGOUT_REDIRECT_URL', '/')

def _env_bool(name, default=False):
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")

# Allow local HTTP login by default; enable secure cookies in HTTPS/proxy deployments.
session_cookie_secure = _env_bool("SESSION_COOKIE_SECURE", False)
session_cookie_path = os.getenv("SESSION_COOKIE_PATH", "/")

# Session settings optimized for remote HTTPS proxying
app.config.update(
    SESSION_COOKIE_NAME='ntnx_cm_session',
    SESSION_COOKIE_PATH=session_cookie_path,
    SESSION_COOKIE_SAMESITE='Lax', # 'Lax' is generally safer than 'None'
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SECURE=session_cookie_secure,
    PERMANENT_SESSION_LIFETIME=3600,
    SESSION_REFRESH_EACH_REQUEST=True
)

@app.before_request
def handle_proxy_headers():
    # Force scheme to https if proxy says so
    if request.headers.get('X-Forwarded-Proto') == 'https':
        request.environ['wsgi.url_scheme'] = 'https'

@app.before_request
def auto_login():
    # DISABLE LOGIN: Automatically log in as 'admin' to bypass login screen. 
    # To re-enable login, comment out or remove this before_request hook.
    if not session.get('logged_in'):
        session['logged_in'] = True
        session['username'] = 'admin'

# SSH Credentials
SSH_USER = os.getenv("SSH_USER")
SSH_PASS = os.getenv("SSH_PASS")

# External script status files
AUTOMATED_SHUTDOWN_STATUS_FILE = "/tmp/automated_shutdown.status"
AUTOMATED_STARTUP_STATUS_FILE = "/tmp/automated_startup.status"
PAUSE_FILE = "/tmp/automation.paused"
SCHEDULED_PAUSES_FILE = os.path.join(os.path.dirname(__file__), 'scheduled_pauses.json')
SCHEDULED_PAUSE_ACTIVE_FILE = "/tmp/scheduled_automation.paused"
SLACK_WEBHOOK_URL = os.getenv("SLACK_WEBHOOK_URL")

# Cluster Nodes for Status Check
PC_STATUS_IP = os.getenv("PC_IP")
PE_STATUS_IP = os.getenv("PE_IP")

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def send_slack_notification(message):
    """Send a notification to Slack."""
    if not SLACK_WEBHOOK_URL:
        return
    try:
        payload = {
            "text": message,
            "username": "Cluster Manager",
            "icon_emoji": ":calendar:"
        }
        response = requests.post(SLACK_WEBHOOK_URL, json=payload, timeout=5)
        response.raise_for_status()
    except Exception as e:
        logger.error(f"Failed to send Slack notification: {e}")

# Locks for concurrency management
status_lock = threading.Lock()
jobs_lock = threading.Lock()

# Global status cache
cluster_status_cache = {
    "pc": "unknown",
    "pe": "unknown",
    "nkp": "unknown",
    "pcvms": "unknown",
    "cvms": "unknown",
    "fsvms": "unknown",
    "fs": "unknown",
    "mgmt": "unknown",
    "hosts": "unknown"
}
status_meta = {
    "last_updated": None,
    "update_in_progress": False,
    "last_error": None
}

def check_ping(ip_list_str, jump_host=None):
    if not ip_list_str:
        return "down"
    ips = ip_list_str.split(",")
    for ip in ips:
        ip = ip.strip()
        if not ip: continue
        try:
            # 1. Try local ping
            res = subprocess.run(['ping', '-c', '1', '-W', '1', ip], 
                               capture_output=True, text=True)
            if res.returncode == 0:
                return "up"
            
            # 2. Check if SSH port (22) is open (local)
            import socket
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(1)
            result = sock.connect_ex((ip, 22))
            sock.close()
            if result == 0:
                return "up"

            # 3. Proxy Ping via jump_host if provided
            if jump_host:
                SSH_USER = os.getenv("SSH_USER")
                SSH_PASS = os.getenv("SSH_PASS")
                # Using sshpass for a quick proxy check
                proxy_cmd = f"sshpass -p '{SSH_PASS}' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 {SSH_USER}@{jump_host} 'ping -c 1 -W 1 {ip}'"
                proxy_res = subprocess.run(proxy_cmd, shell=True, capture_output=True)
                if proxy_res.returncode == 0:
                    return "up"
        except:
            pass
    return "down"

def check_nkp_status():
    try:
        # Check if any nodes are 'Ready'
        result = subprocess.run(['kubectl', 'get', 'nodes', '--no-headers'], 
                              capture_output=True, text=True, timeout=5)
        if result.returncode == 0 and "Ready" in result.stdout:
            return "up"
        return "down"
    except Exception:
        return "down"

def check_hosts_status():
    try:
        # Primary source of truth: AHV host reachability.
        # This avoids false "ON" states from out-of-band controller reporting.
        ahv_ips_raw = os.getenv("AHV_IPS", "")
        ahv_ips = [ip.strip() for ip in ahv_ips_raw.split(",") if ip.strip()]
        if ahv_ips:
            reachable = 0
            import socket
            for ip in ahv_ips:
                # Ping first
                ping_res = subprocess.run(
                    ['ping', '-c', '1', '-W', '1', ip],
                    capture_output=True,
                    text=True
                )
                if ping_res.returncode == 0:
                    reachable += 1
                    continue

                # Fallback: SSH port check
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(1)
                try:
                    if sock.connect_ex((ip, 22)) == 0:
                        reachable += 1
                finally:
                    sock.close()

            if reachable == len(ahv_ips):
                return "up"
            return "down"

        # Fallback if AHV_IPS is not configured: use first CIMC host Redfish state
        cimc_hosts_env = os.getenv("CIMC_HOSTS")
        if not cimc_hosts_env:
            return "down"
        host = cimc_hosts_env.split(",")[0].strip()
        cimc_user = os.getenv("CIMC_USER")
        cimc_pass = os.getenv("CIMC_PASS")

        res_id = subprocess.run([
            'curl', '-k', '-s', '-u', f'{cimc_user}:{cimc_pass}',
            '-X', 'GET', f'https://{host}/redfish/v1/Systems'
        ], capture_output=True, text=True, timeout=5)

        if res_id.returncode == 0:
            import json
            data_id = json.loads(res_id.stdout)
            members = data_id.get('Members', [])
            if not members:
                return "down"

            system_path = members[0].get('@odata.id')
            result = subprocess.run([
                'curl', '-k', '-s', '-u', f'{cimc_user}:{cimc_pass}',
                '-X', 'GET', f'https://{host}{system_path}'
            ], capture_output=True, text=True, timeout=5)

            if result.returncode == 0:
                data = json.loads(result.stdout)
                power_state = data.get('PowerState')
                return "up" if power_state == 'On' else "down"
    except Exception as e:
        return "down"
    return "down"

import re

def check_cluster_status(hostname):
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        # Reduced timeout for faster status checks
        client.connect(hostname, username=SSH_USER, password=SSH_PASS, timeout=5)
        
        # Use login shell to ensure 'cluster' command is in PATH
        chan = client.get_transport().open_session()
        chan.settimeout(10) # 10 second timeout for the command execution
        chan.exec_command('bash -l -c "cluster status"')
        
        # Read output with timeout
        output = ""
        while not chan.exit_status_ready():
            if chan.recv_ready():
                output += chan.recv(4096).decode('utf-8')
            else:
                time.sleep(0.1)
                
        # Final read
        while chan.recv_ready():
            output += chan.recv(4096).decode('utf-8')
            
        client.close()
        
        # 1. Look for the explicit summary success indicators
        # We REMOVE "Success!" as it appears even when services are DOWN
        # We ADD "The state of the cluster: start" and "The state of the cluster is UP"
        summary_likely_up = "The state of the cluster: start" in output or \
                           "The state of the cluster is UP" in output or \
                           "Cluster status: UP" in output
        
        # 2. Check for services that are DOWN (more robust regex)
        # Matches patterns like "Service: DOWN", "Service [DOWN]", or "Service   DOWN   []"
        has_down_services = re.search(r'\bDOWN\b', output, re.IGNORECASE)
        
        # 3. Ensure we actually see some "UP" services to avoid false positives 
        # (e.g., if the output is truncated or just says "The state of the cluster: start" without listing services)
        has_up_services = re.search(r'\bUP\b', output, re.IGNORECASE)
        
        if has_down_services:
            logger.warning(f"Cluster {hostname} has DOWN services. Raw output snippet: {output[:500]}...")
        
        if summary_likely_up and has_up_services and not has_down_services:
            return "up"
        
        # If the cluster is in stop state, return down
        if "The state of the cluster: stop" in output:
            return "down"
            
        return "down"
    except Exception as e:
        logger.error(f"Error checking cluster status for {hostname}: {e}")
        return "down"

def check_fs_cluster_status():
    try:
        # Call fsvm_mgr.py status - increased timeout as it may try many CVM/FSVM combinations
        result = subprocess.run(['python3', 'fsvm_mgr.py', 'status'], 
                              capture_output=True, text=True, timeout=120)
        output = result.stdout
        
        # 1. Look for the explicit summary success indicators
        summary_likely_up = "The state of the cluster is UP" in output or \
                           "The state of the cluster: start" in output or \
                           "Cluster status: UP" in output
        
        # 2. Check for services that are DOWN (more robust regex)
        has_down_services = re.search(r'\bDOWN\b', output, re.IGNORECASE)
        
        # 3. Ensure we actually see some "UP" services
        has_up_services = re.search(r'\bUP\b', output, re.IGNORECASE)
        
        if summary_likely_up and has_up_services and not has_down_services:
            return "up"
            
        return "down"
    except Exception as e:
        logger.error(f"Error checking FS cluster status: {e}")
        return "down"

def check_mgmt_status():
    try:
        # Use PC API to list VMs and find their status
        PC_IP = os.getenv("PC_IP")
        USER = os.getenv("PC_USER")
        PASS = os.getenv("PC_PASS")
        
        payload = '{"kind": "vm", "length": 500}'
        result = subprocess.run([
            'curl', '-k', '-s', '-u', f'{USER}:{PASS}',
            '-X', 'POST', f'https://{PC_IP}:9440/api/nutanix/v3/vms/list',
            '-H', 'Content-Type: application/json', '-d', payload
        ], capture_output=True, text=True, timeout=5)
        
        if result.returncode == 0:
            import json
            data = json.loads(result.stdout)
            entities = data.get('entities', [])
            
            # Use configured management VM names from .env
            mgmt_vm_names_env = os.getenv("MGMT_VM_NAMES", "")
            mgmt_vm_names = [name.strip() for name in mgmt_vm_names_env.split(",") if name.strip()]
            
            if not mgmt_vm_names:
                logger.warning("No MGMT_VM_NAMES found in environment")
                return "down"

            # Create a map of name -> vm for quick lookup.
            # Ignore VMs without a name to avoid empty-key collisions.
            vm_map = {}
            for vm in entities:
                vm_name = vm.get('spec', {}).get('name')
                if vm_name:
                    vm_map[vm_name] = vm

            # Support both exact VM names and prefix patterns.
            # Any entry that ends with "_" is treated as a prefix.
            matched_vms = []
            for target_name in mgmt_vm_names:
                if target_name.endswith("_"):
                    prefix_matches = [
                        vm for vm_name, vm in vm_map.items()
                        if vm_name and vm_name.startswith(target_name)
                    ]
                    if not prefix_matches:
                        logger.warning(f"No MGMT VMs found with prefix '{target_name}'")
                        return "down"
                    matched_vms.extend(prefix_matches)
                else:
                    vm = vm_map.get(target_name)
                    if not vm:
                        logger.warning(f"MGMT VM '{target_name}' not found in PC entities")
                        return "down" # Missing a required VM
                    matched_vms.append(vm)

            # De-duplicate VMs when exact and prefix entries overlap
            unique_matched_vms = []
            seen_vm_names = set()
            for vm in matched_vms:
                vm_name = vm.get('spec', {}).get('name', '')
                if vm_name and vm_name not in seen_vm_names:
                    unique_matched_vms.append(vm)
                    seen_vm_names.add(vm_name)

            for vm in unique_matched_vms:
                vm_name = vm.get('spec', {}).get('name', '')
                power_state = vm.get('status', {}).get('resources', {}).get('power_state', '').upper()
                if power_state not in ['ON', 'POWERED_ON']:
                    logger.warning(f"MGMT VM '{vm_name}' is in power state: {power_state}")
                    return "down"

                # Check reachability if powered on
                ip = vm.get('status', {}).get('resources', {}).get('nic_list', [{}])[0].get('ip_endpoint_list', [{}])[0].get('ip')
                if not ip:
                    logger.warning(f"MGMT VM '{vm_name}' has no IP reported by PC")
                    return "down"

                # Ping via PC_IP as proxy
                proxy_cmd = f"sshpass -p '{os.getenv('SSH_PASS')}' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 {os.getenv('SSH_USER')}@{PC_IP} 'ping -c 1 -W 1 {ip}'"
                res = subprocess.run(proxy_cmd, shell=True, capture_output=True)
                if res.returncode != 0:
                    logger.warning(f"MGMT VM '{vm_name}' ({ip}) failed ping check via {PC_IP}. Output: {res.stdout.decode() + res.stderr.decode()}")
                    return "down"
            
            logger.info("All MGMT VMs are up and reachable")
            return "up"
        else:
            logger.error(f"PC VM list failed with return code {result.returncode}: {result.stderr}")
    except:
        pass
    return "down"

def get_scheduled_pauses():
    if not os.path.exists(SCHEDULED_PAUSES_FILE):
        return []
    try:
        with open(SCHEDULED_PAUSES_FILE, 'r') as f:
            pauses = json.load(f)
            # Sort pauses by start_time
            return sorted(pauses, key=lambda x: x.get('start_time', ''))
    except Exception as e:
        logger.error(f"Error reading scheduled pauses: {e}")
        return []

def save_scheduled_pauses(pauses):
    try:
        with open(SCHEDULED_PAUSES_FILE, 'w') as f:
            json.dump(pauses, f, indent=2)
    except Exception as e:
        logger.error(f"Error saving scheduled pauses: {e}")

def check_scheduled_pauses():
    """Check if any scheduled pause is currently active and manage the lock file"""
    pauses = get_scheduled_pauses()
    now = datetime.now()
    is_paused = False
    active_pause_info = None
    
    for p in pauses:
        try:
            start = datetime.fromisoformat(p['start_time'])
            end = datetime.fromisoformat(p['end_time'])
            if start <= now <= end:
                is_paused = True
                active_pause_info = p
                break
        except Exception as e:
            logger.error(f"Error parsing pause times: {e}")
            continue
    
    if is_paused:
        if not os.path.exists(SCHEDULED_PAUSE_ACTIVE_FILE):
            logger.info(f"Activating scheduled pause: {active_pause_info.get('description', 'No description')}")
            with open(SCHEDULED_PAUSE_ACTIVE_FILE, 'w') as f:
                f.write(json.dumps(active_pause_info))
    else:
        if os.path.exists(SCHEDULED_PAUSE_ACTIVE_FILE):
            logger.info("Deactivating scheduled pause")
            os.remove(SCHEDULED_PAUSE_ACTIVE_FILE)

def perform_status_update():
    """Actually performs the status checks and updates the cache incrementally"""
    if not status_lock.acquire(blocking=False):
        logger.info("Status update already in progress. Skipping duplicate run.")
        return False
        
    try:
        status_meta["update_in_progress"] = True
        status_meta["last_error"] = None

        # 1. Physical Hosts (Fastest)
        cluster_status_cache["hosts"] = check_hosts_status()
        
        # 2. CVMs and PCVMs Reachability
        cluster_status_cache["cvms"] = check_ping(os.getenv("CVM_IPS"))
        
        # If CVMs are down, PE status check will be fast (will fail immediately)
        # Use PE_IP as jump host for PCVMs ONLY if CVMs are up
        jump_host = PE_STATUS_IP if cluster_status_cache["cvms"] == "up" else None
        cluster_status_cache["pcvms"] = check_ping(os.getenv("PCVM_IPS"), jump_host=jump_host)
        
        # 3. Cluster Services (SSH - potentially slow)
        # Only try cluster status if CVMs/PCVMs are pingable to avoid long SSH timeouts
        if cluster_status_cache["pcvms"] == "up":
            cluster_status_cache["pc"] = check_cluster_status(PC_STATUS_IP)
        else:
            cluster_status_cache["pc"] = "down"
            
        if cluster_status_cache["cvms"] == "up":
            cluster_status_cache["pe"] = check_cluster_status(PE_STATUS_IP)
        else:
            cluster_status_cache["pe"] = "down"
            
        # 4. FS and MGMT (Depends on PE/PC being up)
        if cluster_status_cache["pc"] == "up":
            cluster_status_cache["mgmt"] = check_mgmt_status()
        else:
            cluster_status_cache["mgmt"] = "down"
            
        if cluster_status_cache["cvms"] == "up" or cluster_status_cache["pc"] == "up":
            # FSVMs ping check
            fsvms_ping = check_ping(os.getenv("FSVM_IPS"), jump_host=PE_STATUS_IP)
            cluster_status_cache["fsvms"] = fsvms_ping
            
            if fsvms_ping == "up":
                cluster_status_cache["fs"] = check_fs_cluster_status()
            else:
                cluster_status_cache["fs"] = "down"
        else:
            cluster_status_cache["fsvms"] = "down"
            cluster_status_cache["fs"] = "down"
            
        # 5. NKP (Fast if kubectl config is correct)
        cluster_status_cache["nkp"] = check_nkp_status()
        
        status_meta["last_updated"] = int(time.time())
        logger.info(f"Incremental update: {cluster_status_cache}")
        return True
    except Exception as e:
        status_meta["last_error"] = str(e)
        logger.error(f"Error performing status update: {e}")
        return False
    finally:
        status_meta["update_in_progress"] = False
        status_lock.release()

def status_polling_worker():
    """Background worker to update cluster status periodically"""
    while True:
        check_scheduled_pauses()
        perform_status_update()
        time.sleep(30) # Poll every 30 seconds to be gentle on SSH and APIs

# Start background thread
polling_thread = threading.Thread(target=status_polling_worker, daemon=True)
polling_thread.start()

def requires_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        # DISABLE LOGIN: Commented out session check.
        # if not session.get('logged_in'):
        #     logger.info(f"Unauthorized request to {request.path}; redirecting to login")
        #     # Return JSON for AJAX/JSON requests if session expired
        #     is_ajax = request.headers.get('X-Requested-With') == 'XMLHttpRequest' or \
        #               'application/json' in request.headers.get('Accept', '').lower() or \
        #               request.path.startswith('/api/')
        #     
        #     if is_ajax:
        #         return {"error": "Session expired. Please refresh the page and login again."}, 401
        #     return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated

@app.route('/api/run/<script_name>')
@requires_auth
def run_job_api(script_name):
    # Map friendly names to actual script files for security
    script_map = {
        'startup': 'startup_nkp_cluster.sh',
        'shutdown': 'shutdown_nkp_cluster.sh',
        'start_pcvm': 'startup_pcvm.sh',
        'shutdown_pcvm': 'shutdown_pcvm_api.sh',
        'start_pc_cluster': 'start_pc_cluster.sh',
        'stop_pc_cluster': 'stop_pc_cluster.sh',
        'start_cvm': 'startup_cvm.sh',
        'shutdown_cvm': 'shutdown_cvm.sh',
        'start_pe_cluster': 'start_pe_cluster.sh',
        'stop_pe_cluster': 'stop_pe_cluster.sh',
        'start_fs_cluster': 'start_fs_cluster.sh',
        'stop_fs_cluster': 'stop_fs_cluster.sh',
        'start_fsnkp': 'startup_fsnkp.sh',
        'stop_fsnkp': 'shutdown_fsnkp.sh',
        'startup_mgmt_vms': 'startup_mgmt_vms.sh',
        'shutdown_mgmt_vms': 'shutdown_mgmt_vms.sh',
        'shutdown_ahv': 'shutdown_ahv.sh',
        'startup_hosts': 'startup_hosts.sh',
        'shutdown_hosts_redfish': 'shutdown_hosts_redfish.sh',
        'shutdown_all': 'shutdown_all_vms.sh'
    }
    
    script_file = script_map.get(script_name)
    if not script_file:
        return {"error": "Invalid script name"}, 400
        
    return run_job(script_file, script_name)

# Direct routes for backward compatibility
@app.route('/startup')
@requires_auth
def startup(): return run_job_api('startup')

@app.route('/shutdown')
@requires_auth
def shutdown(): return run_job_api('shutdown')

@app.route('/shutdown_all')
@requires_auth
def shutdown_all(): return run_job_api('shutdown_all')

@app.route('/stop_pc_cluster')
@requires_auth
def stop_pc_cluster(): return run_job_api('stop_pc_cluster')

@app.route('/stop_pe_cluster')
@requires_auth
def stop_pe_cluster(): return run_job_api('stop_pe_cluster')

@app.route('/start_pc_cluster')
@requires_auth
def start_pc_cluster(): return run_job_api('start_pc_cluster')

@app.route('/start_pe_cluster')
@requires_auth
def start_pe_cluster(): return run_job_api('start_pe_cluster')

@app.route('/start_fs_cluster')
@requires_auth
def start_fs_cluster(): return run_job_api('start_fs_cluster')

@app.route('/stop_fs_cluster')
@requires_auth
def stop_fs_cluster(): return run_job_api('stop_fs_cluster')

@app.route('/start_fsnkp')
@requires_auth
def start_fsnkp(): return run_job_api('start_fsnkp')

@app.route('/stop_fsnkp')
@requires_auth
def stop_fsnkp(): return run_job_api('stop_fsnkp')

@app.route('/shutdown_cvm')
@requires_auth
def shutdown_cvm(): return run_job_api('shutdown_cvm')

@app.route('/start_cvm')
@requires_auth
def start_cvm(): return run_job_api('start_cvm')

@app.route('/shutdown_pcvm')
@requires_auth
def shutdown_pcvm(): return run_job_api('shutdown_pcvm')

@app.route('/start_pcvm')
@requires_auth
def start_pcvm(): return run_job_api('start_pcvm')

@app.route('/shutdown_ahv')
@requires_auth
def shutdown_ahv(): return run_job_api('shutdown_ahv')

@app.route('/shutdown_hosts_redfish')
@requires_auth
def shutdown_hosts_redfish(): return run_job_api('shutdown_hosts_redfish')

@app.route('/startup_hosts')
@requires_auth
def startup_hosts(): return run_job_api('startup_hosts')

@app.route('/startup_mgmt_vms')
@requires_auth
def startup_mgmt_vms(): return run_job_api('startup_mgmt_vms')

@app.route('/shutdown_mgmt_vms')
@requires_auth
def shutdown_mgmt_vms(): return run_job_api('shutdown_mgmt_vms')

@app.route('/automated_full_startup')
@requires_auth
def automated_full_startup():
    """Run full-stack startup (Help → Startup Sequence); see automated_startup/automated_startup.sh."""
    return run_job(os.path.join('automated_startup', 'automated_startup.sh'), 'automated_full_startup')

@app.route('/automated_full_shutdown')
@requires_auth
def automated_full_shutdown():
    """Run full-stack shutdown (Help → Shutdown Sequence); see automated_shutdown/automated_shutdown.sh."""
    return run_job(os.path.join('automated_shutdown', 'automated_shutdown.sh'), 'automated_full_shutdown')

@app.route('/api/automation/status')
@requires_auth
def automation_status_api():
    """Check if automated scripts are paused."""
    return {
        "paused": os.path.exists(PAUSE_FILE),
        "scheduled_pause_active": os.path.exists(SCHEDULED_PAUSE_ACTIVE_FILE)
    }

@app.route('/api/automation/pause', methods=['POST'])
@requires_auth
def automation_pause_api():
    """Pause automated scripts."""
    try:
        with open(PAUSE_FILE, 'w') as f:
            f.write("paused")
        return {"success": True}
    except Exception as e:
        return {"error": str(e)}, 500

@app.route('/api/automation/unpause', methods=['POST'])
@requires_auth
def automation_unpause_api():
    """Unpause automated scripts."""
    try:
        if os.path.exists(PAUSE_FILE):
            os.remove(PAUSE_FILE)
        return {"success": True}
    except Exception as e:
        return {"error": str(e)}, 500

@app.route('/api/automation/scheduled_pauses', methods=['GET'])
@requires_auth
def list_scheduled_pauses():
    """List all scheduled pauses."""
    include_past = request.args.get('include_past', 'false').lower() == 'true'
    pauses = get_scheduled_pauses()
    now = datetime.now()
    
    if include_past:
        return {"pauses": pauses, "scheduled_pause_active": os.path.exists(SCHEDULED_PAUSE_ACTIVE_FILE)}

    active_pauses = []
    for p in pauses:
        try:
            if datetime.fromisoformat(p.get('end_time')) >= now:
                active_pauses.append(p)
        except:
            active_pauses.append(p)
            
    return {"pauses": active_pauses, "scheduled_pause_active": os.path.exists(SCHEDULED_PAUSE_ACTIVE_FILE)}

@app.route('/api/automation/scheduled_pauses', methods=['POST'])
@requires_auth
def add_scheduled_pause():
    """Add a new scheduled pause."""
    try:
        data = request.json
        start_time = data.get('start_time')
        end_time = data.get('end_time')
        description = data.get('description', '')
        first_name = data.get('first_name', '')
        last_name = data.get('last_name', '')
        email = data.get('email', '')

        if not all([start_time, end_time, description, first_name, last_name, email]):
            return {"error": "All fields (Project, Name, Email, and Times) are required"}, 400

        # Validate format
        dt_start = datetime.fromisoformat(start_time)
        dt_end = datetime.fromisoformat(end_time)

        pauses = get_scheduled_pauses()
        new_pause = {
            "id": str(uuid.uuid4()),
            "start_time": start_time,
            "end_time": end_time,
            "description": description,
            "first_name": first_name,
            "last_name": last_name,
            "email": email,
            "created_at": datetime.now().isoformat()
        }
        pauses.append(new_pause)
        save_scheduled_pauses(pauses)
        
        # Send Slack notification
        msg = (
            f"📅 *New Extended Uptime Reservation Created*\n"
            f"*Description:* {description}\n"
            f"*Requester:* {first_name} {last_name} ({email})\n"
            f"*Start:* {dt_start.strftime('%b %d, %I:%M %p')}\n"
            f"*End:* {dt_end.strftime('%b %d, %I:%M %p')}"
        )
        send_slack_notification(msg)
        
        # Trigger an immediate check
        check_scheduled_pauses()
        
        return {"success": True, "pause": new_pause}
    except Exception as e:
        return {"error": str(e)}, 400

@app.route('/api/automation/scheduled_pauses/<pause_id>', methods=['PUT'])
@requires_auth
def update_scheduled_pause(pause_id):
    """Update an existing scheduled pause."""
    try:
        data = request.json
        start_time = data.get('start_time')
        end_time = data.get('end_time')
        description = data.get('description')
        first_name = data.get('first_name')
        last_name = data.get('last_name')
        email = data.get('email')

        if not all([start_time, end_time, description, first_name, last_name, email]):
            return {"error": "All fields (Project, Name, Email, and Times) are required"}, 400

        pauses = get_scheduled_pauses()
        found = False
        
        for p in pauses:
            if p['id'] == pause_id:
                p['start_time'] = start_time
                p['end_time'] = end_time
                p['description'] = description
                p['first_name'] = first_name
                p['last_name'] = last_name
                p['email'] = email
                p['updated_at'] = datetime.now().isoformat()
                found = True
                break
        
        if not found:
            return {"error": "Pause not found"}, 404
            
        save_scheduled_pauses(pauses)
        check_scheduled_pauses()
        return {"success": True}
    except Exception as e:
        return {"error": str(e)}, 400

@app.route('/api/automation/scheduled_pauses/<pause_id>', methods=['DELETE'])
@requires_auth
def delete_scheduled_pause(pause_id):
    """Delete a scheduled pause."""
    try:
        pauses = get_scheduled_pauses()
        pauses = [p for p in pauses if p['id'] != pause_id]
        save_scheduled_pauses(pauses)
        
        # Trigger an immediate check
        check_scheduled_pauses()
        
        return {"success": True}
    except Exception as e:
        return {"error": str(e)}, 500

@app.after_request
def log_response_info(response):
    message = f"Request: {request.method} {request.path} -> {response.status_code}"
    if response.status_code >= 400:
        logger.warning(message)
    else:
        logger.debug(message)
    return response

@app.route('/api/cluster_status')
@requires_auth
def cluster_status_api():
    logger.info(f"API cluster_status called. Cache: {cluster_status_cache}")
    
    # Check for active scheduled pause
    active_pause = None
    if os.path.exists(SCHEDULED_PAUSE_ACTIVE_FILE):
        try:
            with open(SCHEDULED_PAUSE_ACTIVE_FILE, 'r') as f:
                active_pause = json.load(f)
        except:
            pass

    return {
        "status": cluster_status_cache,
        "meta": status_meta,
        "automation_paused": os.path.exists(PAUSE_FILE),
        "scheduled_pause_active": active_pause
    }

@app.route('/api/cluster_status/refresh', methods=['POST'])
@requires_auth
def cluster_status_refresh_api():
    """Trigger a background status refresh without blocking this request."""
    if status_lock.locked():
        return {"accepted": True, "already_running": True}, 202

    refresh_thread = threading.Thread(target=perform_status_update, daemon=True)
    refresh_thread.start()
    return {"accepted": True, "already_running": False}, 202

# LDAP Configuration (Matched to ntnxlablinks)
LDAP_SERVER = os.getenv('LDAP_SERVER')
LDAP_ADMIN_DN = os.getenv('LDAP_ADMIN_DN')
LDAP_ADMIN_PASSWORD = os.getenv('LDAP_ADMIN_PASS')
LDAP_USER_SEARCH_BASE = os.getenv('LDAP_USER_SEARCH_BASE')
LDAP_USER_ATTRIBUTE = os.getenv('LDAP_USER_ATTRIBUTE')

# Local Fallback Configuration
AUTH_USERNAME = os.getenv('AUTH_USERNAME')
AUTH_PASSWORD = os.getenv('AUTH_PASSWORD')

def check_ldap_auth(username, password):
    if not username or not password:
        return False
    
    try:
        server = Server(LDAP_SERVER, get_info=ALL)
        # 1. Bind as Admin
        admin_conn = Connection(server, user=LDAP_ADMIN_DN, password=LDAP_ADMIN_PASSWORD, authentication='SIMPLE')
        if not admin_conn.bind():
            logger.error(f"LDAP Admin bind failed for {LDAP_ADMIN_DN}")
            return False
            
        # 2. Search for User DN
        search_filter = f"({LDAP_USER_ATTRIBUTE}={username})"
        admin_conn.search(LDAP_USER_SEARCH_BASE, search_filter, attributes=[])
        
        if not admin_conn.entries:
            admin_conn.unbind()
            logger.warning(f"LDAP user not found: {username}")
            return False
            
        # 3. Extract User DN
        user_dn = admin_conn.entries[0].entry_dn
        admin_conn.unbind()
        
        # 4. Verify User Credentials
        user_conn = Connection(server, user=user_dn, password=password, authentication='SIMPLE')
        if user_conn.bind():
            logger.info(f"LDAP auth success for {username}")
            user_conn.unbind()
            return True
        
        return False
            
    except Exception as e:
        logger.error(f"LDAP Error: {e}")
        return False

@app.route('/login', methods=['GET', 'POST'])
def login():
    # DISABLE LOGIN: Redirect to index immediately. 
    # To re-enable, remove the redirect line below.
    return redirect(url_for('index'))
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        auth_type = request.form.get('auth_type', 'ldap')
        
        authenticated = False
        if auth_type == 'ldap':
            if check_ldap_auth(username, password):
                authenticated = True
        else:
            if username == AUTH_USERNAME and password == AUTH_PASSWORD:
                authenticated = True
                
        if authenticated:
            logger.info(f"User '{username}' authenticated successfully via {auth_type}. Setting session.")
            session.permanent = True
            session['logged_in'] = True
            session['username'] = username
            # Force session save by modifying it
            session.modified = True
            logger.info(f"Redirecting '{username}' to index. Session data: {dict(session)}")
            return redirect(url_for('index'))
        else:
            logger.warning(f"Login failed for user '{username}' via {auth_type}.")
            flash('Invalid username or password')
            
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.clear()
    return redirect(LOGOUT_REDIRECT_URL)

@app.route('/api/recover_nai_token', methods=['POST'])
@requires_auth
def recover_nai_token():
    """Update NAI registry token and refresh pods."""
    data = request.json
    token = data.get('token')
    if not token:
        return {"error": "Token is required"}, 400
    
    return run_job('update_nai_token.sh', 'recover_nai_token', args=[token])

@app.route('/recover_cluster_pods')
@requires_auth
def recover_cluster_pods():
    """Run NKP cluster recovery script."""
    return run_job('./recover_nkp_cluster.sh', 'recover_cluster_pods')

@app.route('/admin')
@requires_auth
def admin():
    return render_template('admin.html', admin_password=os.getenv('ADMIN_PASSWORD'))

@app.route('/')
@requires_auth
def index():
    return render_template('index.html', console_base_url=os.getenv("CONSOLE_BASE_URL"))

import uuid

# Global job store
jobs = {}

class Job:
    def __init__(self, script_path, script_name=None, args=None):
        self.id = str(uuid.uuid4())
        self.script_path = script_path
        self.script_name = script_name
        self.args = args or []
        self.status = "running"
        self.output = "🚀 Starting operation...\n\n"
        self.exit_code = None
        self.start_time = time.time()
        self.thread = threading.Thread(target=self._run)
        self.thread.start()

    def _run(self):
        try:
            cmd = ['/bin/bash', self.script_path] + self.args
            process = subprocess.Popen(cmd, 
                                     stdout=subprocess.PIPE, 
                                     stderr=subprocess.STDOUT,
                                     stdin=subprocess.PIPE,
                                     text=True,
                                     bufsize=1,
                                     universal_newlines=True)
            
            # Automatically send "yes" to the script if it prompts for confirmation
            try:
                process.stdin.write("yes\n")
                process.stdin.flush()
            except:
                pass
            
            for line in process.stdout:
                with jobs_lock:
                    self.output += line
            
            process.wait()
            with jobs_lock:
                self.exit_code = process.returncode
                self.status = "completed"
                self.output += f"\n--- Script completed with exit code {self.exit_code} ---\n"
        except Exception as e:
            with jobs_lock:
                self.status = "failed"
                self.output += f"\n❌ System Error: {str(e)}\n"

def run_job(script_file, script_name=None, args=None):
    script_path = os.path.join(os.path.dirname(__file__), script_file)
    job = Job(script_path, script_name, args)
    with jobs_lock:
        jobs[job.id] = job
    return {"job_id": job.id}

@app.route('/api/job_status/<job_id>')
@requires_auth
def job_status(job_id):
    if job_id == "external_shutdown":
        if os.path.exists(AUTOMATED_SHUTDOWN_STATUS_FILE):
            try:
                with open(AUTOMATED_SHUTDOWN_STATUS_FILE, 'r') as f:
                    output = f.read()
                return {
                    "id": "external_shutdown",
                    "status": "running",
                    "output": output,
                    "exit_code": None,
                    "script_name": "automated_full_shutdown"
                }
            except Exception as e:
                return {"error": str(e)}, 500
        else:
            return {
                "id": "external_shutdown",
                "status": "completed",
                "output": "--- External script finished ---",
                "exit_code": 0,
                "script_name": "automated_full_shutdown"
            }
    
    if job_id == "external_startup":
        if os.path.exists(AUTOMATED_STARTUP_STATUS_FILE):
            try:
                with open(AUTOMATED_STARTUP_STATUS_FILE, 'r') as f:
                    output = f.read()
                return {
                    "id": "external_startup",
                    "status": "running",
                    "output": output,
                    "exit_code": None,
                    "script_name": "automated_full_startup"
                }
            except Exception as e:
                return {"error": str(e)}, 500
        else:
            return {
                "id": "external_startup",
                "status": "completed",
                "output": "--- External script finished ---",
                "exit_code": 0,
                "script_name": "automated_full_startup"
            }

    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            return {"error": "Job not found"}, 404
        return {
            "id": job.id,
            "status": job.status,
            "output": job.output,
            "exit_code": job.exit_code,
            "script_name": job.script_name
        }

@app.route('/api/active_jobs')
@requires_auth
def active_jobs():
    with jobs_lock:
        active = []
        for job_id, job in jobs.items():
            if job.status == "running":
                active.append({
                    "id": job_id,
                    "script_name": job.script_name,
                    "start_time": job.start_time
                })
        
        # Check for external automated shutdown
        if os.path.exists(AUTOMATED_SHUTDOWN_STATUS_FILE):
            # Check if it's already in active (triggered via UI)
            is_already_tracked = False
            for job in active:
                if job['script_name'] == 'automated_full_shutdown':
                    is_already_tracked = True
                    break
            
            if not is_already_tracked:
                # Add a "mock" job for the external process
                mtime = os.path.getmtime(AUTOMATED_SHUTDOWN_STATUS_FILE)
                active.append({
                    "id": "external_shutdown",
                    "script_name": "automated_full_shutdown",
                    "start_time": mtime
                })

        # Check for external automated startup
        if os.path.exists(AUTOMATED_STARTUP_STATUS_FILE):
            is_already_tracked = False
            for job in active:
                if job['script_name'] == 'automated_full_startup':
                    is_already_tracked = True
                    break
            
            if not is_already_tracked:
                mtime = os.path.getmtime(AUTOMATED_STARTUP_STATUS_FILE)
                active.append({
                    "id": "external_startup",
                    "script_name": "automated_full_startup",
                    "start_time": mtime
                })

        # Sort by start time, newest first
        active.sort(key=lambda x: x['start_time'], reverse=True)
        return {"active_jobs": active}

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5005, debug=True)
