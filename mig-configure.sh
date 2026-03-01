#!/bin/bash
# ============================================================================
# NVIDIA MIG Configuration Tool - Unified TUI + Workflow
# ============================================================================
# Interactive tool that combines the pre.sh and post.sh workflows into a
# single operation. An operator uses the whiptail TUI to select MIG
# partition profiles for each GPU, then the tool automatically:
#   1. Generates a Kubernetes ConfigMap from the selections
#   2. Backs up current cluster state (pre-phase)
#   3. Optionally switches runtime to AUTO, cordons the node
#   4. Applies the MIG configuration with retry + label cycling (post-phase)
#   5. Validates GPU state, optionally generates CDI / switches to CDI, uncordons
#
# CDI/runtime operations are controlled by the CDI_ENABLED flag in config.sh.
# When CDI_ENABLED=false, runtime backup, AUTO/CDI mode switches, and CDI
# generation are all skipped.
#
# This eliminates the manual YAML editing step and the need to run
# pre.sh and post.sh separately.
#
# Standalone pre.sh and post.sh are NOT modified — they remain available
# for operators who prefer the manual two-step workflow.
#
# Dependencies:
#   - config.sh                  (global settings)
#   - common/logging.sh          (log/warn/error)
#   - common/lock.sh             (flock-based mutual exclusion)
#   - common/cdi.sh              (runtime mode and CDI utilities)
#   - common/workload-check.sh   (GPU workload safety gate)
#   - common/template-parser.sh  (MIG template YAML parser)
#   - common/tui.sh              (whiptail TUI screens)
#   - whiptail                   (terminal UI rendering)
#   - kubectl, ssh               (cluster and node operations)
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-02-28
# ============================================================================

# ============================================================================
# SHELL OPTIONS & ERROR HANDLING
# ============================================================================

# set -e   → exit immediately on any command failure
# set -u   → treat unset variables as errors
# set -o pipefail → pipeline fails if any command in it fails (not just the last)
set -euo pipefail

# trap catches any ERR signal (command failure) and prints the failing line number
# before exiting, aiding debugging in non-interactive execution.
trap 'echo "[ERROR] Script failed at ${BASH_SOURCE}:${LINENO}"; exit 1' ERR

# ============================================================================
# CONFIGURATION
# ============================================================================

source config.sh
source common/lock.sh
source common/cdi.sh
source common/workload-check.sh
source common/template-parser.sh
source common/tui.sh

LOCK_FILE="$GLOBAL_LOCK_FILE"

# ============================================================================
# RUNTIME DIRECTORIES
# ============================================================================

# Single timestamped directory for both phases (no duplication).
RUN_LOG_DIR="${BASE_LOG_DIR}/$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${RUN_LOG_DIR}/backup"
LOG_FILE="${RUN_LOG_DIR}/mig-configure.log"

# -p creates parent directories if they don't exist; no error if already present
mkdir -p "$RUN_LOG_DIR" "$BACKUP_DIR"

# Source logging after LOG_FILE is set (logging.sh reads LOG_FILE)
source common/logging.sh

# ============================================================================
# HELPER FUNCTIONS — PRE-PHASE
# ============================================================================

# Backup the ClusterPolicy custom resource from the NVIDIA GPU Operator.
# The ClusterPolicy defines the GPU Operator's overall configuration
# (driver, toolkit, MIG manager settings, etc.).
#
# Side effects:
#   - Creates ${BACKUP_DIR}/cluster-policy.yaml
backup_cluster_policy() {
    log "Backing up ClusterPolicy..."
    # -o yaml exports the full resource definition for later restoration
    kubectl get clusterpolicies.nvidia.com/cluster-policy -o yaml \
        > "${BACKUP_DIR}/cluster-policy.yaml"
}

# Backup the MIG ConfigMap referenced by the ClusterPolicy (if one is configured).
# The MIG ConfigMap defines which MIG partition profiles are available.
#
# Side effects:
#   - Creates ${BACKUP_DIR}/mig-configmap.yaml if a ConfigMap is found
#   - Logs a warning if no MIG ConfigMap is configured
backup_mig_configmap() {
    local mig_configmap

    # jsonpath extracts the ConfigMap name from the ClusterPolicy spec.
    # 2>/dev/null suppresses errors if the field doesn't exist.
    # || true prevents set -e from aborting when the field is missing.
    mig_configmap=$(kubectl get clusterpolicies.nvidia.com/cluster-policy \
        -o jsonpath='{.spec.migManager.config.name}' 2>/dev/null || true)

    # -n checks if the string is non-empty (ConfigMap name was found)
    if [[ -n "$mig_configmap" ]]; then
        log "Backing up MIG ConfigMap: $mig_configmap"
        kubectl get configmap "$mig_configmap" \
            -n "$GPU_OPERATOR_NAMESPACE" -o yaml \
            > "${BACKUP_DIR}/mig-configmap.yaml"
    else
        warn "No MIG ConfigMap configured in ClusterPolicy."
    fi
}

# Backup the MIG-related node labels to a text file.
# These labels (e.g., nvidia.com/mig.config) track which MIG profile
# is currently applied to each node.
#
# Side effects:
#   - Creates ${BACKUP_DIR}/node-mig-labels.txt
backup_node_labels() {
    log "Recording current MIG node labels..."
    # -l filters nodes that have the nvidia.com/mig.config label.
    # -o=custom-columns outputs only the node name and its MIG config label value.
    kubectl get nodes -l nvidia.com/mig.config \
        -o=custom-columns=NODE:.metadata.name,MIG_CONFIG:.metadata.labels."nvidia\.com/mig\.config" \
        > "${BACKUP_DIR}/node-mig-labels.txt"
}

# Cordon the worker node to prevent Kubernetes from scheduling new pods on it
# during MIG reconfiguration.
#
# || true prevents failure if the node is already cordoned.
#
# Side effects:
#   - Node is marked as SchedulingDisabled in Kubernetes
cordon_node() {
    log "Cordoning node ${WORKER_NODE}..."
    kubectl cordon "$WORKER_NODE" >> "$LOG_FILE" 2>&1 || true
}

# ============================================================================
# HELPER FUNCTIONS — POST-PHASE
# ============================================================================

# Poll the MIG configuration state label on the worker node until it
# reaches "success", or bail out on repeated failures / timeout.
#
# The MIG Manager sets the node label nvidia.com/mig.config.state to
# one of: "pending", "success", or "failed". This function polls that
# label at SLEEP_INTERVAL intervals.
#
# Early-success protection: If "success" appears before MIN_SUCCESS_ATTEMPT,
# it is rejected. This guards against stale labels left over from a previous
# configuration — the MIG Manager may not have started processing yet.
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
                return 1
            fi

            log "MIG state SUCCESS detected. Proceeding..."
            return 0

        elif [[ "$state" == "failed" ]]; then
            # (( )) for arithmetic evaluation
            failed_count=$((failed_count + 1))
            warn "MIG state FAILED (${failed_count}/${MAX_FAILED_ALLOWED})"

            if [[ $failed_count -ge $MAX_FAILED_ALLOWED ]]; then
                error "MIG configuration FAILED. Check your MIG config YAML."
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
        count=$((count + 1))
    done
}

# Apply the MIG configuration ConfigMap and trigger the MIG Manager by
# cycling node labels. Retries up to MIG_MAX_APPLY_ATTEMPTS times.
#
# Label cycling strategy: The MIG Manager watches the nvidia.com/mig.config
# label for changes. Simply re-applying the same label value does not trigger
# re-evaluation. To force the Manager to re-process, we set a temporary value
# ("temp") then switch back to "custom-mig-config". The sleep between labels
# gives the Manager time to detect each transition.
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
        log "Applying custom MIG config (${MIG_CONFIG_FILE}) - Attempt ${attempt}"

        # -f = read resource definition from file
        kubectl apply -f "$MIG_CONFIG_FILE" >> "$LOG_FILE" 2>&1

        # --overwrite = replace the label value even if it already exists
        kubectl label node "$WORKER_NODE" nvidia.com/mig.config=temp --overwrite >> "$LOG_FILE" 2>&1
        sleep "$TEMP_LABEL_SLEEP"

        kubectl label node "$WORKER_NODE" nvidia.com/mig.config=custom-mig-config --overwrite >> "$LOG_FILE" 2>&1
        sleep "$CUSTOM_LABEL_SLEEP"

        if wait_for_mig_state; then
            log "MIG successfully applied."
            return 0
        else
            # Re-cycle labels to force the MIG Manager to re-evaluate
            warn "Retrying — cycling labels to trigger MIG Manager re-evaluation..."

            kubectl label node "$WORKER_NODE" nvidia.com/mig.config=temp --overwrite >> "$LOG_FILE" 2>&1
            sleep "$TEMP_LABEL_SLEEP"

            kubectl label node "$WORKER_NODE" nvidia.com/mig.config=custom-mig-config --overwrite >> "$LOG_FILE" 2>&1
            sleep "$CUSTOM_LABEL_SLEEP"
        fi

        attempt=$((attempt + 1))
    done

    error "MIG configuration failed after ${MIG_MAX_APPLY_ATTEMPTS} attempts."
    exit 1
}

# Locate the MIG Manager pod on the worker node and run nvidia-smi inside it
# to validate that GPUs are partitioned correctly.
#
# Side effects:
#   - Prints nvidia-smi output to stdout and log file
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
    kubectl exec -n "$GPU_OPERATOR_NAMESPACE" "$pod" -- nvidia-smi | tee -a "$LOG_FILE"
}

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
# CONFIGMAP GENERATOR
# ============================================================================

# Generate a Kubernetes ConfigMap YAML from the TUI-selected GPU→profile
# assignments. Groups GPUs that share the same profile into a single
# ConfigMap entry with a combined "devices" list.
#
# Arguments:
#   $1 - output_file: Path to write the generated ConfigMap YAML
#
# Side effects:
#   - Creates/overwrites the output file
#   - Exits with 1 if generation fails
generate_mig_configmap() {
    local output_file="$1"

    log "Generating ConfigMap: ${output_file}"

    # declare -A creates an associative (key-value) array.
    # Keys = profile index, values = comma-separated GPU indices.
    # This groups GPUs by their selected profile for efficient ConfigMap output.
    declare -A profile_groups

    local i
    for ((i = 0; i < GPU_COUNT; i++)); do
        local pidx="${GPU_SELECTIONS[$i]}"

        # ${profile_groups[$pidx]+isset} checks if the key exists in the
        # associative array. The "+isset" parameter expansion returns "isset"
        # if the key is set, empty string otherwise.
        if [[ -n "${profile_groups[$pidx]+isset}" ]]; then
            profile_groups[$pidx]+=",${i}"
        else
            profile_groups[$pidx]="${i}"
        fi
    done

    # Write the ConfigMap YAML header.
    # cat with heredoc (<<'EOF') writes multi-line text to the file.
    # The single quotes around EOF prevent variable expansion in the heredoc.
    cat <<'EOF' > "$output_file"
apiVersion: v1
kind: ConfigMap
metadata:
  name: custom-mig-config
  namespace: gpu-operator
data:
  config.yaml: |
    version: v1
    mig-configs:
      custom-mig-config:
EOF

    # Emit one ConfigMap entry per unique profile group.
    # ${!profile_groups[@]} iterates over the keys of the associative array.
    local pidx
    for pidx in "${!profile_groups[@]}"; do
        local gpu_list="${profile_groups[$pidx]}"
        local mig_enabled="${PROFILE_MIG_ENABLED[$pidx]}"
        local profile_name="${PROFILE_NAMES[$pidx]}"

        # Format the device list as a YAML array: [0,1,2] or [3] etc.
        # ${gpu_list//,/, } replaces commas with ", " for YAML formatting.
        local devices_yaml="[${gpu_list//,/, }]"

        # Append this profile entry to the ConfigMap.
        # No heredoc here — we need variable expansion and precise indentation.
        {
            echo "        # --- ${profile_name} ---"
            echo "        - devices: ${devices_yaml}"
            echo "          mig-enabled: ${mig_enabled}"

            # Only emit mig-devices block if MIG is enabled
            if [[ "$mig_enabled" == "true" ]]; then
                echo "          mig-devices:"
                get_profile_mig_devices_yaml "$pidx" 12
            fi
            echo ""
        } >> "$output_file"
    done

    # Validate the output file was created and is non-empty.
    # -s = true if file exists and has size greater than zero.
    if [[ ! -s "$output_file" ]]; then
        error "Failed to generate ConfigMap: output file is empty."
        exit 1
    fi

    log "ConfigMap generated successfully."
}

# ============================================================================
# PHASE ORCHESTRATION
# ============================================================================

# Execute all pre-configuration steps: backup cluster state, check for
# active workloads, optionally switch runtime to AUTO (when CDI_ENABLED=true),
# and cordon the node.
#
# Side effects:
#   - Creates backup files in BACKUP_DIR
#   - Switches runtime to AUTO mode on the worker node (CDI_ENABLED only)
#   - Cordons the worker node
run_pre_phase() {
    log "=============================================================="
    log " PRE-PHASE: Preparing node for MIG reconfiguration"
    log "=============================================================="

    # Step 1: Backup ClusterPolicy (GPU Operator configuration)
    backup_cluster_policy

    # Step 2: Backup MIG ConfigMap (partition profile definitions)
    backup_mig_configmap

    # Step 3: Backup MIG node labels (current partition state)
    backup_node_labels

    # Steps 4 & 6: CDI/runtime operations (only when CDI is enabled)
    if [[ "${CDI_ENABLED}" == "true" ]]; then
        # Step 4: Backup NVIDIA runtime config (config.toml from worker node)
        backup_runtime_config "$WORKER_NODE" "$BACKUP_DIR" "$LOG_FILE"
    fi

    # Step 5: Abort if GPU workloads (dgx-* pods) are still running
    check_gpu_workloads "$WORKER_NODE"

    if [[ "${CDI_ENABLED}" == "true" ]]; then
        # Step 6: Detect runtime mode and switch to AUTO if needed
        log "Checking current NVIDIA runtime mode..."
        local current_mode
        current_mode=$(get_current_runtime_mode "$WORKER_NODE")

        if [[ "$current_mode" == "auto" ]]; then
            log "Runtime already in AUTO mode. No change required."
        else
            log "Current Runtime Mode : ${current_mode}"
            log "Target  Runtime Mode : auto"
            log "Switching runtime mode to AUTO..."
            set_runtime_auto "$WORKER_NODE" "$LOG_FILE"
            log "Runtime mode successfully changed to AUTO."
        fi
    else
        log "CDI is disabled (CDI_ENABLED=false). Skipping runtime backup and AUTO switch."
    fi

    # Step 7: Cordon node to block new pod scheduling during reconfiguration
    cordon_node

    log "Pre-phase completed."
}

# Execute all post-configuration steps: apply MIG config, validate,
# optionally generate CDI and switch to CDI (when CDI_ENABLED=true),
# verify containerd, and uncordon.
#
# Side effects:
#   - Applies MIG ConfigMap and cycles node labels
#   - Generates CDI specification on the worker node (CDI_ENABLED only)
#   - Switches runtime to CDI mode (CDI_ENABLED only)
#   - Uncordons the worker node
run_post_phase() {
    log "=============================================================="
    log " POST-PHASE: Applying MIG configuration"
    log "=============================================================="

    # Step 1: Apply MIG configuration with retry and label cycling
    apply_mig_with_retry

    # Step 2: Validate GPU partition state via nvidia-smi
    run_nvidia_smi

    # Steps 3–4: CDI operations (only when CDI is enabled)
    if [[ "${CDI_ENABLED}" == "true" ]]; then
        # Step 3: Generate CDI specification on the worker node
        log "Generating CDI specification..."
        generate_cdi "$WORKER_NODE" "$LOG_FILE"

        # Step 4: Detect current runtime mode and switch to CDI if needed
        log "Checking current NVIDIA runtime mode..."
        local current_mode
        current_mode=$(get_current_runtime_mode "$WORKER_NODE")

        if [[ "$current_mode" == "cdi" ]]; then
            log "Runtime already in CDI mode."
        else
            log "Current Runtime Mode : ${current_mode}"
            log "Target  Runtime Mode : cdi"
            log "Switching runtime mode to CDI..."
            switch_runtime_to_cdi "$WORKER_NODE" "$LOG_FILE"
            log "Runtime mode successfully changed to CDI."
        fi
    else
        log "CDI is disabled (CDI_ENABLED=false). Skipping CDI generation and runtime switch."
    fi

    # Step 5: Verify containerd is running before uncordoning
    verify_containerd

    # Step 6: Uncordon the worker node to allow pod scheduling
    log "Uncordoning node ${WORKER_NODE}..."
    kubectl uncordon "$WORKER_NODE" >> "$LOG_FILE" 2>&1

    log "Post-phase completed."
}

# ============================================================================
# DEPENDENCY CHECKS
# ============================================================================

# Verify all required external commands are available before starting.
#
# Returns:
#   0 if all dependencies are present
#   1 if any are missing (with error message)
check_dependencies() {
    local missing=()

    # command -v checks if a command exists in PATH without executing it
    local cmd
    for cmd in whiptail kubectl ssh tput; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    # ${#missing[@]} = length of the missing array
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "[ERROR] Missing required commands: ${missing[*]}" >&2
        return 1
    fi

    return 0
}

# ============================================================================
# MAIN LOGIC
# ============================================================================

main() {
    # Step 1: Verify all external dependencies are installed
    check_dependencies

    # Step 2: Load the MIG template and populate profile arrays
    log "Loading MIG template: ${MIG_TEMPLATE_FILE}"
    if ! load_template "$MIG_TEMPLATE_FILE"; then
        error "Failed to load template file: ${MIG_TEMPLATE_FILE}"
        exit 1
    fi
    log "Loaded ${PROFILE_COUNT} profiles for ${GPU_MODEL} (${GPU_COUNT} GPUs)"

    # Step 3: Verify TUI prerequisites (whiptail + terminal size)
    if ! check_tui_deps; then
        error "TUI prerequisites not met."
        exit 1
    fi

    # Step 4: Run the interactive TUI (no lock held during user interaction)
    if ! run_tui; then
        log "User cancelled. No changes made."
        exit 0
    fi

    # Step 5: Acquire global lock AFTER TUI (minimize lock hold time)
    acquire_lock "$LOCK_FILE"

    log "=============================================================="
    log " NVIDIA MIG Configuration Tool"
    log " Node        : ${WORKER_NODE}"
    log " GPU Model   : ${GPU_MODEL}"
    log " Started At  : $(date +"%Y-%m-%d %H:%M:%S")"
    log " Run Folder  : ${RUN_LOG_DIR}"
    log "=============================================================="

    # Log the selected configuration for the record
    local i
    for ((i = 0; i < GPU_COUNT; i++)); do
        local pidx="${GPU_SELECTIONS[$i]}"
        log "  GPU-${i} → ${PROFILE_NAMES[$pidx]}"
    done

    # Step 6: Generate the Kubernetes ConfigMap from selections
    generate_mig_configmap "$MIG_CONFIG_FILE"

    # Step 7: Execute pre-phase (backup, workload check, AUTO mode, cordon)
    run_pre_phase

    # Step 8: Execute post-phase (apply MIG, validate, CDI, uncordon)
    run_post_phase

    log "=============================================================="
    log " MIG CONFIGURATION COMPLETED SUCCESSFULLY"
    log " ConfigMap   : ${MIG_CONFIG_FILE}"
    log " Backup Dir  : ${BACKUP_DIR}"
    log " Log File    : ${LOG_FILE}"
    log "=============================================================="
}

main "$@"
