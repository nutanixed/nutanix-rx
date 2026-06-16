#!/bin/bash

# Configuration
# Detect script directory for local execution, fallback to /app for container
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
APP_DIR="${SCRIPT_DIR:-/app}"
cd "${APP_DIR}"

# Load credentials from .env
if [ -f ".env" ]; then
    export $(grep -v '^#' ".env" | xargs)
fi

echo "--- Shutdown PCVMs via Nutanix v3 API ---"

# 1. Fetch VM list from Prism Element
echo "🔍 Fetching VM list from PE (${PE_IP})..."
VM_LIST=$(curl -k -s -u "${PE_USER}:${PE_PASS}" -X POST "https://${PE_IP}:9440/api/nutanix/v3/vms/list" \
    -H "Content-Type: application/json" -d '{"kind": "vm", "length": 500}')

# 2. Filter for PCVMs and extract UUIDs
# Use PCVM_IPS from environment if available
IFS=',' read -r -a TARGET_IPS <<< "$PCVM_IPS"
TARGET_PATTERN="PCVM"

# Convert array to jq compatible list for matching
JQ_IPS_LIST=$(printf ',"%s"' "${TARGET_IPS[@]}")
JQ_IPS_LIST="[${JQ_IPS_LIST:1}]"

PCVM_UUIDS=$(echo "$VM_LIST" | jq -r --arg pattern "$TARGET_PATTERN" --argjson ips "$JQ_IPS_LIST" '
    .entities[] | 
    select((.spec.name | test($pattern; "i")) or 
           (.status.resources.nic_list[].ip_endpoint_list[].ip | IN($ips[]))) | 
    .metadata.uuid + "|" + .spec.name + "|" + .status.resources.power_state
')

if [ -z "$PCVM_UUIDS" ]; then
    echo "⚠️ No PCVMs found via API."
    exit 0
fi

# 3. Shutdown loop
while read -r line; do
    UUID=$(echo "$line" | cut -d'|' -f1)
    NAME=$(echo "$line" | cut -d'|' -f2)
    POWER_STATE=$(echo "$line" | cut -d'|' -f3 | tr '[:lower:]' '[:upper:]')
    
    if [[ "$POWER_STATE" == "ON" || "$POWER_STATE" == "POWERED_ON" ]]; then
        echo "🛑 Initiating ACPI shutdown for ${NAME} (${UUID})..."
        curl -k -s -u "${PE_USER}:${PE_PASS}" -X POST "https://${PE_IP}:9440/api/nutanix/v2.0/vms/${UUID}/set_power_state" \
            -H "Content-Type: application/json" -d '{"transition": "ACPI_SHUTDOWN"}' > /dev/null
        
        if [ $? -eq 0 ]; then
            echo "  ✓ Shutdown signal sent."
        else
            echo "  ❌ Failed to send shutdown signal."
        fi
    else
        echo "○ Skipping ${NAME}: Already ${POWER_STATE}"
    fi
done <<< "$PCVM_UUIDS"

echo -e "\n--- Verifying PCVM Shutdown (Retry Loop) ---"
echo "⏳ Waiting for PCVMs to become unreachable... (Timeout: 5 minutes)"

MAX_RETRIES="${DEFAULT_MAX_RETRIES:-10}"
RETRY_DELAY="${DEFAULT_RETRY_DELAY:-30}"
TOTAL_VMS=${#TARGET_IPS[@]}

for (( try=1; try<=MAX_RETRIES; try++ )); do
    VMS_DOWN=0
    echo -e "\nAttempt $try/$MAX_RETRIES (Next check in ${RETRY_DELAY}s if needed)..."
    
    for IP in "${TARGET_IPS[@]}"; do
        if ! ping -c 1 -W 1 "$IP" >/dev/null 2>&1; then
            echo "  ✓ ${IP}: PCVM is Powered OFF (Unreachable)"
            ((VMS_DOWN++))
        else
            echo "  ❌ ${IP}: PCVM is still Powered ON (Reachable)"
        fi
    done
    
    if [ "$VMS_DOWN" -eq "$TOTAL_VMS" ]; then
        echo -e "\n✅ All PCVMs are confirmed Powered OFF!"
        break
    fi
    
    if [ "$try" -lt "$MAX_RETRIES" ]; then
        sleep $RETRY_DELAY
    fi
done

if [ "$VMS_DOWN" -lt "$TOTAL_VMS" ]; then
    echo -e "\n⚠️ Verification timeout reached. Not all PCVMs are confirmed Powered OFF yet."
fi

echo "✅ PCVM API Shutdown sequence completed."
