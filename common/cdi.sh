#!/bin/bash
# ==============================================================
# NVIDIA Runtime & CDI Utility Functions
# ==============================================================

# --------------------------------------------------------------
# Get Current NVIDIA Runtime Mode
# --------------------------------------------------------------
get_current_runtime_mode() {
    local node="$1"

    ssh "$node" \
        "grep '^mode' /etc/nvidia-container-runtime/config.toml | awk -F'\"' '{print \$2}'" \
        2>/dev/null || echo "unknown"
}

# --------------------------------------------------------------
# Backup NVIDIA Runtime Config
# --------------------------------------------------------------
backup_runtime_config() {
    local node="$1"
    local backup_dir="$2"
    local log_file="$3"

    ssh "$node" "sudo test -f /etc/nvidia-container-runtime/config.toml" || {
        echo "[ERROR] Runtime config not found on $node"
        exit 1
    }

    scp "${node}:/etc/nvidia-container-runtime/config.toml" \
        "${backup_dir}/config.toml.bak.$(date +%s)" >> "$log_file" 2>&1
}

# --------------------------------------------------------------
# Set Runtime Mode to AUTO
# --------------------------------------------------------------
set_runtime_auto() {
    local node="$1"
    local log_file="$2"

    ssh "$node" \
        "sudo sed -i 's/^mode = .*/mode = \"auto\"/' /etc/nvidia-container-runtime/config.toml" \
        >> "$log_file" 2>&1

    ssh "$node" "sudo systemctl restart containerd" >> "$log_file" 2>&1
}

# --------------------------------------------------------------
# Switch Runtime Mode to CDI
# --------------------------------------------------------------
switch_runtime_to_cdi() {
    local node="$1"
    local log_file="$2"

    ssh "$node" \
        "sudo sed -i 's/^mode = .*/mode = \"cdi\"/' /etc/nvidia-container-runtime/config.toml" \
        >> "$log_file" 2>&1

    ssh "$node" "sudo systemctl restart containerd" >> "$log_file" 2>&1
}

# --------------------------------------------------------------
# Generate CDI Specification
# --------------------------------------------------------------
generate_cdi() {
    local node="$1"
    local log_file="$2"

    ssh "$node" \
        "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml" \
        >> "$log_file" 2>&1
}