#!/bin/bash
# ============================================================================
# NVIDIA Runtime & CDI Utility Functions
# ============================================================================
# Provides functions to detect, backup, and switch the NVIDIA container
# runtime mode (auto/cdi) and to generate CDI specifications.
# Sourced by pre.sh, post.sh, and restart.sh.
#
# All operations are performed on the remote worker node via SSH.
# The target config file is /etc/nvidia-container-runtime/config.toml,
# which controls how the NVIDIA container runtime discovers GPUs.
#
# Runtime modes:
#   auto - Runtime auto-detects available GPUs (used during MIG reconfiguration)
#   cdi  - Runtime uses a CDI spec to expose specific MIG device slices to containers
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-02-26
# ============================================================================

# ============================================================================
# RUNTIME MODE DETECTION
# ============================================================================

# Read the current NVIDIA container runtime mode from config.toml on the
# remote worker node.
#
# Parses the `mode = "..."` line from config.toml and extracts the value
# between double quotes (e.g., "auto" or "cdi").
#
# Arguments:
#   $1 - node: Target worker node hostname
#
# Returns:
#   Prints the mode string (e.g., "auto", "cdi") to stdout.
#   Prints "unknown" if SSH fails or the mode line is not found.
get_current_runtime_mode() {
    local node="$1"

    # grep '^mode' matches the line starting with "mode" in config.toml.
    # awk -F'"' '{print $2}' splits by double-quote delimiter and extracts
    # the second field (the value between quotes).
    # Example: mode = "cdi" → splits to ["mode = ", "cdi", ""] → $2 = "cdi"
    #
    # 2>/dev/null suppresses SSH connection errors from cluttering output.
    # || echo "unknown" provides a fallback if SSH or grep fails.
    ssh "$node" \
        "grep '^mode' /etc/nvidia-container-runtime/config.toml | awk -F'\"' '{print \$2}'" \
        2>/dev/null || echo "unknown"
}

# ============================================================================
# CONFIGURATION BACKUP
# ============================================================================

# Backup the NVIDIA container runtime config from the remote worker node.
# Creates a timestamped copy so each run preserves a unique snapshot.
#
# Arguments:
#   $1 - node: Target worker node hostname
#   $2 - backup_dir: Local directory to store the backup
#   $3 - log_file: Path to the log file for command output
#
# Side effects:
#   - Creates a file: <backup_dir>/config.toml.bak.<epoch_timestamp>
#   - Exits with 1 if config.toml does not exist on the remote node
backup_runtime_config() {
    local node="$1"
    local backup_dir="$2"
    local log_file="$3"

    # Verify the config file exists on the remote node before attempting copy.
    # The || { ... } block runs only if the test fails (file missing).
    ssh "$node" "sudo test -f /etc/nvidia-container-runtime/config.toml" || {
        echo "[ERROR] Runtime config not found on $node"
        exit 1
    }

    # scp copies the config from the remote node to a local timestamped backup.
    # $(date +%s) appends the Unix epoch timestamp to ensure unique filenames
    # across multiple runs.
    scp "${node}:/etc/nvidia-container-runtime/config.toml" \
        "${backup_dir}/config.toml.bak.$(date +%s)" >> "$log_file" 2>&1
}

# ============================================================================
# RUNTIME MODE SWITCHING
# ============================================================================

# Switch NVIDIA container runtime to AUTO mode.
# Used by pre.sh before MIG reconfiguration — AUTO mode allows the
# MIG Manager to freely partition GPUs without CDI spec constraints.
#
# Arguments:
#   $1 - node: Target worker node hostname
#   $2 - log_file: Path to the log file for command output
#
# Side effects:
#   - Modifies /etc/nvidia-container-runtime/config.toml on the remote node
#   - Restarts the containerd service (briefly interrupts container operations)
set_runtime_auto() {
    local node="$1"
    local log_file="$2"

    # sed -i edits the file in place.
    # 's/^mode = .*/mode = "auto"/' is a substitution pattern:
    #   ^        → start of line
    #   mode =   → literal text
    #   .*       → any number of any characters (. = any single char, * = zero or more)
    #            together .* matches the rest of the line (the old value including quotes)
    # The entire match is replaced with: mode = "auto"
    ssh "$node" \
        "sudo sed -i 's/^mode = .*/mode = \"auto\"/' /etc/nvidia-container-runtime/config.toml" \
        >> "$log_file" 2>&1

    # Restart containerd so it picks up the new runtime mode.
    ssh "$node" "sudo systemctl restart containerd" >> "$log_file" 2>&1
}

# Switch NVIDIA container runtime to CDI mode.
# Used by post.sh (after MIG reconfiguration) and restart.sh (after reboot).
# CDI mode makes the runtime use the generated CDI spec (/etc/cdi/nvidia.yaml)
# to expose specific MIG device slices to containers.
#
# Arguments:
#   $1 - node: Target worker node hostname
#   $2 - log_file: Path to the log file for command output
#
# Side effects:
#   - Modifies /etc/nvidia-container-runtime/config.toml on the remote node
#   - Restarts the containerd service (briefly interrupts container operations)
switch_runtime_to_cdi() {
    local node="$1"
    local log_file="$2"

    # sed -i edits the file in place.
    # 's/^mode = .*/mode = "cdi"/' is a substitution pattern:
    #   ^        → start of line
    #   mode =   → literal text
    #   .*       → any number of any characters (. = any single char, * = zero or more)
    #            together .* matches the rest of the line (the old value including quotes)
    # The entire match is replaced with: mode = "cdi"
    ssh "$node" \
        "sudo sed -i 's/^mode = .*/mode = \"cdi\"/' /etc/nvidia-container-runtime/config.toml" \
        >> "$log_file" 2>&1

    # Restart containerd so it picks up the new runtime mode.
    ssh "$node" "sudo systemctl restart containerd" >> "$log_file" 2>&1
}

# ============================================================================
# CDI SPECIFICATION GENERATION
# ============================================================================

# Generate the CDI specification file on the remote worker node.
# nvidia-ctk inspects the current GPU/MIG topology and writes a CDI spec
# that maps each MIG slice to a namespaced device name containers can request.
#
# The output file (/etc/cdi/nvidia.yaml) is read by the container runtime
# when in CDI mode to determine which GPU devices to expose.
#
# Arguments:
#   $1 - node: Target worker node hostname
#   $2 - log_file: Path to the log file for command output
#
# Side effects:
#   - Creates/overwrites /etc/cdi/nvidia.yaml on the remote node
generate_cdi() {
    local node="$1"
    local log_file="$2"

    # nvidia-ctk cdi generate scans the node's GPU topology (including MIG
    # partitions) and produces a CDI spec YAML.
    # --output writes directly to the CDI directory where the runtime expects it.
    ssh "$node" \
        "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml" \
        >> "$log_file" 2>&1
}
