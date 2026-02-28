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

    local cols lines

    # tput cols/lines queries the terminal dimensions from the terminfo database.
    cols=$(tput cols 2>/dev/null || echo 0)
    lines=$(tput lines 2>/dev/null || echo 0)

    if [[ $cols -lt $MIN_TERM_COLS || $lines -lt $MIN_TERM_LINES ]]; then
        echo "[ERROR] Terminal too small: ${cols}x${lines} (need ${MIN_TERM_COLS}x${MIN_TERM_LINES})." >&2
        return 1
    fi

    return 0
}

# Display the welcome screen with GPU hardware information.
# Shows GPU model, memory, and count from the parsed template.
#
# Returns:
#   0 if user presses OK, non-zero if user presses ESC/Cancel
show_welcome_screen() {
    whiptail \
        --title "NVIDIA MIG Configuration Tool" \
        --msgbox "\
 Welcome to the MIG Configuration Tool

 GPU Model  : ${GPU_MODEL}
 GPU Memory : ${GPU_MEMORY}
 GPU Count  : ${GPU_COUNT}

 This tool lets you select a MIG partition profile
 for each GPU, then applies the configuration
 automatically (pre-phase + post-phase).

 Press OK to continue." \
        18 58
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

    # Separator and action items
    menu_items+=("---" "────────────────────────────────")
    menu_items+=("APPLY" ">> Apply configuration to cluster")
    menu_items+=("QUIT" ">> Exit without changes")

    # Calculate menu height: GPU_COUNT + 3 action items, capped at 16
    local menu_height=$((GPU_COUNT + 3))
    if [[ $menu_height -gt 16 ]]; then
        menu_height=16
    fi

    # whiptail --menu presents a scrollable list of tagged items.
    # 3>&1 1>&2 2>&3 swaps stdout and stderr so whiptail's selection
    # (normally written to stderr) goes to stdout for command substitution.
    # The "3>&1 1>&2 2>&3" idiom:
    #   3>&1 = save original stdout to fd 3
    #   1>&2 = redirect stdout to stderr (whiptail writes UI to stdout)
    #   2>&3 = redirect stderr to original stdout (captures whiptail's output)
    whiptail \
        --title "MIG Configuration - GPU Selection" \
        --menu "\nSelect a GPU to change its profile, or APPLY to proceed:\n" \
        $((menu_height + 8)) 64 "$menu_height" \
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
        # Description = "name — description" for clear display
        radio_items+=("$i" "${PROFILE_NAMES[$i]} — ${PROFILE_DESCS[$i]}" "$status")
    done

    # Calculate list height: one row per profile, capped at 14
    local list_height=$PROFILE_COUNT
    if [[ $list_height -gt 14 ]]; then
        list_height=14
    fi

    # whiptail --radiolist shows a single-select list with ON/OFF toggles.
    # Items are: tag description status (repeated for each item).
    whiptail \
        --title "Select MIG Profile for GPU-${gpu_idx}" \
        --radiolist "\nChoose a partition profile for GPU-${gpu_idx}:\n(Use SPACE to select, ENTER to confirm)\n" \
        $((list_height + 9)) 74 "$list_height" \
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

    summary+="Review the MIG configuration before applying:\n\n"
    summary+="  GPU  │ Profile\n"
    summary+="  ─────┼─────────────────────────────────────\n"

    for ((i = 0; i < GPU_COUNT; i++)); do
        local profile_idx="${GPU_SELECTIONS[$i]}"
        local profile_name="${PROFILE_NAMES[$profile_idx]}"

        # printf pads the GPU number to align the table columns.
        # %-4s = left-aligned, 4-character wide string field.
        summary+="$(printf "  %-4s │ %s" "$i" "$profile_name")\n"
    done

    summary+="\nThis will cordon the node, apply MIG partitions,\n"
    summary+="generate CDI specs, and uncordon when complete.\n\n"
    summary+="Proceed?"

    # whiptail --yesno shows a Yes/No dialog.
    # --yes-button/--no-button customize the button labels.
    # printf -v expands the \n escapes into actual newlines.
    local formatted
    # printf with %b interprets backslash escapes in the argument
    formatted=$(printf "%b" "$summary")

    whiptail \
        --title "Confirm MIG Configuration" \
        --yesno "$formatted" \
        $((GPU_COUNT + 16)) 58 \
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
