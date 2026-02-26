#!/usr/bin/env bash
# TPM entry point for tmux-claude-resurrect
# Registers tmux-resurrect post-save and post-restore hooks.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create cache directories
mkdir -p "${HOME}/.cache/tmux-claude-resurrect/panes"
mkdir -p "${HOME}/.cache/tmux-claude-resurrect/snapshots"

# Helper: chain a command onto an existing tmux option value (avoid clobbering)
chain_hook() {
    local option="$1"
    local command="$2"
    local current
    current=$(tmux show-option -gqv "$option")
    if [ -n "$current" ]; then
        tmux set-option -g "$option" "${current} ; ${command}"
    else
        tmux set-option -g "$option" "$command"
    fi
}

# Register hooks with tmux-resurrect
chain_hook "@resurrect-hook-post-save-all" "${CURRENT_DIR}/scripts/save-claude-sessions.sh"
chain_hook "@resurrect-hook-post-restore-all" "${CURRENT_DIR}/scripts/restore-claude-sessions.sh"

# Set defaults for configurable options (only if not already set)
if [ -z "$(tmux show-option -gqv @claude-resurrect-auto-restore)" ]; then
    tmux set-option -g @claude-resurrect-auto-restore "on"
fi
if [ -z "$(tmux show-option -gqv @claude-resurrect-restore-delay)" ]; then
    tmux set-option -g @claude-resurrect-restore-delay "2"
fi
