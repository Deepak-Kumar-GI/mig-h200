#!/bin/bash
# ============================================================================
# MIG Configuration TUI - Whiptail-Based Interface
# ============================================================================
# Provides an interactive terminal UI for selecting MIG partition profiles
# per GPU. Uses whiptail (a lightweight ncurses dialog tool) for rendering.
#
# Screen flow:
#   Welcome (yesno) --> GPU Hub (menu) <--> Profile Picker (menu)
#                           |
#                      Confirmation (yesno) --> proceed / back to hub
#
# The GPU hub uses whiptail exit codes to separate actions:
#   rc=0   (OK / Select button)     = user selected a GPU
#   rc=1   (Cancel / Apply button)  = user wants to apply configuration
#   rc=255 (ESC key)                = user wants to exit
#
# Capture pattern: dialogs that return a selection (menu)
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

# Maximum dialog width (characters). Wide enough for navigation hints
# to display on a single line (~66 chars for the longest hint) but
# capped so dialogs don't look stretched on very wide terminals.
readonly MAX_DLG_WIDTH=78

# Navigation hint for yesno/confirmation screens where ENTER confirms.
readonly NAV_HINT="Arrows=Navigate  TAB=Switch  ENTER=Confirm  ESC=Exit"

# Navigation hint for menu screens (GPU hub, profile picker) where
# ENTER selects a list item rather than confirming an action.
readonly NAV_HINT_MENU="Arrows=Navigate  TAB=Switch  ENTER=Select  ESC=Exit"

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
# (--menu). Set by show_main_menu() and show_profile_picker().
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

# Export the NEWT_COLORS environment variable to apply a green-themed
# color scheme to all whiptail dialogs.
#
# NEWT_COLORS is a newt library feature (whiptail's rendering backend).
# Each entry sets foreground,background for a UI element.
#
# Theme: green borders/titles on black, white text.
# Buttons: black-on-green (inactive) vs white-on-green (focused).
# Selected list items use green to match the overall theme.
#
# Side effects:
#   - Sets the NEWT_COLORS environment variable
setup_tui_colors() {
    # shellcheck disable=SC2155
    # sellistbox    = selected (toggled) item in a radiolist/checklist
    # actsellistbox = focused + selected item in a radiolist/checklist
    # Without these, whiptail falls back to its default red highlight.
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
        sellistbox=black,green
        actsellistbox=white,green
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
    local dlg_w=$((TERM_COLS - 8))

    # Clamp to sane maximums so the dialog doesn't look stretched on huge terminals.
    # (( )) for arithmetic comparison; conditional assignment.
    (( dlg_h > 16 )) && dlg_h=16
    (( dlg_w > MAX_DLG_WIDTH )) && dlg_w=$MAX_DLG_WIDTH

    local body=""
    body+="\n"
    body+="  Model    ${GPU_MODEL}\n"
    body+="  Memory   ${GPU_MEMORY}\n"
    body+="  GPUs     ${GPU_COUNT}\n"
    body+="\n"
    body+="  Configure MIG partitions for each GPU on this worker node.\n"
    body+="\n"
    body+="  ${NAV_HINT}"

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

# Display the GPU selection hub. The menu lists GPU entries only.
# ENTER or the Select button (OK, rc=0) opens the profile picker.
# The Apply button (Cancel, rc=1) proceeds to the confirmation screen.
# ESC (rc=255) offers an exit prompt.
#
# whiptail exit codes used:
#   0   = OK button (Select) — user selected a GPU to configure
#   1   = Cancel button (Apply) — user wants to apply and proceed
#   255 = ESC key — user wants to exit
#
# Returns:
#   Exit code from whiptail (0, 1, or 255)
#
# Side effects:
#   - Sets TUI_RESULT to the selected GPU tag (e.g., "GPU 0") on rc=0
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

    # Calculate menu height: one row per GPU, capped at 16.
    local menu_height=$GPU_COUNT
    (( menu_height > 16 )) && menu_height=16

    # Cap dialog dimensions to terminal size minus margin.
    # 8 extra rows = title + border + prompt text + button row + padding.
    local dlg_h=$((menu_height + 8))
    local dlg_w=$((TERM_COLS - 8))

    (( dlg_h > TERM_LINES - 4 )) && dlg_h=$((TERM_LINES - 4))
    (( dlg_w > MAX_DLG_WIDTH )) && dlg_w=$MAX_DLG_WIDTH

    # Recalculate menu_height if dialog was clamped — whiptail needs
    # the list area to fit inside the dialog (dialog - ~7 overhead rows).
    local max_list=$((dlg_h - 7))
    (( menu_height > max_list )) && menu_height=$max_list

    _whiptail_capture \
        --title " MIG Configuration " \
        --ok-button " Select " \
        --cancel-button " Apply " \
        --menu "$NAV_HINT_MENU" \
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
#   0   on selection (result stored in TUI_RESULT)
#   1   on Back button (no change)
#   255 on ESC (caller should offer exit)
#
# Side effects:
#   - Sets TUI_RESULT to the selected profile index on rc=0
show_profile_picker() {
    local gpu_idx="$1"
    local current_selection="${GPU_SELECTIONS[$gpu_idx]}"
    local menu_items=()
    local i

    for ((i = 0; i < PROFILE_COUNT; i++)); do
        local label="${PROFILE_NAMES[$i]}"

        # Append a marker so the operator can see which profile is
        # already assigned before making a change.
        if [[ $i -eq $current_selection ]]; then
            label+="  [current]"
        fi

        # Menu items are: tag description.
        # Tag = profile index (used as the return value).
        menu_items+=("$i" "$label")
    done

    # Calculate list height: one row per profile, capped at 14.
    local list_height=$PROFILE_COUNT
    (( list_height > 14 )) && list_height=14

    # Cap dialog dimensions to terminal size minus margin.
    # 8 extra rows = title + border + prompt text + button row + padding.
    local dlg_h=$((list_height + 8))
    local dlg_w=$((TERM_COLS - 8))

    (( dlg_h > TERM_LINES - 4 )) && dlg_h=$((TERM_LINES - 4))
    (( dlg_w > MAX_DLG_WIDTH )) && dlg_w=$MAX_DLG_WIDTH

    # Recalculate list_height if dialog was clamped.
    local max_list=$((dlg_h - 7))
    (( list_height > max_list )) && list_height=$max_list

    # --default-item positions the highlight on the currently assigned
    # profile so the user sees which one is active on entry.
    _whiptail_capture \
        --title " GPU ${gpu_idx} -- MIG Profile " \
        --ok-button " Select " \
        --cancel-button " Back " \
        --default-item "$current_selection" \
        --menu "$NAV_HINT_MENU" \
        "$dlg_h" "$dlg_w" "$list_height" \
        "${menu_items[@]}"
}

# Display a confirmation dialog showing the GPU-to-profile assignment
# table before applying changes.
#
# Returns:
#   0   if user confirms (Apply)
#   1   if user presses Back
#   255 if user presses ESC (caller should offer exit)
show_confirmation() {
    local summary=""
    local i

    summary+="  The following profiles will be applied:\n"
    summary+="\n"

    local non_mig=0
    local mig_instances=0

    for ((i = 0; i < GPU_COUNT; i++)); do
        local profile_idx="${GPU_SELECTIONS[$i]}"
        local profile_name="${PROFILE_NAMES[$profile_idx]}"

        # printf pads the GPU label to align the profile column.
        # %-8s = left-aligned, 8-character wide string field.
        summary+="$(printf "    %-8s %s" "GPU ${i}" "$profile_name")\n"

        # Tally device counts for the summary block below.
        if [[ "${PROFILE_MIG_ENABLED[$profile_idx]}" == "false" ]]; then
            # Non-MIG GPU = one full device
            (( non_mig += 1 ))
        else
            # Sum the instance counts from the comma-separated
            # "type:count" pairs in PROFILE_MIG_DEVICES[].
            local devices="${PROFILE_MIG_DEVICES[$profile_idx]}"
            if [[ -n "$devices" ]]; then
                local pair
                # IFS=',' splits on commas so each pair is "type:count"
                IFS=',' read -ra _dev_pairs <<< "$devices"
                for pair in "${_dev_pairs[@]}"; do
                    [[ -z "$pair" ]] && continue
                    # ${pair#*:} removes everything before the first colon
                    # (keeps the count portion)
                    (( mig_instances += ${pair#*:} ))
                done
            fi
        fi
    done

    local total_devices=$(( non_mig + mig_instances ))

    summary+="\n"
    summary+="  Device Summary:\n"
    # printf %-18s aligns the labels, %3d right-aligns the counts.
    summary+="$(printf "    %-18s : %3d" "Non-MIG devices" "$non_mig")\n"
    summary+="$(printf "    %-18s : %3d" "MIG devices" "$mig_instances")\n"
    summary+="$(printf "    %-18s : %3d" "Total devices" "$total_devices")\n"

    summary+="\n"
    summary+="  The node will be cordoned, reconfigured, and uncordoned automatically.\n"
    summary+="\n"
    summary+="  ${NAV_HINT}"

    # printf with %b interprets backslash escapes in the argument.
    local formatted
    formatted=$(printf "%b" "$summary")

    # Cap dialog dimensions to terminal size minus margin.
    # GPU_COUNT + 17 rows = GPU lines + header + device summary (5 lines)
    # + hint + borders.
    local dlg_h=$((GPU_COUNT + 17))
    local dlg_w=$((TERM_COLS - 8))

    (( dlg_h > TERM_LINES - 4 )) && dlg_h=$((TERM_LINES - 4))
    (( dlg_w > MAX_DLG_WIDTH )) && dlg_w=$MAX_DLG_WIDTH

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

# Show an exit confirmation dialog. Used whenever the user presses ESC
# on any screen to provide a consistent "exit from anywhere" experience.
#
# Returns:
#   0 if user confirms exit, non-zero if user chooses to go back
_confirm_exit() {
    whiptail --title " Exit " \
        --yes-button " Exit " --no-button " Back " \
        --yesno "\n  Exit without making changes?" 8 42
}

# Main TUI navigation loop implementing hub-and-spoke navigation.
# Runs the welcome screen, then enters the GPU hub where users can
# select GPUs to configure, apply changes, or exit.
#
# The hub uses whiptail exit codes to route actions:
#   rc=0   (Configure) = open profile picker for selected GPU
#   rc=1   (Apply)     = show confirmation screen
#   rc=255 (ESC)       = show exit confirmation
#
# ESC triggers an exit confirmation on every screen, so the user
# can always exit directly without navigating back to the hub first.
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

        # show_main_menu returns: 0=Select, 1=Apply, 255=ESC.
        # Use `|| rc=$?` instead of `|| true` to capture the actual
        # exit code. `|| true` would always set $? to 0 (the exit code
        # of `true`), masking the real return value from whiptail.
        local rc=0
        show_main_menu || rc=$?

        case $rc in
            0)
                # OK button (Select) — user selected a GPU.
                # Extract GPU index from "GPU N" tag.
                # ${TUI_RESULT#GPU } removes the "GPU " prefix, leaving just N.
                local gpu_idx="${TUI_RESULT#GPU }"

                # Run profile picker; handle its exit code.
                local picker_rc=0
                show_profile_picker "$gpu_idx" || picker_rc=$?

                if [[ $picker_rc -eq 0 && -n "$TUI_RESULT" ]]; then
                    # User selected a profile.
                    GPU_SELECTIONS[$gpu_idx]="$TUI_RESULT"
                elif [[ $picker_rc -eq 255 ]]; then
                    # ESC on profile picker — offer exit.
                    if _confirm_exit; then
                        return 1
                    fi
                fi
                # rc=1 (Back button) -> return to hub unchanged.
                ;;

            1)
                # Cancel button (Apply) — show confirmation.
                # show_confirmation returns: 0=Apply, 1=Back, 255=ESC.
                local confirm_rc=0
                show_confirmation || confirm_rc=$?

                if [[ $confirm_rc -eq 0 ]]; then
                    return 0
                elif [[ $confirm_rc -eq 255 ]]; then
                    # ESC on confirmation — offer exit.
                    if _confirm_exit; then
                        return 1
                    fi
                fi
                # rc=1 (Back button) -> return to hub.
                ;;

            *)
                # ESC (rc=255) or any other code — confirm exit.
                if _confirm_exit; then
                    return 1
                fi
                # User chose "Back" -> return to hub.
                ;;
        esac
    done
}
