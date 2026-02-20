#!/bin/bash

# ==============================================================
# NVIDIA GPU Post-Configuration Utility
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

WORKER_NODE="gu-k8s-worker"
GPU_OPERATOR_NS="gpu-operator"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

MAX_RETRIES=15
SLEEP_INTERVAL=20
MIN_SUCCESS_ATTEMPT=2

# --------------------------------------------------------------
# Logs setup
# --------------------------------------------------------------
BASE_LOG_DIR="logs"
POST_LOG_DIR="${BASE_LOG_DIR}/post"
mkdir -p "$POST_LOG_DIR"
log_file="${POST_LOG_DIR}/postconfig_$(date +%Y%m%d-%H%M%S).log"

log()   { echo "[$(date +"%H:%M:%S")] [INFO]  $1" | tee -a "$log_file"; }
warn()  { echo "[$(date +"%H:%M:%S")] [WARN]  $1" | tee -a "$log_file"; }
error() { echo "[$(date +"%H:%M:%S")] [ERROR] $1" | tee -a "$log_file"; }

log "=============================================================="
log " NVIDIA GPU Post-Configuration"
log " Node        : ${WORKER_NODE}"
log " Started At  : ${TIMESTAMP}"
log "=============================================================="

# --------------------------------------------------------------
# Wait for MIG state
# --------------------------------------------------------------
log "Checking MIG state for node ${WORKER_NODE}..."

count=0

while true; do
    MIG_STATE=$(kubectl get node "${WORKER_NODE}" \
        -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}' 2>/dev/null || echo "")
    
    log "Current MIG state: '${MIG_STATE}' (Attempt: $count)"

    if [[ "${MIG_STATE}" == "success" ]]; then
        if [[ $count -lt $MIN_SUCCESS_ATTEMPT ]]; then
            error "MIG state became SUCCESS too early (attempt $count)."
            exit 1
        fi
        log "Node ${WORKER_NODE} MIG state is SUCCESS. Proceeding..."
        break

    elif [[ "${MIG_STATE}" == "failed" ]]; then
        error "Node ${WORKER_NODE} MIG configuration FAILED."
        exit 1

    elif [[ "${MIG_STATE}" == "pending" ]]; then
        if [[ $count -ge $MAX_RETRIES ]]; then
            error "Timeout waiting for MIG state."
            exit 1
        fi
        log "MIG state is PENDING, waiting ${SLEEP_INTERVAL}s..."
        count=$((count+1))
        sleep $SLEEP_INTERVAL

    else
        error "Unexpected MIG state: '${MIG_STATE}'"
        exit 1
    fi
done

log "MIG state validation completed successfully."

# Locate MIG Manager Pod
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

# Generate CDI
log "Generating static CDI specification..."
ssh "${WORKER_NODE}" \
    "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml" \
    >> "$log_file" 2>&1

log "Switching NVIDIA runtime mode to CDI..."
ssh "${WORKER_NODE}" "sudo sed -i 's/mode = \"auto\"/mode = \"cdi\"/' /etc/nvidia-container-runtime/config.toml"
ssh "${WORKER_NODE}" "sudo systemctl restart containerd"

log "Uncordoning node ${WORKER_NODE}..."
kubectl uncordon "${WORKER_NODE}"

log "--------------------------------------------------------------"
log " POST-CONFIGURATION COMPLETED SUCCESSFULLY"
log " Log File : ${log_file}"
log "--------------------------------------------------------------"
