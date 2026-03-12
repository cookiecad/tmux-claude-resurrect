#!/usr/bin/env bash
# Restores Claude sessions from a snapshot.
# Called by tmux-resurrect post-restore hook (auto) or by the picker (manual).
# Usage: restore-claude-sessions.sh [snapshot-file]

set -euo pipefail

# Read tmux options
auto_restore=$(tmux show-option -gqv @claude-resurrect-auto-restore)
if [ "$auto_restore" = "off" ]; then
    exit 0
fi

restore_delay=$(tmux show-option -gqv @claude-resurrect-restore-delay)
restore_delay="${restore_delay:-2}"

RESURRECT_DIR="${HOME}/.tmux/resurrect"
SNAPSHOTS_DIR="${HOME}/.cache/tmux-claude-resurrect/snapshots"

snapshot_file="${1:-}"

if [ -z "$snapshot_file" ]; then
    # Find the most recent non-empty snapshot (skips post-OOM empty saves)
    snapshot_file=$(python3 -c "
import json, sys, glob, os

snapshots_dir = sys.argv[1]
resurrect_file = sys.argv[2]

# Primary: timestamped snapshots, newest first
candidates = sorted(glob.glob(os.path.join(snapshots_dir, 'snapshot-*.json')), reverse=True)

# Fallback: legacy locations
for fallback in [os.path.join(snapshots_dir, 'claude-sessions.json'), resurrect_file]:
    resolved = os.path.realpath(fallback)
    if os.path.isfile(resolved) and resolved not in candidates:
        candidates.append(resolved)

for path in candidates:
    try:
        with open(path) as f:
            data = json.load(f)
        if data.get('sessions') and len(data['sessions']) > 0:
            print(path)
            sys.exit(0)
    except (json.JSONDecodeError, IOError, KeyError):
        continue

sys.exit(1)
" "$SNAPSHOTS_DIR" "${RESURRECT_DIR}/claude-sessions.json" 2>/dev/null) || exit 0
fi

if [ -z "$snapshot_file" ] || [ ! -f "$snapshot_file" ]; then
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
    project_root = s.get('project_root', '') or s.get('cwd', '')
    print('{}\t{}\t{}\t{}\t{}\t{}'.format(
        s.get('session_id', ''),
        s.get('structural_address', ''),
        s.get('cwd', ''),
        s.get('transcript_path', ''),
        s.get('permission_mode', 'default'),
        project_root
    ))
" "$snapshot_file" | while IFS=$'\t' read -r session_id address cwd transcript_path permission_mode project_root; do
    # Use project_root for cd (correct project resolution), fall back to cwd
    restore_dir="${project_root:-$cwd}"

    # Verify pane exists at this structural address
    if ! tmux display-message -t "$address" -p '#{pane_id}' >/dev/null 2>&1; then
        continue
    fi

    # Skip if Claude is already running in this pane
    pane_cmd=$(tmux display-message -t "$address" -p '#{pane_current_command}')
    if [ "$pane_cmd" = "claude" ]; then
        continue
    fi
    pane_pid=$(tmux display-message -t "$address" -p '#{pane_pid}')
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

    # cd to project_root if the pane isn't already there
    pane_cwd=$(tmux display-message -t "$address" -p '#{pane_current_path}')
    if [ "$pane_cwd" != "$restore_dir" ] && [ -n "$restore_dir" ] && [ -d "$restore_dir" ]; then
        tmux send-keys -t "$address" "cd $(printf '%q' "$restore_dir")" C-m
        sleep 0.3
    fi

    # Send the resume command
    tmux send-keys -t "$address" "$cmd" C-m
done
