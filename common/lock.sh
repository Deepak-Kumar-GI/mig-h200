#!/bin/bash
# ============================================================================
# Global Lock Utility
# ============================================================================
# Provides a file-based mutual exclusion mechanism to prevent concurrent
# MIG/CDI operations. Sourced by pre.sh, post.sh, and restart.sh.
#
# Uses file descriptor locking (flock) instead of checking for a lock file's
# existence. This ensures the lock is automatically released when the process
# exits — even on crashes or SIGKILL — preventing stale locks.
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-02-26
# ============================================================================

# Acquire an exclusive, non-blocking lock on the given file.
# Prevents multiple MIG/CDI scripts from running simultaneously.
#
# Arguments:
#   $1 - lock_file: Path to the lock file (typically /var/lock/nvidia-mig-config.lock)
#
# Side effects:
#   - Opens file descriptor 200 for the lifetime of the calling script
#   - Writes the current PID into the lock file for debugging
#
# Returns:
#   0 on success; exits with 1 if the lock is already held
acquire_lock() {
    local lock_file="$1"

    # exec opens the lock file on FD 200 without spawning a subprocess.
    # Using a file descriptor (rather than a temp file check) ensures the
    # lock persists for the script's lifetime and auto-releases on exit.
    # 200 is an arbitrary high FD number to avoid conflicts with stdin(0)/stdout(1)/stderr(2).
    exec 200>"$lock_file"

    # flock -n = non-blocking; fail immediately if another process holds the lock
    if ! flock -n 200; then
        echo "[ERROR] Another MIG/CDI operation is already running."
        exit 1
    fi

    # Write current PID into the lock file for operator debugging
    # (e.g., identifying which process holds the lock via: cat /var/lock/nvidia-mig-config.lock)
    # 1>&200 redirects stdout to FD 200 (the lock file)
    echo $$ 1>&200
}
