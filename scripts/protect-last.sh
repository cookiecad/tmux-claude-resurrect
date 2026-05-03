#!/usr/bin/env bash
# Post-save guard: prevent tmux-resurrect's `last` symlink from regressing to
# an impoverished state after a tmux crash or restart.
#
# The failure mode this prevents:
#   1. User has N tmux sessions with Claude panes. tmux-resurrect saves them,
#      `last` points to that good file.
#   2. tmux crashes / is killed / OOMs. User restarts tmux (with few sessions).
#   3. tmux-continuum's 5-minute auto-save fires and writes a tiny new file;
#      tmux-resurrect's save.sh updates `last` to point to the tiny file.
#   4. When the user tries `prefix + Ctrl-R`, tmux-resurrect restores from
#      `last` and recovers nothing — the good state is orphaned.
#
# This hook re-points `last` at the recent high-water-mark (HWM) file whenever
# the freshly-saved state is dramatically smaller than recent history. The
# shrunken save file itself is retained — we only refuse to advance `last`.
# After several consecutive small saves we accept the new state as the new
# normal (real user teardowns shouldn't be fought forever).

set -euo pipefail

RESURRECT_DIR="${HOME}/.tmux/resurrect"
STATE_DIR="${HOME}/.cache/tmux-claude-resurrect"
COUNTER_FILE="${STATE_DIR}/protect-consec-small"
LOG_FILE="${STATE_DIR}/protect-log"

CONSEC_SMALL_LIMIT=5             # after this many in a row, trust the small state
HWM_WINDOW_COUNT=50              # consider the N most recent saves as HWM sources
HWM_MAX_AGE_SECONDS=$((7*86400)) # …and only if the HWM file itself is within a week
MIN_HWM_PANES=4                  # below this, don't bother protecting

# Why 7 days: the original 4-hour window meant any gap in saves longer than
# 4 hours would orphan the HWM, leaving no anchor. Apr 27 → Apr 30, 2026:
# saves silently stopped (systemd cgroup-kill bug), `last` aged out of every
# anchor's window, and recovery restored the impoverished pre-failure state.
# A week's window covers most outages without preventing legitimate scale-down.
# HWM_WINDOW_COUNT scales with this — at one save every 5min, 7 days would
# be 2000+ files; we cap at 50 to bound the scan cost.

mkdir -p "$STATE_DIR"

last_link="${RESURRECT_DIR}/last"
[ -L "$last_link" ] || exit 0
current_file="$(readlink -f "$last_link" 2>/dev/null)" || exit 0
[ -f "$current_file" ] || exit 0

count_panes() {
    awk -F'\t' '$1=="pane"' "$1" 2>/dev/null | wc -l
}

current_panes=$(count_panes "$current_file")

# HWM is taken over the N most recent saves only (excluding the current one),
# and each candidate must be within HWM_MAX_AGE_SECONDS. A save from days ago
# is *not* a legitimate HWM — the user has had time to reshape their setup.
now=$(date +%s)
hwm_panes=0
hwm_file=""
while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ "$path" = "$current_file" ] && continue
    mtime=$(stat -c '%Y' "$path" 2>/dev/null || echo 0)
    age=$((now - mtime))
    [ "$age" -gt "$HWM_MAX_AGE_SECONDS" ] && continue
    pc=$(count_panes "$path")
    if [ "$pc" -gt "$hwm_panes" ]; then
        hwm_panes="$pc"
        hwm_file="$path"
    fi
done < <(find "$RESURRECT_DIR" -maxdepth 1 -name 'tmux_resurrect_*.txt' -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -n "$HWM_WINDOW_COUNT" | cut -d' ' -f2-)

consec_small=0
[ -f "$COUNTER_FILE" ] && consec_small=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
[[ "$consec_small" =~ ^[0-9]+$ ]] || consec_small=0

log() {
    printf '%s %s current=%d hwm=%d consec=%d file=%s\n' \
        "$(date -Iseconds)" "$1" "$current_panes" "$hwm_panes" "$consec_small" \
        "$(basename "$current_file")" >> "$LOG_FILE"
}

if [ "$hwm_panes" -lt "$MIN_HWM_PANES" ] || [ -z "$hwm_file" ]; then
    # No meaningful HWM — trust whatever was saved
    echo 0 > "$COUNTER_FILE"
    exit 0
fi

threshold=$((hwm_panes / 2))
if [ "$current_panes" -ge "$threshold" ]; then
    # Current save is within tolerance; HWM advances naturally
    echo 0 > "$COUNTER_FILE"
    exit 0
fi

# Current save is a significant regression
consec_small=$((consec_small + 1))
echo "$consec_small" > "$COUNTER_FILE"

if [ "$consec_small" -lt "$CONSEC_SMALL_LIMIT" ]; then
    # Protect: revert `last` to the HWM file
    ln -sfn "$(basename "$hwm_file")" "$last_link"
    log "PROTECTED"
else
    # New normal — accept the small state and reset the counter
    echo 0 > "$COUNTER_FILE"
    log "ACCEPTED"
fi
