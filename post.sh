#!/bin/bash
# ==============================================================
# NVIDIA GPU Post-Configuration Script
# ==============================================================
#
# PURPOSE
# -------
# Complete worker node configuration after MIG reprovisioning.
#
# WHAT THIS SCRIPT DOES (STEP-BY-STEP)
# ------------------------------------
#   STEP 1  : Acquire global execution lock
#   STEP 2  : Apply custom MIG configuration YAML
#   STEP 3  : Wait for MIG state to reach SUCCESS
#             (with early-success protection & failure handling)
#   STEP 4  : Validate GPU state inside MIG Manager pod
#   STEP 5  : Generate CDI specification
#   STEP 6  : Detect current runtime mode
#   STEP 7  : Switch NVIDIA runtime mode → CDI (if required)
#   STEP 8  : Verify containerd service
#   STEP 9  : Uncordon worker node
#
# ==============================================================

set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO."; exit 1' ERR

# --------------------------------------------------------------
# Load Shared Configuration & Utilities
# --------------------------------------------------------------
source config.sh
source common/lock.sh
source common/cdi.sh

LOCK_FILE="$GLOBAL_LOCK_FILE"

# --------------------------------------------------------------
# Runtime Directories
# --------------------------------------------------------------
RUN_LOG_DIR="${BASE_LOG_DIR}/$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${RUN_LOG_DIR}/backup"
log_file="${RUN_LOG_DIR}/post.log"

mkdir -p "$RUN_LOG_DIR" "$BACKUP_DIR"

# --------------------------------------------------------------
# Logging Functions
# --------------------------------------------------------------
log()  { echo "[$(date +"%H:%M:%S")] [INFO]  $1" | tee -a "$log_file"; }
warn() { echo "[$(date +"%H:%M:%S")] [WARN]  $1" | tee -a "$log_file"; }
error(){ echo "[$(date +"%H:%M:%S")] [ERROR] $1" | tee -a "$log_file"; }

# --------------------------------------------------------------
# Wait for MIG State (ORIGINAL ROBUST VERSION RESTORED)
# --------------------------------------------------------------
wait_for_mig_state() {

    log "Checking MIG state for node ${WORKER_NODE}..."

    local count=1
    local failed_count=1

    while true; do

        local state
        state=$(kubectl get node "$WORKER_NODE" \
            -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}' 2>/dev/null || echo "")

        log "Current MIG state: '${state}' (Attempt: $count)"

        if [[ "$state" == "success" ]]; then

            if [[ $count -lt $MIN_SUCCESS_ATTEMPT ]]; then
                error "MIG success detected too early (attempt $count)"
                return 1   # trigger retry logic
            fi

            log "MIG state SUCCESS detected. Proceeding..."
            return 0

        elif [[ "$state" == "failed" ]]; then

            failed_count=$((failed_count+1))
            warn "MIG state FAILED (${failed_count}/${MAX_FAILED_ALLOWED})"

            if [[ $failed_count -ge $MAX_FAILED_ALLOWED ]]; then
                error "MIG configuration FAILED. Check your MIG config YAML and again run the script post.sh"
                exit 1
            fi

        elif [[ "$state" == "pending" ]]; then

            if [[ $count -ge $MAX_RETRIES ]]; then
                error "Timeout waiting for MIG success."
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

# --------------------------------------------------------------
# Apply MIG Configuration with Retry
# --------------------------------------------------------------
apply_mig_with_retry() {

    local attempt=1

    while [[ $attempt -lt $MIG_MAX_APPLY_ATTEMPTS ]]; do

        log "Applying custom MIG config (${MIG_CONFIG_FILE}) - MIG Attempt $((attempt))"
        kubectl apply -f "$MIG_CONFIG_FILE" >> "$log_file" 2>&1

        kubectl label node "$WORKER_NODE" nvidia.com/mig.config=temp --overwrite >> "$log_file" 2>&1
        sleep "$TEMP_LABEL_SLEEP"

        kubectl label node "$WORKER_NODE" nvidia.com/mig.config=custom-mig-config --overwrite >> "$log_file" 2>&1
        sleep "$CUSTOM_LABEL_SLEEP"

        if wait_for_mig_state; then
            log "MIG successfully applied."
            return 0
        else
            warn "Applying labels..."

            kubectl label node "$WORKER_NODE" nvidia.com/mig.config=temp --overwrite >> "$log_file" 2>&1
            sleep "$TEMP_LABEL_SLEEP"

            kubectl label node "$WORKER_NODE" nvidia.com/mig.config=custom-mig-config --overwrite >> "$log_file" 2>&1
            sleep "$CUSTOM_LABEL_SLEEP"
        fi

        attempt=$((attempt+1))
    done

    error "MIG configuration failed after ${MIG_MAX_APPLY_ATTEMPTS} attempts."
    exit 1
}

# --------------------------------------------------------------
# Run nvidia-smi in MIG Manager Pod
# --------------------------------------------------------------
run_nvidia_smi() {

    log "Locating MIG Manager pod..."

    local pod
    pod=$(kubectl get pods -n "$GPU_OPERATOR_NAMESPACE" -o wide \
        | grep mig-manager | grep "$WORKER_NODE" | awk '{print $1}')

    if [[ -z "$pod" ]]; then
        error "MIG Manager pod not found."
        exit 1
    fi

    log "Executing nvidia-smi inside pod ${pod}..."
    kubectl exec -n "$GPU_OPERATOR_NAMESPACE" "$pod" -- nvidia-smi
}

# --------------------------------------------------------------
# Verify containerd Service
# --------------------------------------------------------------
verify_containerd() {

    log "Verifying containerd service status..."

    if ssh "$WORKER_NODE" "systemctl is-active --quiet containerd"; then
        log "containerd is active."
    else
        error "containerd is NOT active."
        exit 1
    fi
}

# --------------------------------------------------------------
# Main Execution
# --------------------------------------------------------------
main() {

    # STEP 1
    acquire_lock "$LOCK_FILE"

    log "=============================================================="
    log " NVIDIA GPU Post-Configuration"
    log " Node        : ${WORKER_NODE}"
    log " Started At  : $(date +"%Y-%m-%d %H:%M:%S")"
    log " Run Folder  : ${RUN_LOG_DIR}"
    log "=============================================================="

    # STEP 2
    apply_mig_with_retry

    # STEP 3
    run_nvidia_smi

    # STEP 4
    log "Generating CDI specification..."
    generate_cdi "$WORKER_NODE" "$log_file"

    # STEP 5 - Runtime Mode Detection
    log "Checking current NVIDIA runtime mode..."
    current_mode=$(get_current_runtime_mode "$WORKER_NODE")

    if [[ "$current_mode" == "cdi" ]]; then
        log "Runtime already in CDI mode."
    else
        log "Current Runtime Mode : ${current_mode}"
        log "Target  Runtime Mode : cdi"
        log "Switching runtime mode to CDI..."
        switch_runtime_to_cdi "$WORKER_NODE" "$log_file"
        log "Runtime mode successfully changed to CDI."
    fi

    # STEP 6
    verify_containerd

    # STEP 7
    log "Uncordoning node ${WORKER_NODE}..."
    kubectl uncordon "$WORKER_NODE" >> "$log_file" 2>&1

    log "--------------------------------------------------------------"
    log " POST-CONFIGURATION COMPLETED SUCCESSFULLY"
    log " Log File        : ${log_file}"
    log "--------------------------------------------------------------"
}

main "$@"
