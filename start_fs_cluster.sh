#!/bin/bash

# Configuration
APP_DIR="/app"
cd "${APP_DIR}"

# Load credentials from .env
if [ -f "${APP_DIR}/.env" ]; then
    export $(grep -v '^#' "${APP_DIR}/.env" | xargs)
fi

echo "--- Start FSVM Cluster Services ---"
echo "🔗 Connecting to File Services (multi-hop jump through CVM)..."

python3 "${APP_DIR}/fsvm_mgr.py" "start"

if [ $? -eq 0 ]; then
    echo "🚀 FSVM Start command initiated."
else
    echo "❌ FSVM Start command failed."
    exit 1
fi

echo -e "\n--- Verifying FSVM Cluster Status (Retry Loop) ---"
echo "⏳ Waiting for cluster services to become UP... (Timeout: 15 minutes)"

MAX_RETRIES="${DEFAULT_MAX_RETRIES:-30}"
RETRY_DELAY="${DEFAULT_RETRY_DELAY:-30}"

for (( try=1; try<=MAX_RETRIES; try++ )); do
    echo -e "\nAttempt $try/$MAX_RETRIES..."
    
    # Capture status output to a temporary file
    STATUS_OUT=$(python3 "${APP_DIR}/fsvm_mgr.py" "status" 2>&1)
    
    echo "$STATUS_OUT"

    # Check for the explicit UP status indicators
    SUMMARY_UP=false
    if echo "$STATUS_OUT" | grep -qE "The state of the cluster is UP|Cluster status: UP|The state of the cluster: start|Success!"; then
        SUMMARY_UP=true
    fi

    # Check for services that are DOWN (more precise regex)
    HAS_DOWN=false
    if echo "$STATUS_OUT" | grep -Ei ':\s*DOWN|\[DOWN' >/dev/null; then
        HAS_DOWN=true
    fi

    if [ "$SUMMARY_UP" = true ] && [ "$HAS_DOWN" = false ]; then
        echo "✅ FSVM Cluster is confirmed UP!"
        break
    else
        echo "  ❌ Cluster services still starting (some services may be DOWN or UNKNOWN)..."
    fi
    
    if [ "$try" -lt "$MAX_RETRIES" ]; then
        sleep $RETRY_DELAY
    fi
done

echo "--- FSVM Start Sequence Completed ---"