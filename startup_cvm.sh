#!/bin/bash

# Configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
APP_DIR="${SCRIPT_DIR:-/app}"
cd "${APP_DIR}"

# Load credentials from .env
if [ -f ".env" ]; then
    export $(grep -v '^#' ".env" | xargs)
fi

USER="${SSH_USER}"
PASS="${SSH_PASS}"
# Use AHV_IPS from environment
IFS=',' read -r -a HOSTS <<< "$AHV_IPS"

echo "--- CVM Power On Sequence (via AHV Hosts) ---"
export SSHPASS="${PASS}"

for HOST in "${HOSTS[@]}"; do
    echo "🔗 Connecting to Host ${HOST}..."
    # On AHV, we can start the CVM using 'virsh start $(virsh list --all | grep CVM | awk "{print \$2}")'
    sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${USER}@${HOST}" "virsh start \$(virsh list --all | grep CVM | awk '{print \$2}')"
    if [ $? -eq 0 ]; then
        echo "✅ CVM start command sent to ${HOST}"
    else
        echo "❌ Failed to send start command to ${HOST}"
    fi
done

echo -e "\n--- Verifying CVM Status (Retry Loop) ---"
echo "⏳ Waiting for CVMs to become reachable... (Timeout: 10 minutes)"

IFS=',' read -r -a C_IP_LIST <<< "$CVM_IPS"
unset IFS
MAX_RETRIES="${DEFAULT_MAX_RETRIES:-20}"
RETRY_DELAY="${DEFAULT_RETRY_DELAY:-30}"
TOTAL_VMS=${#C_IP_LIST[@]}

for (( try=1; try<=MAX_RETRIES; try++ )); do
    VMS_UP=0
    echo -e "\nAttempt $try/$MAX_RETRIES (Next check in ${RETRY_DELAY}s if needed)..."
    
    for IP in "${C_IP_LIST[@]}"; do
        IP=$(echo "$IP" | xargs)
        if [[ -z "$IP" ]]; then continue; fi
        # We ping the CVM from one of the AHV hosts since the container may not have direct access
        if sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${USER}@${HOSTS[0]}" "ping -c 1 -W 1 $IP" >/dev/null 2>&1; then
            echo "  ✓ ${IP}: CVM Reachable (via AHV @ ${HOSTS[0]})"
            ((VMS_UP++))
        else
            echo "  ❌ ${IP}: CVM Unreachable (Ping from AHV @ ${HOSTS[0]})"
        fi
    done
    
    if [ "$VMS_UP" -eq "$TOTAL_VMS" ]; then
        echo -e "\n✅ All CVMs are confirmed reachable!"
        break
    fi
    
    if [ "$try" -lt "$MAX_RETRIES" ]; then
        sleep $RETRY_DELAY
    fi
done

if [ "$VMS_UP" -lt "$TOTAL_VMS" ]; then
    echo -e "\n⚠️ Verification timeout reached. Not all CVMs are confirmed reachable yet."
fi

echo "--- Finished ---"
