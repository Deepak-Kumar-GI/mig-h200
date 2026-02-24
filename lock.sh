#!/bin/bash
# ==============================================================
# Global Lock Utility
# ==============================================================

# -------------------------
# Acquire Lock
# Usage: acquire_lock <LOCK_FILE>
# -------------------------
acquire_lock() {
    local lock_file="$1"
    exec 200>"$lock_file"

    if ! flock -n 200; then
        echo "[ERROR] Another configuration script is already running."
        echo "Only one of pre/post/restart scripts can run at a time."
        exit 1
    fi

    # Store PID in lock file descriptor
    echo $$ 1>&200
    log "Lock acquired on $lock_file"
}
