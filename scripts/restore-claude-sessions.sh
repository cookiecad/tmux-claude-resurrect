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

# Strict has-session: tmux's default matching is prefix/fnmatch and
# `has-session -t codex` returns true if `codex-view-...` exists.
has_session_strict() {
    tmux has-session -t "=$1" 2>/dev/null
}

# Snapshot session names use the live group/session name at save time
# (typically the clone name like `codex`). The resurrect file's pane lines
# live on the LEADER (e.g. `codex-view-192701-26655`). For each clone in
# the snapshot, find its leader so we know where windows actually live.
resolve_leader() {
    local sess="$1"
    if [ -n "${grouped[$sess]+x}" ]; then
        echo "${grouped[$sess]}"
    else
        echo "$sess"
    fi
}

# Phase 1a: ensure the LEADER session of each snapshot address has the right
# windows. Snapshot addresses use the live group/session name at save time
# (typically the clone, e.g. `codex`), but the resurrect file's pane lines
# live on the leader (`codex-view-192701-26655`). The previous version
# skipped clones in the loop and never created the leader, so the leader's
# multi-window structure was missing — and clones (sharing the leader's
# windows) stayed empty.
#
# We only touch leaders that the snapshot actually addresses: this stays a
# claude/codex restore tool, not a full tmux layout restorer.
declare -A snapshot_leader_windows
while IFS=$'\t' read -r session window pane; do
    [ -z "$session" ] && continue
    leader="$(resolve_leader "$session")"
    snapshot_leader_windows["${leader}:${window}"]=1
done <<< "$needed"

base_idx=$(tmux show -gv base-index 2>/dev/null || echo 0)
for key in "${!snapshot_leader_windows[@]}"; do
    sess="${key%:*}"
    win="${key##*:}"

    if ! has_session_strict "$sess"; then
        dir="${win_dirs[${sess}:${win}]:-$HOME}"
        [ ! -d "$dir" ] && dir="$HOME"
        if [ -n "$tmux_socket" ]; then
            TMUX="" tmux -S "$tmux_socket" new-session -d -s "$sess" -c "$dir" 2>/dev/null || true
        else
            tmux new-session -d -s "$sess" -c "$dir" 2>/dev/null || true
        fi
        if [ "$win" != "$base_idx" ] && has_session_strict "$sess"; then
            tmux move-window -s "${sess}:${base_idx}" -t "${sess}:${win}" 2>/dev/null || true
        fi
    fi

    if has_session_strict "$sess" && \
       ! tmux list-windows -t "$sess" -F '#{window_index}' 2>/dev/null | grep -qx "$win"; then
        dir="${win_dirs[${sess}:${win}]:-$HOME}"
        [ ! -d "$dir" ] && dir="$HOME"
        tmux new-window -d -t "${sess}:${win}" -c "$dir" 2>/dev/null || true
    fi
done

# Phase 1b: ensure each grouped clone is actually grouped with its leader.
#
# Two cases the previous code missed:
#   1) the clone exists, but in a DIFFERENT group than the leader (typical when
#      pre-restore-rename couldn't catch the conflict — e.g., the leader was
#      renamed to -stale- but the clone got created later by an i3 launcher
#      and joined some other "stale" group named after the same root)
#   2) the clone exists ungrouped while the leader has its own group
# In both cases the snapshot's clone-keyed addresses (e.g., `codex:1.0`)
# resolve to a session that doesn't share the leader's windows, so respawn
# misses every window past 0.
#
# Fix: kill the misgrouped clone (preserving its attached clients), recreate
# it as a proper clone of the leader, and switch the saved clients back.
recreate_clone_grouped() {
    local clone="$1" leader="$2"
    local clients
    clients=$(tmux list-clients -t "=$clone" -F '#{client_tty}' 2>/dev/null || true)
    tmux kill-session -t "=$clone" 2>/dev/null || true
    if [ -n "$tmux_socket" ]; then
        TMUX="" tmux -S "$tmux_socket" new-session -d -s "$clone" -t "$leader" 2>/dev/null || true
    else
        tmux new-session -d -s "$clone" -t "$leader" 2>/dev/null || true
    fi
    if [ -n "$clients" ] && has_session_strict "$clone"; then
        while IFS= read -r tty; do
            [ -z "$tty" ] && continue
            tmux switch-client -c "$tty" -t "$clone" 2>/dev/null || true
        done <<< "$clients"
    fi
}

for gsess in "${!grouped[@]}"; do
    orig="${grouped[$gsess]}"
    has_session_strict "$orig" || continue

    if ! has_session_strict "$gsess"; then
        if [ -n "$tmux_socket" ]; then
            TMUX="" tmux -S "$tmux_socket" new-session -d -s "$gsess" -t "$orig" 2>/dev/null || true
        else
            tmux new-session -d -s "$gsess" -t "$orig" 2>/dev/null || true
        fi
        continue
    fi

    # Both exist — verify they share a group. Note: `display-message` doesn't
    # expose session_group reliably (returns empty for grouped sessions in
    # some tmux versions); use `list-sessions -f` filter instead.
    clone_group=$(tmux list-sessions -f "#{==:#{session_name},$gsess}" -F '#{session_group}' 2>/dev/null || true)
    leader_group=$(tmux list-sessions -f "#{==:#{session_name},$orig}" -F '#{session_group}' 2>/dev/null || true)
    if [ -n "$leader_group" ] && [ "$clone_group" = "$leader_group" ]; then
        continue  # Properly grouped already
    fi

    recreate_clone_grouped "$gsess" "$orig"
done

# Strict pane existence check — tmux display-message -t session:W.P falls back
# to the nearest pane when P doesn't exist, which would make us think a pane
# is there when it isn't.
pane_index_exists() {
    local sess="$1" win="$2" idx="$3"
    tmux list-panes -t "${sess}:${win}" -F '#{pane_index}' 2>/dev/null | grep -qx "$idx"
}

# Create missing pane splits within windows. Iterate panes in index order so
# split-window always has an existing pane to split. For grouped clones the
# windows physically live on the leader, so look up dirs there too.
echo "$needed" | sort -u -t$'\t' -k1,1 -k2,2n -k3,3n | while IFS=$'\t' read -r session window pane; do
    [ -z "$session" ] || [ -z "$pane" ] && continue
    leader="$(resolve_leader "$session")"

    # Pane exists? Nothing to do. Splits on a clone propagate to the group, so
    # check existence via the clone's address (matches how Phase 2 will look).
    if pane_index_exists "$session" "$window" "$pane"; then
        continue
    fi

    # Window must exist on the leader (Phase 1a/1b should have made it).
    if ! tmux list-windows -t "$leader" -F '#{window_index}' 2>/dev/null | grep -qx "$window"; then
        continue
    fi

    dir="${pane_dirs[${leader}:${window}.${pane}]:-${win_dirs[${leader}:${window}]:-${pane_dirs[${session}:${window}.${pane}]:-${win_dirs[${session}:${window}]:-$HOME}}}}"
    [ ! -d "$dir" ] && dir="$HOME"

    # split-window -t the previous pane in the window (or whatever's active)
    tmux split-window -d -t "${leader}:${window}" -c "$dir" 2>/dev/null || true
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
