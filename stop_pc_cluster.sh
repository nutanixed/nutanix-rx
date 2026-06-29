#!/bin/bash

# Configuration
APP_DIR="/app"
cd "${APP_DIR}"

# Load credentials from .env
if [ -f "${APP_DIR}/.env" ]; then
    export $(grep -v '^#' "${APP_DIR}/.env" | xargs)
fi

echo "--- Stop PC Cluster Services (${PC_IP}) ---"

# Retry knobs (all optional in .env)
PC_CLUSTER_STOP_MAX_RETRIES="${PC_CLUSTER_STOP_MAX_RETRIES:-12}"
PC_CLUSTER_STOP_RETRY_DELAY="${PC_CLUSTER_STOP_RETRY_DELAY:-30}"
PC_CLUSTER_SSH_CONNECT_TIMEOUT="${PC_CLUSTER_SSH_CONNECT_TIMEOUT:-10}"

# Using SSHPASS environment variable is more robust for special characters like '!'
export SSHPASS="${SSH_PASS}"

attempt=1
while [ "$attempt" -le "$PC_CLUSTER_STOP_MAX_RETRIES" ]; do
    echo "Attempt ${attempt}/${PC_CLUSTER_STOP_MAX_RETRIES}: Stopping PC cluster..."
    if sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout="${PC_CLUSTER_SSH_CONNECT_TIMEOUT}" -tt "${SSH_USER}@${PC_IP}" "bash -l -c \"printf 'y\nI agree\n' | cluster stop\""; then
        echo "✅ PC Cluster stop command initiated."
        exit 0
    fi

    if [ "$attempt" -lt "$PC_CLUSTER_STOP_MAX_RETRIES" ]; then
        echo "⚠️ PC cluster stop attempt failed; retrying in ${PC_CLUSTER_STOP_RETRY_DELAY}s..."
        sleep "${PC_CLUSTER_STOP_RETRY_DELAY}"
    fi
    attempt=$((attempt + 1))
done

echo "❌ Failed to stop PC cluster after ${PC_CLUSTER_STOP_MAX_RETRIES} attempts."
exit 1
