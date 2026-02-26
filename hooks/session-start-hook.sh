#!/usr/bin/env bash
# Claude Code SessionStart hook
# Captures pane→session mapping when Claude starts or resumes.
# Receives JSON on stdin per the Claude hook protocol.

set -euo pipefail

CACHE_DIR="${HOME}/.cache/tmux-claude-resurrect/panes"
mkdir -p "$CACHE_DIR"

# Must be running inside tmux
if [ -z "${TMUX_PANE:-}" ]; then
    exit 0
fi

# Read JSON from stdin
input=$(cat)

# Extract fields using python3 (avoids jq dependency)
read -r session_id cwd transcript_path < <(
    python3 -c "
import json, sys
data = json.loads(sys.argv[1])
print(data.get('session_id', ''), data.get('cwd', ''), data.get('transcript_path', ''))
" "$input"
)

if [ -z "$session_id" ]; then
    exit 0
fi

# Resolve structural address (session:window.pane) — stable across resurrect
structural_address=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}')

# Extract numeric pane id (strip leading %)
pane_number="${TMUX_PANE#%}"

# Detect permission mode from Claude's command line in this pane
pane_pid=$(tmux display-message -t "$TMUX_PANE" -p '#{pane_pid}')
claude_cmdline=""
if [ -n "$pane_pid" ]; then
    # Find claude process among children
    claude_pid=$(pgrep -P "$pane_pid" -f "claude" 2>/dev/null | head -1) || true
    if [ -n "$claude_pid" ]; then
        claude_cmdline=$(tr '\0' ' ' < "/proc/$claude_pid/cmdline" 2>/dev/null) || \
        claude_cmdline=$(ps -p "$claude_pid" -o args= 2>/dev/null) || true
    fi
fi

permission_mode="default"
if echo "$claude_cmdline" | grep -q -- '--dangerously-skip-permissions'; then
    permission_mode="bypassPermissions"
elif echo "$claude_cmdline" | grep -q -- '--permission-mode'; then
    permission_mode=$(echo "$claude_cmdline" | sed -n 's/.*--permission-mode[= ]\([^ ]*\).*/\1/p')
fi

# Write per-pane mapping file
python3 -c "
import json, sys, time
data = {
    'session_id': sys.argv[1],
    'cwd': sys.argv[2],
    'transcript_path': sys.argv[3],
    'structural_address': sys.argv[4],
    'pane_id': sys.argv[5],
    'permission_mode': sys.argv[6],
    'timestamp': time.time()
}
print(json.dumps(data, indent=2))
" "$session_id" "$cwd" "$transcript_path" "$structural_address" "$pane_number" "$permission_mode" \
    > "${CACHE_DIR}/${pane_number}.json"
