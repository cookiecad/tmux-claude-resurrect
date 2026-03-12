#!/usr/bin/env bash
# tmux-resurrect post-save hook
# Creates timestamped snapshots of Claude and Codex sessions with live structural addresses.

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
while IFS=$'\t' read -r pane_pid pane_id pane_cmd live_address pane_cwd; do
    pane_number="${pane_id#%}"

    # --- Detect Claude ---
    is_claude=false
    if [ "$pane_cmd" = "claude" ]; then
        is_claude=true
    elif pgrep -P "$pane_pid" -x "claude" >/dev/null 2>&1; then
        is_claude=true
    fi

    if [ "$is_claude" = true ]; then
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
        sessions+=("${pane_data}|LIVE_ADDR:${live_address}|TYPE:claude")
        continue
    fi

    # --- Detect Codex ---
    # Codex runs as: node /usr/local/bin/codex ... OR directly as codex
    is_codex=false
    codex_pid=""
    if [ "$pane_cmd" = "codex" ]; then
        is_codex=true
        codex_pid="$pane_pid"
    else
        # Check children for codex (often: zsh -> node -> codex, or zsh -> codex)
        codex_pid=$(pgrep -P "$pane_pid" -x "codex" 2>/dev/null | head -1) || true
        if [ -n "$codex_pid" ]; then
            is_codex=true
        else
            # Codex may run as 'node /usr/local/bin/codex'
            for child_pid in $(pgrep -P "$pane_pid" 2>/dev/null); do
                child_cmd=$(tr '\0' ' ' < "/proc/$child_pid/cmdline" 2>/dev/null) || continue
                if [[ "$child_cmd" == *codex* ]]; then
                    is_codex=true
                    codex_pid="$child_pid"
                    break
                fi
            done
        fi
    fi

    if [ "$is_codex" = true ] && [ -n "$codex_pid" ]; then
        # Capture the full command line for replay
        codex_cmdline=$(tr '\0' ' ' < "/proc/$codex_pid/cmdline" 2>/dev/null) || continue
        # Strip 'node /path/to/codex' prefix if present, normalize to just 'codex ...'
        codex_cmd=$(echo "$codex_cmdline" | sed 's|^node [^ ]*/codex|codex|')

        # Try to find codex session ID from /proc/PID/fd (look for open session files)
        codex_session_id=""
        for fd in /proc/"$codex_pid"/fd/*; do
            target=$(readlink "$fd" 2>/dev/null) || continue
            if [[ "$target" == */.codex/sessions/* ]]; then
                # Extract session ID from path: .codex/sessions/SESSION_ID/...
                codex_session_id=$(echo "$target" | sed -n 's|.*/\.codex/sessions/\([^/]*\)/.*|\1|p')
                break
            fi
        done

        # Build codex entry as JSON
        codex_data=$(python3 -c "
import json, sys, time
data = {
    'type': 'codex',
    'structural_address': '',
    'cwd': sys.argv[1],
    'command': sys.argv[2],
    'session_id': sys.argv[3],
    'pane_id': sys.argv[4],
    'timestamp': time.time()
}
print(json.dumps(data))
" "$pane_cwd" "$codex_cmd" "${codex_session_id:-}" "$pane_number")

        sessions+=("${codex_data}|LIVE_ADDR:${live_address}|TYPE:codex")
    fi

done < <(tmux list-panes -a -F '#{pane_pid}	#{pane_id}	#{pane_current_command}	#{session_name}:#{window_index}.#{pane_index}	#{pane_current_path}' 2>/dev/null)

# Generate timestamped snapshot
timestamp=$(date +%Y%m%d-%H%M%S)
snapshot_file="${SNAPSHOTS_DIR}/snapshot-${timestamp}.json"

python3 -c "
import json, sys, time

entries = []
for arg in sys.argv[1:]:
    # Split off metadata appended by the shell loop
    parts = arg
    live_addr = None
    entry_type = 'claude'

    if '|TYPE:' in parts:
        parts, entry_type = parts.rsplit('|TYPE:', 1)
    if '|LIVE_ADDR:' in parts:
        parts, live_addr = parts.rsplit('|LIVE_ADDR:', 1)

    try:
        entry = json.loads(parts)
        if live_addr:
            entry['structural_address'] = live_addr
        # Ensure type field exists
        if 'type' not in entry:
            entry['type'] = entry_type
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
