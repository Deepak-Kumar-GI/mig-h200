#!/bin/bash
# ==============================================================
# Global Lock Utility
# ==============================================================

acquire_lock() {
    local lock_file="$1"

    exec 200>"$lock_file"

    if ! flock -n 200; then
        echo "[ERROR] Another MIG/CDI operation is already running."
        exit 1
    fi

    echo $$ 1>&200
}