#!/bin/bash

# Configuration
APP_DIR="/app"
cd "${APP_DIR}"

echo "--- Stop FSVM Cluster Services ---"
echo "🔗 Connecting to File Services (multi-hop jump through CVM)..."

python3 "${APP_DIR}/fsvm_mgr.py" "stop"

if [ $? -eq 0 ]; then
    echo "🚀 FSVM Stop command initiated."
else
    echo "❌ FSVM Stop command failed."
fi

echo -e "\n--- Verifying FSVM Cluster Status (Retry Loop) ---"
echo "⏳ Waiting for cluster services to become DOWN... (Timeout: 10 minutes)"

MAX_RETRIES=20
RETRY_DELAY=30

for (( try=1; try<=MAX_RETRIES; try++ )); do
    echo -e "\nAttempt $try/$MAX_RETRIES..."
    
    STATUS_OUT=$(python3 "${APP_DIR}/fsvm_mgr.py" "status" 2>&1)
    
    if echo "$STATUS_OUT" | grep -q "The state of the cluster: stop" || ! echo "$STATUS_OUT" | grep -q "UP"; then
        echo "✅ FSVM Cluster is confirmed DOWN!"
        break
    else
        echo "  ❌ Cluster services still stopping..."
    fi
    
    if [ "$try" -lt "$MAX_RETRIES" ]; then
        sleep $RETRY_DELAY
    fi
done

echo "--- FSVM Stop Sequence Completed ---"
