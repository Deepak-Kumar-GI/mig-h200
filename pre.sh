#!/bin/bash
# ==============================================================
# NVIDIA GPU Pre-Configuration Script
# ==============================================================
#
# PURPOSE
# -------
# Prepare the worker node safely before NVIDIA MIG reprovisioning.
#
# This script ensures:
#   - Existing cluster configuration is backed up
#   - Current MIG configuration is preserved
#   - Node labels are recorded
#   - Runtime configuration is backed up
#   - GPU workloads are validated
#   - NVIDIA runtime is switched to AUTO mode (if required)
#   - Node is cordoned to prevent new scheduling
#
# WHAT THIS SCRIPT DOES (STEP-BY-STEP)
# ------------------------------------
#   STEP 1  : Acquire global execution lock
#   STEP 2  : Backup ClusterPolicy
#   STEP 3  : Backup MIG ConfigMap (if configured)
#   STEP 4  : Backup MIG-related node labels
#   STEP 5  : Backup NVIDIA runtime configuration
#   STEP 6  : Check active GPU workloads
#   STEP 7  : Detect current NVIDIA runtime mode
#   STEP 8  : Switch NVIDIA runtime mode → AUTO (if required)
#   STEP 9  : Cordon worker node
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
source common/workload-check.sh

LOCK_FILE="$GLOBAL_LOCK_FILE"

# --------------------------------------------------------------
# Runtime Directories
# --------------------------------------------------------------
RUN_LOG_DIR="${BASE_LOG_DIR}/$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${RUN_LOG_DIR}/backup"
log_file="${RUN_LOG_DIR}/pre.log"

mkdir -p "$RUN_LOG_DIR" "$BACKUP_DIR"

# --------------------------------------------------------------
# Logging Functions
# --------------------------------------------------------------
log()  { echo "[$(date +"%H:%M:%S")] [INFO]  $1" | tee -a "$log_file"; }
warn() { echo "[$(date +"%H:%M:%S")] [WARN]  $1" | tee -a "$log_file"; }
error(){ echo "[$(date +"%H:%M:%S")] [ERROR] $1" | tee -a "$log_file"; }

# --------------------------------------------------------------
# Backup ClusterPolicy
# --------------------------------------------------------------
backup_cluster_policy() {
    log "Backing up ClusterPolicy..."
    kubectl get clusterpolicies.nvidia.com/cluster-policy -o yaml \
        > "${BACKUP_DIR}/cluster-policy.yaml"
}

# --------------------------------------------------------------
# Backup MIG ConfigMap (if exists)
# --------------------------------------------------------------
backup_mig_configmap() {
    local mig_configmap
    mig_configmap=$(kubectl get clusterpolicies.nvidia.com/cluster-policy \
        -o jsonpath='{.spec.migManager.config.name}' 2>/dev/null || true)

    if [[ -n "$mig_configmap" ]]; then
        log "Backing up MIG ConfigMap: $mig_configmap"
        kubectl get configmap "$mig_configmap" \
            -n "$GPU_OPERATOR_NAMESPACE" -o yaml \
            > "${BACKUP_DIR}/mig-configmap.yaml"
    else
        warn "No MIG ConfigMap configured in ClusterPolicy."
    fi
}

# --------------------------------------------------------------
# Backup MIG Node Labels
# --------------------------------------------------------------
backup_node_labels() {
    log "Recording current MIG node labels..."
    kubectl get nodes -l nvidia.com/mig.config \
        -o=custom-columns=NODE:.metadata.name,MIG_CONFIG:.metadata.labels."nvidia\.com/mig\.config" \
        > "${BACKUP_DIR}/node-mig-labels.txt"
}

# --------------------------------------------------------------
# Cordon Node
# --------------------------------------------------------------
cordon_node() {
    log "Cordoning node ${WORKER_NODE}..."
    kubectl cordon "$WORKER_NODE" >> "$log_file" 2>&1 || true
}

# --------------------------------------------------------------
# Main Execution
# --------------------------------------------------------------
main() {

    # STEP 1
    acquire_lock "$LOCK_FILE"

    log "=============================================================="
    log " NVIDIA GPU Pre-Configuration"
    log " Node        : ${WORKER_NODE}"
    log " Started At  : $(date +"%Y-%m-%d %H:%M:%S")"
    log " Run Folder  : ${RUN_LOG_DIR}"
    log "=============================================================="

    # STEP 2
    backup_cluster_policy

    # STEP 3
    backup_mig_configmap

    # STEP 4
    backup_node_labels

    # STEP 5
    backup_runtime_config "$WORKER_NODE" "$BACKUP_DIR" "$log_file"

    # STEP 6
    check_gpu_workloads "$WORKER_NODE"

    # STEP 7
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

    # STEP 8
    cordon_node

    log "--------------------------------------------------------------"
    log " PRE-CONFIGURATION COMPLETED SUCCESSFULLY"
    log " Backup Location : ${BACKUP_DIR}"
    log " Log File        : ${log_file}"
    log "--------------------------------------------------------------"
}

main "$@"