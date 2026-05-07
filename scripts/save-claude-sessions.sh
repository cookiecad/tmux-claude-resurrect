#!/usr/bin/env python3
"""tmux-resurrect post-save hook — creates timestamped snapshots of Claude
and Codex sessions paired with their live structural addresses.

PERFORMANCE: previously this was a bash script that ran `pgrep -P` 2-3x
per pane to detect Claude/Codex children. At 70 panes that meant 140-210
fork+execs per save, taking ~8 seconds. This rewrite reads /proc once
into in-memory maps and does the per-pane work as dict lookups, dropping
hook runtime to ~200ms.

Output is byte-identical to the previous bash+python-heredoc version:
same snapshot JSON shape, same `latest` symlink behavior, same
backward-compat `claude-sessions.json` copy, same MAX_SNAPSHOTS pruning,
same fingerprint dedup.
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
CACHE_DIR = HOME / ".cache" / "tmux-claude-resurrect"
PANES_DIR = CACHE_DIR / "panes"
SNAPSHOTS_DIR = CACHE_DIR / "snapshots"
RESURRECT_DIR = HOME / ".tmux" / "resurrect"
MAX_SNAPSHOTS = 100
MAX_PANE_CACHE_AGE = 7 * 24 * 60 * 60  # seconds


def read_proc_table():
    """Single /proc walk → (proc_by_pid, children_by_ppid).
    proc_by_pid:    {pid: (ppid, comm)}
    children_by_pp: {ppid: [pids]}
    """
    proc = {}
    children = {}
    try:
        entries = os.listdir("/proc")
    except OSError:
        return proc, children
    for name in entries:
        if not name.isdigit():
            continue
        pid = int(name)
        try:
            with open(f"/proc/{pid}/stat") as f:
                content = f.read()
        except OSError:
            continue
        # Format: pid (comm) state ppid pgrp ...
        # comm may contain spaces and `)`; the kernel wraps it with the
        # FIRST `(` and LAST `)` of the line.
        try:
            l_paren = content.index("(")
            r_paren = content.rindex(")")
        except ValueError:
            continue
        comm = content[l_paren + 1 : r_paren]
        rest = content[r_paren + 2 :].split()
        if len(rest) < 2:
            continue
        try:
            ppid = int(rest[1])
        except ValueError:
            continue
        proc[pid] = (ppid, comm)
        children.setdefault(ppid, []).append(pid)
    return proc, children


def read_cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return f.read().decode("utf-8", errors="replace").replace("\0", " ").rstrip()
    except OSError:
        return ""


def find_codex_pid(pane_pid, proc_by_pid, children):
    """Match the bash version's two-pass priority:
    1) any direct child with comm == "codex"        (strict, fast)
    2) any direct child whose cmdline mentions codex (catches `node …/codex`)
    """
    kids = children.get(pane_pid, [])
    for child in kids:
        _, comm = proc_by_pid.get(child, (None, ""))
        if comm == "codex":
            return child
    for child in kids:
        if "codex" in read_cmdline(child):
            return child
    return None


def find_codex_session_id(pid):
    """Look at the codex process's open fds for ~/.codex/sessions/<id>/..."""
    fd_dir = f"/proc/{pid}/fd"
    try:
        fds = os.listdir(fd_dir)
    except OSError:
        return ""
    marker = "/.codex/sessions/"
    for fd in fds:
        try:
            target = os.readlink(f"{fd_dir}/{fd}")
        except OSError:
            continue
        if marker in target:
            return target.split(marker, 1)[1].split("/", 1)[0]
    return ""


def list_panes():
    """Yield (pane_pid:int, pane_id:str, pane_cmd, addr, cwd) for each unique
    pane, collapsing grouped-session clones to one entry per pane_id.
    """
    fmt = (
        "#{pane_pid}\t#{pane_id}\t#{pane_current_command}\t"
        "#{?session_grouped,#{session_group},#{session_name}}"
        ":#{window_index}.#{pane_index}\t#{pane_current_path}"
    )
    try:
        out = subprocess.run(
            ["tmux", "list-panes", "-a", "-F", fmt],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return
    seen = set()
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 5:
            continue
        pid_s, pane_id, cmd, addr, cwd = parts
        if pane_id in seen:
            continue
        seen.add(pane_id)
        try:
            yield int(pid_s), pane_id, cmd, addr, cwd
        except ValueError:
            continue


def session_fingerprint(sessions):
    """Stable hashable representation, excluding the volatile `timestamp`."""
    return sorted(
        json.dumps({k: v for k, v in s.items() if k != "timestamp"}, sort_keys=True)
        for s in sessions
    )


def paired_resurrect_file():
    last_link = RESURRECT_DIR / "last"
    if not last_link.is_symlink():
        return ""
    try:
        return os.path.basename(os.path.realpath(last_link))
    except OSError:
        return ""


def main():
    SNAPSHOTS_DIR.mkdir(parents=True, exist_ok=True)
    RESURRECT_DIR.mkdir(parents=True, exist_ok=True)

    proc_by_pid, children = read_proc_table()
    now = time.time()
    paired = paired_resurrect_file()
    sessions = []

    for pane_pid, pane_id, pane_cmd, addr, cwd in list_panes():
        pane_number = pane_id.lstrip("%")

        # ---- Claude detection ----
        is_claude = pane_cmd == "claude" or any(
            proc_by_pid.get(c, (None, ""))[1] == "claude"
            for c in children.get(pane_pid, [])
        )

        if is_claude:
            pane_file = PANES_DIR / f"{pane_number}.json"
            if not pane_file.exists():
                print(
                    f"tmux-claude-resurrect: WARNING: Claude in pane %{pane_number} has no cache file",
                    file=sys.stderr,
                )
                continue
            try:
                if now - pane_file.stat().st_mtime > MAX_PANE_CACHE_AGE:
                    continue
                pane_data = json.loads(pane_file.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            pane_data["structural_address"] = addr
            pane_data["type"] = "claude"
            sessions.append(pane_data)
            continue

        # ---- Codex detection ----
        if pane_cmd == "codex":
            codex_pid = pane_pid
        else:
            codex_pid = find_codex_pid(pane_pid, proc_by_pid, children)

        if codex_pid:
            cmdline = read_cmdline(codex_pid)
            cmd = re.sub(r"^node\s+\S*/codex", "codex", cmdline)
            sessions.append(
                {
                    "type": "codex",
                    "structural_address": addr,
                    "cwd": cwd,
                    "command": cmd,
                    "session_id": find_codex_session_id(codex_pid),
                    "pane_id": pane_number,
                    "timestamp": now,
                }
            )

    # ---- Dedup against last snapshot ----
    latest_link = SNAPSHOTS_DIR / "latest"
    fingerprint = session_fingerprint(sessions)
    compat_path = RESURRECT_DIR / "claude-sessions.json"

    if latest_link.exists():
        try:
            prev = json.loads(latest_link.read_text())
            if session_fingerprint(prev.get("sessions", [])) == fingerprint:
                # No change — refresh timestamp + paired file, write through
                prev["timestamp"] = now
                prev["resurrect_file"] = paired
                payload = json.dumps(prev, indent=2)
                latest_link.write_text(payload)
                compat_path.write_text(payload)
                return
        except (OSError, json.JSONDecodeError, KeyError):
            pass  # fall through and write fresh

    # ---- Write fresh snapshot ----
    snapshot = {
        "version": 2,
        "timestamp": now,
        "resurrect_file": paired,
        "sessions": sessions,
    }
    payload = json.dumps(snapshot, indent=2)
    ts = time.strftime("%Y%m%d-%H%M%S")
    snapshot_file = SNAPSHOTS_DIR / f"snapshot-{ts}.json"
    snapshot_file.write_text(payload)

    # Atomic symlink update
    tmp_link = SNAPSHOTS_DIR / "latest.tmp"
    try:
        tmp_link.unlink()
    except FileNotFoundError:
        pass
    tmp_link.symlink_to(snapshot_file.name)
    tmp_link.replace(latest_link)

    compat_path.write_text(payload)

    # Prune
    snaps = sorted(
        (
            f
            for f in SNAPSHOTS_DIR.iterdir()
            if f.name.startswith("snapshot-") and f.name.endswith(".json")
        ),
        key=lambda f: f.name,
        reverse=True,
    )
    for old in snaps[MAX_SNAPSHOTS:]:
        try:
            old.unlink()
        except OSError:
            pass


if __name__ == "__main__":
    main()
