#!/bin/bash
# ============================================================================
# NVIDIA GPU Post-Configuration Script
# ============================================================================
# Applies the MIG partition configuration to the worker node and completes
# post-reprovisioning setup (optional CDI generation, runtime switch, uncordon).
# Run this script AFTER pre.sh has cordoned the node and switched the
# runtime to AUTO mode, and after the operator has edited the MIG
# ConfigMap and deleted DGX workloads.
#
# CDI operations (steps 5–6) are controlled by the CDI_ENABLED flag in
# config.sh. When CDI_ENABLED=false, the script skips CDI generation
# and the CDI runtime switch.
#
# Workflow (executed in order):
#   1. Acquire global execution lock
#   2. Apply custom MIG configuration YAML (with retry + label cycling)
#   3. Wait for MIG state to reach SUCCESS (early-success protection)
#   4. Validate GPU state via nvidia-smi inside the MIG Manager pod
#   5. Generate CDI specification on the worker node   (CDI_ENABLED only)
#   6. Detect runtime mode; switch to CDI if needed     (CDI_ENABLED only)
#   7. Verify containerd is running
#   8. Uncordon the worker node
#
# Dependencies:
#   - config.sh        (global settings)
#   - common/lock.sh   (flock-based mutual exclusion)
#   - common/cdi.sh    (runtime mode and CDI generation utilities)
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-02-26
# ============================================================================

# ============================================================================
# SHELL OPTIONS & ERROR HANDLING
# ============================================================================

# set -e  = exit immediately on any command failure
# set -u  = treat unset variables as errors
# set -o pipefail = a pipeline fails if ANY command in it fails (not just the last)
set -euo pipefail

# trap ... ERR fires on any command that exits non-zero.
# ${BASH_SOURCE} = the filename of the currently executing script
# ${LINENO}      = the line number where the error occurred
trap 'echo "[ERROR] Script failed at ${BASH_SOURCE}:${LINENO}"; exit 1' ERR

# ============================================================================
# CONFIGURATION
# ============================================================================

source config.sh
source common/lock.sh
source common/cdi.sh

LOCK_FILE="$GLOBAL_LOCK_FILE"

# ============================================================================
# CONSTANTS
# ============================================================================

RUN_LOG_DIR="${BASE_LOG_DIR}/$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${RUN_LOG_DIR}/backup"
log_file="${RUN_LOG_DIR}/post.log"

mkdir -p "$RUN_LOG_DIR" "$BACKUP_DIR"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Log an INFO-level message to both the console and the log file.
# tee -a = append to file while also printing to stdout
#          (-a = append, without it tee would overwrite)
log()  { echo "[$(date +"%H:%M:%S")] [INFO]  $1" | tee -a "$log_file"; }

# Log a WARN-level message to both the console and the log file.
warn() { echo "[$(date +"%H:%M:%S")] [WARN]  $1" | tee -a "$log_file"; }

# Log an ERROR-level message to both the console and the log file.
error(){ echo "[$(date +"%H:%M:%S")] [ERROR] $1" | tee -a "$log_file"; }

# ----------------------------------------------------------------------------

# Poll the MIG configuration state label on the worker node until it
# reaches "success", or bail out on repeated failures / timeout.
#
# The MIG Manager sets the node label nvidia.com/mig.config.state to
# one of: "pending", "success", or "failed". This function polls that
# label at SLEEP_INTERVAL intervals.
#
# Early-success protection: If "success" appears before MIN_SUCCESS_ATTEMPT,
# it is rejected. This guards against stale labels left over from a previous
# configuration — the MIG Manager may not have started processing yet, so
# the label still reads "success" from the prior run.
#
# Returns:
#   0 - MIG state reached "success" after MIN_SUCCESS_ATTEMPT polls
#   1 - "success" detected too early (caller should retry with label cycling)
#
# Side effects:
#   - Exits the script (exit 1) if failures exceed MAX_FAILED_ALLOWED
#   - Exits the script (exit 1) on timeout (MAX_RETRIES reached while pending)
#   - Exits the script (exit 1) on unexpected state values
wait_for_mig_state() {

    log "Checking MIG state for node ${WORKER_NODE}..."

    local count=1
    local failed_count=0

    while true; do

        local state
        # -o jsonpath extracts a single value from the Kubernetes resource JSON.
        # The backslash-escaped dots (nvidia\.com) are literal dots in the label key.
        # 2>/dev/null suppresses kubectl connection warnings.
        # || echo "" provides an empty fallback so set -e does not abort on failure.
        state=$(kubectl get node "$WORKER_NODE" \
            -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}' 2>/dev/null || echo "")

        log "Current MIG state: '${state}' (Attempt: $count)"

        if [[ "$state" == "success" ]]; then

            # Early-success protection: reject success before enough polls
            # to ensure the MIG Manager has actually re-evaluated the config
            # (not just reporting the stale state from the previous run).
            if [[ $count -lt $MIN_SUCCESS_ATTEMPT ]]; then
                error "MIG success detected too early (attempt $count)"
                return 1   # trigger retry logic in the caller
            fi

            log "MIG state SUCCESS detected. Proceeding..."
            return 0

        elif [[ "$state" == "failed" ]]; then

            # (( )) for arithmetic evaluation
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

# ----------------------------------------------------------------------------

# Apply the MIG configuration ConfigMap and trigger the MIG Manager by
# cycling node labels. Retries up to MIG_MAX_APPLY_ATTEMPTS times.
#
# Label cycling strategy: The MIG Manager watches the nvidia.com/mig.config
# label for changes. Simply re-applying the same label value does not trigger
# re-evaluation. To force the Manager to re-process, we set a temporary value
# ("temp") then switch back to "custom-mig-config". The sleep between labels
# gives the Manager time to detect each transition.
#
# On failure (early-success or timeout), the function re-cycles labels to
# force another MIG Manager evaluation before the next attempt.
#
# Returns:
#   0 on success
#
# Side effects:
#   - Applies the MIG ConfigMap to the cluster
#   - Modifies nvidia.com/mig.config node label
#   - Exits the script (exit 1) after MIG_MAX_APPLY_ATTEMPTS failures
apply_mig_with_retry() {

    local attempt=1

    while [[ $attempt -lt $MIG_MAX_APPLY_ATTEMPTS ]]; do

        log "Applying custom MIG config (${MIG_CONFIG_FILE}) - MIG Attempt $((attempt))"
        # -f = read resource definition from file
        kubectl apply -f "$MIG_CONFIG_FILE" >> "$log_file" 2>&1

        # --overwrite = replace the label value even if it already exists
        kubectl label node "$WORKER_NODE" nvidia.com/mig.config=temp --overwrite >> "$log_file" 2>&1
        sleep "$TEMP_LABEL_SLEEP"

        kubectl label node "$WORKER_NODE" nvidia.com/mig.config=custom-mig-config --overwrite >> "$log_file" 2>&1
        sleep "$CUSTOM_LABEL_SLEEP"

        if wait_for_mig_state; then
            log "MIG successfully applied."
            return 0
        else
            # Re-cycle labels to force the MIG Manager to re-evaluate
            warn "Retrying — cycling labels to trigger MIG Manager re-evaluation..."

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

# ----------------------------------------------------------------------------

# Locate the MIG Manager pod on the worker node and run nvidia-smi inside it
# to validate that GPUs are partitioned correctly.
#
# Side effects:
#   - Prints nvidia-smi output to stdout
#   - Exits the script (exit 1) if the MIG Manager pod is not found
run_nvidia_smi() {

    log "Locating MIG Manager pod..."

    local pod
    # -o wide = include extra columns (including the NODE column) so we can
    #           filter by the target worker node.
    # Pipeline: list all pods → filter to mig-manager → filter to our node → extract pod name
    pod=$(kubectl get pods -n "$GPU_OPERATOR_NAMESPACE" -o wide \
        | grep mig-manager | grep "$WORKER_NODE" | awk '{print $1}')

    # -z = true if string is empty (pod not found)
    if [[ -z "$pod" ]]; then
        error "MIG Manager pod not found."
        exit 1
    fi

    log "Executing nvidia-smi inside pod ${pod}..."
    # kubectl exec -- nvidia-smi runs nvidia-smi inside the container.
    # The "--" separates kubectl flags from the command to execute.
    kubectl exec -n "$GPU_OPERATOR_NAMESPACE" "$pod" -- nvidia-smi
}

# ----------------------------------------------------------------------------

# Verify that the containerd service is running on the worker node.
# containerd must be active for Kubernetes to schedule pods after uncordoning.
#
# Side effects:
#   - Exits the script (exit 1) if containerd is not active
verify_containerd() {

    log "Verifying containerd service status..."

    # systemctl is-active checks whether a systemd unit is running.
    # --quiet suppresses output; only the exit code is used (0 = active).
    if ssh "$WORKER_NODE" "systemctl is-active --quiet containerd"; then
        log "containerd is active."
    else
        error "containerd is NOT active."
        exit 1
    fi
}

# ============================================================================
# MAIN LOGIC
# ============================================================================

main() {

    # Step 1: Acquire global lock to prevent concurrent MIG/CDI operations
    acquire_lock "$LOCK_FILE"

    log "=============================================================="
    log " NVIDIA GPU Post-Configuration"
    log " Node        : ${WORKER_NODE}"
    log " Started At  : $(date +"%Y-%m-%d %H:%M:%S")"
    log " Run Folder  : ${RUN_LOG_DIR}"
    log "=============================================================="

    # Step 2: Apply MIG configuration with retry and label cycling
    apply_mig_with_retry

    # Step 3: Validate GPU partition state via nvidia-smi
    run_nvidia_smi

    # Steps 4–5: CDI operations (only when CDI is enabled)
    if [[ "${CDI_ENABLED}" == "true" ]]; then
        # Step 4: Generate CDI specification on the worker node
        log "Generating CDI specification..."
        generate_cdi "$WORKER_NODE" "$log_file"

        # Step 5: Detect current runtime mode and switch to CDI if needed
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
    else
        log "CDI is disabled (CDI_ENABLED=false). Skipping CDI generation and runtime switch."
    fi

    # Step 6: Verify containerd is running before uncordoning
    verify_containerd

    # Step 7: Uncordon the worker node to allow pod scheduling
    log "Uncordoning node ${WORKER_NODE}..."
    kubectl uncordon "$WORKER_NODE" >> "$log_file" 2>&1

    log "=============================================================="
    log " POST-CONFIGURATION COMPLETED SUCCESSFULLY"
    log " Log File        : ${log_file}"
    log "=============================================================="
}

main "$@"
