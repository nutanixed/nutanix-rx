#!/usr/bin/env bash
#
# Full cluster startup orchestration — mirrors the Help → Startup Sequence in the web UI.
#
# Order (same as in-app documentation):
#   1. Power On Hosts          → startup_hosts.sh
#   2. Start PE Cluster        → start_pe_cluster.sh
#   3. Power On PCVMs          → startup_pcvm.sh
#   4. Start PC Cluster        → start_pc_cluster.sh
#   5. Power on FSVMs          → startup_fsnkp.sh   (matches UI "Power On" under File Services)
#   6. Start FS Cluster        → start_fs_cluster.sh
#   7. Power On Mgmt VMs       → startup_mgmt_vms.sh
#   8. NKP Startup             → startup_nkp_cluster.sh
#   9. NKP Pod Recovery        → startup_nkp_pods.sh
#  10. NDK Webhook Restore     → startup_ndk_webhook.sh
#
# The bundled helper scripts use APP_DIR=/app internally. Run this inside the ntnx-cm
# container (WORKDIR /app), for example:
#   docker exec -it <container_name> bash /app/automated_startup/automated_startup.sh
#
# Optional environment overrides (seconds):
#   WAIT_AFTER_HOSTS      default 600  — hosts/CVM boot (help: up to ~10 min after step 1)
#   WAIT_AFTER_PE         default 600  — PE stabilize before PCVMs (help note for step 3)
#   WAIT_AFTER_PCVM       default 600  — Genesis before PC cluster (help note for step 4)
#   WAIT_AFTER_PC_CLUSTER default 120
#   WAIT_AFTER_FS_POWER   default 120  — after FSVM power-on
#   WAIT_AFTER_FS_CLUSTER default 120
#   WAIT_AFTER_MGMT       default 120  — after mgmt VMs
#   WAIT_BEFORE_NKP       default 60   — before NKP startup
#
#   NTNX_CM_ROOT          default /app — directory containing the *.sh scripts
#
set -euo pipefail

NTNX_CM_ROOT="${NTNX_CM_ROOT:-/app}"

# Load credentials from .env to pick up overrides
if [ -f "${NTNX_CM_ROOT}/.env" ]; then
    export $(grep -v '^#' "${NTNX_CM_ROOT}/.env" | xargs)
fi

WAIT_AFTER_HOSTS="${WAIT_AFTER_HOSTS:-600}"
WAIT_AFTER_PE="${WAIT_AFTER_PE:-600}"
WAIT_AFTER_PCVM="${WAIT_AFTER_PCVM:-600}"
WAIT_AFTER_PC_CLUSTER="${WAIT_AFTER_PC_CLUSTER:-120}"
WAIT_AFTER_FS_POWER="${WAIT_AFTER_FS_POWER:-120}"
WAIT_AFTER_FS_CLUSTER="${WAIT_AFTER_FS_CLUSTER:-120}"
WAIT_AFTER_MGMT="${WAIT_AFTER_MGMT:-120}"
WAIT_BEFORE_NKP="${WAIT_BEFORE_NKP:-60}"

STATUS_FILE="/tmp/automated_startup.status"
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
    log "🛑 Stop requested by admin. Exiting automated startup safely."
    rm -f "$STOP_FILE"
    exit 0
  fi
}

require_root() {
  [[ -d "$NTNX_CM_ROOT" ]] || die "NTNX_CM_ROOT does not exist: $NTNX_CM_ROOT"
  [[ -f "${NTNX_CM_ROOT}/.env" ]] || die "Missing ${NTNX_CM_ROOT}/.env (required by helper scripts)"
  local f
  for f in startup_hosts.sh start_pe_cluster.sh startup_pcvm.sh start_pc_cluster.sh \
           startup_fsnkp.sh start_fs_cluster.sh startup_mgmt_vms.sh startup_nkp_cluster.sh \
           startup_nkp_pods.sh startup_ndk_webhook.sh; do
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
  echo "🚀 Starting automated startup..." > "$STATUS_FILE"
  check_stop_requested

  require_root

  log "========== Automated startup (NTNX_CM_ROOT=${NTNX_CM_ROOT}) =========="

  run_step "1/10 Power On Hosts" "startup_hosts.sh"
  wait_phase "after hosts (CVM/AHV boot per startup_hosts.sh note)" "$WAIT_AFTER_HOSTS"

  run_step "2/10 Start PE Cluster" "start_pe_cluster.sh"
  wait_phase "after PE cluster (stabilize before PCVMs per help)" "$WAIT_AFTER_PE"

  run_step "3/10 Power On PCVMs" "startup_pcvm.sh"
  wait_phase "after PCVM power-on (Genesis / services per help)" "$WAIT_AFTER_PCVM"

  run_step "4/10 Start PC Cluster" "start_pc_cluster.sh"
  wait_phase "after PC cluster" "$WAIT_AFTER_PC_CLUSTER"

  run_step "5/10 Power on FSVMs" "startup_fsnkp.sh"
  wait_phase "after FSVM power-on" "$WAIT_AFTER_FS_POWER"

  run_step "6/10 Start FS Cluster" "start_fs_cluster.sh"
  wait_phase "after FS cluster" "$WAIT_AFTER_FS_CLUSTER"

  run_step "7/10 Power On Mgmt VMs" "startup_mgmt_vms.sh"
  wait_phase "after Mgmt VMs" "$WAIT_AFTER_MGMT"

  wait_phase "before NKP startup" "$WAIT_BEFORE_NKP"

  run_step "8/10 NKP Startup" "startup_nkp_cluster.sh"
  
  run_step "9/10 NKP Pod Recovery" "startup_nkp_pods.sh"

  run_step "10/10 NDK Webhook Restore (prod)" "startup_ndk_webhook.sh"

  log "========== Automated startup completed successfully =========="
}

main "$@"
