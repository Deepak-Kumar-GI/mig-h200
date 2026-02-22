#!/bin/bash

# ==============================================================
# NVIDIA CDI Generation & Runtime Switch Utility
# ==============================================================

set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO."; exit 1' ERR

# --------------------------------------------------------------
# Global Lock
# --------------------------------------------------------------
LOCK_FILE="/var/lock/nvidia-cdi-config.lock"
exec 200>"$LOCK_FILE"

if ! flock -n 200; then
    echo "[ERROR] Another CDI configuration script is already running."
    exit 1
fi

echo $$ 1>&200

# --------------------------------------------------------------
# Variables
# --------------------------------------------------------------
WORKER_NODE="gu-k8s-worker"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# --------------------------------------------------------------
# Logs Setup
# --------------------------------------------------------------
BASE_LOG_DIR="logs"
TIMESTAMP_FOLDER=$(date +%Y%m%d-%H%M%S)
RUN_LOG_DIR="${BASE_LOG_DIR}/${TIMESTAMP_FOLDER}"

mkdir -p "$RUN_LOG_DIR"
log_file="${RUN_LOG_DIR}/generate-cdi.log"

log()   { echo "[$(date +"%H:%M:%S")] [INFO]  $1" | tee -a "$log_file"; }
warn()  { echo "[$(date +"%H:%M:%S")] [WARN]  $1" | tee -a "$log_file"; }
error() { echo "[$(date +"%H:%M:%S")] [ERROR] $1" | tee -a "$log_file"; }

log "=============================================================="
log " NVIDIA CDI Generation & Runtime Configuration"
log " Node        : ${WORKER_NODE}"
log " Started At  : ${TIMESTAMP}"
log " Run Folder  : ${RUN_LOG_DIR}"
log "=============================================================="

# --------------------------------------------------------------
# Runtime Check Before CDI Generation
# --------------------------------------------------------------
log "Checking NVIDIA runtime mode on ${WORKER_NODE}..."

CURRENT_MODE=$(ssh "${WORKER_NODE}" \
  "grep '^mode' /etc/nvidia-container-runtime/config.toml | awk -F'\"' '{print \$2}'" \
  || true)

if [[ -z "${CURRENT_MODE}" ]]; then
    error "Unable to determine current runtime mode."
    exit 1
fi

log "Current runtime mode: ${CURRENT_MODE}"

# --------------------------------------------------------------
# Conditional Logic
# --------------------------------------------------------------
if [[ "${CURRENT_MODE}" == "cdi" ]]; then
    log "Runtime already set to CDI. No action required."
    log "--------------------------------------------------------------"
    log " CDI CONFIGURATION SKIPPED (ALREADY IN CDI MODE)"
    log "--------------------------------------------------------------"
    exit 0

elif [[ "${CURRENT_MODE}" == "auto" ]]; then
    log "Runtime is AUTO. Proceeding with CDI generation."

    # Verify nvidia-ctk exists
    ssh "${WORKER_NODE}" \
        "command -v nvidia-ctk >/dev/null 2>&1" \
        || { error "nvidia-ctk not found on ${WORKER_NODE}"; exit 1; }

    # Generate CDI specification
    log "Generating static CDI specification..."
    ssh "${WORKER_NODE}" \
        "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml" \
        >> "$log_file" 2>&1

    log "CDI specification generated."

    # Backup config before modification
    ssh "${WORKER_NODE}" \
        "sudo cp /etc/nvidia-container-runtime/config.toml /etc/nvidia-container-runtime/config.toml.bak.$(date +%s)"

    # Switch runtime mode to CDI
    log "Switching runtime mode to CDI..."
    ssh "${WORKER_NODE}" \
        "sudo sed -i 's/^mode = .*/mode = \"cdi\"/' /etc/nvidia-container-runtime/config.toml"

    # Restart containerd
    log "Restarting containerd..."
    ssh "${WORKER_NODE}" \
        "sudo systemctl restart containerd"

    # Validate restart
    if ssh "${WORKER_NODE}" "systemctl is-active --quiet containerd"; then
        log "containerd restarted successfully."
    else
        error "containerd failed to restart."
        exit 1
    fi

    log "Runtime successfully switched from AUTO to CDI."

else
    error "Unsupported runtime mode: ${CURRENT_MODE}. Expected 'auto' or 'cdi'."
    exit 1
fi

log "--------------------------------------------------------------"
log " CDI CONFIGURATION COMPLETED SUCCESSFULLY"
log " Log File : ${log_file}"
log "--------------------------------------------------------------"
