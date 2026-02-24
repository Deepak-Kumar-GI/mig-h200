#!/bin/bash
# ==============================================================
# NVIDIA GPU Post-Configuration
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

log()  { echo "[$(date +"%H:%M:%S")] [INFO]  $1" | tee -a "$log_file"; }
warn() { echo "[$(date +"%H:%M:%S")] [WARN]  $1" | tee -a "$log_file"; }
error(){ echo "[$(date +"%H:%M:%S")] [ERROR] $1" | tee -a "$log_file"; }

# -------------------------
# Backup Functions
# -------------------------
backup_mig_runtime() {
    backup_runtime_config "$WORKER_NODE" "$BACKUP_DIR" "$log_file"
}

# -------------------------
# Wait for MIG state
# -------------------------
wait_for_mig_state() {
    log "Checking MIG state for node ${WORKER_NODE}..."
    local count=0
    local failed_count=0

    while true; do
        local state
        state=$(kubectl get node "$WORKER_NODE" \
            -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}' 2>/dev/null || echo "")

        log "Current MIG state: '${state}' (Attempt: $count)"

        if [[ "$state" == "success" ]]; then
            [[ $count -lt $MIN_SUCCESS_ATTEMPT ]] && { error "MIG success too early (attempt $count)"; exit 1; }
            log "MIG state SUCCESS detected. Proceeding..."
            break
        elif [[ "$state" == "failed" ]]; then
            failed_count=$((failed_count+1))
            warn "MIG state FAILED (${failed_count}/${MAX_FAILED_ALLOWED})"
            [[ $failed_count -ge $MAX_FAILED_ALLOWED ]] && { error "MIG configuration FAILED"; exit 1; }
        elif [[ "$state" == "pending" ]]; then
            [[ $count -ge $MAX_RETRIES ]] && { error "Timeout waiting for MIG"; exit 1; }
        else
            error "Unexpected MIG state: '$state'"
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
    pod=$(kubectl get pods -n "$GPU_OPERATOR_NS" -o wide | grep mig-manager | grep "$WORKER_NODE" | awk '{print $1}')
    [[ -z "$pod" ]] && { error "MIG Manager pod not found"; exit 1; }

    log "Executing nvidia-smi in pod $pod..."
    kubectl exec -n "$GPU_OPERATOR_NS" "$pod" -- nvidia-smi
}

# -------------------------
# Generate CDI
# -------------------------
generate_cdi() {
    log "Generating static CDI specification..."
    ssh "$WORKER_NODE" "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml" >> "$log_file" 2>&1
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

    # Backup NVIDIA runtime
    backup_mig_runtime

    # Wait for MIG state
    wait_for_mig_state

    # Run nvidia-smi in MIG Manager pod
    run_nvidia_smi

    # Generate CDI spec
    generate_cdi

    # Switch runtime to CDI
    switch_runtime_to_cdi "$WORKER_NODE" "$log_file"

    # Uncordon node
    log "Uncordoning node ${WORKER_NODE}..."
    kubectl uncordon "$WORKER_NODE" >> "$log_file" 2>&1

    log "--------------------------------------------------------------"
    log " POST-CONFIGURATION COMPLETED SUCCESSFULLY"
    log " Backup Location : ${BACKUP_DIR}"
    log " Log File        : ${log_file}"
    log "--------------------------------------------------------------"
}

main "$@"
