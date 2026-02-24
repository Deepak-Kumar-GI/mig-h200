#!/bin/bash
# ==============================================================
# NVIDIA CDI & Runtime Utility Functions
# ==============================================================
# Contains reusable runtime/CDI helper functions shared across
# all scripts.
# ==============================================================


# -------------------------
# Backup NVIDIA Runtime Config
# -------------------------
# Creates a timestamped backup of:
#   /etc/nvidia-container-runtime/config.toml
# -------------------------
backup_runtime_config() {
    local node="$1"
    local backup_dir="$2"
    local log_file="$3"

    # Verify file exists on remote node
    ssh "$node" "sudo test -f /etc/nvidia-container-runtime/config.toml" || {
        echo "[ERROR] Runtime config not found on $node"
        exit 1
    }

    # Copy file to backup directory
    scp "${node}:/etc/nvidia-container-runtime/config.toml" \
        "${backup_dir}/config.toml.bak.$(date +%s)" >> "$log_file" 2>&1 \
        || {
        echo "[ERROR] Failed to backup runtime config"
        exit 1
    }
}


# -------------------------
# Set Runtime Mode to AUTO
# -------------------------
# Updates runtime config and restarts containerd
# -------------------------
set_runtime_auto() {
    local node="$1"
    local log_file="$2"

    ssh "$node" \
        "sudo sed -i 's/^mode = .*/mode = \"auto\"/' /etc/nvidia-container-runtime/config.toml" \
        >> "$log_file" 2>&1

    ssh "$node" "sudo systemctl restart containerd" >> "$log_file" 2>&1
}


# -------------------------
# Switch Runtime Mode to CDI
# -------------------------
# Updates runtime config and verifies containerd restart
# -------------------------
switch_runtime_to_cdi() {
    local node="$1"
    local log_file="$2"

    ssh "$node" \
        "sudo sed -i 's/^mode = .*/mode = \"cdi\"/' /etc/nvidia-container-runtime/config.toml" \
        >> "$log_file" 2>&1

    ssh "$node" "sudo systemctl restart containerd" >> "$log_file" 2>&1

    # Verify containerd is active
    ssh "$node" "systemctl is-active --quiet containerd" || {
        echo "[ERROR] containerd failed to restart"
        exit 1
    }
}


# -------------------------
# Generate Static CDI Specification
# -------------------------
# Generates:
#   /etc/cdi/nvidia.yaml
# Then verifies file exists.
# -------------------------
generate_cdi() {
    local node="$1"
    local log_file="$2"

    ssh "$node" \
        "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml" \
        >> "$log_file" 2>&1 || {
        echo "[ERROR] Failed to generate CDI specification"
        exit 1
    }

    # Verify CDI file was created
    ssh "$node" "test -f /etc/cdi/nvidia.yaml" >> "$log_file" 2>&1 || {
        echo "[ERROR] CDI file not found after generation"
        exit 1
    }
}
