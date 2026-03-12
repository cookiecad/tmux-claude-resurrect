#!/usr/bin/env bash
# tmux-resurrect post-save hook
# Creates timestamped Claude session snapshots with live structural addresses.

set -euo pipefail

CACHE_DIR="${HOME}/.cache/tmux-claude-resurrect"
PANES_DIR="${CACHE_DIR}/panes"
SNAPSHOTS_DIR="${CACHE_DIR}/snapshots"
RESURRECT_DIR="${HOME}/.tmux/resurrect"
MAX_SNAPSHOTS=100

mkdir -p "$SNAPSHOTS_DIR" "$RESURRECT_DIR"

MAX_AGE=$((7 * 24 * 60 * 60))
now=$(date +%s)

sessions=()

# Iterate all tmux panes — capture live structural address alongside pane metadata.
# Using tab delimiter in tmux format string.
while IFS=$'\t' read -r pane_pid pane_id pane_cmd live_address; do
    pane_number="${pane_id#%}"

    # Detect Claude: either as the direct pane command, or as a child process
    is_claude=false
    if [ "$pane_cmd" = "claude" ]; then
        is_claude=true
    elif pgrep -P "$pane_pid" -x "claude" >/dev/null 2>&1; then
        is_claude=true
    fi
    if [ "$is_claude" = false ]; then
        continue
    fi

    # Check for cached pane mapping (written by SessionStart hook)
    pane_file="${PANES_DIR}/${pane_number}.json"
    if [ ! -f "$pane_file" ]; then
        echo "tmux-claude-resurrect: WARNING: Claude in pane %${pane_number} has no cache file" >&2
        continue
    fi

    # Skip stale files (>7 days old)
    file_mtime=$(stat -c '%Y' "$pane_file" 2>/dev/null || stat -f '%m' "$pane_file" 2>/dev/null) || continue
    age=$((now - file_mtime))
    if [ "$age" -gt "$MAX_AGE" ]; then
        continue
    fi

    # Read cached data and pair with the live structural address
    pane_data=$(cat "$pane_file")
    sessions+=("${pane_data}|LIVE_ADDR:${live_address}")
done < <(tmux list-panes -a -F '#{pane_pid}	#{pane_id}	#{pane_current_command}	#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)

# Generate timestamped snapshot
timestamp=$(date +%Y%m%d-%H%M%S)
snapshot_file="${SNAPSHOTS_DIR}/snapshot-${timestamp}.json"

python3 -c "
import json, sys, time

entries = []
for arg in sys.argv[1:]:
    # Split off live address appended by the shell loop
    if '|LIVE_ADDR:' in arg:
        json_part, live_addr = arg.rsplit('|LIVE_ADDR:', 1)
    else:
        json_part = arg
        live_addr = None
    try:
        entry = json.loads(json_part)
        if live_addr:
            entry['structural_address'] = live_addr
        entries.append(entry)
    except json.JSONDecodeError:
        pass

snapshot = {
    'version': 2,
    'timestamp': time.time(),
    'sessions': entries
}
print(json.dumps(snapshot, indent=2))
" "${sessions[@]+"${sessions[@]}"}" > "$snapshot_file"

# Update 'latest' symlink (use basename so the link is relative)
ln -sf "$(basename "$snapshot_file")" "${SNAPSHOTS_DIR}/latest"

# Copy to resurrect dir for backward compatibility
cp "$snapshot_file" "${RESURRECT_DIR}/claude-sessions.json"

# Prune: keep last MAX_SNAPSHOTS, delete older ones
ls -1t "${SNAPSHOTS_DIR}"/snapshot-*.json 2>/dev/null | tail -n +$((MAX_SNAPSHOTS + 1)) | xargs -r rm -f
