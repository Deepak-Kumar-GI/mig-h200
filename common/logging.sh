#!/bin/bash
# ============================================================================
# Shared Logging Utility
# ============================================================================
# Provides color-coded log(), warn(), and error() functions used by all
# scripts. Console output uses ANSI colors for quick visual scanning;
# log file output is plain text (no escape codes) for clean grep/review.
#
# Usage:
#   LOG_FILE="/path/to/logfile.log"   # must be set before sourcing
#   source common/logging.sh
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-02-28
# ============================================================================

# ============================================================================
# CONSTANTS
# ============================================================================

# ANSI color codes for terminal output.
# \033[ is the escape sequence prefix; the number selects the color.
readonly _CLR_GREEN='\033[0;32m'
readonly _CLR_YELLOW='\033[0;33m'
readonly _CLR_RED='\033[0;31m'
readonly _CLR_RESET='\033[0m'

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Log an INFO-level message.
# Console gets green-colored output; log file gets plain text.
#
# Arguments:
#   $1 - message: The message string to log
#
# Side effects:
#   - Writes to stdout (console) with color
#   - Appends plain text to LOG_FILE
log() {
    local timestamp
    timestamp="$(date +"%H:%M:%S")"
    local plain="[${timestamp}] [INFO]  $1"

    # printf handles ANSI codes reliably (echo -e behavior varies across shells).
    # Print colored output to console only.
    printf "${_CLR_GREEN}%s${_CLR_RESET}\n" "$plain"

    # Append plain (no color codes) line to the log file.
    echo "$plain" >> "$LOG_FILE"
}

# Log a WARN-level message.
# Console gets yellow-colored output; log file gets plain text.
#
# Arguments:
#   $1 - message: The message string to log
#
# Side effects:
#   - Writes to stdout (console) with color
#   - Appends plain text to LOG_FILE
warn() {
    local timestamp
    timestamp="$(date +"%H:%M:%S")"
    local plain="[${timestamp}] [WARN]  $1"

    printf "${_CLR_YELLOW}%s${_CLR_RESET}\n" "$plain"
    echo "$plain" >> "$LOG_FILE"
}

# Log an ERROR-level message.
# Console gets red-colored output; log file gets plain text.
#
# Arguments:
#   $1 - message: The message string to log
#
# Side effects:
#   - Writes to stderr (console) with color
#   - Appends plain text to LOG_FILE
error() {
    local timestamp
    timestamp="$(date +"%H:%M:%S")"
    local plain="[${timestamp}] [ERROR] $1"

    # Errors go to stderr (>&2) so they're visible even if stdout is redirected.
    printf "${_CLR_RED}%s${_CLR_RESET}\n" "$plain" >&2
    echo "$plain" >> "$LOG_FILE"
}
