#!/bin/bash
# ==============================================================
# NVIDIA Runtime Mode Switch Script
# ==============================================================
#
# PURPOSE
# -------
# Switch NVIDIA container runtime from AUTO → CDI.
#
# Requires CDI_ENABLED=true in config.sh. When CDI is disabled,
# the script exits immediately with a log message — there is
# no runtime mode to restore.
#
# WHAT THIS SCRIPT DOES (STEP-BY-STEP)
# ------------------------------------
#   STEP 1  : Acquire global execution lock
#   STEP 2  : Exit early if CDI_ENABLED=false
#   STEP 3  : Backup NVIDIA container runtime configuration
#   STEP 4  : Detect current runtime mode
#   STEP 5  : Switch runtime mode → CDI (if required)
#   STEP 6  : Verify containerd service
#
# ==============================================================

set -euo pipefail
trap 'echo "[ERROR] Script failed at ${BASH_SOURCE}:${LINENO}"; exit 1' ERR

source config.sh
source common/lock.sh
source common/cdi.sh
source common/workload-check.sh
source common/log-cleanup.sh

LOCK_FILE="$GLOBAL_LOCK_FILE"

RUN_LOG_DIR="${BASE_LOG_DIR}/$(date +%Y%m%d-%H%M%S)"
log_file="${RUN_LOG_DIR}/runtime-switch.log"
mkdir -p "$RUN_LOG_DIR"

log()  { echo "[$(date +"%H:%M:%S")] [INFO]  $1" | tee -a "$log_file"; }
error(){ echo "[$(date +"%H:%M:%S")] [ERROR] $1" | tee -a "$log_file"; }

verify_containerd() {
    if ssh "$WORKER_NODE" "systemctl is-active --quiet containerd"; then
        log "containerd is active."
    else
        error "containerd is NOT active."
        exit 1
    fi
}

main() {

    acquire_lock "$LOCK_FILE"

    # Prune log directories older than LOG_RETENTION_DAYS (best-effort, non-fatal)
    cleanup_old_logs "$BASE_LOG_DIR" "$LOG_RETENTION_DAYS" "$RUN_LOG_DIR" || true

    if [[ "${CDI_ENABLED}" != "true" ]]; then
        log "CDI is disabled (CDI_ENABLED=false). Runtime mode restore is not needed."
        exit 0
    fi

    log "=============================================================="
    log " NVIDIA Runtime Mode Switch (AUTO → CDI)"
    log " Node        : ${WORKER_NODE}"
    log " Started At  : $(date +"%Y-%m-%d %H:%M:%S")"
    log " Run Folder  : ${RUN_LOG_DIR}"
    log "=============================================================="

    check_gpu_workloads "$WORKER_NODE"

    log "Backing up NVIDIA runtime configuration..."
    backup_runtime_config "$WORKER_NODE" "$RUN_LOG_DIR" "$log_file"

    log "Checking current NVIDIA runtime mode..."
    current_mode=$(get_current_runtime_mode "$WORKER_NODE")

    if [[ "$current_mode" == "cdi" ]]; then
        log "Runtime already in CDI mode. No change required."
    else
        log "Current Runtime Mode : ${current_mode}"
        log "Target  Runtime Mode : cdi"
        log "Switching runtime mode to CDI..."
        switch_runtime_to_cdi "$WORKER_NODE" "$log_file"
        log "Runtime mode successfully changed to CDI."
    fi

    verify_containerd

    log "--------------------------------------------------------------"
    log " RUNTIME MODE SWITCH COMPLETED SUCCESSFULLY"
    log " Log File : ${log_file}"
    log "--------------------------------------------------------------"
}

main "$@"
