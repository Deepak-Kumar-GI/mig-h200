#!/bin/bash
# ==============================================================
# NVIDIA GPU Pre-Configuration (Function-Based)
# ==============================================================
set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO."; exit 1' ERR

source lock.sh
source cdi.sh

LOCK_FILE="/var/lock/nvidia-mig-config.lock"
WORKER_NODE="gu-k8s-worker"
GPU_OPERATOR_NAMESPACE="gpu-operator"

BASE_LOG_DIR="logs"
RUN_LOG_DIR="${BASE_LOG_DIR}/$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${RUN_LOG_DIR}/backup"
log_file="${RUN_LOG_DIR}/pre.log"

log() { echo "[$(date +"%H:%M:%S")] [INFO] $1" | tee -a "$log_file"; }
warn() { echo "[$(date +"%H:%M:%S")] [WARN] $1" | tee -a "$log_file"; }

mkdir -p "$RUN_LOG_DIR" "$BACKUP_DIR"

# -------------------------
# Functions
# -------------------------
backup_cluster_policy() {
    log "Backing up ClusterPolicy..."
    kubectl get clusterpolicies.nvidia.com/cluster-policy -o yaml > "${BACKUP_DIR}/cluster-policy.yaml"
}

backup_mig_configmap() {
    local mig_configmap
    mig_configmap=$(kubectl get clusterpolicies.nvidia.com/cluster-policy \
        -o jsonpath='{.spec.migManager.config.name}' 2>/dev/null || true)

    if [[ -n "$mig_configmap" ]]; then
        log "Backing up MIG ConfigMap: $mig_configmap"
        kubectl get configmap "$mig_configmap" -n "$GPU_OPERATOR_NAMESPACE" -o yaml > "${BACKUP_DIR}/mig-configmap.yaml"
    else
        warn "No MIG ConfigMap configured."
    fi
}

backup_node_labels() {
    log "Recording current MIG node labels..."
    kubectl get nodes -l nvidia.com/mig.config \
        -o=custom-columns=NODE:.metadata.name,MIG_CONFIG:.metadata.labels."nvidia\.com/mig\.config" \
        > "${BACKUP_DIR}/node-mig-labels.txt" || true
    log "Node labels saved to ${BACKUP_DIR}/node-mig-labels.txt"
}

backup_runtime_config() {
    log "Backing up NVIDIA container runtime config..."
    scp "${WORKER_NODE}:/etc/nvidia-container-runtime/config.toml" \
        "${BACKUP_DIR}/config.toml.bak.$(date +%s)" >> "$log_file" 2>&1
}

cordon_node() {
    log "Cordoning node ${WORKER_NODE}..."
    kubectl cordon "$WORKER_NODE" >> "$log_file" 2>&1 || true
}

# -------------------------
# Main Execution
# -------------------------
main() {
    # Acquire lock
    acquire_lock "$LOCK_FILE"

    log "=============================================================="
    log " NVIDIA GPU Pre-Configuration"
    log " Node        : ${WORKER_NODE}"
    log " Started At  : $(date +"%Y-%m-%d %H:%M:%S")"
    log " Run Folder  : ${RUN_LOG_DIR}"
    log "=============================================================="

    # Backup steps
    backup_cluster_policy
    backup_mig_configmap
    backup_node_labels
    backup_runtime_config

    # Set runtime to AUTO
    set_runtime_auto "$WORKER_NODE" "$log_file"

    # Cordon node
    cordon_node

    log "--------------------------------------------------------------"
    log " PRE-CONFIGURATION COMPLETED SUCCESSFULLY"
    log " Backup Location : ${BACKUP_DIR}"
    log " Log File        : ${log_file}"
    log "--------------------------------------------------------------"
    log "ACTION REQUIRED: Stop all GPU workloads before proceeding with MIG reconfiguration."
}

main "$@"
