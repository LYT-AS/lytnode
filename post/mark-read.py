#!/usr/bin/env python3
"""Stamp read-state onto a Post message the recipient has actually handled.

This is the replacement for receipt-acks. A message whose only content is "I saw
it" carries nothing the sender can act on, but the sender still needs to tell
"seen, working on it" from "never seen". That signal belongs in the ledger, not in
the mailbox: the recipient stamps `status` on its own inbox copy, the copy syncs
back (inbox/ and archive/ are both synced, additively), and the sender reads it
with `post-status.py --sent`.

Two states, matching the enum in validate.py:
  read   — the recipient has seen it. Enough for no-reply purposes.
  acked  — the recipient has answered or acted on it. Required for reply purposes
           (query/blocker/brief/directive) before they count as handled.

Auto-archives when `should_auto_archive` says the message is done, so the inbox
keeps meaning "still pending" and the stale-task gate stays honest.

Usage:
  mark-read.py <msg_id>                 # status: read, for the cwd's participant
  mark-read.py <msg_id> --acked         # status: acked (answered/acted on)
  mark-read.py <msg_id> <pid>           # explicit participant id
  mark-read.py --all                    # mark every unread in this inbox as read

Idempotent: a message already at or past the requested state is left alone.
Never touches another participant's inbox unless a pid is given explicitly.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from archive import (  # noqa: E402
    PROJECTS,
    archive,
    resolve_participant,
    set_status,
    should_auto_archive,
)

# Ordered weakest → strongest. A stamp never moves a message backwards.
STATUS_RANK = {"unread": 0, "read": 1, "acked": 2, "resolved": 3}


def scan_field(text: str, key: str) -> str:
    """Read one scalar field out of .orc frontmatter without a YAML dependency."""
    prefix = key + ":"
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(prefix):
            return stripped[len(prefix):].strip().strip('"').strip("'")
    return ""


def stamp(msg_id: str, pid: str, new_status: str) -> int:
    """Set status on one inbox message, then auto-archive it when it counts as handled."""
    orc = PROJECTS / pid / "inbox" / f"{msg_id}.orc"
    if not orc.exists():
        print(f"mark-read: {msg_id} not in {pid}/inbox (already archived?) — skip")
        return 0

    text = orc.read_text()
    current = scan_field(text, "status") or "unread"
    if STATUS_RANK.get(current, 0) >= STATUS_RANK[new_status]:
        print(f"mark-read: {msg_id} already '{current}' — skip")
        return 0

    if not set_status(orc, new_status):
        print(f"mark-read: {msg_id} has no status: line — not stamped", file=sys.stderr)
        return 1
    print(f"mark-read: {msg_id} → status: {new_status}")

    purpose = scan_field(text, "purpose")
    if should_auto_archive(purpose, new_status):
        archive(msg_id, pid)
    return 0


def stamp_all(pid: str, new_status: str) -> int:
    """Stamp every message in this inbox that is still weaker than new_status."""
    inbox = PROJECTS / pid / "inbox"
    if not inbox.exists():
        print(f"mark-read: no inbox for '{pid}'", file=sys.stderr)
        return 1
    targets = sorted(orc.stem for orc in inbox.glob("*.orc"))
    if not targets:
        print(f"mark-read: {pid}/inbox is empty")
        return 0
    rc = 0
    for msg_id in targets:
        rc |= stamp(msg_id, pid, new_status)
    return rc


def main() -> int:
    args = [a for a in sys.argv[1:]]
    new_status = "acked" if "--acked" in args else "read"
    do_all = "--all" in args
    positional = [a for a in args if not a.startswith("--")]

    if not do_all and not positional:
        print(__doc__.strip().split("\n\n")[-1], file=sys.stderr)
        return 2

    msg_id = None if do_all else positional[0]
    explicit_pid = positional[1] if len(positional) > 1 else (
        positional[0] if do_all and positional else None
    )

    pid = explicit_pid or resolve_participant(str(Path.cwd()))
    if not pid:
        print("mark-read: could not resolve participant from cwd — pass a pid",
              file=sys.stderr)
        return 2

    return stamp_all(pid, new_status) if do_all else stamp(msg_id, pid, new_status)


if __name__ == "__main__":
    sys.exit(main())
