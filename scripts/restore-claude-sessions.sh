#!/usr/bin/env bash
# tmux-resurrect post-restore hook
# Reads the saved snapshot and sends `claude --resume` to each pane.

set -euo pipefail

# Read tmux options
auto_restore=$(tmux show-option -gqv @claude-resurrect-auto-restore)
if [ "$auto_restore" = "off" ]; then
    exit 0
fi

restore_delay=$(tmux show-option -gqv @claude-resurrect-restore-delay)
restore_delay="${restore_delay:-2}"

# Locate snapshot — prefer resurrect dir, fall back to cache
RESURRECT_DIR="${HOME}/.tmux/resurrect"
CACHE_DIR="${HOME}/.cache/tmux-claude-resurrect/snapshots"

snapshot_file=""
if [ -f "${RESURRECT_DIR}/claude-sessions.json" ]; then
    snapshot_file="${RESURRECT_DIR}/claude-sessions.json"
elif [ -f "${CACHE_DIR}/claude-sessions.json" ]; then
    snapshot_file="${CACHE_DIR}/claude-sessions.json"
fi

if [ -z "$snapshot_file" ]; then
    exit 0
fi

# Wait for shells to initialize
sleep "$restore_delay"

# Parse snapshot and restore each session
python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    snapshot = json.load(f)
for s in snapshot.get('sessions', []):
    print('{session_id}\t{structural_address}\t{cwd}\t{transcript_path}\t{permission_mode}'.format(**s))
" "$snapshot_file" | while IFS=$'\t' read -r session_id address cwd transcript_path permission_mode; do
    # Verify pane exists
    if ! tmux display-message -t "$address" -p '#{pane_id}' >/dev/null 2>&1; then
        continue
    fi

    # Skip if Claude is already running in this pane
    pane_pid=$(tmux display-message -t "$address" -p '#{pane_pid}')
    pane_cmd=$(tmux display-message -t "$address" -p '#{pane_current_command}')
    if [ "$pane_cmd" = "claude" ]; then
        continue
    fi
    if pgrep -P "$pane_pid" -x "claude" >/dev/null 2>&1; then
        continue
    fi

    # Verify transcript file still exists
    if [ -n "$transcript_path" ] && [ ! -f "$transcript_path" ]; then
        continue
    fi

    # Build resume command
    cmd="claude --resume $session_id"

    if [ "$permission_mode" = "bypassPermissions" ]; then
        cmd="$cmd --dangerously-skip-permissions"
    elif [ -n "$permission_mode" ] && [ "$permission_mode" != "default" ]; then
        cmd="$cmd --permission-mode $permission_mode"
    fi

    # Check if pane cwd matches; cd first if not
    pane_cwd=$(tmux display-message -t "$address" -p '#{pane_current_path}')
    if [ "$pane_cwd" != "$cwd" ] && [ -n "$cwd" ]; then
        tmux send-keys -t "$address" "cd $(printf '%q' "$cwd")" C-m
        sleep 0.3
    fi

    # Send the resume command
    tmux send-keys -t "$address" "$cmd" C-m
done
