#!/usr/bin/env bash
# Preview helper for pick-snapshot.sh — shows snapshot details for fzf preview pane.
# Usage: preview-snapshot.sh <snapshot-file-path>

python3 -c "
import json, sys, os
from datetime import datetime
from collections import Counter

with open(sys.argv[1]) as f:
    data = json.load(f)

sessions = data.get('sessions', [])
ts = data.get('timestamp', 0)
dt = datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M:%S') if ts else '?'

print(f'Snapshot:  {os.path.basename(sys.argv[1])}')
print(f'Time:      {dt}')
print(f'Version:   {data.get(\"version\", \"?\")}')
print(f'Sessions:  {len(sessions)}')

by_type = Counter(s.get('type', 'claude') for s in sessions)
if by_type:
    print(f'Types:     {dict(by_type)}')
print()

if not sessions:
    print('  (empty snapshot)')
else:
    # Group by type for display
    claude_sessions = [s for s in sessions if s.get('type', 'claude') == 'claude']
    codex_sessions = [s for s in sessions if s.get('type') == 'codex']

    if claude_sessions:
        print(f'  Claude ({len(claude_sessions)})')
        print(f'  {\"Address\":<25} {\"Session ID\":<14} {\"Project\":<20} {\"Mode\"}')
        print(f'  {\"-\" * 25} {\"-\" * 14} {\"-\" * 20} {\"-\" * 20}')
        for s in claude_sessions:
            addr = s.get('structural_address', '?')
            sid = s.get('session_id', '?')[:12] + '..'
            proj_root = s.get('project_root', s.get('cwd', '?'))
            proj = os.path.basename(proj_root) if proj_root else '?'
            perm = s.get('permission_mode', 'default')
            transcript = s.get('transcript_path', '')
            exists = '+' if os.path.isfile(transcript) else 'x'
            print(f'  {addr:<25} {sid:<14} {proj:<20} {perm} {exists}')
        print()

    if codex_sessions:
        print(f'  Codex ({len(codex_sessions)})')
        print(f'  {\"Address\":<25} {\"Session ID\":<14} {\"Command\"}')
        print(f'  {\"-\" * 25} {\"-\" * 14} {\"-\" * 50}')
        for s in codex_sessions:
            addr = s.get('structural_address', '?')
            sid = s.get('session_id', '')
            sid_display = (sid[:12] + '..') if sid else '(full-auto)'
            cmd = s.get('command', '?')
            # Truncate long commands
            if len(cmd) > 60:
                cmd = cmd[:57] + '...'
            print(f'  {addr:<25} {sid_display:<14} {cmd}')
        print()
" "$1"
