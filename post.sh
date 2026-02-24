#!/bin/bash
# ==============================================================
# NVIDIA GPU Post-Configuration
# ==============================================================
set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO."; exit 1' ERR

source lock.sh
source cdi.sh

LOCK_FILE="/var/lock/nvidia-mig-config.lock"
WORKER_NODE="gu-k8s-worker"
GPU_OPERATOR_NS="gpu-operator"

BASE_LOG_DIR="logs"
RUN_LOG_DIR="${BASE_LOG_DIR}/$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${RUN_LOG_DIR}/backup"
log_file="${RUN_LOG_DIR}/post.log"

mkdir -p "$RUN_LOG_DIR" "$BACKUP_DIR"
log() { echo "[$(date +"%H:%M:%S")] [INFO] $1" | tee -a "$log_file"; }

acquire_lock "$LOCK_FILE"

# Backup runtime config
scp "${WORKER_NODE}:/etc/nvidia-container-runtime/config.toml" "${BACKUP_DIR}/config.toml.bak.$(date +%s)" >> "$log_file" 2>&1

# Wait for MIG state
count=0; failed=0
while true; do
    state=$(kubectl get node "$WORKER_NODE" -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}' 2>/dev/null || echo "")
    log "Current MIG state: $state (Attempt $count)"
    [[ "$state" == "success" ]] && break
    [[ "$state" == "failed" ]] && { failed=$((failed+1)); [[ $failed -ge 2 ]] && { echo "[ERROR] MIG failed"; exit 1; } }
    [[ $count -ge 15 ]] && { echo "[ERROR] Timeout waiting for MIG"; exit 1; }
    sleep 20; count=$((count+1))
done

# Run nvidia-smi in MIG Manager pod
pod=$(kubectl get pods -n "$GPU_OPERATOR_NS" -o wide | grep mig-manager | grep "$WORKER_NODE" | awk '{print $1}')
kubectl exec -n "$GPU_OPERATOR_NS" "$pod" -- nvidia-smi

# Generate CDI
ssh "$WORKER_NODE" "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml" >> "$log_file" 2>&1

# Switch runtime to CDI using shared function
switch_runtime_to_cdi "$WORKER_NODE" "$log_file"

# Uncordon node
kubectl uncordon "$WORKER_NODE" >> "$log_file" 2>&1
log "Post-configuration completed."
