#!/bin/bash
# ============================================================================
# MIG Template Parser - Pure-Bash YAML Parser
# ============================================================================
# Parses the MIG configuration template YAML into parallel indexed arrays
# that the TUI and ConfigMap generator consume. Uses a state-machine approach
# to handle the nested YAML structure without requiring jq or yq.
#
# Data structures populated:
#   GPU_MODEL, GPU_MEMORY, GPU_COUNT  — GPU hardware metadata
#   PROFILE_NAMES[]       — display names ("MIG Disabled (Full GPU)", ...)
#   PROFILE_DESCS[]       — human-readable descriptions
#   PROFILE_MIG_ENABLED[] — "true" / "false" per profile
#   PROFILE_MIG_DEVICES[] — "slice:count,..." or "" (empty for MIG disabled)
#   PROFILE_COUNT         — total number of profiles parsed
#
# Usage:
#   source common/template-parser.sh
#   load_template "custom-mig-config-template.yaml"
#   echo "${PROFILE_NAMES[0]}"   # → "MIG Disabled (Full GPU)"
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-02-28
# ============================================================================

# ============================================================================
# CONSTANTS
# ============================================================================

# Parser states for the state-machine approach.
# readonly prevents accidental modification.
readonly _STATE_TOP=0          # Top-level: looking for gpu: or profiles:
readonly _STATE_GPU=1          # Inside gpu: block
readonly _STATE_PROFILE=2      # Inside a single profile (after "- name:")
readonly _STATE_MIG_DEVICES=3  # Inside mig-devices: sub-block

# ============================================================================
# GLOBAL DATA STRUCTURES
# ============================================================================

GPU_MODEL=""
GPU_MEMORY=""
GPU_COUNT=0

PROFILE_NAMES=()
PROFILE_DESCS=()
PROFILE_MIG_ENABLED=()
PROFILE_MIG_DEVICES=()
PROFILE_COUNT=0

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Strip leading/trailing whitespace and surrounding quotes from a string.
# Used to clean raw YAML values like '  "1g.18gb"  ' → '1g.18gb'.
#
# Arguments:
#   $1 - str: The raw string to trim
#
# Returns:
#   Prints the cleaned string to stdout
_trim_and_unquote() {
    local str="$1"

    # ${str#"${str%%[![:space:]]*}"} removes leading whitespace:
    #   ${str%%[![:space:]]*} = everything from the start up to the first
    #                           non-space character (the leading whitespace)
    #   ${str#...}            = remove that prefix
    str="${str#"${str%%[![:space:]]*}"}"

    # ${str%"${str##*[![:space:]]}"} removes trailing whitespace:
    #   ${str##*[![:space:]]} = everything from the last non-space character
    #                           to the end (the trailing whitespace)
    #   ${str%...}            = remove that suffix
    str="${str%"${str##*[![:space:]]}"}"

    # Remove surrounding double quotes if present.
    # ${str#\"} removes a leading quote; ${str%\"} removes a trailing quote.
    str="${str#\"}"
    str="${str%\"}"

    echo "$str"
}

# Save the currently accumulated profile data into the parallel arrays.
# Called when a new profile starts or at end-of-file.
#
# Side effects:
#   - Appends to PROFILE_NAMES[], PROFILE_DESCS[], PROFILE_MIG_ENABLED[],
#     PROFILE_MIG_DEVICES[]
#   - Increments PROFILE_COUNT
#   - Resets _cur_* accumulator variables
_flush_profile() {
    # Only flush if we have a profile name accumulated
    if [[ -n "$_cur_name" ]]; then
        PROFILE_NAMES+=("$_cur_name")
        PROFILE_DESCS+=("$_cur_desc")
        PROFILE_MIG_ENABLED+=("$_cur_mig_enabled")

        # Remove trailing comma from device list if present.
        # ${_cur_devices%,} removes a single trailing comma.
        PROFILE_MIG_DEVICES+=("${_cur_devices%,}")
        PROFILE_COUNT=$((PROFILE_COUNT + 1))
    fi

    # Reset accumulators for the next profile
    _cur_name=""
    _cur_desc=""
    _cur_mig_enabled=""
    _cur_devices=""
}

# ============================================================================
# MAIN LOGIC
# ============================================================================

# Parse a MIG configuration template YAML file and populate the global
# data structures (GPU_MODEL, PROFILE_NAMES[], etc.).
#
# Uses a state machine that transitions between top-level, gpu-block,
# profile-block, and mig-devices-block states based on YAML indentation
# and key patterns.
#
# Arguments:
#   $1 - file: Path to the template YAML file
#
# Returns:
#   0 on success
#   1 on validation failure (missing file, no profiles, etc.)
#
# Side effects:
#   - Populates all global GPU_* and PROFILE_* variables
load_template() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        echo "[ERROR] Template file not found: ${file}" >&2
        return 1
    fi

    # Reset all global state in case load_template is called multiple times
    GPU_MODEL=""
    GPU_MEMORY=""
    GPU_COUNT=0
    PROFILE_NAMES=()
    PROFILE_DESCS=()
    PROFILE_MIG_ENABLED=()
    PROFILE_MIG_DEVICES=()
    PROFILE_COUNT=0

    # Accumulator variables for the profile currently being parsed
    local _cur_name=""
    local _cur_desc=""
    local _cur_mig_enabled=""
    local _cur_devices=""

    local state=$_STATE_TOP
    local line

    # Read the file line by line. IFS= prevents word splitting.
    # -r prevents backslash interpretation (treats \ as literal).
    while IFS= read -r line || [[ -n "$line" ]]; do

        # Strip Windows carriage returns (\r) for cross-platform compatibility.
        # ${line//$'\r'/} removes all \r characters from the line.
        line="${line//$'\r'/}"

        # Skip blank lines and comment-only lines (lines starting with #).
        # =~ is the regex match operator in bash.
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # ----------------------------------------------------------------
        # TOP-LEVEL STATE: look for section headers
        # ----------------------------------------------------------------
        if [[ $state -eq $_STATE_TOP ]]; then

            # Match "gpu:" at the start of a line (no leading whitespace)
            if [[ "$line" =~ ^gpu: ]]; then
                state=$_STATE_GPU
                continue
            fi

            # Match "profiles:" at the start of a line
            if [[ "$line" =~ ^profiles: ]]; then
                # Profiles are parsed per-item when we hit "- name:"
                continue
            fi

            # Match the start of a new profile entry: "  - name: ..."
            # [[:space:]]+ requires leading whitespace (YAML list indent).
            if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+name:[[:space:]]*(.*) ]]; then
                # BASH_REMATCH[1] captures the group after "name:"
                _flush_profile
                _cur_name="$(_trim_and_unquote "${BASH_REMATCH[1]}")"
                state=$_STATE_PROFILE
                continue
            fi

        # ----------------------------------------------------------------
        # GPU BLOCK: parse model, memory, count
        # ----------------------------------------------------------------
        elif [[ $state -eq $_STATE_GPU ]]; then

            # If line has no leading whitespace, we've left the gpu: block
            if [[ ! "$line" =~ ^[[:space:]] ]]; then
                state=$_STATE_TOP

                # Re-process this line in TOP state (it might be "profiles:")
                if [[ "$line" =~ ^profiles: ]]; then
                    continue
                fi
                if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+name:[[:space:]]*(.*) ]]; then
                    _flush_profile
                    _cur_name="$(_trim_and_unquote "${BASH_REMATCH[1]}")"
                    state=$_STATE_PROFILE
                    continue
                fi
                continue
            fi

            # Extract "key: value" pairs under the gpu: block.
            # The regex captures the key and value separately.
            if [[ "$line" =~ ^[[:space:]]+(model|memory|count):[[:space:]]*(.*) ]]; then
                local key="${BASH_REMATCH[1]}"
                local val
                val="$(_trim_and_unquote "${BASH_REMATCH[2]}")"

                case "$key" in
                    model)  GPU_MODEL="$val"  ;;
                    memory) GPU_MEMORY="$val"  ;;
                    count)  GPU_COUNT="$val"   ;;
                esac
            fi

        # ----------------------------------------------------------------
        # PROFILE BLOCK: parse description, mig-enabled, mig-devices
        # ----------------------------------------------------------------
        elif [[ $state -eq $_STATE_PROFILE ]]; then

            # New profile entry → flush current and start fresh
            if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+name:[[:space:]]*(.*) ]]; then
                _flush_profile
                _cur_name="$(_trim_and_unquote "${BASH_REMATCH[1]}")"
                continue
            fi

            # "description:" field
            if [[ "$line" =~ ^[[:space:]]+description:[[:space:]]*(.*) ]]; then
                _cur_desc="$(_trim_and_unquote "${BASH_REMATCH[1]}")"
                continue
            fi

            # "mig-enabled:" field
            if [[ "$line" =~ ^[[:space:]]+mig-enabled:[[:space:]]*(.*) ]]; then
                _cur_mig_enabled="$(_trim_and_unquote "${BASH_REMATCH[1]}")"
                continue
            fi

            # "mig-devices:" header → transition to MIG_DEVICES sub-state
            if [[ "$line" =~ ^[[:space:]]+mig-devices: ]]; then
                state=$_STATE_MIG_DEVICES
                continue
            fi

            # If we encounter a non-indented line, the profiles section ended
            if [[ ! "$line" =~ ^[[:space:]] ]]; then
                _flush_profile
                state=$_STATE_TOP
                continue
            fi

        # ----------------------------------------------------------------
        # MIG-DEVICES BLOCK: parse "slice_type": count entries
        # ----------------------------------------------------------------
        elif [[ $state -eq $_STATE_MIG_DEVICES ]]; then

            # New profile entry → flush and transition back to PROFILE state
            if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+name:[[:space:]]*(.*) ]]; then
                _flush_profile
                _cur_name="$(_trim_and_unquote "${BASH_REMATCH[1]}")"
                state=$_STATE_PROFILE
                continue
            fi

            # Match "description:" or "mig-enabled:" to detect that we've
            # moved past the mig-devices block into the next profile field.
            if [[ "$line" =~ ^[[:space:]]+(description|mig-enabled):[[:space:]] ]]; then
                state=$_STATE_PROFILE

                # Re-process in PROFILE state
                if [[ "$line" =~ ^[[:space:]]+description:[[:space:]]*(.*) ]]; then
                    _cur_desc="$(_trim_and_unquote "${BASH_REMATCH[1]}")"
                elif [[ "$line" =~ ^[[:space:]]+mig-enabled:[[:space:]]*(.*) ]]; then
                    _cur_mig_enabled="$(_trim_and_unquote "${BASH_REMATCH[1]}")"
                fi
                continue
            fi

            # Parse a mig-device entry: "slice_type": count
            # Example:   "1g.18gb": 7  → key=1g.18gb, val=7
            # The regex handles quoted keys and numeric values.
            if [[ "$line" =~ ^[[:space:]]+\"([^\"]+)\":[[:space:]]*([0-9]+) ]]; then
                local device_key="${BASH_REMATCH[1]}"
                local device_val="${BASH_REMATCH[2]}"

                # Accumulate devices as comma-separated "key:value" pairs.
                # Example: "1g.18gb:7,1g.18gb+me:1"
                _cur_devices+="${device_key}:${device_val},"
                continue
            fi

            # Non-indented line means we left the profiles section entirely
            if [[ ! "$line" =~ ^[[:space:]] ]]; then
                _flush_profile
                state=$_STATE_TOP
                continue
            fi
        fi

    done < "$file"

    # Flush the last profile (no trailing "- name:" to trigger it)
    _flush_profile

    # ====================================================================
    # VALIDATION
    # ====================================================================

    if [[ $GPU_COUNT -le 0 ]]; then
        echo "[ERROR] Template validation failed: GPU count is 0 or missing." >&2
        return 1
    fi

    if [[ $PROFILE_COUNT -le 0 ]]; then
        echo "[ERROR] Template validation failed: no profiles parsed." >&2
        return 1
    fi

    # Check for empty profile names (indicates a parsing issue)
    local i
    for ((i = 0; i < PROFILE_COUNT; i++)); do
        if [[ -z "${PROFILE_NAMES[$i]}" ]]; then
            echo "[ERROR] Template validation failed: profile $i has an empty name." >&2
            return 1
        fi
    done

    return 0
}

# Return the profile display name by index.
#
# Arguments:
#   $1 - idx: Profile index (0-based)
#
# Returns:
#   Prints the profile name to stdout
get_profile_name() {
    echo "${PROFILE_NAMES[$1]}"
}

# Return whether MIG is enabled for a profile.
#
# Arguments:
#   $1 - idx: Profile index (0-based)
#
# Returns:
#   Prints "true" or "false" to stdout
get_profile_mig_enabled() {
    echo "${PROFILE_MIG_ENABLED[$1]}"
}

# Return the mig-devices entries for a profile, formatted as YAML lines
# suitable for direct insertion into a Kubernetes ConfigMap.
#
# Arguments:
#   $1 - idx: Profile index (0-based)
#   $2 - indent: Number of spaces to indent each line (default: 10)
#
# Returns:
#   Prints formatted YAML lines to stdout, one per device.
#   Prints nothing if the profile has no mig-devices (MIG disabled).
get_profile_mig_devices_yaml() {
    local idx="$1"

    # ${2:-10} uses 10 as the default if $2 is not provided
    local indent="${2:-10}"
    local devices="${PROFILE_MIG_DEVICES[$idx]}"

    # Empty device list means MIG is disabled for this profile
    if [[ -z "$devices" ]]; then
        return
    fi

    # Build the indentation string by repeating spaces.
    local pad=""
    local s
    for ((s = 0; s < indent; s++)); do
        pad+=" "
    done

    # Split comma-separated "key:value" pairs using IFS (Internal Field Separator).
    # IFS=',' causes read to split on commas instead of whitespace.
    local pair
    IFS=',' read -ra pairs <<< "$devices"
    for pair in "${pairs[@]}"; do
        # Skip empty entries (from trailing comma)
        [[ -z "$pair" ]] && continue

        # Split "key:value" on the colon.
        # ${pair%%:*} removes everything after the first colon (keeps the key).
        # ${pair#*:}  removes everything before the first colon (keeps the value).
        local key="${pair%%:*}"
        local val="${pair#*:}"

        echo "${pad}\"${key}\": ${val}"
    done
}
