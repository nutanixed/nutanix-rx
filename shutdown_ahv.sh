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
IFS=',' read -r -a HOST_IPS_ARRAY <<< "$AHV_IPS"
unset IFS # Reset IFS

echo "--- Shutdown AHV Hosts (${AHV_IPS}) ---"
export SSHPASS="${SSH_PASS}"

for IP in "${HOST_IPS_ARRAY[@]}"; do
    IP=$(echo "$IP" | xargs)
    if [[ -z "$IP" ]]; then continue; fi
    
    (
        if ping -c 1 -W 2 "$IP" >/dev/null 2>&1; then
            echo "🛑 Sending shutdown -P to AHV Host: ${IP}..."
            sshpass -e ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@${IP}" "shutdown -P now" > /dev/null 2>&1
            echo "✓ Shutdown command acknowledged for ${IP}."
        else
            echo "○ Skipping ${IP}: Already unreachable."
        fi
    ) &
done

wait

echo -e "\n--- Parallel Shutdown Phase Completed ---"

echo -e "\n--- Verifying AHV Shutdown (Retry Loop) ---"
echo "⏳ Waiting for AHV hosts to become unreachable... (Timeout: 10 minutes)"

MAX_RETRIES="${DEFAULT_MAX_RETRIES:-20}"
RETRY_DELAY="${DEFAULT_RETRY_DELAY:-30}"
TOTAL_HOSTS=${#HOST_IPS_ARRAY[@]}

for (( try=1; try<=MAX_RETRIES; try++ )); do
    HOSTS_DOWN=0
    echo -e "\nAttempt $try/$MAX_RETRIES (Next check in ${RETRY_DELAY}s if needed)..."
    
    for IP in "${HOST_IPS_ARRAY[@]}"; do
        IP=$(echo "$IP" | xargs)
        if ! ping -c 1 -W 1 "$IP" >/dev/null 2>&1; then
            echo "  ✓ ${IP}: AHV Host is Powered OFF (Unreachable)"
            ((HOSTS_DOWN++))
        else
            echo "  ❌ ${IP}: AHV Host is still Powered ON (Reachable)"
        fi
    done
    
    if [ "$HOSTS_DOWN" -eq "$TOTAL_HOSTS" ]; then
        echo -e "\n✅ All AHV hosts are confirmed Powered OFF!"
        break
    fi
    
    if [ "$try" -lt "$MAX_RETRIES" ]; then
        sleep $RETRY_DELAY
    fi
done

if [ "$HOSTS_DOWN" -lt "$TOTAL_HOSTS" ]; then
    echo -e "\n⚠️ Verification timeout reached. Not all AHV hosts are confirmed Powered OFF yet."
fi
