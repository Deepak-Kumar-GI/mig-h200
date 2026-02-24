#!/bin/bash
# ==============================================================
# NVIDIA GPU Post-Configuration
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
BACKUP_DIR="${RUN_LOG_DIR}/backup"
log_file="${RUN_LOG_DIR}/post.log"

mkdir -p "$RUN_LOG_DIR" "$BACKUP_DIR"

# -------------------------
# Logging Functions
# -------------------------
log()  { echo "[$(date +"%H:%M:%S")] [INFO]  $1" | tee -a "$log_file"; }
warn() { echo "[$(date +"%H:%M:%S")] [WARN]  $1" | tee -a "$log_file"; }
error(){ echo "[$(date +"%H:%M:%S")] [ERROR] $1" | tee -a "$log_file"; }

# -------------------------
# Wait for MIG State
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
            if [[ $count -lt $MIN_SUCCESS_ATTEMPT ]]; then
                error "MIG success detected too early (attempt $count). Reapply temp and custom-mig-config labels"
                exit 1
            fi
            log "MIG state SUCCESS detected. Proceeding..."
            break

        elif [[ "$state" == "failed" ]]; then
            failed_count=$((failed_count+1))
            warn "MIG state FAILED (${failed_count}/${MAX_FAILED_ALLOWED})"

            if [[ $failed_count -ge $MAX_FAILED_ALLOWED ]]; then
                error "MIG configuration FAILED. Check your mig configuration yaml-file and reapply temp and custom-mig-config labels"
                exit 1
            fi

        elif [[ "$state" == "pending" ]]; then
            if [[ $count -ge $MAX_RETRIES ]]; then
                error "Timeout waiting for MIG success"
                exit 1
            fi

        else
            error "Unexpected MIG state: '$state'"
            exit 1
        fi

        sleep "$SLEEP_INTERVAL"
        count=$((count+1))
    done
}

# -------------------------
# Run nvidia-smi in MIG Manager Pod
# -------------------------
run_nvidia_smi() {
    log "Locating MIG Manager pod..."

    local pod
    pod=$(kubectl get pods -n "$GPU_OPERATOR_NAMESPACE" -o wide \
        | grep mig-manager | grep "$WORKER_NODE" | awk '{print $1}')

    if [[ -z "$pod" ]]; then
        error "MIG Manager pod not found"
        exit 1
    fi

    log "Executing nvidia-smi in pod $pod..."
    kubectl exec -n "$GPU_OPERATOR_NAMESPACE" "$pod" -- nvidia-smi
}

# -------------------------
# Main Execution
# -------------------------
main() {

    acquire_lock "$LOCK_FILE"
    log "Lock acquired on $LOCK_FILE"

    log "=============================================================="
    log " NVIDIA GPU Post-Configuration"
    log " Node        : ${WORKER_NODE}"
    log " Started At  : $(date +"%Y-%m-%d %H:%M:%S")"
    log " Run Folder  : ${RUN_LOG_DIR}"
    log "=============================================================="

    # Backup runtime config
    backup_runtime_config "$WORKER_NODE" "$BACKUP_DIR" "$log_file"

    # Wait for MIG to complete successfully
    wait_for_mig_state

    # Validate GPU state inside MIG Manager
    run_nvidia_smi

    # Generate CDI spec
    generate_cdi "$WORKER_NODE" "$log_file"

    # Switch runtime to CDI mode
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
