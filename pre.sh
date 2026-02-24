#!/bin/bash
# ==============================================================
# NVIDIA GPU Pre-Configuration
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

# Acquire lock
acquire_lock "$LOCK_FILE"

log "Starting NVIDIA GPU Pre-Configuration"

# Backup cluster policy
kubectl get clusterpolicies.nvidia.com/cluster-policy -o yaml > "${BACKUP_DIR}/cluster-policy.yaml"

# Backup MIG ConfigMap
MIG_CONFIGMAP=$(kubectl get clusterpolicies.nvidia.com/cluster-policy -o jsonpath='{.spec.migManager.config.name}' 2>/dev/null || true)
if [[ -n "$MIG_CONFIGMAP" ]]; then
    kubectl get configmap "$MIG_CONFIGMAP" -n "$GPU_OPERATOR_NAMESPACE" -o yaml > "${BACKUP_DIR}/mig-configmap.yaml"
else
    warn "No MIG ConfigMap configured."
fi

# Backup runtime config
scp "${WORKER_NODE}:/etc/nvidia-container-runtime/config.toml" "${BACKUP_DIR}/config.toml.bak.$(date +%s)" >> "$log_file" 2>&1

# Set runtime to AUTO using shared function
set_runtime_auto "$WORKER_NODE" "$log_file"

# Cordon node
kubectl cordon "$WORKER_NODE" >> "$log_file" 2>&1
log "Node cordoned. Pre-configuration completed."
