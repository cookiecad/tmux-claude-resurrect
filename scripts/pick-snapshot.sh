#!/usr/bin/env bash
# Interactive snapshot picker for Claude session restore.
# Launched via tmux popup (prefix + R by default).

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
        # Format: 20260311-194359 → 2026-03-11 19:43:59
        if len(date_part) == 15:
            display_date = f'{date_part[0:4]}-{date_part[4:6]}-{date_part[6:8]} {date_part[9:11]}:{date_part[11:13]}:{date_part[13:15]}'
        else:
            display_date = date_part

        if count == 0:
            breakdown = '(empty)'
        else:
            names = Counter()
            for s in sessions:
                addr = s.get('structural_address', '?:?')
                name = addr.split(':')[0]
                names[name] += 1
            breakdown = ', '.join(f'{n}({c})' for n, c in names.most_common())

        print(f'{display_date}  │ {count:2d} sessions │ {breakdown}\t{f}')
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
    # fzf mode with preview
    selected=$(echo "$entries" | fzf \
        --delimiter=$'\t' \
        --with-nth=1 \
        --header="Select a Claude session snapshot to restore (ESC to cancel)" \
        --preview="bash ${PREVIEW_SCRIPT} {2}" \
        --preview-window=right:50%:wrap \
        --reverse \
        --no-mouse \
    ) || exit 0

    chosen_file=$(echo "$selected" | cut -d$'\t' -f2)
else
    # Fallback: numbered menu
    echo "Claude Session Snapshots"
    echo "========================"
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
echo "Restoring from: $(basename "$chosen_file")"

# Count sessions for confirmation
session_count=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    print(len(json.load(f).get('sessions', [])))
" "$chosen_file")
echo "Resuming ${session_count} Claude session(s)..."

# Force auto-restore on (picker is explicit user intent)
tmux set-option -g @claude-resurrect-auto-restore "on"

# Run restore
bash "$RESTORE_SCRIPT" "$chosen_file"

echo "Done — Claude sessions are resuming in their panes."
sleep 2
