#!/bin/bash
# Quick diagnostic — tests 3 different whiptail capture methods.
# Run: ./test-tui.sh   and check /tmp/tui-test.log after.

LOG="/tmp/tui-test.log"
echo "=== TUI test $(date) ===" > "$LOG"

echo "--- whiptail version ---" >> "$LOG"
whiptail --version >> "$LOG" 2>&1 || echo "no --version flag" >> "$LOG"
dpkg -l | grep -E 'whiptail|newt|dialog' >> "$LOG" 2>&1 || true
echo "" >> "$LOG"

# Method 1: stderr → temp file  (current approach)
echo "=== Method 1: stderr to tmpfile ===" >> "$LOG"
tmpfile=$(mktemp)
whiptail --menu "Method 1: stderr to tmpfile" 15 50 3 \
    "A" "Alpha" "B" "Bravo" "C" "Charlie" \
    2>"$tmpfile" </dev/tty >/dev/tty
rc=$?
echo "rc=$rc  result='$(cat "$tmpfile")'" >> "$LOG"
rm -f "$tmpfile"

# Method 2: fd swap inside $()
echo "=== Method 2: fd swap in command sub ===" >> "$LOG"
result=$(whiptail --menu "Method 2: fd swap" 15 50 3 \
    "A" "Alpha" "B" "Bravo" "C" "Charlie" \
    3>&1 1>&2 2>&3) </dev/tty
rc=$?
echo "rc=$rc  result='$result'" >> "$LOG"

# Method 3: fd swap with explicit /dev/tty
echo "=== Method 3: fd swap + /dev/tty ===" >> "$LOG"
result=$(whiptail --menu "Method 3: fd swap + /dev/tty" 15 50 3 \
    "A" "Alpha" "B" "Bravo" "C" "Charlie" \
    </dev/tty 3>&1 1>/dev/tty 2>&3)
rc=$?
echo "rc=$rc  result='$result'" >> "$LOG"

echo "" >> "$LOG"
echo "=== Done ===" >> "$LOG"

echo "Test complete. Results in: $LOG"
cat "$LOG"
