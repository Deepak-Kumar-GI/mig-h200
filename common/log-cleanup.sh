#!/bin/bash
# ============================================================================
# Log Cleanup - Age-Based Log Directory Pruning
# ============================================================================
# Removes old timestamped log directories based on the date encoded in their
# directory names (YYYYMMDD-HHMMSS format). Uses string comparison against a
# computed cutoff date rather than filesystem mtime, ensuring reliable
# behaviour regardless of file copies or backups that reset timestamps.
#
# This module is sourced by all entry-point scripts and called once at the
# start of each run (after the global lock is acquired).
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-03-01
# ============================================================================

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Remove log directories older than a specified number of days.
# Only targets directories matching the strict YYYYMMDD-HHMMSS naming
# pattern. The current run's directory is explicitly excluded to prevent
# self-deletion.
#
# Arguments:
#   $1 - base_dir:       Root log directory (e.g., "logs")
#   $2 - retention_days: Number of days to keep (0 = skip cleanup entirely)
#   $3 - current_run:    Full path to the current run's log directory
#
# Returns:
#   0 - Always (best-effort; individual deletion failures are warned, not fatal)
#
# Side effects:
#   - Deletes directories under base_dir that are older than the cutoff
#   - Prints summary to stdout (not the log file, to keep current-run logs clean)
cleanup_old_logs() {
    local base_dir="$1"
    local retention_days="$2"
    local current_run="$3"

    # Skip cleanup if the log directory doesn't exist yet (first run)
    if [[ ! -d "$base_dir" ]]; then
        return 0
    fi

    # retention_days <= 0 disables cleanup entirely
    if [[ "$retention_days" -le 0 ]]; then
        return 0
    fi

    # Compute the cutoff date string (YYYYMMDD format).
    # Directories with a date prefix older than this value will be removed.
    # date -d "-N days" computes a date N days in the past.
    # +%Y%m%d formats the output as YYYYMMDD for direct string comparison.
    local cutoff_date
    cutoff_date=$(date -d "-${retention_days} days" +"%Y%m%d")

    local deleted=0
    local dir

    # Glob for directories matching the YYYYMMDD-HHMMSS naming convention.
    # The [0-9] character classes enforce exactly 8 digits, a dash, and 6 digits.
    for dir in "${base_dir}"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]/; do
        # -d verifies the glob actually matched a directory
        # (if no matches, the unexpanded glob literal is skipped here)
        [[ -d "$dir" ]] || continue

        # Never delete the current run's directory.
        # realpath is not used here — simple prefix comparison is sufficient
        # because both paths share the same base_dir prefix.
        # ${dir%/} strips the trailing slash added by the glob for clean comparison.
        if [[ "${dir%/}" == "${current_run}" ]]; then
            continue
        fi

        # Extract the YYYYMMDD portion from the directory name.
        # basename strips the path, leaving "YYYYMMDD-HHMMSS".
        # ${name%%-*} removes the longest suffix starting with "-",
        # leaving just the 8-digit date prefix.
        local name
        name=$(basename "$dir")
        local dir_date="${name%%-*}"

        # String comparison works for YYYYMMDD format because the lexicographic
        # order matches chronological order (20250101 < 20260301).
        if [[ "$dir_date" < "$cutoff_date" ]]; then
            if rm -rf "${dir%/}"; then
                deleted=$((deleted + 1))
            else
                echo "[WARN] Failed to delete old log directory: ${dir}" >&2
            fi
        fi
    done

    if [[ $deleted -gt 0 ]]; then
        echo "[INFO] Log cleanup: removed ${deleted} log director$([ "$deleted" -eq 1 ] && echo "y" || echo "ies") older than ${retention_days} days."
    fi

    return 0
}
