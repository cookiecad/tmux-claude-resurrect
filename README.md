# tmux-claude-resurrect

Automatically resume [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions after tmux restore.

When tmux dies (crash, reboot, `kill-server`), all running Claude Code sessions are lost. Claude conversations persist on disk, but the mapping of "which pane had which Claude session" is gone. This plugin bridges Claude Code's session persistence with [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) to automatically resume Claude sessions in their original panes.

## How it works

1. **Capture** — A Claude Code `SessionStart` hook records pane→session mappings whenever Claude starts or resumes
2. **Save** — When you press `prefix + Ctrl-S`, tmux-resurrect's post-save hook snapshots all active Claude pane mappings
3. **Restore** — When you press `prefix + Ctrl-R`, tmux-resurrect's post-restore hook sends `claude --resume <id>` to each pane

## Requirements

- [tmux](https://github.com/tmux/tmux) 1.9+
- [TPM](https://github.com/tmux-plugins/tpm)
- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- `python3` (for JSON parsing)

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

Example:

```tmux
set -g @claude-resurrect-restore-delay '3'
```

## Usage

1. Start Claude Code in one or more tmux panes
2. Save with `prefix + Ctrl-S` (tmux-resurrect save)
3. After a crash or reboot, restore with `prefix + Ctrl-R` (tmux-resurrect restore)
4. Claude sessions automatically resume in their original panes

### Permission modes

The plugin captures and restores Claude's permission mode:
- Sessions started with `--dangerously-skip-permissions` will resume with that flag
- Sessions with custom `--permission-mode` values are preserved

## How the cache works

```
~/.cache/tmux-claude-resurrect/
├── panes/
│   └── {pane_id}.json        # Per-pane session metadata (written by SessionStart hook)
└── snapshots/
    └── claude-sessions.json  # Consolidated snapshot (written at save time)
```

The snapshot is also copied to `~/.tmux/resurrect/claude-sessions.json` so it travels with the resurrect state.

## License

[MIT](LICENSE)
