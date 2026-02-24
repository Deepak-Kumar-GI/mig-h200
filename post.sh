#!/bin/bash

# ==============================================================
# NVIDIA GPU Post-Configuration Utility with Timestamped Logs
# ==============================================================

set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO."; exit 1' ERR

# --------------------------------------------------------------
# Global Lock (Prevents concurrent pre/post execution)
# --------------------------------------------------------------
LOCK_FILE="/var/lock/nvidia-mig-config.lock"
exec 200>"$LOCK_FILE"

if ! flock -n 200; then
    echo "[ERROR] Another MIG configuration script is already running."
    echo "Only one of pre.sh or post.sh can run at a time."
    exit 1
fi

echo $$ 1>&200

# --------------------------------------------------------------
# Variables
# --------------------------------------------------------------
WORKER_NODE="gu-k8s-worker"
GPU_OPERATOR_NS="gpu-operator"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

MAX_RETRIES=15
SLEEP_INTERVAL=20
MIN_SUCCESS_ATTEMPT=2
MAX_FAILED_ALLOWED=2

# --------------------------------------------------------------
# Logs & Backup Setup
# --------------------------------------------------------------
BASE_LOG_DIR="logs"
TIMESTAMP_FOLDER=$(date +%Y%m%d-%H%M%S)
RUN_LOG_DIR="${BASE_LOG_DIR}/${TIMESTAMP_FOLDER}"
BACKUP_DIR="${RUN_LOG_DIR}/backup"

mkdir -p "$RUN_LOG_DIR" "$BACKUP_DIR"

log_file="${RUN_LOG_DIR}/post.log"

log()   { echo "[$(date +"%H:%M:%S")] [INFO]  $1" | tee -a "$log_file"; }
warn()  { echo "[$(date +"%H:%M:%S")] [WARN]  $1" | tee -a "$log_file"; }
error() { echo "[$(date +"%H:%M:%S")] [ERROR] $1" | tee -a "$log_file"; }

log "=============================================================="
log " NVIDIA GPU Post-Configuration"
log " Node        : ${WORKER_NODE}"
log " Started At  : ${TIMESTAMP}"
log " Run Folder  : ${RUN_LOG_DIR}"
log "=============================================================="

# --------------------------------------------------------------
# Backup NVIDIA Runtime Config (REMOTE → LOCAL)
# --------------------------------------------------------------
log "Backing up NVIDIA container runtime config from ${WORKER_NODE}..."

RUNTIME_BACKUP_FILE="${BACKUP_DIR}/config.toml.bak.$(date +%s)"

scp "${WORKER_NODE}:/etc/nvidia-container-runtime/config.toml" \
    "${RUNTIME_BACKUP_FILE}" >> "$log_file" 2>&1 \
    || { error "Failed to backup runtime config."; exit 1; }

log "Runtime config backup stored at: ${RUNTIME_BACKUP_FILE}"

# --------------------------------------------------------------
# Wait for MIG state
# --------------------------------------------------------------
log "Checking MIG state for node ${WORKER_NODE}..."

count=0
FAILED_COUNT=0

while true; do
    MIG_STATE=$(kubectl get node "${WORKER_NODE}" \
        -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}' 2>/dev/null || echo "")

    log "Current MIG state: '${MIG_STATE}' (Attempt: $count)"

    if [[ "${MIG_STATE}" == "success" ]]; then
        if [[ $count -lt $MIN_SUCCESS_ATTEMPT ]]; then
            error "MIG state became SUCCESS too early (attempt $count). Reapply labels."
            exit 1
        fi
        log "Node ${WORKER_NODE} MIG state is SUCCESS. Proceeding..."
        break

    elif [[ "${MIG_STATE}" == "failed" ]]; then
        FAILED_COUNT=$((FAILED_COUNT+1))
        warn "MIG state reported FAILED (${FAILED_COUNT}/${MAX_FAILED_ALLOWED})"

        if [[ $FAILED_COUNT -ge $MAX_FAILED_ALLOWED ]]; then
            error "MIG configuration FAILED after ${FAILED_COUNT} attempts."
            exit 1
        fi

        sleep $SLEEP_INTERVAL
        count=$((count+1))

    elif [[ "${MIG_STATE}" == "pending" ]]; then
        if [[ $count -ge $MAX_RETRIES ]]; then
            error "Timeout waiting for MIG state."
            exit 1
        fi

        sleep $SLEEP_INTERVAL
        count=$((count+1))

    else
        error "Unexpected MIG state: '${MIG_STATE}'."
        exit 1
    fi
done

log "MIG state validation completed successfully."

# --------------------------------------------------------------
# Locate MIG Manager Pod
# --------------------------------------------------------------
log "Locating MIG Manager pod..."

MIG_MANAGER_POD=$(kubectl get pods -n ${GPU_OPERATOR_NS} -o wide \
    | grep mig-manager \
    | grep "${WORKER_NODE}" \
    | awk '{print $1}')

if [[ -z "${MIG_MANAGER_POD}" ]]; then
    error "MIG Manager pod not found."
    exit 1
fi

log "Executing nvidia-smi inside MIG Manager pod..."
kubectl exec -n ${GPU_OPERATOR_NS} "${MIG_MANAGER_POD}" -- nvidia-smi

# --------------------------------------------------------------
# Generate CDI specification
# --------------------------------------------------------------
log "Generating static CDI specification..."
ssh "${WORKER_NODE}" \
    "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml" \
    >> "$log_file" 2>&1

# --------------------------------------------------------------
# Switch Runtime to CDI
# --------------------------------------------------------------
log "Switching NVIDIA runtime mode to CDI..."

ssh "${WORKER_NODE}" \
    "sudo sed -i 's/mode = \"auto\"/mode = \"cdi\"/' \
    /etc/nvidia-container-runtime/config.toml" \
    >> "$log_file" 2>&1

ssh "${WORKER_NODE}" \
    "sudo systemctl restart containerd" \
    >> "$log_file" 2>&1

log "Runtime switched to CDI successfully."

# --------------------------------------------------------------
# Uncordon node
# --------------------------------------------------------------
log "Uncordoning node ${WORKER_NODE}..."
kubectl uncordon "${WORKER_NODE}" >> "$log_file" 2>&1

log "--------------------------------------------------------------"
log " POST-CONFIGURATION COMPLETED SUCCESSFULLY"
log " Backup Location : ${BACKUP_DIR}"
log " Log File        : ${log_file}"
log "--------------------------------------------------------------"
