#!/bin/bash

# Configuration
if [ -d "/app" ]; then
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
APP_DIR="${SCRIPT_DIR:-/app}"
    IS_CONTAINER=true
else
    APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    IS_CONTAINER=false
fi
cd "${APP_DIR}"

# Load credentials from .env for any custom config if needed
if [ -f ".env" ]; then
    export $(grep -v '^#' ".env" | xargs)
fi

# Define kubectl command
KUBECTL_CMD="kubectl --request-timeout=20s"
KUBECONFIG_PATH=""

# Resolve kubeconfig path
if [ "$IS_CONTAINER" = true ]; then
    KUBECONFIG_PATH="/app/.kube/config"
    if [ ! -f "$KUBECONFIG_PATH" ]; then KUBECONFIG_PATH="/root/.kube/config"; fi
else
    KUBECONFIG_PATH="${APP_DIR}/.kube/config"
    if ! command -v kubectl &> /dev/null; then
        if docker ps | grep -q "ntnx-cm"; then
            echo "💡 Local kubectl missing, delegating to ntnx-cm container..."
            KUBECTL_CMD="docker exec ntnx-cm kubectl --kubeconfig /app/.kube/config"
            KUBECONFIG_PATH="INTERNAL_CONTAINER"
        else
            echo "❌ ERROR: kubectl not found on host and ntnx-cm container is not running."
            exit 1
        fi
    fi
fi

if [ "$KUBECONFIG_PATH" != "INTERNAL_CONTAINER" ] && [ -n "$KUBECONFIG_PATH" ]; then
    KUBECTL_CMD="$KUBECTL_CMD --kubeconfig $KUBECONFIG_PATH"
fi

echo "--- NKP Cluster Recovery Sequence ---"

# 1. Global Pod Cleanup (Unknown / Terminating)
echo "🧹 Phase 1: Cleaning up stuck pods across all namespaces..."

# Unknown Pods
UNKNOWN_PODS_COUNT=$($KUBECTL_CMD get pods -A | grep Unknown | wc -l)
if [ "$UNKNOWN_PODS_COUNT" -gt 0 ]; then
    echo "  🗑️ Found $UNKNOWN_PODS_COUNT pods in 'Unknown' state. Force deleting..."
    $KUBECTL_CMD get pods -A | grep Unknown | awk '{print $1 " " $2}' | while read -r ns pod; do
        echo "    - Deleting $pod in $ns"
        $KUBECTL_CMD delete pod "$pod" -n "$ns" --force --grace-period=0 2>/dev/null
    done
else
    echo "  ✅ No 'Unknown' pods found."
fi

# Stuck Terminating Pods (older than 1 minute)
TERMINATING_PODS_COUNT=$($KUBECTL_CMD get pods -A | grep Terminating | wc -l)
if [ "$TERMINATING_PODS_COUNT" -gt 0 ]; then
    echo "  🗑️ Found $TERMINATING_PODS_COUNT pods in 'Terminating' state. Force clearing..."
    $KUBECTL_CMD get pods -A | grep Terminating | awk '{print $1 " " $2}' | while read -r ns pod; do
        echo "    - Force clearing $pod in $ns"
        $KUBECTL_CMD delete pod "$pod" -n "$ns" --force --grace-period=0 2>/dev/null
    done
else
    echo "  ✅ No 'Terminating' pods found."
fi

# 2. Storage Infrastructure Recovery (Nutanix CSI)
echo "💾 Phase 2: Verifying Nutanix CSI Controller..."
CSI_NS="ntnx-system"
CSI_PODS=$($KUBECTL_CMD get pods -n "$CSI_NS" -l app=nutanix-csi-controller --no-headers 2>/dev/null | awk '{print $1}')
if [ -n "$CSI_PODS" ]; then
    echo "  ♻️ Restarting CSI controllers to refresh storage bindings..."
    $KUBECTL_CMD rollout restart deployment nutanix-csi-controller -n "$CSI_NS"
else
    echo "  ⚠️ Nutanix CSI pods not found in $CSI_NS."
fi

# 3. NAI (Nutanix AI) System Recovery
echo "🧠 Phase 3: NAI (Nutanix AI) System Stabilization..."
NAI_NS="nai-system"

# Restart ClickHouse Operator
echo "  ♻️ Restarting ClickHouse Operator..."
OPERATOR_POD=$($KUBECTL_CMD get pods -n "$NAI_NS" -l app.kubernetes.io/name=nai-clickhouse-operator --no-headers 2>/dev/null | awk '{print $1}')
if [ -n "$OPERATOR_POD" ]; then
    $KUBECTL_CMD delete pod "$OPERATOR_POD" -n "$NAI_NS"
    echo "    ✅ Operator restart signal sent."
else
    echo "    ⚠️ ClickHouse Operator pod not found."
fi

# Wait for ClickHouse
echo "  ⏳ Waiting for ClickHouse database readiness..."
MAX_WAIT=180
WAIT_COUNT=0
while ! $KUBECTL_CMD get pods -n "$NAI_NS" -l clickhouse.altinity.com/ready=yes --no-headers 2>/dev/null | grep -q "1/1"; do
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        echo "    ❌ Timeout waiting for ClickHouse. Continuing anyway..."
        break
    fi
    echo "    ...waiting for ClickHouse ($WAIT_COUNT/$MAX_WAIT)"
    sleep 10
    WAIT_COUNT=$((WAIT_COUNT + 10))
done
echo "    ✅ ClickHouse is ready."

# Rollout dependent services
echo "  🚀 Rollout restart of dependent NAI services..."
$KUBECTL_CMD rollout restart deployment nai-api -n "$NAI_NS" 2>/dev/null
$KUBECTL_CMD rollout restart daemonset nai-otel-collector-collector -n "$NAI_NS" 2>/dev/null

# 4. Kommander Health Check (Optional)
echo "🛠️ Phase 4: Kommander Component Refresh..."
KOMMANDER_NS="kommander"
if $KUBECTL_CMD get ns "$KOMMANDER_NS" >/dev/null 2>&1; then
    echo "  ♻️ Refreshing Kommander UI and CM..."
    $KUBECTL_CMD rollout restart deployment kommander-cm -n "$KOMMANDER_NS" 2>/dev/null
    $KUBECTL_CMD rollout restart deployment kommander-kommander-ui -n "$KOMMANDER_NS" 2>/dev/null
fi

echo "✅ Recovery sequence completed."
$KUBECTL_CMD get pods -A | grep -v "Running" | grep -v "Completed"
