#!/bin/bash

# ============================================================== 
#  NVIDIA GPU Pre-Configuration Utility with Logs Folder
# ============================================================== 

set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO."; exit 1' ERR

WORKER_NODE="gu-k8s-worker"
GPU_OPERATOR_NAMESPACE="gpu-operator"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# -------------------------------
# Logs & Backup Setup
# -------------------------------
BASE_LOG_DIR="logs"
PRE_LOG_DIR="${BASE_LOG_DIR}/pre"
BACKUP_DIR="${BASE_LOG_DIR}/backup/backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$PRE_LOG_DIR" "$BACKUP_DIR"

log_file="${PRE_LOG_DIR}/preconfig_$(date +%Y%m%d-%H%M%S).log"

log() { echo "[$(date +"%H:%M:%S")] [INFO] $1" | tee -a "$log_file"; }
warn() { echo "[$(date +"%H:%M:%S")] [WARN] $1" | tee -a "$log_file"; }
error() { echo "[$(date +"%H:%M:%S")] [ERROR] $1" | tee -a "$log_file"; }

# -------------------------------
# Script Start
# -------------------------------
log "=============================================================="
log " NVIDIA GPU Pre-Configuration"
log " Node        : ${WORKER_NODE}"
log " Started At  : ${TIMESTAMP}"
log "=============================================================="

# Backup ClusterPolicy
log "Backing up ClusterPolicy to ${BACKUP_DIR}..."
kubectl get clusterpolicies.nvidia.com/cluster-policy -o yaml \
    > "${BACKUP_DIR}/cluster-policy.yaml"

# Backup MIG ConfigMap if exists
MIG_CONFIGMAP=$(kubectl get clusterpolicies.nvidia.com/cluster-policy \
  -o jsonpath='{.spec.migManager.config.name}' 2>/dev/null || true)

if [[ -n "${MIG_CONFIGMAP}" ]]; then
    log "MIG ConfigMap detected: ${MIG_CONFIGMAP}"
    kubectl get configmap "${MIG_CONFIGMAP}" \
        -n "${GPU_OPERATOR_NAMESPACE}" -o yaml \
        > "${BACKUP_DIR}/mig-configmap.yaml"
else
    warn "No MIG ConfigMap configured."
fi

# Record current MIG node labels
kubectl get nodes -l nvidia.com/mig.config \
    -o=custom-columns=NODE:.metadata.name,MIG_CONFIG:.metadata.labels."nvidia\.com/mig\.config" \
    > "${BACKUP_DIR}/node-mig-labels.txt" || true

log "Backup phase completed successfully."

# Runtime Configuration
log "Checking NVIDIA runtime mode on ${WORKER_NODE}..."
CURRENT_MODE=$(ssh "${WORKER_NODE}" \
  "grep '^mode' /etc/nvidia-container-runtime/config.toml | awk -F'\"' '{print \$2}'" \
  || true)

if [[ -z "${CURRENT_MODE}" ]]; then
    warn "Unable to determine current runtime mode."
else
    log "Current runtime mode: ${CURRENT_MODE}"
fi

if [[ "${CURRENT_MODE}" != "auto" ]]; then
    log "Switching runtime mode to AUTO..."
    ssh "${WORKER_NODE}" "sudo sed -i 's/mode = \"cdi\"/mode = \"auto\"/' /etc/nvidia-container-runtime/config.toml"
    ssh "${WORKER_NODE}" "sudo systemctl restart containerd"
    log "Runtime successfully switched to AUTO."
else
    log "Runtime already set to AUTO. No action required."
fi

log "--------------------------------------------------------------"
log " PRE-CONFIGURATION COMPLETED SUCCESSFULLY"
log " Backup Location : ${BACKUP_DIR}"
log " Log File        : ${log_file}"
log "--------------------------------------------------------------"
log "ACTION REQUIRED:"
log "Stop all GPU workloads on ${WORKER_NODE} before proceeding with MIG reconfiguration."
