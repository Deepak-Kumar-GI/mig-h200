#!/bin/bash
# ============================================================================
# MIG Configuration TUI - Whiptail-Based Interface
# ============================================================================
# Provides an interactive terminal UI for selecting MIG partition profiles
# per GPU. Uses whiptail (a lightweight ncurses dialog tool) for rendering.
#
# Screen flow:
#   Welcome (msgbox) → Main Menu Hub (menu) ←→ Profile Picker (radiolist)
#                           ↓
#                      Confirmation (yesno) → proceed / back to hub
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
readonly MIN_TERM_COLS=60
readonly MIN_TERM_LINES=20

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

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Export the NEWT_COLORS environment variable to apply an NVIDIA-branded
# green-on-black color theme to all whiptail dialogs.
#
# NEWT_COLORS is a newt library feature (whiptail's rendering backend).
# Each entry sets foreground,background for a UI element.
#
# Side effects:
#   - Sets the NEWT_COLORS environment variable
setup_tui_colors() {
    # shellcheck disable=SC2155
    export NEWT_COLORS='
        root=green,black
        border=green,black
        window=green,black
        shadow=green,black
        title=green,black
        button=black,green
        actbutton=black,green
        checkbox=green,black
        actcheckbox=black,green
        listbox=green,black
        actlistbox=black,green
        sellistbox=black,green
        actsellistbox=black,green
        textbox=green,black
        acttextbox=black,green
        entry=green,black
        compactbutton=black,green
        helpline=green,black
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

# Display the welcome screen with GPU hardware information.
# Shows GPU model, memory, and count from the parsed template.
# Dialog dimensions are capped to fit the current terminal.
#
# Returns:
#   0 if user presses OK, non-zero if user presses ESC/Cancel
show_welcome_screen() {
    # Cap dialog to terminal size minus a 2-line/4-col margin so whiptail
    # never tries to draw outside the terminal (which causes it to fail).
    local dlg_h=$((TERM_LINES - 2))
    local dlg_w=$((TERM_COLS - 4))

    # Clamp to sane maximums so the dialog doesn't look stretched on huge terminals.
    # (( )) for arithmetic comparison; conditional assignment.
    (( dlg_h > 14 )) && dlg_h=14
    (( dlg_w > 58 )) && dlg_w=58

    whiptail \
        --title "NVIDIA MIG Configuration Tool" \
        --msgbox "Welcome to the MIG Configuration Tool

GPU Model  : ${GPU_MODEL}
GPU Memory : ${GPU_MEMORY}
GPU Count  : ${GPU_COUNT}

Select a MIG profile for each GPU, then
apply to run the full workflow automatically.

Press OK to continue." \
        "$dlg_h" "$dlg_w"
}

# Display the main menu hub showing all GPUs and their current profile
# selections. Provides APPLY and QUIT options at the bottom.
#
# Returns:
#   0 on selection (writes chosen tag to stdout via fd 3)
#   non-zero on Cancel/ESC
#
# Side effects:
#   - Outputs the selected menu tag to file descriptor 3
show_main_menu() {
    local menu_items=()
    local i

    # Build menu items: one entry per GPU showing its current profile
    for ((i = 0; i < GPU_COUNT; i++)); do
        local profile_idx="${GPU_SELECTIONS[$i]}"
        local profile_name="${PROFILE_NAMES[$profile_idx]}"
        menu_items+=("GPU-${i}" "${profile_name}")
    done

    # Separator and action items (ASCII-safe dash line for portability)
    menu_items+=("---" "--------------------------------")
    menu_items+=("APPLY" ">> Apply configuration to cluster")
    menu_items+=("QUIT" ">> Exit without changes")

    # Calculate menu height: GPU_COUNT + 3 action items, capped at 16
    local menu_height=$((GPU_COUNT + 3))
    (( menu_height > 16 )) && menu_height=16

    # Cap dialog dimensions to terminal size minus margin.
    # 8 extra rows = title + border + prompt text + button row + padding.
    local dlg_h=$((menu_height + 8))
    local dlg_w=$((TERM_COLS - 4))

    (( dlg_h > TERM_LINES - 2 )) && dlg_h=$((TERM_LINES - 2))
    (( dlg_w > 64 )) && dlg_w=64

    # Recalculate menu_height if dialog was clamped — whiptail needs
    # the list area to fit inside the dialog (dialog - ~7 overhead rows).
    local max_list=$((dlg_h - 7))
    (( menu_height > max_list )) && menu_height=$max_list

    # whiptail --menu presents a scrollable list of tagged items.
    # 3>&1 1>&2 2>&3 swaps stdout and stderr so whiptail's selection
    # (normally written to stderr) goes to stdout for command substitution.
    # The "3>&1 1>&2 2>&3" idiom:
    #   3>&1 = save original stdout to fd 3
    #   1>&2 = redirect stdout to stderr (whiptail writes UI to stdout)
    #   2>&3 = redirect stderr to original stdout (captures whiptail's output)
    whiptail \
        --title "MIG Configuration - GPU Selection" \
        --menu "Select a GPU to change its profile, or APPLY:" \
        "$dlg_h" "$dlg_w" "$menu_height" \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3
}

# Display a radio list of all available MIG profiles for a specific GPU.
# The current selection is pre-selected (ON).
#
# Arguments:
#   $1 - gpu_idx: The GPU index (0-based) being configured
#
# Returns:
#   0 on selection (writes chosen profile index to stdout via fd 3)
#   non-zero on Cancel/ESC (no change)
#
# Side effects:
#   - Outputs the selected profile index to stdout via fd swap
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

        # Radio list items are: tag description status
        # Tag = profile index (used as the return value)
        # Description = profile name (whiptail truncates if it overflows)
        radio_items+=("$i" "${PROFILE_NAMES[$i]}" "$status")
    done

    # Calculate list height: one row per profile, capped at 14
    local list_height=$PROFILE_COUNT
    (( list_height > 14 )) && list_height=14

    # Cap dialog dimensions to terminal size minus margin.
    # 9 extra rows = title + border + prompt text (3 lines) + button row + padding.
    local dlg_h=$((list_height + 9))
    local dlg_w=$((TERM_COLS - 4))

    (( dlg_h > TERM_LINES - 2 )) && dlg_h=$((TERM_LINES - 2))
    (( dlg_w > 64 )) && dlg_w=64

    # Recalculate list_height if dialog was clamped
    local max_list=$((dlg_h - 8))
    (( list_height > max_list )) && list_height=$max_list

    # whiptail --radiolist shows a single-select list with ON/OFF toggles.
    # Items are: tag description status (repeated for each item).
    whiptail \
        --title "Select MIG Profile for GPU-${gpu_idx}" \
        --radiolist "SPACE to select, ENTER to confirm:" \
        "$dlg_h" "$dlg_w" "$list_height" \
        "${radio_items[@]}" \
        3>&1 1>&2 2>&3
}

# Display a confirmation dialog showing the full GPU→profile assignment
# table before applying changes.
#
# Returns:
#   0 if user confirms (Yes)
#   non-zero if user cancels (No)
show_confirmation() {
    local summary=""
    local i

    summary+="Review the MIG configuration:\n\n"
    summary+="  GPU | Profile\n"
    summary+="  ----+-------------------------------\n"

    for ((i = 0; i < GPU_COUNT; i++)); do
        local profile_idx="${GPU_SELECTIONS[$i]}"
        local profile_name="${PROFILE_NAMES[$profile_idx]}"

        # printf pads the GPU number to align the table columns.
        # %-4s = left-aligned, 4-character wide string field.
        summary+="$(printf "  %-4s| %s" "$i" "$profile_name")\n"
    done

    summary+="\nThis will cordon the node, apply MIG\n"
    summary+="partitions, generate CDI, and uncordon.\n\n"
    summary+="Proceed?"

    # printf with %b interprets backslash escapes in the argument
    local formatted
    formatted=$(printf "%b" "$summary")

    # Cap dialog dimensions to terminal size minus margin
    local dlg_h=$((GPU_COUNT + 14))
    local dlg_w=$((TERM_COLS - 4))

    (( dlg_h > TERM_LINES - 2 )) && dlg_h=$((TERM_LINES - 2))
    (( dlg_w > 54 )) && dlg_w=54

    # whiptail --yesno shows a Yes/No dialog.
    # --yes-button/--no-button customize the button labels.
    whiptail \
        --title "Confirm MIG Configuration" \
        --yesno "$formatted" \
        "$dlg_h" "$dlg_w" \
        --yes-button "Apply" \
        --no-button "Back"
}

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
        local choice
        choice=$(show_main_menu) || {
            # Cancel/ESC on main menu → confirm exit
            if whiptail --title "Exit" --yesno "Exit without making changes?" 8 44; then
                return 1
            fi
            continue
        }

        case "$choice" in
            GPU-*)
                # Extract GPU index from "GPU-N" tag.
                # ${choice#GPU-} removes the "GPU-" prefix, leaving just N.
                local gpu_idx="${choice#GPU-}"

                local new_profile
                new_profile=$(show_profile_picker "$gpu_idx") || {
                    # Cancel on profile picker → return to hub unchanged
                    continue
                }

                # Validate that the selection is not empty
                if [[ -n "$new_profile" ]]; then
                    GPU_SELECTIONS[$gpu_idx]="$new_profile"
                fi
                ;;

            "APPLY")
                if show_confirmation; then
                    return 0
                fi
                # User chose "Back" → return to hub
                ;;

            "QUIT")
                if whiptail --title "Exit" --yesno "Exit without making changes?" 8 44; then
                    return 1
                fi
                ;;

            "---")
                # Separator item — do nothing, return to menu
                ;;
        esac
    done
}
