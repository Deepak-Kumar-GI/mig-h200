#!/bin/bash
# ==============================================================
# NVIDIA CDI & Runtime Utility Functions
# ==============================================================

# -------------------------
# Logging Functions (used by scripts)
# -------------------------
log()  { echo "[$(date +"%H:%M:%S")] [INFO]  $1"; }
warn() { echo "[$(date +"%H:%M:%S")] [WARN]  $1"; }
error(){ echo "[$(date +"%H:%M:%S")] [ERROR] $1"; }

# -------------------------
# Backup NVIDIA container runtime config
# Usage: backup_runtime_config <NODE> <BACKUP_DIR> <LOG_FILE>
# -------------------------
backup_runtime_config() {
    local node="${1:-$WORKER_NODE}"
    local backup_dir="${2:-$BACKUP_DIR}"
    local log_file="${3:-$log_file}"

    log "Backing up NVIDIA container runtime config from $node..."
    scp "${node}:/etc/nvidia-container-runtime/config.toml" \
        "${backup_dir}/config.toml.bak.$(date +%s)" >> "$log_file" 2>&1 \
        || { error "Failed to backup runtime config from $node"; exit 1; }
    log "Runtime config backup completed."
}

# -------------------------
# Switch NVIDIA runtime to AUTO
# Usage: set_runtime_auto <NODE> <LOG_FILE>
# -------------------------
set_runtime_auto() {
    local node="${1:-$WORKER_NODE}"
    local log_file="${2:-$log_file}"

    log "Checking NVIDIA runtime mode on $node..."
    local current_mode
    current_mode=$(ssh "$node" "grep '^mode' /etc/nvidia-container-runtime/config.toml | awk -F'\"' '{print \$2}'" || true)

    if [[ -z "$current_mode" ]]; then
        warn "Unable to determine current runtime mode."
        return
    fi
    log "Current runtime mode: $current_mode"

    if [[ "$current_mode" != "auto" ]]; then
        log "Switching runtime mode to AUTO..."
        ssh "$node" "sudo sed -i 's/^mode = .*/mode = \"auto\"/' /etc/nvidia-container-runtime/config.toml" >> "$log_file" 2>&1
        ssh "$node" "sudo systemctl restart containerd" >> "$log_file" 2>&1
        log "Runtime successfully switched to AUTO."
    else
        log "Runtime already set to AUTO. No action required."
    fi
}

# -------------------------
# Switch NVIDIA runtime to CDI
# Usage: switch_runtime_to_cdi <NODE> <LOG_FILE>
# -------------------------
switch_runtime_to_cdi() {
    local node="${1:-$WORKER_NODE}"
    local log_file="${2:-$log_file}"

    log "Checking NVIDIA runtime mode on $node..."
    local current_mode
    current_mode=$(ssh "$node" "grep '^mode' /etc/nvidia-container-runtime/config.toml | awk -F'\"' '{print \$2}'" || true)

    if [[ -z "$current_mode" ]]; then
        error "Unable to determine current runtime mode."
        exit 1
    fi
    log "Current runtime mode: $current_mode"

    if [[ "$current_mode" == "cdi" ]]; then
        log "Runtime already in CDI mode. No action required."
        return
    elif [[ "$current_mode" == "auto" ]]; then
        log "Switching runtime mode from AUTO to CDI..."
        ssh "$node" "sudo sed -i 's/^mode = .*/mode = \"cdi\"/' /etc/nvidia-container-runtime/config.toml" >> "$log_file" 2>&1
        ssh "$node" "sudo systemctl restart containerd" >> "$log_file" 2>&1

        if ssh "$node" "systemctl is-active --quiet containerd"; then
            log "containerd restarted successfully."
        else
            error "containerd failed to restart."
            exit 1
        fi

        log "Runtime successfully switched to CDI."
    else
        error "Unsupported runtime mode: $current_mode. Expected 'auto' or 'cdi'."
        exit 1
    fi
}

# -------------------------
# Generate Static CDI Specification
# Usage: generate_cdi <NODE> <LOG_FILE>
# -------------------------
generate_cdi() {
    local node="${1:-$WORKER_NODE}"
    local log_file="${2:-$log_file}"

    log "Generating static CDI specification on $node..."

    ssh "$node" "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml" \
        >> "$log_file" 2>&1 || {
        error "Failed to generate CDI specification on $node"
        exit 1
    }

    # Verify CDI file exists
    ssh "$node" "test -f /etc/cdi/nvidia.yaml" \
        >> "$log_file" 2>&1 || {
        error "CDI file not found after generation!"
        exit 1
    }

    log "CDI specification successfully generated and verified at /etc/cdi/nvidia.yaml"
}
