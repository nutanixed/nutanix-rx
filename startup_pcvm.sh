#!/bin/bash

# Configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
APP_DIR="${SCRIPT_DIR:-/app}"
cd "${APP_DIR}"

# Load credentials from .env
if [ -f ".env" ]; then
    export $(grep -v '^#' ".env" | xargs)
fi

# Use environment variables
export SSHPASS="${SSH_PASS}"

# Function to fetch VMs by prefix from PE
get_vm_list() {
    # Using v2 API as it is more reliable for simple VM lists from PE
    curl -k -s -u "${PE_USER}:${PE_PASS}" "https://${PE_IP}:9440/api/nutanix/v2.0/vms"
}

# Function to power on a VM
power_on_vm() {
    local uuid=$1
    local name=$2
    
    # Check current power state via v2 API
    local power_state=$(curl -k -s -u "${PE_USER}:${PE_PASS}" "https://${PE_IP}:9440/api/nutanix/v2.0/vms/${uuid}" | jq -r '.power_state')
    
    if [[ "$power_state" == "on" || "$power_state" == "ON" ]]; then
        echo "✅ ${name} is already ON."
        return 0
    fi

    echo "Initiating Power On for: ${name}"
    curl -k -s -u "${PE_USER}:${PE_PASS}" -X POST "https://${PE_IP}:9440/api/nutanix/v2.0/vms/${uuid}/set_power_state" \
        -H "Content-Type: application/json" -d '{"transition": "ON"}' > /dev/null
}

echo "--- PCVM Cluster Power On Sequence ---"

# Target pattern from environment or default
PATTERN="PCVM"

VMS_JSON=$(get_vm_list)
while read -r vm_info; do
    uuid=$(echo "$vm_info" | cut -d'|' -f1)
    name=$(echo "$vm_info" | cut -d'|' -f2)
    
    if [[ -n "${uuid}" && "${uuid}" != "null" ]]; then
        power_on_vm "${uuid}" "${name}"
    fi
done < <(echo "$VMS_JSON" | jq -r --arg pat "$PATTERN" '.entities[] | select(.name | contains($pat)) | .uuid + "|" + .name')

echo -e "\n--- Verifying PCVM Status (Retry Loop) ---"
echo "⏳ Waiting for PCVMs to become reachable... (Timeout: 10 minutes)"

IFS=',' read -r -a PC_IP_LIST <<< "$PCVM_IPS"
unset IFS
MAX_RETRIES="${DEFAULT_MAX_RETRIES:-20}"
RETRY_DELAY="${DEFAULT_RETRY_DELAY:-30}"
TOTAL_VMS=${#PC_IP_LIST[@]}

for (( try=1; try<=MAX_RETRIES; try++ )); do
    VMS_UP=0
    echo -e "\nAttempt $try/$MAX_RETRIES (Next check in ${RETRY_DELAY}s if needed)..."
    
    for IP in "${PC_IP_LIST[@]}"; do
        IP=$(echo "$IP" | xargs)
        if [[ -z "$IP" ]]; then continue; fi
        # We ping the PCVM from the PE CVM since the container may not have direct access
        if sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${PE_IP}" "ping -c 1 -W 1 $IP" >/dev/null 2>&1; then
            echo "  ✓ ${IP}: PCVM Reachable (via PE @ ${PE_IP})"
            ((VMS_UP++))
        else
            echo "  ❌ ${IP}: PCVM Unreachable (Ping from PE @ ${PE_IP})"
        fi
    done
    
    if [ "$VMS_UP" -eq "$TOTAL_VMS" ]; then
        echo -e "\n✅ All PCVMs are confirmed reachable!"
        break
    fi
    
    if [ "$try" -lt "$MAX_RETRIES" ]; then
        sleep $RETRY_DELAY
    fi
done

if [ "$VMS_UP" -lt "$TOTAL_VMS" ]; then
    echo -e "\n⚠️ Verification timeout reached. Not all PCVMs are confirmed reachable yet."
fi

echo "--- Finished ---"
