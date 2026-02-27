#!/bin/bash
# ============================================================================
# NVIDIA GPU Pre-Configuration Script
# ============================================================================
# Prepare the worker node safely before NVIDIA MIG reprovisioning.
#
# This is the FIRST script in the reprovisioning workflow (pre.sh → post.sh).
# It creates backups of all GPU-related configurations, validates that no
# GPU workloads are running, switches the runtime to AUTO mode so the
# MIG Manager can freely reconfigure partitions, and cordons the node
# to prevent new pods from being scheduled during reconfiguration.
#
# WHAT THIS SCRIPT DOES (STEP-BY-STEP)
# ------------------------------------
#   STEP 1  : Acquire global execution lock
#   STEP 2  : Backup ClusterPolicy
#   STEP 3  : Backup MIG ConfigMap (if configured)
#   STEP 4  : Backup MIG-related node labels
#   STEP 5  : Backup NVIDIA runtime configuration
#   STEP 6  : Check active GPU workloads
#   STEP 7  : Detect current NVIDIA runtime mode and switch to AUTO
#   STEP 8  : Cordon worker node
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-02-26
# ============================================================================

# set -e   → exit immediately on any command failure
# set -u   → treat unset variables as errors
# set -o pipefail → pipeline fails if any command in it fails (not just the last)
set -euo pipefail

# trap catches any ERR signal (command failure) and prints the failing line number
# before exiting, aiding debugging in non-interactive execution.
trap 'echo "[ERROR] Script failed at ${BASH_SOURCE}:${LINENO}"; exit 1' ERR

# ============================================================================
# LOAD SHARED CONFIGURATION & UTILITIES
# ============================================================================

source config.sh                   # Global settings (node name, namespaces, retry params)
source common/lock.sh              # acquire_lock()
source common/cdi.sh               # get_current_runtime_mode(), set_runtime_auto(), backup_runtime_config()
source common/workload-check.sh    # check_gpu_workloads()

LOCK_FILE="$GLOBAL_LOCK_FILE"

# ============================================================================
# RUNTIME DIRECTORIES
# ============================================================================

# Each run creates a timestamped directory for logs and backups.
# Format: logs/YYYYMMDD-HHMMSS/
RUN_LOG_DIR="${BASE_LOG_DIR}/$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${RUN_LOG_DIR}/backup"
log_file="${RUN_LOG_DIR}/pre.log"

# -p creates parent directories if they don't exist; no error if already present
mkdir -p "$RUN_LOG_DIR" "$BACKUP_DIR"

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

# tee -a writes to both stdout (console) and appends to the log file,
# so the operator sees output in real time while it's also persisted.
log()  { echo "[$(date +"%H:%M:%S")] [INFO]  $1" | tee -a "$log_file"; }
warn() { echo "[$(date +"%H:%M:%S")] [WARN]  $1" | tee -a "$log_file"; }
error(){ echo "[$(date +"%H:%M:%S")] [ERROR] $1" | tee -a "$log_file"; }

# ============================================================================
# HELPER FUNCTIONS
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
# is currently applied to each node. Preserving them allows comparison
# after reconfiguration.
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
    kubectl cordon "$WORKER_NODE" >> "$log_file" 2>&1 || true
}

# ============================================================================
# MAIN LOGIC
# ============================================================================

main() {

    # STEP 1: Acquire global lock to prevent concurrent MIG/CDI operations
    acquire_lock "$LOCK_FILE"

    log "=============================================================="
    log " NVIDIA GPU Pre-Configuration"
    log " Node        : ${WORKER_NODE}"
    log " Started At  : $(date +"%Y-%m-%d %H:%M:%S")"
    log " Run Folder  : ${RUN_LOG_DIR}"
    log "=============================================================="

    # STEP 2: Backup ClusterPolicy (GPU Operator configuration)
    backup_cluster_policy

    # STEP 3: Backup MIG ConfigMap (partition profile definitions)
    backup_mig_configmap

    # STEP 4: Backup MIG node labels (current partition state)
    backup_node_labels

    # STEP 5: Backup NVIDIA runtime config (config.toml from worker node)
    backup_runtime_config "$WORKER_NODE" "$BACKUP_DIR" "$log_file"

    # STEP 6: Abort if GPU workloads (dgx-* pods) are still running
    check_gpu_workloads "$WORKER_NODE"

    # STEP 7: Detect runtime mode and switch to AUTO if needed
    log "Checking current NVIDIA runtime mode..."
    current_mode=$(get_current_runtime_mode "$WORKER_NODE")

    if [[ "$current_mode" == "auto" ]]; then
        log "Runtime already in AUTO mode. No change required."
    else
        log "Current Runtime Mode : ${current_mode}"
        log "Target  Runtime Mode : auto"
        log "Switching runtime mode to AUTO..."
        set_runtime_auto "$WORKER_NODE" "$log_file"
        log "Runtime mode successfully changed to AUTO."
    fi

    # STEP 8: Cordon node to block new pod scheduling during reconfiguration
    cordon_node

    log "--------------------------------------------------------------"
    log " PRE-CONFIGURATION COMPLETED SUCCESSFULLY"
    log " Backup Location : ${BACKUP_DIR}"
    log " Log File        : ${log_file}"
    log "--------------------------------------------------------------"
}

main "$@"
