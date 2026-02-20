#!/bin/bash

# ============================================================== 
# NVIDIA GPU Post-Configuration Utility
# Target Node : gu-k8s-worker
# Purpose     : Validate MIG, Generate CDI, Enable CDI Runtime
# ==============================================================

set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO."; exit 1' ERR

WORKER_NODE="gu-k8s-worker"
GPU_OPERATOR_NS="gpu-operator"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

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
# Wait for MIG state to be SUCCESS or FAILED
# --------------------------------------------------------------
log "Checking MIG state for node ${WORKER_NODE}..."

MAX_RETRIES=15        # Maximum attempts (~5 minutes total)
SLEEP_INTERVAL=20      # seconds
count=0

while true; do
    MIG_STATE=$(kubectl get node "${WORKER_NODE}" \
        -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}' 2>/dev/null || echo "")
    
    log "Current MIG state: '${MIG_STATE}'"

    if [[ "${MIG_STATE}" == "success" ]]; then
        log "Node ${WORKER_NODE} MIG state is SUCCESS. Proceeding..."
        break
    elif [[ "${MIG_STATE}" == "failed" ]]; then
        error "Node ${WORKER_NODE} MIG configuration FAILED."
        exit 1
    elif [[ "${MIG_STATE}" == "pending" ]]; then
        if [[ $count -ge $MAX_RETRIES ]]; then
            error "Node ${WORKER_NODE} did not reach a final MIG state after $((MAX_RETRIES*SLEEP_INTERVAL)) seconds."
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
# CDI Generation
# --------------------------------------------------------------
log "Generating static CDI specification..."
ssh "${WORKER_NODE}" "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"

log "Validating CDI specification file..."
ssh "${WORKER_NODE}" "ls -lh /etc/cdi/nvidia.yaml"

# --------------------------------------------------------------
# Runtime Switch to CDI
# --------------------------------------------------------------
log "Switching NVIDIA runtime mode to CDI..."
ssh "${WORKER_NODE}" "sudo sed -i 's/mode = \"auto\"/mode = \"cdi\"/' /etc/nvidia-container-runtime/config.toml"
ssh "${WORKER_NODE}" "sudo systemctl restart containerd"
log "Runtime successfully switched to CDI mode."

# --------------------------------------------------------------
# Node Uncordon
# --------------------------------------------------------------
log "Uncordoning node ${WORKER_NODE}..."
kubectl uncordon "${WORKER_NODE}"

log "--------------------------------------------------------------"
log " POST-CONFIGURATION COMPLETED SUCCESSFULLY"
log " Log File : ${log_file}"
log "--------------------------------------------------------------"
