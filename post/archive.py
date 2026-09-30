#!/usr/bin/env python3
"""Archive a handled Post message: move it from inbox/ to archive/.

After a recipient acts on (or acks) a message, archiving keeps the inbox to
ONLY-pending messages — so the stale-task gate and the web stale-banner count
real backlog, not messages already dealt with.

Usage:
  archive.py <msg_id>            # archive for the cwd's participant
  archive.py <msg_id> <pid>      # archive for an explicit participant id

Resolves the participant from cwd against the registry when pid is omitted.
Moves both <msg_id>.orc and <msg_id>.md; sets status to `resolved` on the .orc.
Idempotent: a msg_id already in archive/ (or absent from inbox) is a no-op.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

POST_ROOT = Path.home() / ".claude" / "post"
PROJECTS = POST_ROOT / "projects"
# The one participant list: {id, path} rows (registry.md). The doorbell
# (ring-spawn.sh) resolves its participant through this file too, so a machine
# with a list gets rung, a machine without one stays quiet.
REGISTRY = POST_ROOT / "participants.json"


def resolve_participant(cwd: str) -> str | None:
    """Match cwd against registry paths; return the participant id (longest prefix)."""
    if not REGISTRY.exists():
        return None
    try:
        entries = json.loads(REGISTRY.read_text())
    except (json.JSONDecodeError, OSError):
        return None
    cwd_path = Path(cwd).resolve()
    best_id, best_len = None, -1
    for e in entries:
        if not isinstance(e, dict) or "path" not in e or "id" not in e:
            continue
        try:
            proot = Path(e["path"]).expanduser().resolve()
        except OSError:
            continue
        if cwd_path == proot or proot in cwd_path.parents:
            if len(str(proot)) > best_len:
                best_id, best_len = e["id"], len(str(proot))
    return best_id


# Purpose classes for auto-archiving. A message is auto-archived when it is HANDLED —
# but "handled" depends on whether the message expects a reply:
#   - No-reply purposes (info/knowledge/chat/interactive/ack) are done once READ.
#   - Reply purposes (query/blocker/brief/directive) must stay in the inbox until
#     ACKED/RESOLVED, so an open thread isn't lost the moment it's merely read.
ARCHIVE_ON_READ = {"info", "knowledge", "chat", "interactive", "ack"}
ARCHIVE_ON_ACKED = {"query", "blocker", "brief", "directive"}


def should_auto_archive(purpose: str, new_status: str) -> bool:
    """True if a message of this purpose, reaching this status, should be auto-archived.

    No-reply purposes archive at `read`; reply purposes archive at `acked`/`resolved`.
    Unknown purpose → never auto-archive (conservative; manual archive still works).
    """
    if purpose in ARCHIVE_ON_READ:
        return new_status == "read"
    if purpose in ARCHIVE_ON_ACKED:
        return new_status in ("acked", "resolved")
    return False


def write_tombstone(msg_id: str, pid: str) -> None:
    """Drop a tombstone marker so cross-machine sync removes this msg from BOTH inboxes.

    Archiving moves the file out of inbox locally, but additive (no --delete) sync
    would copy the other machine's still-present inbox copy back. The tombstone
    syncs both ways; sync-post.sh then sweeps inbox on each machine. Idempotent.
    """
    tdir = PROJECTS / pid / "tombstones"
    tdir.mkdir(parents=True, exist_ok=True)
    (tdir / f"{msg_id}.tombstone").write_text(msg_id + "\n")


def set_status(orc: Path, value: str) -> bool:
    """Stamp `status: <value>` into the .orc frontmatter (stdlib line edit).

    Returns True when the file was rewritten. The sender reads this field back off
    the recipient's synced inbox/archive copy to answer "have they seen it?" — which
    is why read-state belongs in the ledger and not in a receipt message.
    """
    try:
        lines = orc.read_text().splitlines()
    except OSError:
        return False
    out, replaced = [], False
    for line in lines:
        if line.strip().startswith("status:"):
            out.append(f"status: {value}")
            replaced = True
        else:
            out.append(line)
    if replaced:
        orc.write_text("\n".join(out) + "\n")
    return replaced


def set_status_resolved(orc: Path) -> None:
    """Stamp status: resolved into the .orc frontmatter."""
    set_status(orc, "resolved")


def archive(msg_id: str, pid: str) -> int:
    inbox = PROJECTS / pid / "inbox"
    archive_dir = PROJECTS / pid / "archive"
    orc = inbox / f"{msg_id}.orc"
    if not orc.exists():
        # Already archived or never here — idempotent no-op.
        print(f"archive: {msg_id} not in {pid}/inbox (already archived?) — skip")
        return 0
    archive_dir.mkdir(parents=True, exist_ok=True)
    set_status_resolved(orc)
    md = inbox / f"{msg_id}.md"
    orc.rename(archive_dir / orc.name)
    if md.exists():
        md.rename(archive_dir / md.name)
    write_tombstone(msg_id, pid)
    print(f"archived {msg_id} → {pid}/archive/ (+tombstone)")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: archive.py <msg_id> [participant_id]", file=sys.stderr)
        return 2
    msg_id = sys.argv[1]
    pid = sys.argv[2] if len(sys.argv) > 2 else resolve_participant(str(Path.cwd()))
    if not pid:
        print("archive: could not resolve participant from cwd — pass pid explicitly",
              file=sys.stderr)
        return 1
    return archive(msg_id, pid)


if __name__ == "__main__":
    sys.exit(main())
