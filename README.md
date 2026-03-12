# tmux-claude-resurrect

Automatically resume [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions after tmux restore.

When tmux dies (crash, reboot, `kill-server`) or pane processes are killed (OOM, etc.), all running Claude Code sessions are lost. Claude conversations persist on disk, but the mapping of "which pane had which Claude session" is gone. This plugin bridges Claude Code's session persistence with [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) to automatically resume Claude sessions in their original panes.

## How it works

1. **Capture** — A Claude Code `SessionStart` hook records pane→session mappings whenever Claude starts or resumes
2. **Save** — When tmux-resurrect saves (manual or via tmux-continuum), timestamped snapshots of all active Claude sessions are created
3. **Restore** — After tmux-resurrect restore, the most recent non-empty snapshot is used to resume Claude sessions
4. **Picker** — Press `prefix + R` to browse snapshot history and restore from any point in time

## Snapshot history

Previous versions kept a single `claude-sessions.json` that was overwritten on every save. If processes died (e.g., OOM killer) and a save happened before restore, the good state was lost forever.

Now, each save creates a timestamped snapshot (`snapshot-YYYYMMDD-HHMMSS.json`). The last 100 snapshots are kept (~8 hours at 5-minute continuum intervals). The restore logic automatically skips empty snapshots, and the picker lets you browse and select any saved snapshot.

## Requirements

- [tmux](https://github.com/tmux/tmux) 3.2+ (for popup support in the picker)
- [TPM](https://github.com/tmux-plugins/tpm)
- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- `python3` (for JSON parsing)
- `fzf` (optional, for interactive picker — falls back to numbered menu)

## Installation

### 1. Install with TPM

Add to `~/.tmux.conf`:

```tmux
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'napter/tmux-claude-resurrect'
```

Then press `prefix + I` to install.

### 2. Add the Claude Code hook

Add a `SessionStart` hook to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.tmux/plugins/tmux-claude-resurrect/hooks/session-start-hook.sh"
          }
        ]
      }
    ]
  }
}
```

> **Note:** If you installed from a local path instead of TPM, adjust the command path accordingly.

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `@claude-resurrect-auto-restore` | `on` | Set to `off` to disable automatic Claude session resume |
| `@claude-resurrect-restore-delay` | `2` | Seconds to wait for shells to initialize before sending resume commands |
| `@claude-resurrect-picker-key` | `R` | Key for the snapshot picker (bound as `prefix + <key>`) |

Example:

```tmux
set -g @claude-resurrect-restore-delay '3'
set -g @claude-resurrect-picker-key 'R'
```

## Usage

### Automatic restore

1. Start Claude Code in one or more tmux panes
2. Save with `prefix + Ctrl-S` (tmux-resurrect save)
3. After a crash or reboot, restore with `prefix + Ctrl-R` (tmux-resurrect restore)
4. Claude sessions automatically resume in their original panes (using the most recent non-empty snapshot)

### Snapshot picker

Press `prefix + R` to open the snapshot picker. It shows all saved snapshots with:
- Timestamp
- Number of Claude sessions
- Breakdown by tmux session name

Select a snapshot and all Claude sessions from that point in time are restored to their panes.

This is useful when:
- The automatic restore picked the wrong snapshot
- You want to restore sessions from an older point in time
- Processes died without a tmux restart (e.g., OOM kill) and you need to manually trigger restore

### Permission modes

The plugin captures and restores Claude's permission mode:
- Sessions started with `--dangerously-skip-permissions` will resume with that flag
- Sessions with custom `--permission-mode` values are preserved

## How the cache works

```
~/.cache/tmux-claude-resurrect/
├── panes/
│   └── {pane_id}.json              # Per-pane session metadata (written by SessionStart hook)
└── snapshots/
    ├── snapshot-YYYYMMDD-HHMMSS.json  # Timestamped snapshots (last 100 kept)
    └── latest                          # Symlink to most recent snapshot
```

Each snapshot is also copied to `~/.tmux/resurrect/claude-sessions.json` for backward compatibility.

### Snapshot format (v2)

```json
{
  "version": 2,
  "timestamp": 1773271499.0,
  "sessions": [
    {
      "session_id": "abc-123",
      "structural_address": "forecasting:2.0",
      "cwd": "/path/to/working/dir",
      "project_root": "/path/to/project/root",
      "transcript_path": "/home/user/.claude/projects/.../abc-123.jsonl",
      "permission_mode": "bypassPermissions",
      "pane_id": "354"
    }
  ]
}
```

Key improvements over v1:
- **`structural_address`** is resolved live at save time (not cached from session start), so it stays correct when panes are moved between sessions/windows
- **`project_root`** ensures `claude --resume` runs from the correct directory for project resolution, even if the pane's cwd changed since the session was created

## License

[MIT](LICENSE)
