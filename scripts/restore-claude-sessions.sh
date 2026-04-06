#!/usr/bin/env bash
# Restores Claude and Codex sessions from a snapshot.
# Called by tmux-resurrect post-restore hook (auto) or by the picker (manual).
#
# Strategy:
#   1. Read the latest non-empty snapshot.
#   2. Ensure every saved structural_address exists: create missing sessions,
#      windows, and pane splits from the tmux-resurrect state file. This makes
#      us robust to tmux-resurrect failing to restore multi-pane layouts.
#   3. For each snapshot entry, use `tmux respawn-pane -k` to atomically replace
#      the pane's default shell with `claude --resume <id>` / codex. No
#      send-keys, no shell-prompt race, no magic sleeps.
#
# Usage: restore-claude-sessions.sh [snapshot-file]

set -euo pipefail

snapshot_file="${1:-}"

# Read tmux options
auto_restore=$(tmux show-option -gqv @claude-resurrect-auto-restore)
if [ "$auto_restore" = "off" ]; then
    exit 0
fi

RESURRECT_DIR="${HOME}/.tmux/resurrect"
SNAPSHOTS_DIR="${HOME}/.cache/tmux-claude-resurrect/snapshots"

if [ -z "$snapshot_file" ]; then
    # Find the most recent non-empty snapshot (skips post-disaster empty saves)
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

# ----------------------------------------------------------------------------
# Phase 1: ensure snapshot structural_addresses exist in tmux
# ----------------------------------------------------------------------------
# Find the best tmux-resurrect state file for layout info (directories, splits)
last_link="${RESURRECT_DIR}/last"
resurrect_file=""
if [ -L "$last_link" ] && [ -f "$last_link" ]; then
    resurrect_file="$(readlink -f "$last_link")"
else
    # Broken or missing symlink — find most recent valid state
    resurrect_file=$(find "$RESURRECT_DIR" -maxdepth 1 -name 'tmux_resurrect_*.txt' -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)
    if [ -n "$resurrect_file" ]; then
        ln -sf "$(basename "$resurrect_file")" "$last_link"
    fi
fi

# Extract all (session, window, pane) addresses this snapshot needs.
needed=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    snapshot = json.load(f)
seen = set()
for s in snapshot.get('sessions', []):
    addr = s.get('structural_address', '')
    if not addr:
        continue
    parts = addr.split(':')
    session = parts[0]
    wp = parts[1] if len(parts) > 1 else '0.0'
    wparts = wp.split('.')
    window = wparts[0]
    pane = wparts[1] if len(wparts) > 1 else '0'
    key = f'{session}\t{window}\t{pane}'
    if key not in seen:
        seen.add(key)
        print(key)
" "$snapshot_file" 2>/dev/null || true)

# Parse resurrect state file for window/session cwds and grouping.
declare -A win_dirs
declare -A pane_dirs
declare -A grouped

if [ -n "$resurrect_file" ] && [ -f "$resurrect_file" ]; then
    # Format: pane\tsession\twindow\t...\tpane_index\tpane_title\tdir\t...
    while IFS=$'\t' read -r line_type sess win _wa _wf pidx _pt dir _rest; do
        if [ "$line_type" = "pane" ]; then
            dir="${dir#:}"
            dir="${dir/#\~/$HOME}"
            [ -n "$dir" ] && pane_dirs["${sess}:${win}.${pidx}"]="$dir"
            # First pane per window seeds the window dir fallback
            [ -z "${win_dirs[${sess}:${win}]+x}" ] && win_dirs["${sess}:${win}"]="$dir"
        fi
    done < "$resurrect_file"

    while IFS=$'\t' read -r line_type gsess orig _rest; do
        if [ "$line_type" = "grouped_session" ]; then
            grouped["$gsess"]="$orig"
        fi
    done < "$resurrect_file"
fi

# Socket for TMUX="" isolated new-session calls
tmux_socket=$(echo "${TMUX:-}" | cut -d',' -f1)

# Create missing sessions and windows first (skip grouped clones — they come last)
echo "$needed" | sort -u | while IFS=$'\t' read -r session window pane; do
    [ -z "$session" ] && continue

    # Skip grouped session clones — handled after their primary exists
    if [ -n "${grouped[$session]+x}" ]; then
        continue
    fi

    if ! tmux has-session -t "$session" 2>/dev/null; then
        dir="${win_dirs[${session}:${window}]:-$HOME}"
        [ ! -d "$dir" ] && dir="$HOME"
        if [ -n "$tmux_socket" ]; then
            TMUX="" tmux -S "$tmux_socket" new-session -d -s "$session" -c "$dir"
        else
            tmux new-session -d -s "$session" -c "$dir"
        fi
        # If the first window index needs to be something other than base-index, move it
        base_idx=$(tmux show -gv base-index 2>/dev/null || echo 0)
        if [ "$window" != "$base_idx" ]; then
            tmux move-window -s "${session}:${base_idx}" -t "${session}:${window}" 2>/dev/null || true
        fi
    fi

    if ! tmux list-windows -t "$session" -F '#{window_index}' 2>/dev/null | grep -qx "$window"; then
        dir="${win_dirs[${session}:${window}]:-$HOME}"
        [ ! -d "$dir" ] && dir="$HOME"
        tmux new-window -d -t "${session}:${window}" -c "$dir"
    fi
done

# Create grouped session clones (now their primary exists)
for gsess in "${!grouped[@]}"; do
    orig="${grouped[$gsess]}"
    if tmux has-session -t "$orig" 2>/dev/null && ! tmux has-session -t "$gsess" 2>/dev/null; then
        if [ -n "$tmux_socket" ]; then
            TMUX="" tmux -S "$tmux_socket" new-session -d -s "$gsess" -t "$orig" 2>/dev/null || true
        else
            tmux new-session -d -s "$gsess" -t "$orig" 2>/dev/null || true
        fi
    fi
done

# Strict pane existence check — tmux display-message -t session:W.P falls back
# to the nearest pane when P doesn't exist, which would make us think a pane
# is there when it isn't.
pane_index_exists() {
    local sess="$1" win="$2" idx="$3"
    tmux list-panes -t "${sess}:${win}" -F '#{pane_index}' 2>/dev/null | grep -qx "$idx"
}

# Create missing pane splits within windows. Iterate panes in index order so
# split-window always has an existing pane to split.
echo "$needed" | sort -u -t$'\t' -k1,1 -k2,2n -k3,3n | while IFS=$'\t' read -r session window pane; do
    [ -z "$session" ] || [ -z "$pane" ] && continue

    # Pane exists? Nothing to do.
    if pane_index_exists "$session" "$window" "$pane"; then
        continue
    fi

    # Window must exist (loop above created it); bail if it somehow doesn't.
    if ! tmux list-windows -t "$session" -F '#{window_index}' 2>/dev/null | grep -qx "$window"; then
        continue
    fi

    dir="${pane_dirs[${session}:${window}.${pane}]:-${win_dirs[${session}:${window}]:-$HOME}}"
    [ ! -d "$dir" ] && dir="$HOME"

    # split-window -t the previous pane in the window (or whatever's active)
    tmux split-window -d -t "${session}:${window}" -c "$dir" 2>/dev/null || true
done

# ----------------------------------------------------------------------------
# Phase 2: launch claude/codex in each target pane via respawn-pane
# ----------------------------------------------------------------------------

# Helper: does this pane already have claude/codex running? Handles the common
# case where codex runs as `node /usr/local/bin/codex` so pane_current_command
# is `node` and a pgrep for "codex" on the pane pid misses it.
pane_already_running() {
    local address="$1"
    local pane_cmd
    pane_cmd=$(tmux display-message -t "$address" -p '#{pane_current_command}' 2>/dev/null || echo "")
    case "$pane_cmd" in
        claude|codex) return 0 ;;
    esac
    local pane_pid
    pane_pid=$(tmux display-message -t "$address" -p '#{pane_pid}' 2>/dev/null || echo "")
    [ -z "$pane_pid" ] && return 1
    # Direct children: match claude/codex
    if pgrep -P "$pane_pid" -x "claude" >/dev/null 2>&1; then return 0; fi
    if pgrep -P "$pane_pid" -x "codex" >/dev/null 2>&1; then return 0; fi
    # Walk direct children and check their cmdline for codex (node wrapper)
    local child_pid child_cmd
    for child_pid in $(pgrep -P "$pane_pid" 2>/dev/null); do
        child_cmd=$(tr '\0' ' ' < "/proc/$child_pid/cmdline" 2>/dev/null) || continue
        case "$child_cmd" in
            *codex*) return 0 ;;
        esac
    done
    return 1
}

python3 -c "
import json, sys
SEP = '\x1f'
with open(sys.argv[1]) as f:
    snapshot = json.load(f)
for s in snapshot.get('sessions', []):
    entry_type = s.get('type', 'claude')
    project_root = s.get('project_root', '') or s.get('cwd', '')
    print(SEP.join([
        entry_type,
        s.get('session_id', ''),
        s.get('structural_address', ''),
        s.get('cwd', ''),
        s.get('transcript_path', ''),
        s.get('permission_mode', 'default'),
        project_root,
        s.get('command', '')
    ]))
" "$snapshot_file" | while IFS=$'\x1f' read -r entry_type session_id address cwd transcript_path permission_mode project_root command; do
    # Pane must exist at the exact index (Phase 1 should have created it).
    # Use list-panes because display-message -t sess:W.P silently falls back
    # to the nearest pane when P doesn't exist.
    sess_part="${address%%:*}"
    wp_part="${address#*:}"
    win_part="${wp_part%%.*}"
    pidx_part="${wp_part##*.}"
    if ! tmux list-panes -t "${sess_part}:${win_part}" -F '#{pane_index}' 2>/dev/null | grep -qx "$pidx_part"; then
        continue
    fi

    # Skip if the target process is already running
    if pane_already_running "$address"; then
        continue
    fi

    # Build the resume command
    cmd=""
    restore_dir=""

    if [ "$entry_type" = "claude" ]; then
        if [ -n "$transcript_path" ] && [ ! -f "$transcript_path" ]; then
            continue
        fi
        cmd="claude --resume $session_id"
        if [ "$permission_mode" = "bypassPermissions" ]; then
            cmd="$cmd --dangerously-skip-permissions"
        elif [ -n "$permission_mode" ] && [ "$permission_mode" != "default" ]; then
            cmd="$cmd --permission-mode $permission_mode"
        fi
        restore_dir="${project_root:-$cwd}"

    elif [ "$entry_type" = "codex" ]; then
        if [ -n "$session_id" ]; then
            cmd="codex resume $session_id"
        elif [ -n "$command" ]; then
            cmd="$command"
        else
            continue
        fi
        restore_dir="$cwd"
    else
        continue
    fi

    [ ! -d "$restore_dir" ] && restore_dir="$HOME"

    # Atomic replacement: kill the pane's current process and spawn the resume
    # command directly. No shell, no prompt race, no send-keys.
    tmux respawn-pane -k -t "$address" -c "$restore_dir" "$cmd" 2>/dev/null || true
done

# ----------------------------------------------------------------------------
# Phase 3: move clients attached to renamed sessions back to the restored name
# ----------------------------------------------------------------------------
# The pre-restore rename hook writes a map of (client_tty, original_session)
# pairs; switch each client to the restored session if it now exists.
rename_map="${HOME}/.cache/tmux-claude-resurrect/pre-restore-clients"
if [ -f "$rename_map" ]; then
    while IFS=$'\t' read -r client_tty target_session; do
        [ -z "$client_tty" ] || [ -z "$target_session" ] && continue
        if tmux has-session -t "$target_session" 2>/dev/null; then
            tmux switch-client -c "$client_tty" -t "$target_session" 2>/dev/null || true
        fi
    done < "$rename_map"
    rm -f "$rename_map"
fi
