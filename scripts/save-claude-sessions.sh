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

# Iterate panes with a CANONICAL address (session_group name if the session is grouped,
# else the session name). This collapses grouped-session clones — e.g., main, main-9,
# main-14, main-15, main-16 all mapping to the same underlying panes — to a single
# entry per unique pane_id, instead of storing N duplicates.
done < <(tmux list-panes -a -F '#{pane_pid}	#{pane_id}	#{pane_current_command}	#{?session_grouped,#{session_group},#{session_name}}:#{window_index}.#{pane_index}	#{pane_current_path}' 2>/dev/null \
    | awk -F'\t' '!seen[$2]++')

# Generate snapshot via python3 — skips writing if sessions haven't changed
python3 -c "
import json, sys, time, os

SNAPSHOTS_DIR = sys.argv[1]
RESURRECT_DIR = sys.argv[2]
MAX_SNAPSHOTS = int(sys.argv[3])
raw_entries = sys.argv[4:]

# Parse session entries from shell args
entries = []
for arg in raw_entries:
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
        if 'type' not in entry:
            entry['type'] = entry_type
        entries.append(entry)
    except json.JSONDecodeError:
        pass

# Compare against latest snapshot (ignoring timestamps)
def session_fingerprint(sessions):
    \"\"\"Canonical fingerprint of sessions, ignoring volatile fields.\"\"\"
    stable = []
    for s in sessions:
        key = {k: v for k, v in s.items() if k != 'timestamp'}
        stable.append(json.dumps(key, sort_keys=True))
    return sorted(stable)

latest_link = os.path.join(SNAPSHOTS_DIR, 'latest')
if os.path.exists(latest_link):
    try:
        with open(latest_link) as f:
            prev = json.load(f)
        if session_fingerprint(prev.get('sessions', [])) == session_fingerprint(entries):
            # No change — update timestamp in existing file and exit
            prev['timestamp'] = time.time()
            with open(latest_link, 'w') as f:
                json.dump(prev, f, indent=2)
            # Also update backward-compat copy
            compat = os.path.join(RESURRECT_DIR, 'claude-sessions.json')
            with open(compat, 'w') as f:
                json.dump(prev, f, indent=2)
            sys.exit(0)
    except (json.JSONDecodeError, KeyError, OSError):
        pass  # Corrupt or missing — write a fresh snapshot

# Build and write new snapshot
snapshot = {
    'version': 2,
    'timestamp': time.time(),
    'sessions': entries
}

timestamp = time.strftime('%Y%m%d-%H%M%S')
snapshot_file = os.path.join(SNAPSHOTS_DIR, f'snapshot-{timestamp}.json')
with open(snapshot_file, 'w') as f:
    json.dump(snapshot, f, indent=2)

# Update 'latest' symlink
latest = os.path.join(SNAPSHOTS_DIR, 'latest')
tmp_link = latest + '.tmp'
os.symlink(os.path.basename(snapshot_file), tmp_link)
os.rename(tmp_link, latest)

# Backward compatibility copy
compat = os.path.join(RESURRECT_DIR, 'claude-sessions.json')
with open(compat, 'w') as f:
    json.dump(snapshot, f, indent=2)

# Prune old snapshots
snaps = sorted(
    [f for f in os.listdir(SNAPSHOTS_DIR) if f.startswith('snapshot-') and f.endswith('.json')],
    reverse=True
)
for old in snaps[MAX_SNAPSHOTS:]:
    os.remove(os.path.join(SNAPSHOTS_DIR, old))
" "$SNAPSHOTS_DIR" "$RESURRECT_DIR" "$MAX_SNAPSHOTS" "${sessions[@]+"${sessions[@]}"}"
