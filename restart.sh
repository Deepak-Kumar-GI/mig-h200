#!/bin/bash
# ==============================================================
# NVIDIA Runtime Mode Switch Utility (AUTO -> CDI)
# ==============================================================
#
# Purpose:
#   Switch NVIDIA container runtime from AUTO mode to CDI mode
#   after MIG configuration is completed.
#
# What this script does:
#   1. Acquire exclusive lock
#   2. Confirm no GPU workloads are running
#   3. Backup NVIDIA runtime config
#   4. Switch runtime to CDI
#   5. Provide detailed log and summary
#
# ==============================================================

set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO."; exit 1' ERR

# -------------------------
# Source Shared Utilities
# -------------------------
source config.sh
source lock.sh
source cdi.sh

LOCK_FILE="$GLOBAL_LOCK_FILE"

# -------------------------
# Runtime Directories
# -------------------------
RUN_LOG_DIR="${BASE_LOG_DIR}/$(date +%Y%m%d-%H%M%S)"
log_file="${RUN_LOG_DIR}/runtime-switch.log"
mkdir -p "$RUN_LOG_DIR"

# -------------------------
# Logging Functions
# -------------------------
log()   { echo "[$(date +"%H:%M:%S")] [INFO]  $1" | tee -a "$log_file"; }
warn()  { echo "[$(date +"%H:%M:%S")] [WARN]  $1" | tee -a "$log_file"; }
error() { echo "[$(date +"%H:%M:%S")] [ERROR] $1" | tee -a "$log_file"; }

# -------------------------
# Confirmation Before Proceeding
# -------------------------
confirm_no_workloads() {
    echo
    echo "⚠️  Ensure NO GPU workloads are running on ${WORKER_NODE}"
    read -p "Proceed with runtime switch to CDI? (y/n): " answer
    case "$answer" in
        y|Y ) log "User confirmed no GPU workloads are running." ;;
        * ) echo "Operation cancelled."; exit 1 ;;
    esac
}

# -------------------------
# Main Execution
# -------------------------
main() {
    # Acquire global lock
    acquire_lock "$LOCK_FILE"
    log "Lock acquired on $LOCK_FILE"

    confirm_no_workloads

    # Banner
    log "=============================================================="
    log " NVIDIA Runtime Mode Switch (AUTO -> CDI)"
    log " Node        : ${WORKER_NODE}"
    log " Started At  : $(date +"%Y-%m-%d %H:%M:%S")"
    log " Run Folder  : ${RUN_LOG_DIR}"
    log "=============================================================="

    # Backup NVIDIA runtime config before switching
    backup_runtime_config "$WORKER_NODE" "$RUN_LOG_DIR" "$log_file"

    # Switch runtime mode to CDI
    switch_runtime_to_cdi "$WORKER_NODE" "$log_file"

    # Summary
    log "--------------------------------------------------------------"
    log " RUNTIME MODE SWITCH COMPLETED SUCCESSFULLY"
    log " Log File : ${log_file}"
    log "--------------------------------------------------------------"
}

main "$@"
