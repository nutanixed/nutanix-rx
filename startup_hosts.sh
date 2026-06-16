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

# Use environment variables
IFS=',' read -r -a CIMC_HOSTS <<< "$CIMC_HOSTS"
IFS=',' read -r -a AHV_IPS <<< "$AHV_IPS"
IFS=',' read -r -a CVM_IPS_MAP <<< "$CVM_IPS"

echo "--- Global Host Power On Tool (CIMC Redfish) ---"
echo "⚠️  Note: Physical hosts can take up to 10 minutes to boot AHV and start the CVM."
echo ""

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
    
    if [[ "$POWER_STATE" == "On" ]]; then
        echo "○ Skipping $host: Already Powered On"
        continue
    fi
    
    echo "Sending Power On request to ${host}${SYSTEM_PATH}..."
    
    # 2. Redfish Power On action
    RESPONSE=$(curl -k -s -u "${CIMC_USER}:${CIMC_PASS}" \
        -X POST "https://${host}${SYSTEM_PATH}/Actions/ComputerSystem.Reset" \
        -H "Content-Type: application/json" \
        -d '{"ResetType": "On"}')
    
    if [[ $? -eq 0 ]]; then
        echo "✓ Power On request sent to $host"
    else
        echo "✗ Failed to send request to $host"
    fi
done

echo -e "\n--- Verifying AHV & CVM Status (Retry Loop) ---"
echo "⏳ Waiting for AHV hosts to become reachable... (Timeout: 15 minutes)"

MAX_RETRIES="${DEFAULT_MAX_RETRIES:-30}"
RETRY_DELAY="${DEFAULT_RETRY_DELAY:-30}"
TOTAL_HOSTS=${#AHV_IPS[@]}

for (( try=1; try<=MAX_RETRIES; try++ )); do
    HOSTS_UP=0
    echo -e "\nAttempt $try/$MAX_RETRIES (Next check in ${RETRY_DELAY}s if needed)..."
    
    for i in "${!AHV_IPS[@]}"; do
        AHV_IP="${AHV_IPS[$i]}"
        CVM_IP="${CVM_IPS_MAP[$i]}"
        
        AHV_REACHABLE=false
        CVM_ONLINE=false
        
        # 1. Check AHV Reachability via Ping or SSH Port 22
        if ping -c 1 -W 1 "$AHV_IP" >/dev/null 2>&1; then
            echo "  ✓ ${AHV_IP}: AHV Reachable (Ping)"
            AHV_REACHABLE=true
        elif sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 "${SSH_USER}@${AHV_IP}" "exit" >/dev/null 2>&1; then
            echo "  ✓ ${AHV_IP}: AHV Reachable (via SSH Check)"
            AHV_REACHABLE=true
        else
            echo "  ❌ ${AHV_IP}: AHV Unreachable"
        fi
        
        # 2. Check CVM Reachability via Ping or SSH Check
        if ping -c 1 -W 1 "$CVM_IP" >/dev/null 2>&1; then
            echo "    ✓ ${CVM_IP}: CVM ONLINE (Ping)"
            CVM_ONLINE=true
        elif sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 "${SSH_USER}@${CVM_IP}" "exit" >/dev/null 2>&1; then
            echo "    ✓ ${CVM_IP}: CVM ONLINE (via SSH Check)"
            CVM_ONLINE=true
        else
            # Try virsh as fallback if AHV is reachable but CVM ping/ssh fails
            if $AHV_REACHABLE; then
                CVM_STATUS=$(sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 "${SSH_USER}@${AHV_IP}" "virsh list --all | grep CVM" 2>/dev/null)
                if [[ -n "$CVM_STATUS" ]]; then
                    if echo "$CVM_STATUS" | grep -q "running"; then
                        echo "    ✓ ${CVM_IP}: CVM ONLINE (virsh)"
                        CVM_ONLINE=true
                    else
                        echo "    ⚠️ ${CVM_IP}: CVM OFFLINE (virsh)"
                    fi
                else
                    echo "    ❌ ${CVM_IP}: CVM Not Found (virsh)"
                fi
            else
                echo "    ❌ ${CVM_IP}: CVM OFFLINE"
            fi
        fi
        
        if $CVM_ONLINE; then
            ((HOSTS_UP++))
        fi
    done
    
    if [ "$HOSTS_UP" -eq "$TOTAL_HOSTS" ]; then
        echo -e "\n✅ All hosts and CVMs are confirmed up!"
        break
    fi
    
    if [ "$try" -lt "$MAX_RETRIES" ]; then
        sleep $RETRY_DELAY
    fi
done

if [ "$HOSTS_UP" -lt "$TOTAL_HOSTS" ]; then
    echo -e "\n⚠️ Verification timeout reached. Not all CVMs are confirmed running yet."
fi

echo -e "\nSummary: Power On requests processed and status verified."
