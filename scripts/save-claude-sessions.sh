#!/usr/bin/env bash
# tmux-resurrect post-save hook
# Snapshots all active Claude pane mappings into a consolidated file.

set -euo pipefail

CACHE_DIR="${HOME}/.cache/tmux-claude-resurrect"
PANES_DIR="${CACHE_DIR}/panes"
SNAPSHOTS_DIR="${CACHE_DIR}/snapshots"
RESURRECT_DIR="${HOME}/.tmux/resurrect"

mkdir -p "$SNAPSHOTS_DIR" "$RESURRECT_DIR"

# Max age for cached pane files (7 days in seconds)
MAX_AGE=$((7 * 24 * 60 * 60))
now=$(date +%s)

sessions=()

# Iterate all tmux panes
while IFS= read -r line; do
    pane_pid=$(echo "$line" | cut -d' ' -f1)
    pane_id=$(echo "$line" | cut -d' ' -f2)
    pane_cmd=$(echo "$line" | cut -d' ' -f3)
    pane_number="${pane_id#%}"

    # Detect Claude: either as the direct pane command, or as a child process
    # Note: pane_current_command shows the foreground process name (works even
    # if claude is deep in the process tree, e.g. zsh->chezmoi->zsh->claude)
    is_claude=false
    if [ "$pane_cmd" = "claude" ]; then
        is_claude=true
    elif pgrep -P "$pane_pid" -x "claude" >/dev/null 2>&1; then
        is_claude=true
    fi
    if [ "$is_claude" = false ]; then
        continue
    fi

    # Check for cached pane mapping
    pane_file="${PANES_DIR}/${pane_number}.json"
    if [ ! -f "$pane_file" ]; then
        echo "tmux-claude-resurrect: WARNING: Claude in pane %${pane_number} has no cache file (SessionStart hook may not have fired)" >&2
        continue
    fi

    # Skip stale files (>7 days old)
    file_mtime=$(stat -c '%Y' "$pane_file" 2>/dev/null || stat -f '%m' "$pane_file" 2>/dev/null) || continue
    age=$((now - file_mtime))
    if [ "$age" -gt "$MAX_AGE" ]; then
        continue
    fi

    # Read the pane mapping
    pane_data=$(cat "$pane_file")
    sessions+=("$pane_data")
done < <(tmux list-panes -a -F '#{pane_pid} #{pane_id} #{pane_current_command}' 2>/dev/null)

# Build consolidated snapshot
snapshot_file="${SNAPSHOTS_DIR}/claude-sessions.json"

python3 -c "
import json, sys, time

entries = []
for arg in sys.argv[1:]:
    try:
        entries.append(json.loads(arg))
    except json.JSONDecodeError:
        pass

snapshot = {
    'version': 1,
    'timestamp': time.time(),
    'sessions': entries
}
print(json.dumps(snapshot, indent=2))
" "${sessions[@]+"${sessions[@]}"}" > "$snapshot_file"

# Also copy to resurrect dir so it travels with the resurrect state
cp "$snapshot_file" "${RESURRECT_DIR}/claude-sessions.json"
