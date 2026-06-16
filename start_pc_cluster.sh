#!/bin/bash

# Configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
APP_DIR="${SCRIPT_DIR:-/app}"
cd "${APP_DIR}"

# Load credentials from .env
if [ -f ".env" ]; then
    export $(grep -v '^#' ".env" | xargs)
fi

echo "--- Start PC Cluster Services (${PC_IP}) ---"
echo "⚠️  Note: Genesis may take up to 10 minutes to come online prior to the cluster starting."
echo ""

# Using SSHPASS environment variable is more robust for special characters like '!'
export SSHPASS="${SSH_PASS}"
sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -tt "${SSH_USER}@${PC_IP}" "bash -l -c 'cluster start'"

if [ $? -eq 0 ]; then
    echo "🚀 PC Cluster start command initiated."
else
    echo "❌ Failed to start PC cluster."
    exit 1
fi

echo -e "\n--- Verifying PC Cluster Status (Retry Loop) ---"
echo "⏳ Waiting for cluster services to become UP... (Timeout: 15 minutes)"

MAX_RETRIES="${DEFAULT_MAX_RETRIES:-30}"
RETRY_DELAY="${DEFAULT_RETRY_DELAY:-30}"

for (( try=1; try<=MAX_RETRIES; try++ )); do
    echo -e "\nAttempt $try/$MAX_RETRIES..."
    
    STATUS_OUT=$(sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${PC_IP}" "bash -l -c 'cluster status'" 2>&1)
    
    # Check for the explicit UP status indicators
    # We REMOVE "The state of the cluster: start" as it appears even when services are DOWN
    SUMMARY_UP=false
    if echo "$STATUS_OUT" | grep -qE "The state of the cluster is UP|Cluster status: UP|Success!"; then
        SUMMARY_UP=true
    fi

    # Check for services that are DOWN (more robust regex)
    HAS_DOWN=false
    if echo "$STATUS_OUT" | grep -Ei '\bDOWN\b' >/dev/null; then
        HAS_DOWN=true
    fi

    if [ "$SUMMARY_UP" = true ] && [ "$HAS_DOWN" = false ]; then
        echo "✅ PC Cluster is confirmed UP!"
        break
    else
        echo "  ❌ Cluster services still starting (some services may be DOWN or UNKNOWN)..."
    fi
    
    if [ "$try" -lt "$MAX_RETRIES" ]; then
        sleep $RETRY_DELAY
    fi
done

echo "--- Finished ---"
