import paramiko
import sys
import os
import time
from dotenv import load_dotenv

# Load credentials from .env
load_dotenv(override=True)

# List of CVMs for the jump host
env_cvm_ips = os.getenv("CVM_IPS")
CVM_IPS = [ip.strip() for ip in env_cvm_ips.split(",")] if env_cvm_ips else []
# List of FSVMs to send the command
env_fsvm_ips = os.getenv("FSVM_IPS")
FSVM_IPS = [ip.strip() for ip in env_fsvm_ips.split(",")] if env_fsvm_ips else []

# Credentials from .env
# Jump (CVM) credentials - try both sets from .env if needed
PE_USER = os.getenv("PE_USER")
PE_PASS = os.getenv("PE_PASS")
SSH_USER = os.getenv("SSH_USER")
SSH_PASS = os.getenv("SSH_PASS")

# FSVM credentials
FSVM_USER = os.getenv("FSVM_USER")
FSVM_PASS = os.getenv("FSVM_PASS")

def establish_connection(cvm_ip, fsvm_ip):
    """Tries to connect through a CVM to an FSVM."""
    try:
        # 1. Connect to Jump Host (CVM)
        print(f"DEBUG: Attempting to connect to CVM jump host {cvm_ip}...")
        jump_client = paramiko.SSHClient()
        jump_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        
        # Try different credential pairs if they differ
        jump_auth_success = False
        creds_to_try = [
            (SSH_USER, SSH_PASS),
            (PE_USER, PE_PASS)
        ]
        
        for user, passwd in creds_to_try:
            try:
                jump_client.connect(cvm_ip, username=user, password=passwd, timeout=10)
                print(f"DEBUG: CVM Jump Host {cvm_ip} Authentication Successful (user: {user}).")
                jump_auth_success = True
                break
            except paramiko.AuthenticationException:
                continue
            except Exception as e:
                print(f"DEBUG: CVM connection error: {e}")
                break
                
        if not jump_auth_success:
            return None, None
            
        # 2. Open Transport through CVM to FSVM
        print(f"DEBUG: Opening direct-tcpip tunnel through {cvm_ip} to {fsvm_ip}:22...")
        jump_transport = jump_client.get_transport()
        dest_addr = (fsvm_ip, 22)
        local_addr = (cvm_ip, 22)
        channel = jump_transport.open_channel("direct-tcpip", dest_addr, local_addr)
        
        # 3. Connect to FSVM via Channel
        print(f"DEBUG: Connecting to FSVM at {fsvm_ip} via tunnel...")
        fsvm_client = paramiko.SSHClient()
        fsvm_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        fsvm_client.connect(fsvm_ip, username=FSVM_USER, password=FSVM_PASS, sock=channel)
        print(f"DEBUG: FSVM {fsvm_ip} Authentication Successful.")
        
        return jump_client, fsvm_client
    except Exception as e:
        print(f"DEBUG: Failed to establish multi-hop connection: {e}")
        return None, None

def run_fsvm_operation(operation):
    """Iterates through CVMs and FSVMs to find a working path and run the command."""
    if operation == "stop":
        # FSVM 'cluster stop' needs 'y' and 'I agree'
        command = "printf 'y\\nI agree\\n' | bash -l -c 'cluster stop'"
    elif operation == "start":
        # 'cluster start'
        command = "bash -l -c 'cluster start'"
    elif operation == "status":
        # 'cluster status'
        command = "bash -l -c 'cluster status'"
    else:
        print(f"Error: Unknown operation {operation}")
        return False
        
    for cvm in CVM_IPS:
        for fsvm in FSVM_IPS:
            print(f"\n--- Trying CVM: {cvm} -> FSVM: {fsvm} ---")
            jump_client, fsvm_client = establish_connection(cvm, fsvm)
            
            if fsvm_client:
                try:
                    if operation != "status":
                        print(f"Executing '{operation}' on FS cluster via {fsvm}...")
                    
                    stdin, stdout, stderr = fsvm_client.exec_command(command, get_pty=True)
                    
                    # Stream output
                    status_full_output = ""
                    for line in stdout:
                        line_text = line.strip()
                        print(line_text)
                        status_full_output += line_text + "\n"
                        
                    fsvm_client.close()
                    jump_client.close()
                    
                    if operation != "status":
                        print(f"✅ FS Operation '{operation}' successfully initiated via {fsvm}.")
                    else:
                        # Return success only if cluster is actually UP/starting and no DOWN services
                        # Matches app.py logic
                        summary_up = "The state of the cluster is UP" in status_full_output or \
                                    "The state of the cluster: start" in status_full_output or \
                                    "Cluster status: UP" in status_full_output
                        has_down = "DOWN" in status_full_output.upper()
                        has_up = "UP" in status_full_output.upper()
                        
                        if summary_up and has_up and not has_down:
                            return True
                        else:
                            # Try next CVM/FSVM combination if this one says it's down but we want to be sure
                            print(f"DEBUG: {fsvm} reports cluster not fully UP yet. Trying next...")
                            continue

                    return True
                except Exception as e:
                    print(f"ERROR executing command: {e}")
                    fsvm_client.close()
                    jump_client.close()
            else:
                print(f"⚠️  Could not reach {fsvm} through {cvm}, trying next combination...")
                
    return False

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 fsvm_mgr.py <start|stop|status>")
        sys.exit(1)
        
    op = sys.argv[1].lower()
    if op not in ["start", "stop", "status"]:
        print("Error: operation must be 'start', 'stop' or 'status'")
        sys.exit(1)
        
    if run_fsvm_operation(op):
        sys.exit(0)
    else:
        sys.exit(1)
