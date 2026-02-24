#!/bin/bash
# ==============================================================
# Lock Utility for NVIDIA Scripts
# ==============================================================
# Usage: acquire_lock "/var/lock/lock-file-name.lock"

acquire_lock() {
    local lock_file="$1"
    exec 200>"$lock_file"
    if ! flock -n 200; then
        echo "[ERROR] Another instance is already running (lock: $lock_file)."
        exit 1
    fi
    echo $$ 1>&200
}
