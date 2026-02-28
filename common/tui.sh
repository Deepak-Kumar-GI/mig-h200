#!/bin/bash
# ============================================================================
# MIG Configuration TUI - Whiptail-Based Interface
# ============================================================================
# Provides an interactive terminal UI for selecting MIG partition profiles
# per GPU. Uses whiptail (a lightweight ncurses dialog tool) for rendering.
#
# Screen flow:
#   Welcome (yesno) --> Main Menu Hub (menu) <--> Profile Picker (radiolist)
#                            |
#                       Confirmation (yesno) --> proceed / back to hub
#
# Capture pattern: dialogs that return a selection (menu, radiolist)
# redirect stderr to a temp file (whiptail writes its selection there)
# and store the result in the TUI_RESULT global. This avoids the
# 3>&1 1>&2 2>&3 fd-swap inside $() which breaks under set -euo pipefail.
# Display-only dialogs (msgbox, yesno) call whiptail directly.
#
# Depends on: common/template-parser.sh (profile arrays must be populated)
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-02-28
# ============================================================================

# ============================================================================
# CONSTANTS
# ============================================================================

# Minimum terminal dimensions required for the TUI.
# Whiptail needs enough space for menus, radio lists, and confirmation screens.
readonly MIN_TERM_COLS=80
readonly MIN_TERM_LINES=24

# ============================================================================
# GLOBAL STATE
# ============================================================================

# GPU_SELECTIONS[i] = profile index chosen for GPU i.
# Initialized to 0 (first profile, typically "MIG Disabled") by run_tui().
# declare -a creates an indexed array.
declare -a GPU_SELECTIONS

# Actual terminal dimensions, set by check_tui_deps().
# Used to size every dialog so it never exceeds the terminal.
TERM_COLS=80
TERM_LINES=24

# Holds the output from the last whiptail dialog that returns a selection
# (--menu, --radiolist). Set by show_main_menu() and show_profile_picker().
TUI_RESULT=""

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Capture whiptail's selection via a temp file on stderr.
# whiptail draws its UI on stdout (terminal) and writes the user's
# selection to stderr. Redirecting stderr to a temp file captures the
# selection without needing a $() subshell or the 3>&1 1>&2 2>&3 fd-swap
# (which breaks under set -euo pipefail in some bash versions).
#
# Arguments:
#   All arguments are passed through to whiptail unchanged.
#
# Returns:
#   whiptail's exit code (0 = selection made, 1 = Cancel, 255 = ESC)
#
# Side effects:
#   - Sets TUI_RESULT to the selected tag (on success) or "" (on cancel)
#   - Creates and removes a temp file in /tmp
_whiptail_capture() {
    local _tmpf
    # mktemp creates a unique temp file securely (no race conditions).
    _tmpf=$(mktemp)

    whiptail "$@" 2>"$_tmpf"
    local rc=$?

    # $(<file) reads file contents without spawning a subprocess (cat).
    TUI_RESULT=$(<"$_tmpf")
    rm -f "$_tmpf"

    return $rc
}

# Export the NEWT_COLORS environment variable to apply a green-bordered
# color theme to all whiptail dialogs.
#
# NEWT_COLORS is a newt library feature (whiptail's rendering backend).
# Each entry sets foreground,background for a UI element.
#
# Theme: green borders/titles on black, white text.
# Buttons: black-on-green (inactive) vs white-on-green (focused).
#
# Side effects:
#   - Sets the NEWT_COLORS environment variable
setup_tui_colors() {
    # shellcheck disable=SC2155
    export NEWT_COLORS='
        root=white,black
        border=green,black
        window=white,black
        shadow=,black
        title=green,black
        button=black,green
        actbutton=white,green
        checkbox=white,black
        actcheckbox=black,green
        listbox=white,black
        actlistbox=black,green
        textbox=white,black
        roottext=green,black
    '
}

# Verify that whiptail is installed and the terminal is large enough.
#
# Returns:
#   0 if all checks pass
#   1 if whiptail is missing or terminal is too small
#
# Side effects:
#   - Sets TERM_COLS and TERM_LINES globals
#   - Prints error messages to stderr on failure
check_tui_deps() {
    # command -v checks if a command exists in PATH without executing it
    if ! command -v whiptail >/dev/null 2>&1; then
        echo "[ERROR] whiptail is not installed. Install it with:" >&2
        echo "        apt-get install whiptail   (Debian/Ubuntu)" >&2
        echo "        yum install newt            (RHEL/CentOS)" >&2
        return 1
    fi

    # tput cols/lines queries the terminal dimensions from the terminfo database.
    # Store in globals so all dialog functions can size themselves dynamically.
    TERM_COLS=$(tput cols 2>/dev/null || echo 0)
    TERM_LINES=$(tput lines 2>/dev/null || echo 0)

    if [[ $TERM_COLS -lt $MIN_TERM_COLS || $TERM_LINES -lt $MIN_TERM_LINES ]]; then
        echo "[ERROR] Terminal too small: ${TERM_COLS}x${TERM_LINES} (need ${MIN_TERM_COLS}x${MIN_TERM_LINES})." >&2
        return 1
    fi

    return 0
}

# ============================================================================
# TUI SCREENS
# ============================================================================

# Display the welcome screen with GPU hardware information.
# Minimal layout modeled after BIOS system information panels.
#
# Returns:
#   0 if user presses Continue, non-zero if user presses Exit/ESC
show_welcome_screen() {
    local dlg_h=$((TERM_LINES - 4))
    local dlg_w=$((TERM_COLS - 10))

    # Clamp to sane maximums so the dialog doesn't look stretched on huge terminals.
    # (( )) for arithmetic comparison; conditional assignment.
    (( dlg_h > 14 )) && dlg_h=14
    (( dlg_w > 56 )) && dlg_w=56

    local body=""
    body+="\n"
    body+="  Model    ${GPU_MODEL}\n"
    body+="  Memory   ${GPU_MEMORY}\n"
    body+="  GPUs     ${GPU_COUNT}\n"
    body+="\n"
    body+="  Configure MIG partitions for each GPU\n"
    body+="  on this worker node."

    local formatted
    # printf with %b interprets backslash escapes (\n) in the argument.
    formatted=$(printf "%b" "$body")

    whiptail \
        --title " NVIDIA MIG Configuration " \
        --yes-button " Continue " \
        --no-button " Exit " \
        --yesno "$formatted" \
        "$dlg_h" "$dlg_w"
}

# Display the main menu hub showing all GPUs and their current profile
# selections. APPLY and QUIT sit at the bottom of the same list.
#
# Returns:
#   0 on selection (result stored in TUI_RESULT)
#   non-zero on Cancel/ESC
#
# Side effects:
#   - Sets TUI_RESULT to the selected menu tag (e.g., "GPU 0", "APPLY")
show_main_menu() {
    local menu_items=()
    local i

    # Build menu items: one entry per GPU showing its current profile.
    for ((i = 0; i < GPU_COUNT; i++)); do
        local profile_idx="${GPU_SELECTIONS[$i]}"
        local profile_name="${PROFILE_NAMES[$profile_idx]}"

        # Tag = "GPU N" (space, not dash — reads as a label, not a code).
        # Description = bare profile name, no decorations.
        menu_items+=("GPU ${i}" "${profile_name}")
    done

    # Action items at the bottom of the menu.
    # Tags must NOT start with "-" — whiptail would parse them as CLI options.
    menu_items+=("APPLY" "Apply configuration")
    menu_items+=("QUIT" "Exit without changes")

    # Calculate menu height: GPU_COUNT + 2 action items, capped at 16.
    local menu_height=$((GPU_COUNT + 2))
    (( menu_height > 16 )) && menu_height=16

    # Cap dialog dimensions to terminal size minus margin.
    # 8 extra rows = title + border + prompt text + button row + padding.
    local dlg_h=$((menu_height + 8))
    local dlg_w=$((TERM_COLS - 10))

    (( dlg_h > TERM_LINES - 4 )) && dlg_h=$((TERM_LINES - 4))
    (( dlg_w > 60 )) && dlg_w=60

    # Recalculate menu_height if dialog was clamped — whiptail needs
    # the list area to fit inside the dialog (dialog - ~7 overhead rows).
    local max_list=$((dlg_h - 7))
    (( menu_height > max_list )) && menu_height=$max_list

    _whiptail_capture \
        --title " MIG Configuration -- GPU Selection " \
        --ok-button " Select " \
        --cancel-button " Exit " \
        --menu "Choose a GPU to change its profile." \
        "$dlg_h" "$dlg_w" "$menu_height" \
        "${menu_items[@]}"
}

# Display a radio list of available MIG profiles for a specific GPU.
# Profile names only — no descriptions. The name is the specification
# (e.g., "2g.35gb x3" is self-documenting to a DGX operator).
#
# Arguments:
#   $1 - gpu_idx: The GPU index (0-based) being configured
#
# Returns:
#   0 on selection (result stored in TUI_RESULT)
#   non-zero on Cancel/ESC (no change)
#
# Side effects:
#   - Sets TUI_RESULT to the selected profile index
show_profile_picker() {
    local gpu_idx="$1"
    local current_selection="${GPU_SELECTIONS[$gpu_idx]}"
    local radio_items=()
    local i

    for ((i = 0; i < PROFILE_COUNT; i++)); do
        local status="OFF"

        # Pre-select the currently assigned profile.
        if [[ $i -eq $current_selection ]]; then
            status="ON"
        fi

        # Radio list items are: tag description status.
        # Tag = profile index (used as the return value).
        # Description = profile name only, no appended description.
        radio_items+=("$i" "${PROFILE_NAMES[$i]}" "$status")
    done

    # Calculate list height: one row per profile, capped at 14.
    local list_height=$PROFILE_COUNT
    (( list_height > 14 )) && list_height=14

    # Cap dialog dimensions to terminal size minus margin.
    # 8 extra rows = title + border + prompt text + button row + padding.
    local dlg_h=$((list_height + 8))
    local dlg_w=$((TERM_COLS - 10))

    (( dlg_h > TERM_LINES - 4 )) && dlg_h=$((TERM_LINES - 4))
    (( dlg_w > 60 )) && dlg_w=60

    # Recalculate list_height if dialog was clamped.
    local max_list=$((dlg_h - 7))
    (( list_height > max_list )) && list_height=$max_list

    _whiptail_capture \
        --title " GPU ${gpu_idx} -- MIG Profile " \
        --ok-button " Select " \
        --cancel-button " Back " \
        --radiolist "Select a profile for GPU ${gpu_idx}." \
        "$dlg_h" "$dlg_w" "$list_height" \
        "${radio_items[@]}"
}

# Display a confirmation dialog showing the GPU-to-profile assignment
# table before applying changes.
#
# Returns:
#   0 if user confirms (Apply)
#   non-zero if user cancels (Back)
show_confirmation() {
    local summary=""
    local i

    summary+="  The following profiles will be applied:\n"
    summary+="\n"

    for ((i = 0; i < GPU_COUNT; i++)); do
        local profile_idx="${GPU_SELECTIONS[$i]}"
        local profile_name="${PROFILE_NAMES[$profile_idx]}"

        # printf pads the GPU label to align the profile column.
        # %-8s = left-aligned, 8-character wide string field.
        summary+="$(printf "    %-8s %s" "GPU ${i}" "$profile_name")\n"
    done

    summary+="\n"
    summary+="  The node will be cordoned, reconfigured,\n"
    summary+="  and uncordoned automatically."

    # printf with %b interprets backslash escapes in the argument.
    local formatted
    formatted=$(printf "%b" "$summary")

    # Cap dialog dimensions to terminal size minus margin.
    # GPU_COUNT + 10 rows = GPU lines + header + summary sentence + borders.
    local dlg_h=$((GPU_COUNT + 10))
    local dlg_w=$((TERM_COLS - 10))

    (( dlg_h > TERM_LINES - 4 )) && dlg_h=$((TERM_LINES - 4))
    (( dlg_w > 56 )) && dlg_w=56

    whiptail \
        --title " Confirm Configuration " \
        --yes-button " Apply " \
        --no-button " Back " \
        --yesno "$formatted" \
        "$dlg_h" "$dlg_w"
}

# ============================================================================
# MAIN LOGIC
# ============================================================================

# Main TUI navigation loop implementing hub-and-spoke navigation.
# Runs the welcome screen, then enters the main menu hub where users
# can select GPUs, pick profiles, and ultimately apply or quit.
#
# Returns:
#   0 if user confirmed and wants to proceed with APPLY
#   1 if user chose to quit without changes
#
# Side effects:
#   - Populates GPU_SELECTIONS[] with user choices
run_tui() {
    # Initialize all GPUs to profile 0 (typically "MIG Disabled").
    local i
    for ((i = 0; i < GPU_COUNT; i++)); do
        GPU_SELECTIONS[$i]=0
    done

    setup_tui_colors

    # Show welcome screen; exit if user cancels.
    if ! show_welcome_screen; then
        return 1
    fi

    # Hub-and-spoke navigation loop.
    while true; do

        if ! show_main_menu; then
            # Cancel/ESC on main menu -> confirm exit.
            if whiptail --title " Exit " \
                    --yes-button " Exit " --no-button " Back " \
                    --yesno "\n  Exit without making changes?" 8 42; then
                return 1
            fi
            continue
        fi

        local choice="$TUI_RESULT"

        case "$choice" in
            GPU\ *)
                # Extract GPU index from "GPU N" tag.
                # ${choice#GPU } removes the "GPU " prefix, leaving just N.
                local gpu_idx="${choice#GPU }"

                if show_profile_picker "$gpu_idx"; then
                    # Validate that the selection is not empty.
                    if [[ -n "$TUI_RESULT" ]]; then
                        GPU_SELECTIONS[$gpu_idx]="$TUI_RESULT"
                    fi
                fi
                # Cancel on profile picker -> return to hub unchanged.
                ;;

            "APPLY")
                if show_confirmation; then
                    return 0
                fi
                # User chose "Back" -> return to hub.
                ;;

            "QUIT")
                if whiptail --title " Exit " \
                        --yes-button " Exit " --no-button " Back " \
                        --yesno "\n  Exit without making changes?" 8 42; then
                    return 1
                fi
                ;;
        esac
    done
}
