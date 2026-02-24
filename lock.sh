#!/bin/bash
# ==============================================================
# Global Lock Utility
# ==============================================================
# Provides exclusive execution control so that only one script
# (pre/post/restart) can run at any given time.
# ==============================================================

acquire_lock() {
    local lock_file="$1"

    # Open file descriptor 200 for locking
    exec 200>"$lock_file"

    # Try to acquire non-blocking lock
    if ! flock -n 200; then
        echo "[ERROR] Another MIG/CDI operation is already running."
        echo "Only one of pre.sh, post.sh, or restart.sh may run at a time."
        exit 1
    fi

    # Store current process ID in lock file
    echo $$ 1>&200
}
