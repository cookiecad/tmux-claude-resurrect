#!/usr/bin/env bash
# tmux-resurrect pre-restore hook
#
# tmux-resurrect cannot recreate a saved session if a session with the same
# name already exists (e.g. the user started a fresh tmux after a crash and
# has an empty `main` waiting). The attempt fails with "duplicate session"
# and the saved content is never restored.
#
# This hook reads the saved tmux-resurrect state file, finds session names
# the restore will need, and renames any pre-existing conflicts to
# `<name>-stale-<TS>`. It also records (client_tty, original_session) pairs
# so the post-restore hook can switch attached clients back to the freshly
# restored session.

set -euo pipefail

RESURRECT_DIR="${HOME}/.tmux/resurrect"
CACHE_DIR="${HOME}/.cache/tmux-claude-resurrect"
RENAME_MAP="${CACHE_DIR}/pre-restore-clients"

mkdir -p "$CACHE_DIR"

# Find the most recent tmux-resurrect state file (the one about to be restored).
last_link="${RESURRECT_DIR}/last"
if [ -L "$last_link" ] && [ -f "$last_link" ]; then
    resurrect_file="$(readlink -f "$last_link")"
else
    resurrect_file=$(find "$RESURRECT_DIR" -maxdepth 1 -name 'tmux_resurrect_*.txt' -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)
fi

if [ -z "${resurrect_file:-}" ] || [ ! -f "$resurrect_file" ]; then
    exit 0
fi

# Collect every session name the restore will touch: from pane lines (primary
# sessions) and grouped_session lines (both the clone and its original).
needed_sessions=$(awk -F'\t' '
    $1 == "pane" { print $2 }
    $1 == "grouped_session" { print $2; print $3 }
' "$resurrect_file" | sort -u)

[ -z "$needed_sessions" ] && exit 0

timestamp=$(date +%s)
: > "$RENAME_MAP"

while IFS= read -r sess; do
    [ -z "$sess" ] && continue
    tmux has-session -t "$sess" 2>/dev/null || continue

    stale_name="${sess}-stale-${timestamp}"
    # Unlikely, but guard against the stale name colliding too
    suffix=0
    while tmux has-session -t "$stale_name" 2>/dev/null; do
        suffix=$((suffix + 1))
        stale_name="${sess}-stale-${timestamp}-${suffix}"
    done

    # Remember which clients were attached to this session so we can switch
    # them to the restored session afterwards.
    tmux list-clients -t "$sess" -F '#{client_tty}' 2>/dev/null | while IFS= read -r tty; do
        [ -n "$tty" ] && printf '%s\t%s\n' "$tty" "$sess" >> "$RENAME_MAP"
    done

    tmux rename-session -t "$sess" "$stale_name" 2>/dev/null || true
done <<< "$needed_sessions"
