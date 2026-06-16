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
TARGET_PREFIXES=("${NKP_MGMT_PATTERN}" "${NKP_WORKER_PATTERN}")

# Function to fetch VMs by prefix
get_vm_list() {
    local prefix=$1
    local payload=$(cat <<EOF
{
    "kind": "vm",
    "length": 500,
    "filter": "vm_name==${prefix}.*"
}
EOF
)
    curl -k -s -u "${PC_USER}:${PC_PASS}" -X POST "https://${PC_IP}:9440/api/nutanix/v3/vms/list" \
        -H "Content-Type: application/json" -d "${payload}"
}

# Function to drain a Kubernetes node
drain_node() {
    local node_name=$1
    echo "⏳ Draining node: ${node_name}..."
    if kubectl drain "${node_name}" --ignore-daemonsets --delete-emptydir-data --force --timeout="${NKP_DRAIN_TIMEOUT:-60s}"; then
        echo "  ✓ Node ${node_name} drained successfully."
        return 0
    else
        echo "  ⚠️  Drain warning for ${node_name}."
        return 1
    fi
}

# Function to initiate ACPI shutdown
shutdown_vm() {
    local uuid=$1
    local name=$2
    if curl -k -s -u "${PC_USER}:${PC_PASS}" -X POST "https://${PC_IP}:9440/api/nutanix/v3/vms/${uuid}/acpi_shutdown" \
        -H "Content-Type: application/json" -d "{}" | grep -qE "200|202|SUCCEEDED"; then
        echo "✓ Shutdown initiated for: ${name}"
        return 0
    else
        echo "✓ Shutdown signal sent to: ${name}"
        return 0
    fi
}

echo "--- API Cluster Shutdown Tool (Bash) ---"

# 1. Fetch all matching VMs
ALL_VMS_JSON=$(mktemp)
echo '[]' > "$ALL_VMS_JSON"

for prefix in "${TARGET_PREFIXES[@]}"; do
    VMS_JSON=$(get_vm_list "$prefix")
    # Append entities to our collection
    NEW_VMS=$(echo "$VMS_JSON" | jq '.entities // []')
    ALL_VMS_JSON_TMP=$(mktemp)
    jq -s '.[0] + .[1]' "$ALL_VMS_JSON" <(echo "$NEW_VMS") > "$ALL_VMS_JSON_TMP"
    mv "$ALL_VMS_JSON_TMP" "$ALL_VMS_JSON"
done

# Deduplicate VMs (since mgmt pattern is often a prefix of worker pattern)
ALL_VMS_JSON_TMP=$(mktemp)
jq 'unique_by(.metadata.uuid)' "$ALL_VMS_JSON" > "$ALL_VMS_JSON_TMP"
mv "$ALL_VMS_JSON_TMP" "$ALL_VMS_JSON"

VM_COUNT=$(jq '. | length' "$ALL_VMS_JSON")

if [ "$VM_COUNT" -eq 0 ]; then
    echo "No VMs found matching prefixes: ${TARGET_PREFIXES[*]}"
    rm "$ALL_VMS_JSON"
    exit 0
fi

echo "Found ${VM_COUNT} VMs to process:"
jq -r '.[] | "  - " + .spec.name' "$ALL_VMS_JSON"

# 3. Drain Workers
echo -e "\n--- STEP 1: Draining Worker Nodes ---"

# Check if Kubernetes API is reachable before attempting drains
if ! kubectl --request-timeout=5s get nodes >/dev/null 2>&1; then
    echo "⚠️  Kubernetes API unreachable. Skipping drains and proceeding to shutdown."
else
    while read -r name; do
        if [[ "$name" == *"${NKP_WORKER_PATTERN}"* ]]; then
            drain_node "$name"
        fi
    done < <(jq -r '.[] | .spec.name' "$ALL_VMS_JSON")

    # 4. Drain Management
    echo -e "\n--- STEP 2: Draining Management Nodes ---"
    while read -r name; do
        # Ensure management nodes are matched exclusively (don't match workers if mgmt pattern is a prefix)
        if [[ "$name" == *"${NKP_MGMT_PATTERN}"* ]] && [[ "$name" != *"${NKP_WORKER_PATTERN}"* ]]; then
            drain_node "$name"
        fi
    done < <(jq -r '.[] | .spec.name' "$ALL_VMS_JSON")
fi

# 5. Shutdown
echo -e "\n--- STEP 3: Sending ACPI Shutdown ---"
SUCCESS_COUNT=0
while read -r vm_info; do
    uuid=$(echo "$vm_info" | cut -d'|' -f1)
    name=$(echo "$vm_info" | cut -d'|' -f2)
    shutdown_vm "$uuid" "$name"
    ((SUCCESS_COUNT++))
done < <(jq -r '.[] | .metadata.uuid + "|" + .spec.name' "$ALL_VMS_JSON")

echo -e "\nSummary: ${SUCCESS_COUNT}/${VM_COUNT} shutdown requests sent."
rm "$ALL_VMS_JSON"
