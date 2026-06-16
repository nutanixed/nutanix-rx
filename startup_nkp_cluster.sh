#!/bin/bash

# Configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
APP_DIR="${SCRIPT_DIR:-/app}"
cd "${APP_DIR}"

# Load credentials from .env
if [ -f ".env" ]; then
    export $(grep -v '^#' ".env" | xargs)
fi

# Sync .kube/config with NKP_API_IP if set
if [ -n "${NKP_API_IP}" ] && [ -f "${APP_DIR}/.kube/config" ]; then
    PORT="${NKP_K8S_PORT:-6443}"
    echo "🔄 Syncing .kube/config with API: ${NKP_API_IP}:${PORT}"
    sed -i "s|server: https://.*:[0-9]*|server: https://${NKP_API_IP}:${PORT}|g" "${APP_DIR}/.kube/config"
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

# Function to power on a VM
power_on_vm() {
    local uuid=$1
    local name=$2
    
    # Check current power state first
    local state=$(curl -k -s -u "${PC_USER}:${PC_PASS}" "https://${PC_IP}:9440/api/nutanix/v3/vms/${uuid}" | jq -r '.spec.resources.power_state')
    
    if [ "$state" == "ON" ]; then
        echo "✅ ${name} is already ON."
        return 0
    fi

    # Update state to ON using PUT
    # Nutanix v3 PUT requires only spec and metadata (with uuid and spec_version)
    local full_vm_data=$(curl -k -s -u "${PC_USER}:${PC_PASS}" "https://${PC_IP}:9440/api/nutanix/v3/vms/${uuid}")
    local payload=$(echo "$full_vm_data" | jq '{
        spec: .spec,
        metadata: {
            kind: .metadata.kind,
            uuid: .metadata.uuid,
            spec_version: .metadata.spec_version
        }
    } | .spec.resources.power_state = "ON"')

    local response=$(curl -k -s -u "${PC_USER}:${PC_PASS}" -X PUT "https://${PC_IP}:9440/api/nutanix/v3/vms/${uuid}" \
        -H "Content-Type: application/json" \
        -d "${payload}")

    if echo "$response" | grep -qE "200|202|SUCCEEDED|task_uuid"; then
        echo "🚀 Power ON initiated for: ${name}"
        return 0
    else
        echo "❌ Failed to power on ${name}."
        return 1
    fi
}

echo "--- API Cluster Startup Tool ---"

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

echo "Found ${VM_COUNT} VMs to power on."

# 3. Power ON Management Nodes First
echo -e "\n--- STEP 1: Powering ON Management Nodes ---"
while read -r vm_info; do
    uuid=$(echo "$vm_info" | cut -d'|' -f1)
    name=$(echo "$vm_info" | cut -d'|' -f2)
    # Ensure management nodes are matched exclusively (don't match workers if mgmt pattern is a prefix)
    if [[ "$name" == *"${NKP_MGMT_PATTERN}"* ]] && [[ "$name" != *"${NKP_WORKER_PATTERN}"* ]]; then
        power_on_vm "$uuid" "$name"
    fi
done < <(jq -r '.[] | .metadata.uuid + "|" + .spec.name' "$ALL_VMS_JSON")

echo -e "\n⏳ Waiting ${NKP_STARTUP_STABILIZE_DELAY:-60} seconds for management plane to stabilize..."
sleep "${NKP_STARTUP_STABILIZE_DELAY:-60}"

# 4. Power ON Worker Nodes
echo -e "\n--- STEP 2: Powering ON Worker Nodes ---"
while read -r vm_info; do
    uuid=$(echo "$vm_info" | cut -d'|' -f1)
    name=$(echo "$vm_info" | cut -d'|' -f2)
    if [[ "$name" == *"${NKP_WORKER_PATTERN}"* ]]; then
        power_on_vm "$uuid" "$name"
    fi
done < <(jq -r '.[] | .metadata.uuid + "|" + .spec.name' "$ALL_VMS_JSON")

echo -e "\n--- STEP 3: Waiting for Nodes and Uncordoning ---"
echo "⏳ This may take a few minutes as OS boots and services start..."

# We wait in a loop for nodes to appear and uncordon them if they are SchedulingDisabled
MAX_RETRIES="${NKP_MAX_RETRIES:-10}"
RETRY_COUNT=0
NODES_TO_UNCORDON=$(jq -r '.[] | .spec.name' "$ALL_VMS_JSON")

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    ALL_READY=true
    for node in $NODES_TO_UNCORDON; do
        # Check if node exists in k8s
        if kubectl get node "$node" >/dev/null 2>&1; then
            # Check if it's cordoned
            if kubectl get node "$node" | grep -q "SchedulingDisabled"; then
                echo "🔓 Uncordoning node: $node"
                kubectl uncordon "$node"
            else
                echo "✅ Node $node is already uncordoned or ready."
            fi
        else
            echo "💤 Waiting for node $node to join cluster..."
            ALL_READY=false
        fi
    done

    if [ "$ALL_READY" = true ]; then
        echo -e "\n✨ All nodes have joined and are uncordoned!"
        break
    fi

    echo "Re-checking in ${NKP_RETRY_DELAY:-30} seconds... (Attempt $((RETRY_COUNT+1))/$MAX_RETRIES)"
    sleep "${NKP_RETRY_DELAY:-30}"
    RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ "$ALL_READY" = false ]; then
    echo -e "\n⚠️  Some nodes did not join the cluster in time. Please check manually with 'kubectl get nodes'."
fi

echo -e "\nSummary: Power ON signals sent to ${VM_COUNT} VMs."
rm "$ALL_VMS_JSON"
