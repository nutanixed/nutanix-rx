#!/bin/bash

# Post-PC fallback: shut down any non-infra VMs still powered on.
# Intended to run after PC cluster + PCVM shutdown, before PE cluster stop.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
APP_DIR="${SCRIPT_DIR:-/app}"
cd "${APP_DIR}"

if [ -f ".env" ]; then
    export $(grep -v '^#' ".env" | xargs)
fi

EXCLUDE_PATTERN="${SHUTDOWN_ALL_EXCLUDE_PATTERN:-^(nkp-clus20)}"
MAX_RETRIES="${RESIDUAL_VM_MAX_RETRIES:-8}"
RETRY_DELAY="${RESIDUAL_VM_RETRY_DELAY:-15}"
FORCE_OFF="${RESIDUAL_VM_FORCE_OFF:-true}"

get_all_vms() {
    curl -k -s -u "${PE_USER}:${PE_PASS}" "https://${PE_IP}:9440/api/nutanix/v2.0/vms"
}

echo "--- Residual VM Shutdown Guard (post-PC) ---"

ALL_VMS_JSON="$(get_all_vms)"
if [ -z "${ALL_VMS_JSON}" ]; then
    echo "❌ Error: failed to fetch VM list from Prism Element (${PE_IP})."
    exit 1
fi

# Keep infra exclusions aligned with main shutdown_all_vms.sh behavior.
TARGET_VM_LINES="$(echo "${ALL_VMS_JSON}" | jq -r --arg pattern "${EXCLUDE_PATTERN}" '
  .entities[] | select(
    (.controller_vm == false or .controller_vm == null) and
    (.name | test($pattern; "i") | not) and
    (.name | test("^NTNX-.*-CVM$"; "i") | not) and
    (.name | test("-PCVM-"; "i") | not) and
    (.name | test("NTNX-fsnkp"; "i") | not) and
    (.power_state == "on" or .power_state == "POWERED_ON")
  ) | .uuid + "|" + .name
')"

if [ -z "${TARGET_VM_LINES}" ]; then
    echo "✅ No residual powered-on user VMs detected."
    exit 0
fi

echo "Found residual powered-on VMs:"
echo "${TARGET_VM_LINES}" | while read -r line; do
    [ -n "${line}" ] || continue
    echo "  - $(echo "${line}" | cut -d'|' -f2)"
done

echo
echo "--- Sending ACPI shutdown to residual VMs ---"
while read -r line; do
    [ -n "${line}" ] || continue
    uuid="$(echo "${line}" | cut -d'|' -f1)"
    name="$(echo "${line}" | cut -d'|' -f2)"
    echo "🛑 ACPI shutdown for: ${name}"
    curl -k -s -u "${PE_USER}:${PE_PASS}" \
        -X POST "https://${PE_IP}:9440/api/nutanix/v2.0/vms/${uuid}/set_power_state" \
        -H "Content-Type: application/json" \
        -d '{"transition":"ACPI_SHUTDOWN"}' > /dev/null || true
done <<< "${TARGET_VM_LINES}"

echo
echo "--- Verifying residual shutdown ---"
for (( try=1; try<=MAX_RETRIES; try++ )); do
    CURRENT_VMS_JSON="$(get_all_vms)"
    STILL_ON_LINES="$(echo "${CURRENT_VMS_JSON}" | jq -r --arg pattern "${EXCLUDE_PATTERN}" '
      .entities[] | select(
        (.controller_vm == false or .controller_vm == null) and
        (.name | test($pattern; "i") | not) and
        (.name | test("^NTNX-.*-CVM$"; "i") | not) and
        (.name | test("-PCVM-"; "i") | not) and
        (.name | test("NTNX-fsnkp"; "i") | not) and
        (.power_state == "on" or .power_state == "POWERED_ON")
      ) | .uuid + "|" + .name
    ')"

    if [ -z "${STILL_ON_LINES}" ]; then
        echo "✅ Residual VM check passed (all targeted VMs are off)."
        exit 0
    fi

    # Count non-empty lines without requiring ripgrep in the runtime container.
    count="$(printf '%s\n' "${STILL_ON_LINES}" | awk 'NF { c++ } END { print c+0 }')"
    echo "Attempt ${try}/${MAX_RETRIES}: ${count} residual VM(s) still on."
    if [ "${try}" -lt "${MAX_RETRIES}" ]; then
        sleep "${RETRY_DELAY}"
    fi
done

if [[ "${FORCE_OFF,,}" == "true" ]]; then
    echo
    echo "⚠️ Residual VMs still on after ACPI grace period; applying hard power-off."
    while read -r line; do
        [ -n "${line}" ] || continue
        uuid="$(echo "${line}" | cut -d'|' -f1)"
        name="$(echo "${line}" | cut -d'|' -f2)"
        echo "⛔ Hard power-off for: ${name}"
        curl -k -s -u "${PE_USER}:${PE_PASS}" \
            -X POST "https://${PE_IP}:9440/api/nutanix/v2.0/vms/${uuid}/set_power_state" \
            -H "Content-Type: application/json" \
            -d '{"transition":"OFF"}' > /dev/null || true
    done <<< "${STILL_ON_LINES}"
else
    echo
    echo "⚠️ Residual VMs still on, but RESIDUAL_VM_FORCE_OFF=false so no hard power-off was issued."
fi

echo "Residual VM guard completed."
