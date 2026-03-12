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
read -r session_id cwd transcript_path project_root < <(
    python3 -c "
import json, sys, os
data = json.loads(sys.argv[1])
session_id = data.get('session_id', '')
cwd = data.get('cwd', '')
transcript_path = data.get('transcript_path', '')

# Derive project_root: walk up from cwd to find the directory whose
# slash-to-dash encoding matches the transcript_path's parent dir name.
# e.g. /home/user/project → -home-user-project
project_root = cwd  # fallback
if transcript_path:
    encoded_dir = os.path.basename(os.path.dirname(transcript_path))
    candidate = cwd
    while candidate and candidate != '/':
        if candidate.replace('/', '-') == encoded_dir:
            project_root = candidate
            break
        candidate = os.path.dirname(candidate)

print(session_id, cwd, transcript_path, project_root)
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
    claude_pid=$(pgrep -P "$pane_pid" -x "claude" 2>/dev/null | head -1) || true
    # Fallback: claude may BE the pane process (no parent shell)
    if [ -z "$claude_pid" ]; then
        pane_cmd_check=$(tr '\0' ' ' < "/proc/$pane_pid/cmdline" 2>/dev/null || ps -p "$pane_pid" -o args= 2>/dev/null) || true
        if [[ "${pane_cmd_check:-}" == *claude* ]]; then
            claude_pid="$pane_pid"
        fi
    fi
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
    'project_root': sys.argv[7],
    'timestamp': time.time()
}
print(json.dumps(data, indent=2))
" "$session_id" "$cwd" "$transcript_path" "$structural_address" "$pane_number" "$permission_mode" "$project_root" \
    > "${CACHE_DIR}/${pane_number}.json"
