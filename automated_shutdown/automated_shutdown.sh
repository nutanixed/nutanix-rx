#!/usr/bin/env bash
#
# Full cluster shutdown orchestration — mirrors the Help → Shutdown Sequence in the web UI.
#
# Order (same as in-app documentation):
#   1. NDK Webhook Safeguard   → shutdown_ndk_webhook.sh
#   2. NKP Shutdown            → shutdown_nkp_cluster.sh
#   3. Stop FS Cluster         → stop_fs_cluster.sh
#   4. Shutdown FSVMs          → shutdown_fsnkp.sh   (matches UI "Shutdown FSVMs")
#   5. Shutdown User VMs       → shutdown_all_vms.sh
#   6. Stop PC Cluster         → stop_pc_cluster.sh
#   7. Shutdown PCVMs          → shutdown_pcvm_api.sh
#   8. Power-Off Remaining VMs → shutdown_residual_vms.sh
#   9. Stop PE Cluster         → stop_pe_cluster.sh
#  10. Shutdown CVMs           → shutdown_cvm.sh
#  11. Shutdown AHV            → shutdown_ahv.sh
#  12. Power Off Hosts        → shutdown_hosts_redfish.sh
#
# The bundled helper scripts use APP_DIR=/app internally. Run this inside the ntnx-cm
# container (WORKDIR /app), for example:
#   docker exec -it <container_name> bash /app/automated_shutdown/automated_shutdown.sh
#
# Optional environment overrides (seconds):
#   WAIT_AFTER_NKP            default 300  — after NKP drain/shutdown
#   WAIT_AFTER_FS_CLUSTER     default 120  — after FS cluster stop
#   WAIT_AFTER_FSVM           default 180  — after FSVM power-off
#   WAIT_AFTER_USER_VMS       default 300  — after user VM shutdown
#   WAIT_AFTER_PC_CLUSTER     default 120  — after PC cluster stop
#   WAIT_AFTER_PCVM           default 120  — after PCVM shutdown
#   WAIT_AFTER_PE_CLUSTER     default 120  — after PE cluster stop
#   WAIT_AFTER_CVM            default 120  — after CVM shutdown
#   WAIT_AFTER_AHV            default 180  — after AHV shutdown
#
#   NTNX_CM_ROOT              default /app — directory containing the *.sh scripts
#   RESIDUAL_VM_MAX_RETRIES   default 8    — post-PC residual VM checks
#   RESIDUAL_VM_RETRY_DELAY   default 15   — seconds between residual VM checks
#   RESIDUAL_VM_FORCE_OFF     default true — hard power-off if residual VMs remain
#
set -euo pipefail

NTNX_CM_ROOT="${NTNX_CM_ROOT:-/app}"

# Load credentials from .env to pick up overrides
if [ -f "${NTNX_CM_ROOT}/.env" ]; then
    export $(grep -v '^#' "${NTNX_CM_ROOT}/.env" | xargs)
fi

WAIT_AFTER_NKP="${WAIT_AFTER_NKP:-300}"
WAIT_AFTER_FS_CLUSTER="${WAIT_AFTER_FS_CLUSTER:-120}"
WAIT_AFTER_FSVM="${WAIT_AFTER_FSVM:-180}"
WAIT_AFTER_USER_VMS="${WAIT_AFTER_USER_VMS:-300}"
WAIT_AFTER_PC_CLUSTER="${WAIT_AFTER_PC_CLUSTER_STOP:-120}"
WAIT_AFTER_PCVM="${WAIT_AFTER_PCVM_STOP:-120}"
WAIT_AFTER_PE_CLUSTER="${WAIT_AFTER_PE_CLUSTER_STOP:-120}"
WAIT_AFTER_CVM="${WAIT_AFTER_CVM:-120}"
WAIT_AFTER_AHV="${WAIT_AFTER_AHV:-180}"

STATUS_FILE="/tmp/automated_shutdown.status"
STOP_FILE="/tmp/automation.stop_requested"

log() { 
  local msg="[$(date -Iseconds)] $*"
  echo "$msg"
  echo "$msg" >> "$STATUS_FILE"
}

die() { 
  log "ERROR: $*"
  rm -f "$STATUS_FILE"
  exit 1 
}

check_stop_requested() {
  if [[ -f "$STOP_FILE" ]]; then
    log "🛑 Stop requested by admin. Exiting automated shutdown safely."
    rm -f "$STOP_FILE"
    exit 0
  fi
}

require_root() {
  [[ -d "$NTNX_CM_ROOT" ]] || die "NTNX_CM_ROOT does not exist: $NTNX_CM_ROOT"
  [[ -f "${NTNX_CM_ROOT}/.env" ]] || die "Missing ${NTNX_CM_ROOT}/.env (required by helper scripts)"
  local f
  for f in shutdown_ndk_webhook.sh shutdown_nkp_cluster.sh stop_fs_cluster.sh shutdown_fsnkp.sh shutdown_all_vms.sh \
           stop_pc_cluster.sh shutdown_pcvm_api.sh shutdown_residual_vms.sh stop_pe_cluster.sh shutdown_cvm.sh \
           shutdown_ahv.sh shutdown_hosts_redfish.sh; do
    [[ -f "${NTNX_CM_ROOT}/${f}" ]] || die "Missing script: ${NTNX_CM_ROOT}/${f}"
  done
}

run_step() {
  local title="$1"
  local script="$2"
  shift 2
  check_stop_requested
  log "BEGIN: $title → $script $*"
  bash "${NTNX_CM_ROOT}/${script}" "$@" 2>&1 | while read -r line; do
    log "  $line"
  done
  log "END:   $title (ok)"
  check_stop_requested
}

wait_phase() {
  local label="$1"
  local seconds="$2"
  [[ "$seconds" -gt 0 ]] || return 0
  log "Waiting ${seconds}s — ${label}"
  local remaining="$seconds"
  while [[ "$remaining" -gt 0 ]]; do
    check_stop_requested
    local chunk=5
    if [[ "$remaining" -lt 5 ]]; then
      chunk="$remaining"
    fi
    sleep "$chunk"
    remaining=$((remaining - chunk))
  done
}

main() {
  # Initialize status file to ensure it exists for cleanup if needed
  # However, we check pauses FIRST.
  
  # Check if automation is paused
  if [[ -f "/tmp/automation.paused" ]]; then
    [[ -f "$STATUS_FILE" ]] && rm -f "$STATUS_FILE"
    echo "Automation is DISABLED (Manual Pause: /tmp/automation.paused exists). Exiting."
    exit 0
  fi

  if [[ -f "/tmp/scheduled_automation.paused" ]]; then
    [[ -f "$STATUS_FILE" ]] && rm -f "$STATUS_FILE"
    echo "Automation is DISABLED (Scheduled Pause: /tmp/scheduled_automation.paused exists). Exiting."
    exit 0
  fi

  # Clean up status file on exit
  trap "rm -f $STATUS_FILE" EXIT
  
  # Initialize status file
  echo "🚀 Starting automated shutdown..." > "$STATUS_FILE"
  check_stop_requested
  
  require_root
  
  log "========== Automated shutdown (NTNX_CM_ROOT=${NTNX_CM_ROOT}) =========="
  
  run_step "Step 0: NDK Webhook Safeguard (safe)" "shutdown_ndk_webhook.sh"

  run_step "1/11 NKP Shutdown" "shutdown_nkp_cluster.sh"
  wait_phase "after NKP shutdown" "$WAIT_AFTER_NKP"

  run_step "2/11 Stop FS Cluster" "stop_fs_cluster.sh"
  wait_phase "after FS cluster stop" "$WAIT_AFTER_FS_CLUSTER"

  run_step "3/11 Shutdown FSVMs" "shutdown_fsnkp.sh"
  wait_phase "after FSVM shutdown" "$WAIT_AFTER_FSVM"

  run_step "4/11 Shutdown User VMs" "shutdown_all_vms.sh"
  wait_phase "after user VM shutdown" "$WAIT_AFTER_USER_VMS"

  run_step "5/11 Stop PC Cluster" "stop_pc_cluster.sh"
  wait_phase "after PC cluster stop" "$WAIT_AFTER_PC_CLUSTER"

  run_step "6/11 Shutdown PCVMs" "shutdown_pcvm_api.sh"
  wait_phase "after PCVM shutdown" "$WAIT_AFTER_PCVM"

  run_step "7/11 Power-Off Remaining VMs" "shutdown_residual_vms.sh"
  run_step "8/11 Stop PE Cluster" "stop_pe_cluster.sh"
  wait_phase "after PE cluster stop" "$WAIT_AFTER_PE_CLUSTER"

  run_step "9/11 Shutdown CVMs" "shutdown_cvm.sh"
  wait_phase "after CVM shutdown" "$WAIT_AFTER_CVM"

  run_step "10/11 Shutdown AHV" "shutdown_ahv.sh"
  wait_phase "after AHV shutdown" "$WAIT_AFTER_AHV"

  run_step "11/11 Power Off Hosts" "shutdown_hosts_redfish.sh"

  log "========== Automated shutdown completed successfully =========="
}

main "$@"
