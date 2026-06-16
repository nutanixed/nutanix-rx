#!/bin/bash

# Configuration
# Detect script directory for local execution, fallback to /app for container
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
APP_DIR="${SCRIPT_DIR:-/app}"
cd "${APP_DIR}"

# Load credentials from .env
if [ -f ".env" ]; then
    export $(grep -v '^#' ".env" | xargs)
fi

# Use SSHPASS from environment
export SSHPASS="${SSH_PASS}"

# Use MGMT_VM_NAMES from environment if available
IFS=',' read -r -a MGMT_VMS <<< "$MGMT_VM_NAMES"

echo "--- Starting Management VMs ---"

# Discovery logic: find configured VMs from MGMT_VM_NAMES
echo "--- Starting Management VMs (Configured in MGMT_VM_NAMES) ---"

# 1. Fetch all VMs
ALL_VMS_JSON=$(curl -k -s -u "${PC_USER}:${PC_PASS}" -X POST "https://${PC_IP}:9440/api/nutanix/v3/vms/list" \
    -H "Content-Type: application/json" -d '{"kind": "vm", "length": 500}')

# Use MGMT_VM_NAMES from environment if available, otherwise fallback to system_ prefix for discovery
if [[ -n "$MGMT_VM_NAMES" ]]; then
    # Create a regex from MGMT_VM_NAMES for jq (e.g., "^(vm1|vm2|vm3)$")
    NAMES_REGEX="^($(echo "$MGMT_VM_NAMES" | sed 's/,/|/g'))$"
    FILTER_LOGIC="select(.spec.name | test(\"$NAMES_REGEX\"))"
    echo "Using configured names: $MGMT_VM_NAMES"
else
    FILTER_LOGIC="select(.spec.name | startswith(\"system_\"))"
    echo "No MGMT_VM_NAMES found, falling back to 'system_' prefix discovery."
fi

# Filter and extract info
# Format: UUID|NAME|POWER_STATE
TARGET_VMS_INFO=$(echo "$ALL_VMS_JSON" | jq -r ".entities[] | ${FILTER_LOGIC} | .metadata.uuid + \"|\" + .spec.name + \"|\" + .status.resources.power_state")

if [[ -z "$TARGET_VMS_INFO" ]]; then
    echo "⚠️ No VMs found matching criteria."
    exit 0
fi

while read -r line; do
    uuid=$(echo "$line" | cut -d'|' -f1)
    vm_name=$(echo "$line" | cut -d'|' -f2)
    power_state=$(echo "$line" | cut -d'|' -f3 | tr '[:lower:]' '[:upper:]')
    
    if [[ -n "$uuid" && "$uuid" != "null" ]]; then
        if [[ "$power_state" == "OFF" || "$power_state" == "POWERED_OFF" ]]; then
            echo "Initiating Power On for: $vm_name"
            # Get latest full VM data to ensure spec is correct
            full_vm_data=$(curl -k -s -u "${PC_USER}:${PC_PASS}" "https://${PC_IP}:9440/api/nutanix/v3/vms/${uuid}")
            # Update state to ON and prepare payload for PUT
            payload=$(echo "$full_vm_data" | jq '{
                spec: .spec,
                metadata: {
                    kind: .metadata.kind,
                    uuid: .metadata.uuid,
                    spec_version: .metadata.spec_version
                }
            } | .spec.resources.power_state = "ON"')
            
            response=$(curl -k -s -u "${PC_USER}:${PC_PASS}" -X PUT "https://${PC_IP}:9440/api/nutanix/v3/vms/${uuid}" \
                -H "Content-Type: application/json" \
                -d "${payload}")
            
            if echo "$response" | grep -qE "200|202|SUCCEEDED|task_uuid"; then
                echo "🚀 Power ON initiated for: ${vm_name}"
            else
                echo "❌ Failed to power on ${vm_name}."
            fi
        else
            echo "○ Skipping $vm_name: Already $power_state"
        fi
    fi
done <<< "$TARGET_VMS_INFO"

echo -e "\n--- Verifying Management VMs Status (Retry Loop) ---"
echo "⏳ Waiting for Management VMs to become reachable via PC... (Timeout: 10 minutes)"

MAX_RETRIES="${MGMT_MAX_RETRIES:-20}"
RETRY_DELAY="${MGMT_RETRY_DELAY:-30}"

for (( try=1; try<=MAX_RETRIES; try++ )); do
    # Fetch latest IP info
    ALL_VMS_JSON=$(curl -k -s -u "${PC_USER}:${PC_PASS}" -X POST "https://${PC_IP}:9440/api/nutanix/v3/vms/list" \
        -H "Content-Type: application/json" -d '{"kind": "vm", "length": 500}')
    
    # Extract IPs for matching VMs
    MGMT_VM_IPS=($(echo "$ALL_VMS_JSON" | jq -r ".entities[] | ${FILTER_LOGIC} | .status.resources.nic_list[0].ip_endpoint_list[0].ip? // empty"))
    TOTAL_VMS=${#MGMT_VM_IPS[@]}
    
    if [ "$TOTAL_VMS" -eq 0 ]; then
        echo "Attempt $try/$MAX_RETRIES: No IPs discovered yet. Waiting..."
    else
        VMS_UP=0
        echo -e "\nAttempt $try/$MAX_RETRIES: Checking $TOTAL_VMS discovered VMs..."
        
        for IP in "${MGMT_VM_IPS[@]}"; do
            # Try to ping via SSH from PC (if sshpass is available), otherwise ping directly
            if command -v sshpass >/dev/null 2>&1; then
                if sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${PC_IP}" "ping -c 1 -W 1 $IP" >/dev/null 2>&1; then
                    echo "  ✓ ${IP}: Mgmt VM Reachable (via PC)"
                    ((VMS_UP++))
                else
                    echo "  ❌ ${IP}: Mgmt VM Unreachable (via PC)"
                fi
            else
                # Fallback to direct ping if running outside container without sshpass
                if ping -c 1 -W 1 "$IP" >/dev/null 2>&1; then
                    echo "  ✓ ${IP}: Mgmt VM Reachable (Direct)"
                    ((VMS_UP++))
                else
                    echo "  ❌ ${IP}: Mgmt VM Unreachable (Direct)"
                fi
            fi
        done
        
        if [ "$VMS_UP" -eq "$TOTAL_VMS" ]; then
            echo -e "\n✅ All discovered Management VMs are confirmed reachable!"
            break
        fi
    fi
    
    if [ "$try" -lt "$MAX_RETRIES" ]; then
        sleep $RETRY_DELAY
    fi
done

echo "--- Finished ---"
