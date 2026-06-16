#!/bin/bash

# Configuration
APP_DIR="/app"
cd "${APP_DIR}"

# Load credentials from .env
if [ -f "${APP_DIR}/.env" ]; then
    export $(grep -v '^#' "${APP_DIR}/.env" | xargs)
fi

echo "--- Stop PC Cluster Services (${PC_IP}) ---"

# Using SSHPASS environment variable is more robust for special characters like '!'
export SSHPASS="${SSH_PASS}"
sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -tt "${SSH_USER}@${PC_IP}" "bash -l -c \"printf 'y\nI agree\n' | cluster stop\""

if [ $? -eq 0 ]; then
    echo "✅ PC Cluster stop command initiated."
else
    echo "❌ Failed to stop PC cluster."
    exit 1
fi
