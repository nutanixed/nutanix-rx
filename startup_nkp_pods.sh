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

# Load credentials from .env
if [ -f ".env" ]; then
    export $(grep -v '^#' ".env" | xargs)
fi

# Define namespaces to recover (from .env or default)
IFS=',' read -r -a NAMESPACES <<< "${NKP_RECOVERY_NAMESPACES:-kommander,ntnx-system}"

# Define kubectl command
KUBECTL_CMD="kubectl --request-timeout=10s"
KUBECONFIG_PATH=""

# Resolve kubeconfig path (based on where we are)
if [ "$IS_CONTAINER" = true ]; then
    KUBECONFIG_PATH="/app/.kube/config"
    if [ ! -f "$KUBECONFIG_PATH" ]; then KUBECONFIG_PATH="/root/.kube/config"; fi
else
    KUBECONFIG_PATH="${APP_DIR}/.kube/config"
    # If we are on the host and kubectl is missing, we will use docker exec
    if ! command -v kubectl &> /dev/null; then
        if docker ps | grep -q "ntnx-cm"; then
            echo "💡 Local kubectl missing, delegating to ntnx-cm container..."
            # Inside the container, the path is /app/.kube/config
            KUBECTL_CMD="docker exec ntnx-cm kubectl --kubeconfig /app/.kube/config"
            # We don't need a host-side KUBECONFIG_PATH if we delegate
            KUBECONFIG_PATH="INTERNAL_CONTAINER"
        else
            echo "❌ ERROR: kubectl not found on host and ntnx-cm container is not running."
            exit 1
        fi
    fi
fi

# Add explicit --kubeconfig if we have a path and are NOT delegating
if [ "$KUBECONFIG_PATH" != "INTERNAL_CONTAINER" ] && [ -n "$KUBECONFIG_PATH" ]; then
    KUBECTL_CMD="$KUBECTL_CMD --kubeconfig $KUBECONFIG_PATH"
fi

echo "--- NKP Pod Health Check & Recovery ---"
if [ "$KUBECONFIG_PATH" != "INTERNAL_CONTAINER" ]; then
    echo "💡 Using KUBECONFIG: $KUBECONFIG_PATH"
    echo "💡 Current Context: $($KUBECTL_CMD config current-context 2>/dev/null || echo 'Unknown')"
fi

# We wait for pods to attempt startup
echo "⏳ Waiting ${NKP_POD_RECOVERY_SETTLE_TIME:-5}s for pods to settle..."
sleep "${NKP_POD_RECOVERY_SETTLE_TIME:-5}"

recover_namespace_pods() {
    local ns=$1
    echo "🔍 Checking namespace: $ns"
    
    # Check if we can talk to the cluster
    if ! $KUBECTL_CMD get ns > /dev/null 2>&1; then
        echo "❌ ERROR: Cannot reach cluster API. Please check connectivity or container status."
        return 1
    fi

    # Check if namespace exists
    if ! $KUBECTL_CMD get ns "$ns" > /dev/null 2>&1; then
        echo "⚠️ Namespace $ns not found, skipping..."
        return
    fi

    # Get pods in CrashLoopBackOff or ImagePullBackOff
    local pods=$($KUBECTL_CMD get pods -n "$ns" --no-headers | grep -E "CrashLoopBackOff|ImagePullBackOff" | awk '{print $1}')
    
    if [ -n "$pods" ]; then
        for pod in $pods; do
            echo "♻️ Recovering pod $pod in namespace $ns..."
            $KUBECTL_CMD delete pod "$pod" -n "$ns" --wait=false
        done
        echo "✅ Recovery signals sent to affected pods in $ns."
    else
        echo "✅ No pods in CrashLoopBackOff or ImagePullBackOff found in $ns."
    fi
}

# Targeted recovery for critical namespaces
for ns in "${NAMESPACES[@]}"; do
    recover_namespace_pods "$ns"
done

echo -e "\n--- Recovery sequence completed ---"
