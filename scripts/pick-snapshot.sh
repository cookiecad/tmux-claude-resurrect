#!/usr/bin/env bash
# Interactive snapshot picker for Claude/Codex session restore.
# Launched via tmux popup (prefix + R by default).
# Automatically triggers tmux-resurrect restore if windows/panes are missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOTS_DIR="${HOME}/.cache/tmux-claude-resurrect/snapshots"
RESTORE_SCRIPT="${SCRIPT_DIR}/restore-claude-sessions.sh"
PREVIEW_SCRIPT="${SCRIPT_DIR}/preview-snapshot.sh"

# Build list: one line per snapshot, tab-delimited: display | filepath
entries=$(python3 -c "
import json, glob, os, sys
from collections import Counter

snapshots_dir = sys.argv[1]
files = sorted(glob.glob(os.path.join(snapshots_dir, 'snapshot-*.json')), reverse=True)

for f in files:
    try:
        with open(f) as fh:
            data = json.load(fh)
        sessions = data.get('sessions', [])
        count = len(sessions)

        # Extract date from filename: snapshot-YYYYMMDD-HHMMSS.json
        fname = os.path.basename(f)
        date_part = fname.replace('snapshot-', '').replace('.json', '')
        if len(date_part) == 15:
            display_date = f'{date_part[0:4]}-{date_part[4:6]}-{date_part[6:8]} {date_part[9:11]}:{date_part[11:13]}:{date_part[13:15]}'
        else:
            display_date = date_part

        if count == 0:
            breakdown = '(empty)'
        else:
            by_type = Counter()
            by_session = Counter()
            for s in sessions:
                by_type[s.get('type', 'claude')] += 1
                addr = s.get('structural_address', '?:?')
                by_session[addr.split(':')[0]] += 1
            type_info = ' '.join(f'{t}:{c}' for t, c in by_type.most_common())
            breakdown = f'[{type_info}] ' + ', '.join(f'{n}({c})' for n, c in by_session.most_common())

        print(f'{display_date}  | {count:2d} sessions | {breakdown}\t{f}')
    except Exception:
        pass
" "$SNAPSHOTS_DIR")

if [ -z "$entries" ]; then
    echo "No snapshots found in ${SNAPSHOTS_DIR}"
    echo "Snapshots are created when tmux-resurrect saves (prefix + Ctrl-S)."
    read -r -p "Press Enter to exit..."
    exit 1
fi

if command -v fzf >/dev/null 2>&1; then
    selected=$(echo "$entries" | fzf \
        --delimiter=$'\t' \
        --with-nth=1 \
        --header="Select a snapshot to restore (ESC to cancel)" \
        --preview="bash ${PREVIEW_SCRIPT} {2}" \
        --preview-window=right:50%:wrap \
        --reverse \
        --no-mouse \
    ) || exit 0

    chosen_file=$(echo "$selected" | cut -d$'\t' -f2)
else
    echo "Session Snapshots"
    echo "================="
    echo ""
    i=1
    declare -a files_arr
    while IFS=$'\t' read -r display filepath; do
        printf "  %3d) %s\n" "$i" "$display"
        files_arr[$i]="$filepath"
        ((i++))
    done <<< "$entries"
    echo ""
    read -r -p "Enter number (or 'q' to cancel): " choice
    [[ "$choice" == "q" || -z "$choice" ]] && exit 0
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$i" ]; then
        echo "Invalid selection."
        exit 1
    fi
    chosen_file="${files_arr[$choice]}"
fi

if [ -z "${chosen_file:-}" ] || [ ! -f "$chosen_file" ]; then
    echo "Snapshot file not found."
    exit 1
fi

echo ""

# --- Check if tmux-resurrect restore is needed ---
# Compare sessions in the snapshot vs what currently exists in tmux
needs_resurrect=$(python3 -c "
import json, sys, subprocess

with open(sys.argv[1]) as f:
    data = json.load(f)

# Get session names needed by the snapshot
needed = set()
for s in data.get('sessions', []):
    addr = s.get('structural_address', '')
    if ':' in addr:
        needed.add(addr.split(':')[0])

# Get existing tmux sessions
result = subprocess.run(['tmux', 'list-sessions', '-F', '#{session_name}'],
                        capture_output=True, text=True)
existing = set(result.stdout.strip().split('\n')) if result.stdout.strip() else set()

missing = needed - existing
if missing:
    print(' '.join(sorted(missing)))
" "$chosen_file" 2>/dev/null) || true

restore_flags=""
if [ -n "$needs_resurrect" ]; then
    echo "Missing tmux sessions: $needs_resurrect"
    echo "Will run tmux-resurrect to create windows/panes first."
    echo ""
    restore_flags="--with-resurrect"
fi

# Count sessions for display
session_info=$(python3 -c "
import json, sys
from collections import Counter
with open(sys.argv[1]) as f:
    data = json.load(f)
sessions = data.get('sessions', [])
by_type = Counter(s.get('type', 'claude') for s in sessions)
parts = []
for t, c in by_type.most_common():
    parts.append(f'{c} {t}')
print(', '.join(parts))
" "$chosen_file")

echo "Restoring from: $(basename "$chosen_file")"
echo "Sessions: ${session_info}"
echo ""

# Force auto-restore on (picker is explicit user intent)
tmux set-option -g @claude-resurrect-auto-restore "on"

# Run restore (optionally with resurrect first)
bash "$RESTORE_SCRIPT" $restore_flags "$chosen_file"

echo "Done — sessions are resuming in their panes."
sleep 2
