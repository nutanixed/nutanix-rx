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

# Check for token argument
if [ -z "$1" ]; then
    echo "❌ ERROR: No token provided."
    echo "Usage: $0 <token>"
    exit 1
fi
TOKEN=$1

# Resolve kubeconfig path
KUBECONFIG_PATH="/app/.kube/config"
if [ ! -f "$KUBECONFIG_PATH" ]; then KUBECONFIG_PATH="/root/.kube/config"; fi
if [ ! -f "$KUBECONFIG_PATH" ] && [ "$IS_CONTAINER" = false ]; then KUBECONFIG_PATH="${APP_DIR}/.kube/config"; fi

export KUBECONFIG=$KUBECONFIG_PATH

echo "--- 1. Uncordoning Nodes ---"
# Automatically uncordon any cordoned nodes to ensure scheduling is possible
kubectl get nodes -o name | xargs -I {} kubectl uncordon {}

echo "--- 2. Updating Registry Secrets ---"
# Update secret in nai-system
echo "Updating secret in nai-system..."
kubectl -n nai-system create secret docker-registry nai-regcred --docker-server="https://index.docker.io/v1/" --docker-username="ntnxsvcgpt" --docker-password="$TOKEN" --docker-email="edward.keiper@nutanix.com" --dry-run=client -o yaml | kubectl apply -f -

# Update secret in envoy-gateway-system
echo "Updating secret in envoy-gateway-system..."
kubectl -n envoy-gateway-system create secret docker-registry nai-regcred --docker-server="https://index.docker.io/v1/" --docker-username="ntnxsvcgpt" --docker-password="$TOKEN" --docker-email="edward.keiper@nutanix.com" --dry-run=client -o yaml | kubectl apply -f -

echo "--- 3. Cleaning Up Failed/Stuck Pods ---"
# List of namespaces to clean
NAMESPACES=("nai-system" "envoy-gateway-system" "nai-admin")
for NS in "${NAMESPACES[@]}"; do
    echo "Cleaning namespace: $NS"
    # Delete pods that are stuck in problematic states to force a fresh pull/restart
    kubectl get pods -n $NS --no-headers | grep -E "ImagePullBackOff|ErrImagePull|Error|Unknown|Pending|Init:ImagePullBackOff" | awk '{print $1}' | xargs -r kubectl delete pod -n $NS --wait=false
done

echo "--- 4. Current Status ---"
sleep 2
kubectl get pods -A | grep -E "nai|envoy"
echo "--- Script Complete ---"
