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

# Use MGMT_VM_NAMES from environment if available
IFS=',' read -r -a MGMT_VMS <<< "$MGMT_VM_NAMES"

echo "--- Shutting Down Management VMs ---"

# Discovery logic: find configured VMs from MGMT_VM_NAMES
echo "--- Shutting Down Management VMs (Configured in MGMT_VM_NAMES) ---"

# 1. Fetch all VMs from PE (v2.0 API is more resilient)
ALL_VMS_JSON=$(curl -k -s -u "${PE_USER}:${PE_PASS}" "https://${PE_IP}:9440/api/nutanix/v2.0/vms")

# Use MGMT_VM_NAMES from environment if available, otherwise fallback to system_ prefix for discovery
if [[ -n "$MGMT_VM_NAMES" ]]; then
    # Create a regex from MGMT_VM_NAMES for jq (e.g., "^(vm1|vm2|vm3)$")
    NAMES_REGEX="^($(echo "$MGMT_VM_NAMES" | sed 's/,/|/g'))$"
    FILTER_LOGIC="select(.name | test(\"$NAMES_REGEX\"))"
    echo "Using configured names: $MGMT_VM_NAMES"
else
    FILTER_LOGIC="select(.name | startswith(\"system_\"))"
    echo "No MGMT_VM_NAMES found, falling back to 'system_' prefix discovery."
fi

# Filter and extract info
# Format: UUID|NAME|POWER_STATE
TARGET_VMS_INFO=$(echo "$ALL_VMS_JSON" | jq -r ".entities[] | ${FILTER_LOGIC} | .uuid + \"|\" + .name + \"|\" + .power_state")

if [[ -z "$TARGET_VMS_INFO" || "$TARGET_VMS_INFO" == "null" ]]; then
    echo "⚠️ No VMs found matching criteria."
    exit 0
fi

while read -r line; do
    uuid=$(echo "$line" | cut -d'|' -f1)
    vm_name=$(echo "$line" | cut -d'|' -f2)
    power_state=$(echo "$line" | cut -d'|' -f3 | tr '[:lower:]' '[:upper:]')
    
    if [[ -n "$uuid" && "$uuid" != "null" ]]; then
        if [[ "$power_state" == "ON" || "$power_state" == "POWERED_ON" ]]; then
            echo "Initiating Shutdown for: $vm_name"
            
            response=$(curl -k -s -u "${PE_USER}:${PE_PASS}" -X POST "https://${PE_IP}:9440/api/nutanix/v2.0/vms/${uuid}/set_power_state" \
                -H "Content-Type: application/json" \
                -d '{"transition": "ACPI_SHUTDOWN"}')
            
            if echo "$response" | grep -qE "task_uuid|uuid"; then
                echo "🚀 Shutdown initiated for: ${vm_name}"
            else
                echo "❌ Failed to shutdown ${vm_name}."
            fi
        else
            echo "○ Skipping $vm_name: Already $power_state"
        fi
    fi
done <<< "$TARGET_VMS_INFO"

echo "--- Finished ---"
