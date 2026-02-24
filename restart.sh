#!/bin/bash
# ==============================================================
# NVIDIA Runtime Mode Switch Utility (AUTO -> CDI)
# ==============================================================
set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO."; exit 1' ERR

# -------------------------
# Source Shared Utilities
# -------------------------
source lock.sh
source cdi.sh

# -------------------------
# Variables
# -------------------------
LOCK_FILE="/var/lock/nvidia-cdi-config.lock"
WORKER_NODE="gu-k8s-worker"

BASE_LOG_DIR="logs"
RUN_LOG_DIR="${BASE_LOG_DIR}/$(date +%Y%m%d-%H%M%S)"
log_file="${RUN_LOG_DIR}/runtime-switch.log"

mkdir -p "$RUN_LOG_DIR"

log()   { echo "[$(date +"%H:%M:%S")] [INFO] $1" | tee -a "$log_file"; }
error() { echo "[$(date +"%H:%M:%S")] [ERROR] $1" | tee -a "$log_file"; }

# -------------------------
# Main Execution
# -------------------------
main() {
    log "=============================================================="
    log " NVIDIA Runtime Mode Switch (AUTO -> CDI)"
    log " Node        : ${WORKER_NODE}"
    log " Started At  : $(date +"%Y-%m-%d %H:%M:%S")"
    log " Run Folder  : ${RUN_LOG_DIR}"
    log "=============================================================="

    # Acquire lock
    acquire_lock "$LOCK_FILE"

    # Switch runtime to CDI using shared function
    switch_runtime_to_cdi "$WORKER_NODE" "$log_file"

    log "--------------------------------------------------------------"
    log " RUNTIME MODE SWITCH COMPLETED SUCCESSFULLY"
    log " Log File : ${log_file}"
    log "--------------------------------------------------------------"
}

main "$@"
