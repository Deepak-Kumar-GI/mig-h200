#!/bin/bash
# ==============================================================
# NVIDIA GPU Post-Configuration (Full Logic)
# ==============================================================
set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO."; exit 1' ERR

source lock.sh
source cdi.sh

# -------------------------
# Variables
# -------------------------
LOCK_FILE="/var/lock/nvidia-mig-config.lock"
WORKER_NODE="gu-k8s-worker"
GPU_OPERATOR_NS="gpu-operator"

MAX_RETRIES=15
SLEEP_INTERVAL=20
MIN_SUCCESS_ATTEMPT=2
MAX_FAILED_ALLOWED=2

BASE_LOG_DIR="logs"
RUN_LOG_DIR="${BASE_LOG_DIR}/$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${RUN_LOG_DIR}/backup"
log_file="${RUN_LOG_DIR}/post.log"

mkdir -p "$RUN_LOG_DIR" "$BACKUP_DIR"
log() { echo "[$(date +"%H:%M:%S")] [INFO]  $1" | tee -a "$log_file"; }
warn() { echo "[$(date +"%H:%M:%S")] [WARN]  $1" | tee -a "$log_file"; }
error() { echo "[$(date +"%H:%M:%S")] [ERROR] $1" | tee -a "$log_file"; }

# -------------------------
# Backup runtime config
# -------------------------
backup_runtime_config() {
    log "Backing up NVIDIA container runtime config..."
    scp "${WORKER_NODE}:/etc/nvidia-container-runtime/config.toml" \
        "${BACKUP_DIR}/config.toml.bak.$(date +%s)" >> "$log_file" 2>&1 \
        || { error "Failed to backup runtime config."; exit 1; }
}

# -------------------------
# Wait for MIG state
# -------------------------
wait_for_mig_state() {
    log "Checking MIG state for node ${WORKER_NODE}..."
    local count=0
    local failed_count=0

    while true; do
        local mig_state
        mig_state=$(kubectl get node "${WORKER_NODE}" \
            -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}' 2>/dev/null || echo "")

        log "Current MIG state: '${mig_state}' (Attempt: $count)"

        if [[ "${mig_state}" == "success" ]]; then
            if [[ $count -lt $MIN_SUCCESS_ATTEMPT ]]; then
                error "MIG state became SUCCESS too early (attempt $count)."
                exit 1
            fi
            log "Node ${WORKER_NODE} MIG state is SUCCESS. Proceeding..."
            break
        elif [[ "${mig_state}" == "failed" ]]; then
            failed_count=$((failed_count+1))
            warn "MIG state reported FAILED (${failed_count}/${MAX_FAILED_ALLOWED})"
            if [[ $failed_count -ge $MAX_FAILED_ALLOWED ]]; then
                error "MIG configuration FAILED after ${failed_count} attempts."
                exit 1
            fi
        elif [[ "${mig_state}" == "pending" ]]; then
            if [[ $count -ge $MAX_RETRIES ]]; then
                error "Timeout waiting for MIG state."
                exit 1
            fi
        else
            error "Unexpected MIG state: '${mig_state}'."
            exit 1
        fi

        sleep $SLEEP_INTERVAL
        count=$((count+1))
    done
}

# -------------------------
# Run nvidia-smi in MIG Manager pod
# -------------------------
run_nvidia_smi() {
    log "Locating MIG Manager pod..."
    local pod
    pod=$(kubectl get pods -n "${GPU_OPERATOR_NS}" -o wide \
        | grep mig-manager \
        | grep "${WORKER_NODE}" \
        | awk '{print $1}')

    if [[ -z "$pod" ]]; then
        error "MIG Manager pod not found."
        exit 1
    fi

    log "Executing nvidia-smi inside MIG Manager pod..."
    kubectl exec -n "${GPU_OPERATOR_NS}" "${pod}" -- nvidia-smi
}

# -------------------------
# Generate CDI spec
# -------------------------
generate_cdi() {
    log "Generating static CDI specification..."
    ssh "${WORKER_NODE}" "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml" >> "$log_file" 2>&1
}

# -------------------------
# Main Execution
# -------------------------
main() {
    acquire_lock "$LOCK_FILE"
    log "=============================================================="
    log " NVIDIA GPU Post-Configuration"
    log " Node        : ${WORKER_NODE}"
    log " Started At  : $(date +"%Y-%m-%d %H:%M:%S")"
    log " Run Folder  : ${RUN_LOG_DIR}"
    log "=============================================================="

    # Backup runtime
    backup_runtime_config

    # Wait for MIG state
    wait_for_mig_state

    # Run nvidia-smi in pod
    run_nvidia_smi

    # Generate CDI
    generate_cdi

    # Switch runtime to CDI
    switch_runtime_to_cdi "$WORKER_NODE" "$log_file"

    # Uncordon node
    log "Uncordoning node ${WORKER_NODE}..."
    kubectl uncordon "${WORKER_NODE}" >> "$log_file" 2>&1

    log "--------------------------------------------------------------"
    log " POST-CONFIGURATION COMPLETED SUCCESSFULLY"
    log " Backup Location : ${BACKUP_DIR}"
    log " Log File        : ${log_file}"
    log "--------------------------------------------------------------"
}

main "$@"
