#!/bin/bash

# Configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
APP_DIR="${SCRIPT_DIR:-/app}"
cd "${APP_DIR}"

# Load credentials from .env
if [ -f ".env" ]; then
    export $(grep -v '^#' ".env" | xargs)
fi

# Use SSHPASS from environment
export SSHPASS="${SSH_PASS}"

# Use FSVM_VM_NAMES from environment if available
IFS=',' read -r -a TARGET_VMS <<< "$FSVM_VM_NAMES"

# Function to fetch VM UUID by name from PE (v2.0)
get_vm_uuid_from_pe() {
    local name=$1
    # PE v2.0 list VMs and filter by name
    curl -k -s -u "${PE_USER}:${PE_PASS}" "https://${PE_IP}:9440/api/nutanix/v2.0/vms/?filter=vm_name%3D%3D${name}" | jq -r '.entities[0].uuid // empty'
}

# Function to power on a VM via PE (v2.0)
power_on_vm_pe() {
    local uuid=$1
    local name=$2
    
    # Get current state via PE
    local state=$(curl -k -s -u "${PE_USER}:${PE_PASS}" "https://${PE_IP}:9440/api/nutanix/v2.0/vms/${uuid}" | jq -r '.power_state')
    
    if [ "$state" == "on" ] || [ "$state" == "ON" ]; then
        echo "✅ ${name} is already ON."
        return 0
    fi

    # Update state to ON using POST /set_power_state
    local response=$(curl -k -s -u "${PE_USER}:${PE_PASS}" -X POST "https://${PE_IP}:9440/api/nutanix/v2.0/vms/${uuid}/set_power_state" \
        -H "Content-Type: application/json" \
        -d '{"transition": "ON"}')
    
    if echo "$response" | grep -qE "task_uuid|SUCCEEDED"; then
        echo "🚀 Power ON initiated via PE for: ${name}"
    else
        echo "❌ Failed to power on ${name} via PE. Response: ${response}"
    fi
}

echo "--- FSNKP Power On Sequence (via Prism Element) ---"

for NAME in "${TARGET_VMS[@]}"; do
    UUID=$(get_vm_uuid_from_pe "${NAME}")
    if [ -n "${UUID}" ] && [ "${UUID}" != "null" ]; then
        power_on_vm_pe "${UUID}" "${NAME}"
    else
        echo "❌ Could not find VM on PE: ${NAME}"
    fi
done

echo -e "\n--- Verifying FSVM Status (Retry Loop) ---"
echo "⏳ Waiting for FSVMs to become reachable... (Timeout: 10 minutes)"

IFS=',' read -r -a F_IP_LIST <<< "$FSVM_IPS"
MAX_RETRIES="${DEFAULT_MAX_RETRIES:-20}"
RETRY_DELAY="${DEFAULT_RETRY_DELAY:-30}"
TOTAL_VMS=${#F_IP_LIST[@]}

for (( try=1; try<=MAX_RETRIES; try++ )); do
    VMS_UP=0
    echo -e "\nAttempt $try/$MAX_RETRIES (Next check in ${RETRY_DELAY}s if needed)..."
    
    for IP in "${F_IP_LIST[@]}"; do
        # We ping via PC IP because that's where the jump host logic usually lives in these scripts,
        # but the power-on itself is now handled by PE.
        if sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${PC_IP}" "ping -c 1 -W 1 $IP" >/dev/null 2>&1; then
            echo "  ✓ ${IP}: FSVM Reachable (via PC @ ${PC_IP})"
            ((VMS_UP++))
        else
            echo "  ❌ ${IP}: FSVM Unreachable (Ping from PC @ ${PC_IP})"
        fi
    done
    
    if [ "$VMS_UP" -eq "$TOTAL_VMS" ]; then
        echo -e "\n✅ All FSVMs are confirmed reachable!"
        break
    fi
    
    if [ "$try" -lt "$MAX_RETRIES" ]; then
        sleep $RETRY_DELAY
    fi
done

if [ "$VMS_UP" -lt "$TOTAL_VMS" ]; then
    echo -e "\n⚠️ Verification timeout reached. Not all FSVMs are confirmed reachable yet."
fi

echo "--- Finished ---"
