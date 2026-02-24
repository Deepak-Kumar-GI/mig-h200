#!/bin/bash
# ==============================================================
# NVIDIA CDI / Runtime Helper
# ==============================================================
# Usage:
#   set_runtime_auto <node>
#   switch_runtime_to_cdi <node> <log_file>

set_runtime_auto() {
    local node="$1"
    local log_file="$2"

    CURRENT_MODE=$(ssh "$node" "grep '^mode' /etc/nvidia-container-runtime/config.toml | awk -F'\"' '{print \$2}'" || true)
    if [[ -z "$CURRENT_MODE" ]]; then
        echo "[WARN] Unable to determine runtime mode for $node" | tee -a "$log_file"
        return
    fi
    echo "[INFO] Current runtime mode: $CURRENT_MODE" | tee -a "$log_file"

    if [[ "$CURRENT_MODE" != "auto" ]]; then
        echo "[INFO] Switching runtime to AUTO on $node..." | tee -a "$log_file"
        ssh "$node" "sudo sed -i 's/mode = \"cdi\"/mode = \"auto\"/' /etc/nvidia-container-runtime/config.toml" >>"$log_file" 2>&1
        ssh "$node" "sudo systemctl restart containerd" >>"$log_file" 2>&1
        echo "[INFO] Runtime switched to AUTO successfully" | tee -a "$log_file"
    else
        echo "[INFO] Runtime already set to AUTO" | tee -a "$log_file"
    fi
}

switch_runtime_to_cdi() {
    local node="$1"
    local log_file="$2"

    CURRENT_MODE=$(ssh "$node" "grep '^mode' /etc/nvidia-container-runtime/config.toml | awk -F'\"' '{print \$2}'" || true)
    [[ -z "$CURRENT_MODE" ]] && { echo "[ERROR] Cannot determine runtime mode on $node"; exit 1; }

    if [[ "$CURRENT_MODE" == "cdi" ]]; then
        echo "[INFO] Runtime already in CDI mode on $node" | tee -a "$log_file"
        return
    fi

    echo "[INFO] Switching runtime from $CURRENT_MODE to CDI on $node..." | tee -a "$log_file"
    ssh "$node" "sudo sed -i 's/^mode = .*/mode = \"cdi\"/' /etc/nvidia-container-runtime/config.toml" >>"$log_file" 2>&1
    ssh "$node" "sudo systemctl restart containerd" >>"$log_file" 2>&1
    ssh "$node" "systemctl is-active --quiet containerd" || { echo "[ERROR] containerd failed to restart on $node"; exit 1; }
    echo "[INFO] Runtime switched to CDI successfully on $node" | tee -a "$log_file"
}
