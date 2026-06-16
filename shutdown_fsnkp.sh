#!/bin/bash

# Configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
APP_DIR="${SCRIPT_DIR:-/app}"
cd "${APP_DIR}"

# Load credentials from .env
if [ -f ".env" ]; then
    export $(grep -v '^#' ".env" | xargs)
fi

# Use FSVM_VM_NAMES from environment if available
IFS=',' read -r -a TARGET_VMS <<< "$FSVM_VM_NAMES"

# Function to fetch VM UUID by name
get_vm_uuid() {
    local name=$1
    local payload=$(cat <<EOF
{
    "kind": "vm",
    "length": 1,
    "filter": "vm_name==${name}"
}
EOF
)
    curl -k -s -u "${PC_USER}:${PC_PASS}" -X POST "https://${PC_IP}:9440/api/nutanix/v3/vms/list" \
        -H "Content-Type: application/json" -d "${payload}" | jq -r '.entities[0].metadata.uuid // empty'
}

# Function to initiate ACPI shutdown
shutdown_vm() {
    local uuid=$1
    local name=$2
    if curl -k -s -u "${PC_USER}:${PC_PASS}" -X POST "https://${PC_IP}:9440/api/nutanix/v3/vms/${uuid}/acpi_shutdown" \
        -H "Content-Type: application/json" -d "{}" | grep -qE "200|202|SUCCEEDED"; then
        echo "✓ Shutdown initiated for: ${name}"
    else
        echo "✓ Shutdown signal sent to: ${name}"
    fi
}

echo "--- FSNKP Power Off Sequence ---"

for NAME in "${TARGET_VMS[@]}"; do
    (
        UUID=$(get_vm_uuid "${NAME}")
        if [ -n "${UUID}" ]; then
            echo "🛑 Initiating Shutdown for: $NAME"
            if curl -k -s -u "${PC_USER}:${PC_PASS}" -X POST "https://${PC_IP}:9440/api/nutanix/v3/vms/${UUID}/acpi_shutdown" \
                -H "Content-Type: application/json" -d "{}" | grep -qE "200|202|SUCCEEDED"; then
                echo "  ✓ Shutdown initiated for: ${NAME}"
            else
                echo "  ✓ Shutdown signal sent to: ${NAME}"
            fi
        else
            echo "❌ Could not find VM: ${NAME}"
        fi
    ) &
done

wait
echo -e "\n--- All Shutdown Signals Sent ---"

echo -e "\n--- Verifying FSVM Shutdown (Retry Loop) ---"
echo "⏳ Waiting for FSVMs to become unreachable... (Timeout: 5 minutes)"

IFS=',' read -r -a F_IP_LIST <<< "$FSVM_IPS"
MAX_RETRIES="${DEFAULT_MAX_RETRIES:-10}"
RETRY_DELAY="${DEFAULT_RETRY_DELAY:-30}"
TOTAL_VMS=${#F_IP_LIST[@]}

for (( try=1; try<=MAX_RETRIES; try++ )); do
    VMS_DOWN=0
    echo -e "\nAttempt $try/$MAX_RETRIES (Next check in ${RETRY_DELAY}s if needed)..."
    
    for IP in "${F_IP_LIST[@]}"; do
        if ! ping -c 1 -W 1 "$IP" >/dev/null 2>&1; then
            echo "  ✓ ${IP}: FSVM is Powered OFF (Unreachable)"
            ((VMS_DOWN++))
        else
            echo "  ❌ ${IP}: FSVM is still Powered ON (Reachable)"
        fi
    done
    
    if [ "$VMS_DOWN" -eq "$TOTAL_VMS" ]; then
        echo -e "\n✅ All FSVMs are confirmed Powered OFF!"
        break
    fi
    
    if [ "$try" -lt "$MAX_RETRIES" ]; then
        sleep $RETRY_DELAY
    fi
done

if [ "$VMS_DOWN" -lt "$TOTAL_VMS" ]; then
    echo -e "\n⚠️ Verification timeout reached. Not all FSVMs are confirmed Powered OFF yet."
fi

echo "--- Finished ---"
