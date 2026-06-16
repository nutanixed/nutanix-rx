#!/bin/bash
# shutdown_ndk_webhook.sh - Set NDK webhook failure policies to Ignore (safe for shutdown)

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
if [ -f ".env" ]; then
    export $(grep -v '^#' ".env" | xargs)
fi

if [ "${ENABLE_NDK:-false}" != "true" ]; then
    echo "NDK Webhook management is disabled (ENABLE_NDK != true). Skipping."
    exit 0
fi

# Define kubectl command
KUBECTL_CMD="kubectl --request-timeout=10s"
KUBECONFIG_PATH=""

if [ "$IS_CONTAINER" = true ]; then
    KUBECONFIG_PATH="/app/.kube/config"
    if [ ! -f "$KUBECONFIG_PATH" ]; then KUBECONFIG_PATH="/root/.kube/config"; fi
else
    KUBECONFIG_PATH="${APP_DIR}/.kube/config"
    if ! command -v kubectl &> /dev/null; then
        if docker ps | grep -q "ntnx-cm"; then
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

# Set policy to Ignore for shutdown
POLICY="Ignore"

echo "--- Setting NDK Webhooks to $POLICY mode (Shutdown Safeguard) ---"

# Mutating Webhook
if $KUBECTL_CMD get mutatingwebhookconfiguration ndk-ndk-mutating-webhook-configuration >/dev/null 2>&1; then
    echo "Updating MutatingWebhookConfiguration..."
    for i in {0..3}; do
        $KUBECTL_CMD patch mutatingwebhookconfiguration ndk-ndk-mutating-webhook-configuration \
            --type='json' -p="[{\"op\": \"replace\", \"path\": \"/webhooks/$i/failurePolicy\", \"value\": \"$POLICY\"}]" 2>/dev/null
    done
else
    echo "MutatingWebhookConfiguration not found."
fi

# Validating Webhook
if $KUBECTL_CMD get validatingwebhookconfiguration ndk-ndk-validating-webhook-configuration >/dev/null 2>&1; then
    echo "Updating ValidatingWebhookConfiguration..."
    for i in {0..3}; do
        $KUBECTL_CMD patch validatingwebhookconfiguration ndk-ndk-validating-webhook-configuration \
            --type='json' -p="[{\"op\": \"replace\", \"path\": \"/webhooks/$i/failurePolicy\", \"value\": \"$POLICY\"}]" 2>/dev/null
    done
else
    echo "ValidatingWebhookConfiguration not found."
fi

echo "Done."
