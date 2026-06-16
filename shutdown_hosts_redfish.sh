#!/bin/bash

# Configuration
APP_DIR="/app"
cd "${APP_DIR}"

# Load credentials from .env
if [ -f "${APP_DIR}/.env" ]; then
    export $(grep -v '^#' "${APP_DIR}/.env" | xargs)
fi

# Use environment variables
IFS=',' read -r -a CIMC_HOSTS <<< "$CIMC_HOSTS"

echo "--- Global Host Power Off Tool (CIMC Redfish) ---"

for host in "${CIMC_HOSTS[@]}"; do
    echo "Processing $host..."
    
    # 1. Discover the ComputerSystem ID dynamically
    SYSTEM_DATA=$(curl -k -s -u "${CIMC_USER}:${CIMC_PASS}" -X GET "https://${host}/redfish/v1/Systems")
    SYSTEM_PATH=$(echo "$SYSTEM_DATA" | jq -r '.Members[0]["@odata.id"]')

    if [[ -z "$SYSTEM_PATH" || "$SYSTEM_PATH" == "null" ]]; then
        echo "✗ Failed to discover SystemId for $host"
        continue
    fi
    
    # 1.5 Check PowerState
    POWER_STATE=$(curl -k -s -u "${CIMC_USER}:${CIMC_PASS}" -X GET "https://${host}${SYSTEM_PATH}" | jq -r '.PowerState')
    
    if [[ "$POWER_STATE" == "Off" ]]; then
        echo "○ Skipping $host: Already Powered Off"
        continue
    fi
    
    echo "Sending ForceOff request to ${host}${SYSTEM_PATH}..."
    
    # 2. Redfish Power Off action
    RESPONSE=$(curl -k -s -u "${CIMC_USER}:${CIMC_PASS}" \
        -X POST "https://${host}${SYSTEM_PATH}/Actions/ComputerSystem.Reset" \
        -H "Content-Type: application/json" \
        -d '{"ResetType": "ForceOff"}')
    
    if [[ $? -eq 0 ]]; then
        echo "✓ Shutdown request sent to $host"
    else
        echo "✗ Failed to send request to $host"
    fi
done

echo -e "\n--- Verifying Host Shutdown (Retry Loop) ---"
echo "⏳ Waiting for hosts to become unreachable... (Timeout: 10 minutes)"

MAX_RETRIES="${DEFAULT_MAX_RETRIES:-20}"
RETRY_DELAY="${DEFAULT_RETRY_DELAY:-30}"
IFS=',' read -r -a AHV_IPS_ARRAY <<< "$AHV_IPS"
unset IFS
TOTAL_HOSTS=${#AHV_IPS_ARRAY[@]}

for (( try=1; try<=MAX_RETRIES; try++ )); do
    HOSTS_DOWN=0
    echo -e "\nAttempt $try/$MAX_RETRIES (Next check in ${RETRY_DELAY}s if needed)..."
    
    for IP in "${AHV_IPS_ARRAY[@]}"; do
        IP=$(echo "$IP" | xargs)
        if ! ping -c 1 -W 1 "$IP" >/dev/null 2>&1; then
            echo "  ✓ ${IP}: Host is Powered OFF (Unreachable)"
            ((HOSTS_DOWN++))
        else
            echo "  ❌ ${IP}: Host is still Powered ON (Reachable)"
        fi
    done
    
    if [ "$HOSTS_DOWN" -eq "$TOTAL_HOSTS" ]; then
        echo -e "\n✅ All hosts are confirmed Powered OFF!"
        break
    fi
    
    if [ "$try" -lt "$MAX_RETRIES" ]; then
        sleep $RETRY_DELAY
    fi
done

if [ "$HOSTS_DOWN" -lt "$TOTAL_HOSTS" ]; then
    echo -e "\n⚠️ Verification timeout reached. Some hosts may still be powering off."
fi

echo -e "\nSummary: All Power Off requests processed and verified."
