#!/bin/bash

# Configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
APP_DIR="${SCRIPT_DIR:-/app}"
cd "${APP_DIR}"

# Load credentials from .env
if [ -f ".env" ]; then
    export $(grep -v '^#' ".env" | xargs)
fi

# EXCLUDE list to prevent shutting down infrastructure (CVMs)
# We use PE API now, so we filter by 'controller_vm' property or specific naming.
EXCLUDE_PATTERN="${SHUTDOWN_ALL_EXCLUDE_PATTERN:-^(nkp-clus20)}"

# Function to fetch all VMs from Prism Element
get_all_vms() {
    curl -k -s -u "${PE_USER}:${PE_PASS}" "https://${PE_IP}:9440/api/nutanix/v2.0/vms"
}

echo "--- Global Lab Shutdown Tool (via Prism Element) ---"

# 1. Fetch all VMs and filter
# We exclude Controller VMs, PCVMs, FSVMs and anything matching the EXCLUDE_PATTERN
ALL_VMS_JSON=$(get_all_vms)

if [ -z "$ALL_VMS_JSON" ]; then
    echo "❌ Error: Failed to fetch VM list from Prism Element (${PE_IP})"
    exit 1
fi

# We specifically exclude:
# - Controller VMs (.controller_vm)
# - PCVMs (contain -PCVM-)
# - FSVMs (contain NTNX-fsnkp)
# - The EXCLUDE_PATTERN (nkp-clus20)
FILTERED_VMS=$(echo "$ALL_VMS_JSON" | jq --arg pattern "$EXCLUDE_PATTERN" '
    .entities | map(select(
        (.controller_vm == false or .controller_vm == null) and
        (.name | test($pattern; "i") | not) and
        (.name | test("^NTNX-.*-CVM$"; "i") | not) and
        (.name | test("-PCVM-"; "i") | not) and
        (.name | test("NTNX-fsnkp"; "i") | not)
    ))')

VM_COUNT=$(echo "$FILTERED_VMS" | jq '. | length')

if [ -z "$VM_COUNT" ] || [ "$VM_COUNT" -eq 0 ]; then
    echo "No VMs found to shut down."
    exit 0
fi

echo "Found ${VM_COUNT} VMs to shut down (excluding CVMs and $EXCLUDE_PATTERN):"
echo "$FILTERED_VMS" | jq -r '.[] | "  - " + .name + " (" + .power_state + ")"'

# 2. Shutdown loop (Parallel ACPI Shutdown)
echo -e "\n--- Sending ACPI Shutdown ---"
while read -r vm_info; do
    uuid=$(echo "$vm_info" | cut -d'|' -f1)
    name=$(echo "$vm_info" | cut -d'|' -f2)
    power_state=$(echo "$vm_info" | cut -d'|' -f3 | tr '[:lower:]' '[:upper:]')
    
    if [[ "$power_state" == "ON" || "$power_state" == "POWERED_ON" ]]; then
        (
            echo "🛑 Initiating Shutdown for: $name"
            # Using PE v2.0 API for power actions
            if curl -k -s -u "${PE_USER}:${PE_PASS}" -X POST "https://${PE_IP}:9440/api/nutanix/v2.0/vms/${uuid}/set_power_state" \
                -H "Content-Type: application/json" -d '{"transition": "ACPI_SHUTDOWN"}' | grep -qE "task_uuid|SUCCEEDED"; then
                echo "  ✓ Shutdown signal accepted for: ${name}"
            else
                echo "  ❌ Failed to send shutdown signal to: ${name}"
            fi
        ) &
    else
        echo "○ Skipping: ${name} (Already ${power_state})"
    fi
done < <(echo "$FILTERED_VMS" | jq -r '.[] | .uuid + "|" + .name + "|" + .power_state')

wait
echo -e "\n--- All Shutdown Signals Sent ---"

echo -e "\n--- Verifying VM Shutdown (Retry Loop) ---"
echo "⏳ Waiting for VMs to become unreachable... (Timeout: 10 minutes)"

MAX_RETRIES="${DEFAULT_MAX_RETRIES:-20}"
RETRY_DELAY="${DEFAULT_RETRY_DELAY:-30}"

for (( try=1; try<=MAX_RETRIES; try++ )); do
    # Fetch latest status
    CURRENT_VMS_JSON=$(get_all_vms)
    VMS_STILL_ON=$(echo "$CURRENT_VMS_JSON" | jq --arg pattern "$EXCLUDE_PATTERN" '
        .entities | map(select(
            (.controller_vm == false or .controller_vm == null) and
            (.name | test($pattern; "i") | not) and
            (.name | test("^NTNX-.*-CVM$"; "i") | not) and
            (.power_state == "on" or .power_state == "POWERED_ON")
        )) | length')
    
    if [ "$VMS_STILL_ON" -eq 0 ]; then
        echo -e "\n✅ All target VMs are confirmed Powered OFF!"
        break
    fi
    
    echo "Attempt $try/$MAX_RETRIES: ${VMS_STILL_ON} VMs still powering off..."
    
    if [ "$try" -lt "$MAX_RETRIES" ]; then
        sleep $RETRY_DELAY
    fi
done

if [ "$VMS_STILL_ON" -gt 0 ]; then
    echo -e "\n⚠️ Verification timeout reached. Some VMs may still be shutting down."
    echo "VMs still ON:"
    echo "$CURRENT_VMS_JSON" | jq -r --arg pattern "$EXCLUDE_PATTERN" '
        .entities | .[] | select(
            (.controller_vm == false or .controller_vm == null) and
            (.name | test($pattern; "i") | not) and
            (.name | test("^NTNX-.*-CVM$"; "i") | not) and
            (.power_state == "on" or .power_state == "POWERED_ON")
        ) | "  - " + .name'
fi

echo -e "\n--- Finished ---"
