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

# Export the NEWT_COLORS environment variable to apply a clean
# cyan/white color theme with green highlights to all whiptail dialogs.
#
# NEWT_COLORS is a newt library feature (whiptail's rendering backend).
# Each entry sets foreground,background for a UI element.
#
# Side effects:
#   - Sets the NEWT_COLORS environment variable
setup_tui_colors() {
    # shellcheck disable=SC2155
    # button    = inactive buttons (black text on cyan bg)
    # actbutton = focused button (black text on GREEN bg -- clearly distinct)
    # actlistbox/actcheckbox use cyan highlight; active button uses green
    # so the focused button always stands out from list selections.
    export NEWT_COLORS='
        root=white,black
        border=cyan,black
        window=white,black
        shadow=,black
        title=cyan,black
        button=black,cyan
        actbutton=black,green
        checkbox=white,black
        actcheckbox=black,cyan
        listbox=white,black
        actlistbox=black,cyan
        textbox=white,black
        roottext=cyan,black
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

# Display the welcome screen with GPU hardware information and navigation
# instructions. Uses --yesno with Continue/Exit buttons.
#
# Returns:
#   0 if user presses Continue, non-zero if user presses Exit/ESC
show_welcome_screen() {
    local dlg_h=$((TERM_LINES - 4))
    local dlg_w=$((TERM_COLS - 10))

    # Clamp to sane maximums so the dialog doesn't look stretched on huge terminals.
    # (( )) for arithmetic comparison; conditional assignment.
    (( dlg_h > 20 )) && dlg_h=20
    (( dlg_w > 68 )) && dlg_w=68

    local body=""
    body+="       NVIDIA MIG Partition Configuration\n"
    body+="\n"
    body+="  Hardware Summary\n"
    body+="  ================================================\n"
    body+="   GPU Model   :  ${GPU_MODEL}\n"
    body+="   GPU Memory  :  ${GPU_MEMORY}\n"
    body+="   GPU Count   :  ${GPU_COUNT}\n"
    body+="  ================================================\n"
    body+="\n"
    body+="  This tool lets you select a MIG partition\n"
    body+="  profile for each GPU, then automatically\n"
    body+="  applies the configuration to the cluster.\n"
    body+="\n"
    body+="  Navigation:\n"
    body+="    Arrow keys .... Move       TAB ....... Buttons\n"
    body+="    SPACE ......... Select     ENTER ..... Confirm"

    local formatted
    formatted=$(printf "%b" "$body")

    whiptail \
        --title " NVIDIA MIG Configuration Tool " \
        --yes-button " Continue " \
        --no-button " Exit " \
        --yesno "$formatted" \
        "$dlg_h" "$dlg_w"
}

# Display the main menu hub showing all GPUs and their current profile
# selections. Provides APPLY and QUIT options at the bottom.
#
# Returns:
#   0 on selection (result stored in TUI_RESULT)
#   non-zero on Cancel/ESC
#
# Side effects:
#   - Sets TUI_RESULT to the selected menu tag (e.g., "GPU-0", "APPLY")
show_main_menu() {
    local menu_items=()
    local i

    # Build menu items: one entry per GPU showing its current profile.
    # printf pads the GPU index to keep the menu aligned.
    for ((i = 0; i < GPU_COUNT; i++)); do
        local profile_idx="${GPU_SELECTIONS[$i]}"
        local profile_name="${PROFILE_NAMES[$profile_idx]}"

        # Tag = "GPU-N", Description = profile name with arrow prefix
        menu_items+=("GPU-${i}" "=> ${profile_name}")
    done

    # Action items at the bottom of the menu.
    # Tags must NOT start with "-" -- whiptail would parse them as CLI options.
    menu_items+=("APPLY" "** Apply configuration to cluster **")
    menu_items+=("QUIT" "   Exit without changes")

    # Calculate menu height: GPU_COUNT + 2 action items, capped at 16
    local menu_height=$((GPU_COUNT + 2))
    (( menu_height > 16 )) && menu_height=16

    # Cap dialog dimensions to terminal size minus margin.
    # 8 extra rows = title + border + prompt text + button row + padding.
    local dlg_h=$((menu_height + 8))
    local dlg_w=$((TERM_COLS - 10))

    (( dlg_h > TERM_LINES - 4 )) && dlg_h=$((TERM_LINES - 4))
    (( dlg_w > 70 )) && dlg_w=70

    # Recalculate menu_height if dialog was clamped -- whiptail needs
    # the list area to fit inside the dialog (dialog - ~7 overhead rows).
    local max_list=$((dlg_h - 7))
    (( menu_height > max_list )) && menu_height=$max_list

    _whiptail_capture \
        --title " MIG Configuration :: GPU Selection " \
        --ok-button " Select " \
        --cancel-button " Exit " \
        --menu "Select a GPU to change its profile, or APPLY to proceed." \
        "$dlg_h" "$dlg_w" "$menu_height" \
        "${menu_items[@]}"
}

# Display a radio list of all available MIG profiles for a specific GPU.
# Shows the profile description alongside each name so the operator
# knows what each profile provides.
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

        # Pre-select the currently assigned profile
        if [[ $i -eq $current_selection ]]; then
            status="ON"
        fi

        # Build a descriptive label: name + description
        # Example: "1g.18gb x7  --  7 small slices, 18GB each"
        local label="${PROFILE_NAMES[$i]}"
        if [[ -n "${PROFILE_DESCS[$i]}" ]]; then
            label+="  --  ${PROFILE_DESCS[$i]}"
        fi

        # Radio list items are: tag description status
        # Tag = profile index (used as the return value)
        radio_items+=("$i" "$label" "$status")
    done

    # Calculate list height: one row per profile, capped at 14
    local list_height=$PROFILE_COUNT
    (( list_height > 14 )) && list_height=14

    # Cap dialog dimensions to terminal size minus margin.
    # 9 extra rows = title + border + prompt text + button row + padding.
    local dlg_h=$((list_height + 9))
    local dlg_w=$((TERM_COLS - 6))

    (( dlg_h > TERM_LINES - 4 )) && dlg_h=$((TERM_LINES - 4))
    (( dlg_w > 78 )) && dlg_w=78

    # Recalculate list_height if dialog was clamped
    local max_list=$((dlg_h - 8))
    (( list_height > max_list )) && list_height=$max_list

    _whiptail_capture \
        --title " GPU-${gpu_idx} :: Select MIG Profile " \
        --ok-button " Select " \
        --cancel-button " Back " \
        --radiolist "SPACE = pick a profile    TAB = switch buttons    ENTER = confirm" \
        "$dlg_h" "$dlg_w" "$list_height" \
        "${radio_items[@]}"
}

# Display a confirmation dialog showing the full GPU->profile assignment
# table before applying changes.
#
# Returns:
#   0 if user confirms (Apply)
#   non-zero if user cancels (Back)
show_confirmation() {
    local summary=""
    local i

    summary+="  GPU  | MIG Profile\n"
    summary+="  =====+=============================================\n"

    for ((i = 0; i < GPU_COUNT; i++)); do
        local profile_idx="${GPU_SELECTIONS[$i]}"
        local profile_name="${PROFILE_NAMES[$profile_idx]}"

        # printf pads the GPU number to align the table columns.
        # %-5s = left-aligned, 5-character wide string field.
        summary+="$(printf "  %-5s| %s" "$i" "$profile_name")\n"
    done

    summary+="  =====+=============================================\n"
    summary+="\n"
    summary+="  This will:\n"
    summary+="    1. Cordon the worker node\n"
    summary+="    2. Apply MIG partition configuration\n"
    summary+="    3. Generate CDI specification\n"
    summary+="    4. Switch runtime to CDI mode\n"
    summary+="    5. Uncordon the worker node\n"
    summary+="\n"
    summary+="  Proceed with applying this configuration?"

    # printf with %b interprets backslash escapes in the argument
    local formatted
    formatted=$(printf "%b" "$summary")

    # Cap dialog dimensions to terminal size minus margin
    local dlg_h=$((GPU_COUNT + 20))
    local dlg_w=$((TERM_COLS - 10))

    (( dlg_h > TERM_LINES - 4 )) && dlg_h=$((TERM_LINES - 4))
    (( dlg_w > 60 )) && dlg_w=60

    whiptail \
        --title " Confirm MIG Configuration " \
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
    # Initialize all GPUs to profile 0 (typically "MIG Disabled")
    local i
    for ((i = 0; i < GPU_COUNT; i++)); do
        GPU_SELECTIONS[$i]=0
    done

    setup_tui_colors

    # Show welcome screen; exit if user cancels
    if ! show_welcome_screen; then
        return 1
    fi

    # Hub-and-spoke navigation loop
    while true; do

        if ! show_main_menu; then
            # Cancel/ESC on main menu -> confirm exit
            if whiptail --title " Exit " \
                    --yes-button " Exit " --no-button " Back " \
                    --yesno "\n  Exit without making changes?" 9 44; then
                return 1
            fi
            continue
        fi

        local choice="$TUI_RESULT"

        case "$choice" in
            GPU-*)
                # Extract GPU index from "GPU-N" tag.
                # ${choice#GPU-} removes the "GPU-" prefix, leaving just N.
                local gpu_idx="${choice#GPU-}"

                if show_profile_picker "$gpu_idx"; then
                    # Validate that the selection is not empty
                    if [[ -n "$TUI_RESULT" ]]; then
                        GPU_SELECTIONS[$gpu_idx]="$TUI_RESULT"
                    fi
                fi
                # Cancel on profile picker -> return to hub unchanged
                ;;

            "APPLY")
                if show_confirmation; then
                    return 0
                fi
                # User chose "Back" -> return to hub
                ;;

            "QUIT")
                if whiptail --title " Exit " \
                        --yes-button " Exit " --no-button " Back " \
                        --yesno "\n  Exit without making changes?" 9 44; then
                    return 1
                fi
                ;;
        esac
    done
}
