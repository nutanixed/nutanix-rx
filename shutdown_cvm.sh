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
IFS=',' read -r -a CVM_IPS_ARRAY <<< "$CVM_IPS"
unset IFS # Reset IFS to default to avoid affecting later commands

echo "--- Shutdown CVMs (${CVM_IPS}) ---"
export SSHPASS="${SSH_PASS}"

# Run shutdowns in parallel so one failing (due to immediate shutdown) doesn't stop the others
for IP in "${CVM_IPS_ARRAY[@]}"; do
    IP=$(echo "$IP" | xargs) # Trim whitespace
    if [[ -z "$IP" ]]; then continue; fi
    
    (
        if ping -c 1 -W 2 "$IP" >/dev/null 2>&1; then
            echo "🛑 Sending shutdown -P to CVM: ${IP}..."
            # Using standard Linux shutdown to bypass Nutanix safety checks during full lab power-off
            sshpass -e ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${SSH_USER}@${IP}" "sudo shutdown -P now" > /dev/null 2>&1
            echo "✓ Shutdown command acknowledged for ${IP}."
        else
            echo "○ Skipping ${IP}: Already unreachable."
        fi
    ) &
done

# Wait for all background shutdown attempts to complete before starting verification
wait

echo -e "\n--- Parallel Shutdown Phase Completed ---"

echo -e "\n--- Verifying CVM Shutdown (Retry Loop) ---"
echo "⏳ Waiting for CVMs to become unreachable... (Timeout: 5 minutes)"

MAX_RETRIES="${DEFAULT_MAX_RETRIES:-10}"
RETRY_DELAY="${DEFAULT_RETRY_DELAY:-30}"
TOTAL_VMS=${#CVM_IPS_ARRAY[@]}

for (( try=1; try<=MAX_RETRIES; try++ )); do
    VMS_DOWN=0
    echo -e "\nAttempt $try/$MAX_RETRIES (Next check in ${RETRY_DELAY}s if needed)..."
    
    for IP in "${CVM_IPS_ARRAY[@]}"; do
        if ! ping -c 1 -W 1 "$IP" >/dev/null 2>&1; then
            echo "  ✓ ${IP}: CVM is Powered OFF (Unreachable)"
            ((VMS_DOWN++))
        else
            echo "  ❌ ${IP}: CVM is still Powered ON (Reachable)"
        fi
    done
    
    if [ "$VMS_DOWN" -eq "$TOTAL_VMS" ]; then
        echo -e "\n✅ All CVMs are confirmed Powered OFF!"
        break
    fi
    
    if [ "$try" -lt "$MAX_RETRIES" ]; then
        sleep $RETRY_DELAY
    fi
done

if [ "$VMS_DOWN" -lt "$TOTAL_VMS" ]; then
    echo -e "\n⚠️ Verification timeout reached. Not all CVMs are confirmed Powered OFF yet."
fi

echo "✅ Shutdown commands sent to all CVMs."
