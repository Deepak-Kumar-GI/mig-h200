#!/bin/bash
# ============================================================================
# TUI Debug Script - Systematic diagnosis of whiptail issues
# ============================================================================
# Runs 6 progressive tests to isolate exactly which environment factor
# breaks whiptail inside mig-configure.sh.
#
# Run: ./test-tui-debug.sh   (on the DGX cluster)
# Results written to /tmp/tui-debug.log AND shown on screen.
# ============================================================================

LOG="/tmp/tui-debug.log"
echo "=== TUI Debug $(date) ===" > "$LOG"

pass() { echo "  PASS: $1" | tee -a "$LOG"; }
fail() { echo "  FAIL: $1 (rc=$2)" | tee -a "$LOG"; }
info() { echo "  INFO: $1" | tee -a "$LOG"; }

# -------------------------------------------------------
echo "" | tee -a "$LOG"
echo "=== Environment ===" | tee -a "$LOG"
echo "Terminal: $(tput cols)x$(tput lines)" | tee -a "$LOG"
echo "Bash: ${BASH_VERSION}" | tee -a "$LOG"
whiptail --version >> "$LOG" 2>&1 || echo "no --version" >> "$LOG"
echo "FD state: $(ls -la /proc/$$/fd 2>/dev/null | head -6)" >> "$LOG"

# -------------------------------------------------------
echo "" | tee -a "$LOG"
echo "=== Test 1: Plain whiptail menu (no set -e, no colors) ===" | tee -a "$LOG"
result=$(whiptail --title "Test 1" --menu "Pick one" 15 50 3 \
    "A" "Alpha" "B" "Bravo" "C" "Charlie" \
    3>&1 1>&2 2>&3) ; rc=$?
if [[ $rc -eq 0 ]]; then pass "result='$result'"; else fail "whiptail returned" "$rc"; fi

# -------------------------------------------------------
echo "" | tee -a "$LOG"
echo "=== Test 2: With set -euo pipefail + ERR trap ===" | tee -a "$LOG"
(
    set -euo pipefail
    trap 'echo "ERR trap fired at line $LINENO" >> /tmp/tui-debug.log' ERR

    result=$(whiptail --title "Test 2: set -euo" --menu "Pick one" 15 50 3 \
        "A" "Alpha" "B" "Bravo" "C" "Charlie" \
        3>&1 1>&2 2>&3) || true
    rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "  PASS: result='$result'" | tee -a /tmp/tui-debug.log
    else
        echo "  FAIL: whiptail returned rc=$rc" | tee -a /tmp/tui-debug.log
    fi
)

# -------------------------------------------------------
echo "" | tee -a "$LOG"
echo "=== Test 3: With NEWT_COLORS theme ===" | tee -a "$LOG"
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
result=$(whiptail --title "Test 3: NEWT_COLORS" --menu "Pick one" 15 50 3 \
    "A" "Alpha" "B" "Bravo" "C" "Charlie" \
    3>&1 1>&2 2>&3) ; rc=$?
if [[ $rc -eq 0 ]]; then pass "result='$result'"; else fail "whiptail returned" "$rc"; fi
unset NEWT_COLORS

# -------------------------------------------------------
echo "" | tee -a "$LOG"
echo "=== Test 4: Whiptail --yesno (same as welcome screen) ===" | tee -a "$LOG"
echo "  [Press Continue or Exit when the dialog shows]" | tee -a "$LOG"
whiptail --title "Test 4: yesno" \
    --yes-button "Continue" --no-button "Exit" \
    --yesno "Welcome test\n\nGPU Model: NVIDIA H200\nGPU Count: 8\n\nPress TAB to switch buttons." \
    12 50
rc=$?
if [[ $rc -eq 0 ]]; then pass "User pressed Continue (rc=0)"; else info "User pressed Exit (rc=$rc)"; fi

# -------------------------------------------------------
echo "" | tee -a "$LOG"
echo "=== Test 5: 11-item menu (same size as GPU menu) ===" | tee -a "$LOG"
result=$(whiptail --title "Test 5: 11 items" \
    --ok-button "Select" --cancel-button "Exit" \
    --menu "Arrows=navigate  TAB=buttons  ENTER=confirm" \
    19 64 11 \
    "GPU-0" "MIG Disabled (Full GPU)" \
    "GPU-1" "MIG Disabled (Full GPU)" \
    "GPU-2" "MIG Disabled (Full GPU)" \
    "GPU-3" "MIG Disabled (Full GPU)" \
    "GPU-4" "MIG Disabled (Full GPU)" \
    "GPU-5" "MIG Disabled (Full GPU)" \
    "GPU-6" "MIG Disabled (Full GPU)" \
    "GPU-7" "MIG Disabled (Full GPU)" \
    "---"   "--------------------------------" \
    "APPLY" ">> Apply configuration to cluster" \
    "QUIT"  ">> Exit without changes" \
    3>&1 1>&2 2>&3) ; rc=$?
if [[ $rc -eq 0 ]]; then pass "result='$result'"; else fail "whiptail returned" "$rc"; fi

# -------------------------------------------------------
echo "" | tee -a "$LOG"
echo "=== Test 6: Full environment (sources + set -euo + template + TUI) ===" | tee -a "$LOG"
echo "  [This replicates mig-configure.sh exactly]" | tee -a "$LOG"
(
    set -euo pipefail
    trap 'echo "  ERR trap fired at ${BASH_SOURCE}:${LINENO}" | tee -a /tmp/tui-debug.log' ERR

    cd "$(dirname "$0")"
    source config.sh
    source common/template-parser.sh
    source common/tui.sh

    # Create a temp log file for the logging module
    _test_log_dir=$(mktemp -d)
    LOG_FILE="${_test_log_dir}/test.log"
    source common/logging.sh

    echo "  Loading template..." | tee -a /tmp/tui-debug.log
    if ! load_template "$MIG_TEMPLATE_FILE"; then
        echo "  FAIL: template load failed" | tee -a /tmp/tui-debug.log
        exit 1
    fi
    echo "  Template loaded: ${PROFILE_COUNT} profiles, ${GPU_COUNT} GPUs" | tee -a /tmp/tui-debug.log

    echo "  Checking TUI deps..." | tee -a /tmp/tui-debug.log
    if ! check_tui_deps; then
        echo "  FAIL: TUI deps check failed" | tee -a /tmp/tui-debug.log
        exit 1
    fi
    echo "  Terminal: ${TERM_COLS}x${TERM_LINES}" | tee -a /tmp/tui-debug.log

    echo "  Running TUI (same as mig-configure.sh)..." | tee -a /tmp/tui-debug.log
    if ! run_tui; then
        echo "  INFO: User cancelled TUI (rc=$?)" | tee -a /tmp/tui-debug.log
    else
        echo "  PASS: TUI completed. Selections:" | tee -a /tmp/tui-debug.log
        for ((i = 0; i < GPU_COUNT; i++)); do
            pidx="${GPU_SELECTIONS[$i]}"
            echo "    GPU-${i} -> ${PROFILE_NAMES[$pidx]}" | tee -a /tmp/tui-debug.log
        done
    fi

    rm -rf "$_test_log_dir"
)

echo "" | tee -a "$LOG"
echo "=== Done ===" | tee -a "$LOG"
echo "Full log: $LOG"
cat "$LOG"
