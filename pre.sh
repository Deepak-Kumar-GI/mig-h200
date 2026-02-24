#!/bin/bash
# ==============================================================
# NVIDIA GPU Pre-Configuration Script
# ==============================================================
#
# Purpose:
#   Prepare a worker node for MIG reconfiguration.
#
# What this script does:
#   1. Acquire global execution lock
#   2. Backup ClusterPolicy
#   3. Backup MIG ConfigMap
#   4. Backup current MIG node labels
#   5. Backup NVIDIA container runtime config
#   6. Switch NVIDIA runtime mode to AUTO
#   7. Cordon the worker node
#
# NOTE:
#   After completion, all GPU workloads must be stopped
#   before proceeding with MIG reconfiguration.
#
# ==============================================================

set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO."; exit 1' ERR

# --------------------------------------------------------------
# Load Shared Configuration & Utilities
# --------------------------------------------------------------
source config.sh      # Global variables
source lock.sh        # Locking mechanism
source cdi.sh         # Runtime helper functions

# Use single global lock
LOCK_FILE="$GLOBAL_LOCK_FILE"

# --------------------------------------------------------------
# Runtime Directories
# --------------------------------------------------------------
# Create timestamped run directory for logs and backups
RUN_LOG_DIR="${BASE_LOG_DIR}/$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${RUN_LOG_DIR}/backup"
log_file="${RUN_LOG_DIR}/pre.log"

mkdir -p "$RUN_LOG_DIR" "$BACKUP_DIR"

# --------------------------------------------------------------
# Logging Functions
# --------------------------------------------------------------
# All logs are printed to console and written to log file
log()  { echo "[$(date +"%H:%M:%S")] [INFO]  $1"  | tee -a "$log_file"; }
warn() { echo "[$(date +"%H:%M:%S")] [WARN]  $1"  | tee -a "$log_file"; }
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
# Backup MIG ConfigMap
# --------------------------------------------------------------
backup_mig_configmap() {
    local mig_configmap

    # Extract MIG ConfigMap name from ClusterPolicy
    mig_configmap=$(kubectl get clusterpolicies.nvidia.com/cluster-policy \
        -o jsonpath='{.spec.migManager.config.name}' 2>/dev/null || true)

    if [[ -n "$mig_configmap" ]]; then
        log "Backing up MIG ConfigMap: $mig_configmap"
        kubectl get configmap "$mig_configmap" \
            -n "$GPU_OPERATOR_NAMESPACE" -o yaml \
            > "${BACKUP_DIR}/mig-configmap.yaml"
    else
        warn "No MIG ConfigMap configured."
    fi
}

# --------------------------------------------------------------
# Backup Current MIG Node Labels
# --------------------------------------------------------------
backup_node_labels() {
    log "Recording current MIG node labels..."

    kubectl get nodes -l nvidia.com/mig.config \
        -o=custom-columns=NODE:.metadata.name,MIG_CONFIG:.metadata.labels."nvidia\.com/mig\.config" \
        > "${BACKUP_DIR}/node-mig-labels.txt" || true

    log "Node labels saved to ${BACKUP_DIR}/node-mig-labels.txt"
}

# --------------------------------------------------------------
# Cordon Node
# --------------------------------------------------------------
# Prevents new workloads from being scheduled on the node
cordon_node() {
    log "Cordoning node ${WORKER_NODE}..."
    kubectl cordon "$WORKER_NODE" >> "$log_file" 2>&1 || true
}

# --------------------------------------------------------------
# Main Execution
# --------------------------------------------------------------
main() {

    # Acquire exclusive execution lock
    acquire_lock "$LOCK_FILE"
    log "Lock acquired on $LOCK_FILE"

    # Display structured execution banner
    log "=============================================================="
    log " NVIDIA GPU Pre-Configuration"
    log " Node        : ${WORKER_NODE}"
    log " Started At  : $(date +"%Y-%m-%d %H:%M:%S")"
    log " Run Folder  : ${RUN_LOG_DIR}"
    log "=============================================================="

    # Perform backup steps
    backup_cluster_policy
    backup_mig_configmap
    backup_node_labels
    backup_runtime_config "$WORKER_NODE" "$BACKUP_DIR" "$log_file"

    # Switch runtime to AUTO mode before MIG change
    set_runtime_auto "$WORKER_NODE" "$log_file"

    # Cordon worker node
    cordon_node

    # Final success summary
    log "--------------------------------------------------------------"
    log " PRE-CONFIGURATION COMPLETED SUCCESSFULLY"
    log " Backup Location : ${BACKUP_DIR}"
    log " Log File        : ${log_file}"
    log "--------------------------------------------------------------"
    log "ACTION REQUIRED: Stop all GPU workloads on ${WORKER_NODE} before proceeding with MIG reconfiguration."
}

main "$@"
