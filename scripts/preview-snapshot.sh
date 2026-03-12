#!/usr/bin/env bash
# Preview helper for pick-snapshot.sh — shows snapshot details for fzf preview pane.
# Usage: preview-snapshot.sh <snapshot-file-path>

python3 -c "
import json, sys, os
from datetime import datetime

with open(sys.argv[1]) as f:
    data = json.load(f)

sessions = data.get('sessions', [])
ts = data.get('timestamp', 0)
dt = datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M:%S') if ts else '?'

print(f'Snapshot:  {os.path.basename(sys.argv[1])}')
print(f'Time:      {dt}')
print(f'Version:   {data.get(\"version\", \"?\")}')
print(f'Sessions:  {len(sessions)}')
print()

if not sessions:
    print('  (empty snapshot)')
else:
    # Header
    print(f'  {\"Address\":<25} {\"Session ID\":<14} {\"Project\":<25} {\"Mode\"}')
    print(f'  {\"─\" * 25} {\"─\" * 14} {\"─\" * 25} {\"─\" * 20}')
    for s in sessions:
        addr = s.get('structural_address', '?')
        sid = s.get('session_id', '?')[:12] + '..'
        proj_root = s.get('project_root', s.get('cwd', '?'))
        proj = os.path.basename(proj_root) if proj_root else '?'
        perm = s.get('permission_mode', 'default')
        transcript = s.get('transcript_path', '')
        exists = '✓' if os.path.isfile(transcript) else '✗'
        print(f'  {addr:<25} {sid:<14} {proj:<25} {perm} {exists}')
" "$1"
