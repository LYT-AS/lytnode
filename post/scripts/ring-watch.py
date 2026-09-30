#!/usr/bin/env python3
"""Ring the session's own doorbell when new Post lands in its inbox.

The watcher a `Stop` hook leaves behind. It polls ONE participant's inbox and, when
an unread message at or above the local urgency threshold appears, writes one line
into the session's own messaging socket. Claude Code reads that line between tool
calls, or starts a new turn with it when the session is idle — so post announces
itself instead of waiting for the next SessionStart or a "check inbox".

Why this shape (decided 2026-09-03, all of it measured, none of it guessed):

* **Own-child injection works, also from a detached process.** Verified twice in
  one session: a live Bash child and a `nohup` process re-parented to init both had
  their line delivered mid-turn. The auth line carries the token; that is what lets
  a detached process verify on macOS after its parent has exited.
* **The sender cannot ring the recipient's door.** The socket and token are per
  session and exported only to that session's own children. So the receiving side
  rings itself; the sender writes post as before and does nothing new.
* **Credentials never touch disk.** Socket path and token arrive in the
  environment, inherited from the hook that spawned this process, and stay there.
* **A PID is not an identity.** Sockets live at `/tmp/cc-socks/<pid>.sock` and the
  OS reuses PIDs. A watcher that outlives its session could ring a stranger's door.
  So it records the socket's inode at start and exits the moment that changes, and
  `SessionEnd` kills it anyway.
* **Retry is driven by inbox state, not by a timer.** Ring while the message stays
  `unread`, with a widening gap, and stop the moment its status changes — that is
  someone reading it, which is the only thing that should silence a bell.
* **Lease, not lifetime.** The `Stop` hook extends the lease every turn; stop
  talking to the session and the watcher expires on its own. Wall clock, not sleep
  count, so a closed laptop lid does not leave a zombie.
* **The sender advises, the recipient decides.** `urgency` in the envelope is a
  suggestion; what actually rings is set per machine in `~/.claude/post/ring/threshold`.

Stdlib only. Never raises out of the loop.

Usage (spawned by hooks/ring-spawn.sh — not meant to be run by hand):
  ring-watch.py <participant> <session_id> [--lease 1800] [--poll 15]

Environment (inherited from the spawning hook):
  CLAUDE_CODE_MESSAGING_SOCKET   own inbox socket path
  CLAUDE_CODE_MESSAGING_TOKEN    own auth token
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
from pathlib import Path

POST_DIR = Path.home() / ".claude" / "post"
PROJECTS = POST_DIR / "projects"
RING_DIR = POST_DIR / "ring"
THRESHOLD_FILE = RING_DIR / "threshold"

URGENCY_RANK = {"backlog": 0, "low": 1, "normal": 2, "high": 3, "crisis": 4}
DEFAULT_THRESHOLD = "normal"

# Ring on the 1st, 3rd, 7th, 15th … poll a message is still unread: a bell that
# rings every 15 s for an hour is noise, one that rings once is a note nobody saw.
BACKOFF_POLLS = (1, 3, 7, 15, 31, 63)


def log(session_id: str, msg: str) -> None:
    """Append one line to this session's watcher log."""
    try:
        RING_DIR.mkdir(parents=True, exist_ok=True)
        with (RING_DIR / f"{session_id}.log").open("a", encoding="utf-8") as fh:
            fh.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n")
    except OSError:
        pass


def scan_field(text: str, key: str) -> str:
    """Read one scalar frontmatter field without a YAML dependency."""
    prefix = key + ":"
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(prefix):
            return stripped[len(prefix):].strip().strip('"').strip("'")
    return ""


def threshold_rank() -> int:
    """Local urgency floor for ringing. Set per machine, never by the sender."""
    try:
        word = THRESHOLD_FILE.read_text().strip().lower() or DEFAULT_THRESHOLD
    except OSError:
        word = DEFAULT_THRESHOLD
    return URGENCY_RANK.get(word, URGENCY_RANK[DEFAULT_THRESHOLD])


def unread_at_or_above(participant: str, floor: int) -> dict[str, dict]:
    """Unread inbox messages at or above the floor, keyed by msg_id."""
    inbox = PROJECTS / participant / "inbox"
    found: dict[str, dict] = {}
    if not inbox.exists():
        return found
    for orc in inbox.glob("*.orc"):
        try:
            text = orc.read_text()
        except OSError:
            continue
        if (scan_field(text, "status") or "unread") != "unread":
            continue
        urgency = scan_field(text, "urgency") or "normal"
        if URGENCY_RANK.get(urgency, 2) < floor:
            continue
        found[orc.stem] = {
            "from": scan_field(text, "from"),
            "purpose": scan_field(text, "purpose"),
            "urgency": urgency,
            "summary": scan_field(text, "summary"),
        }
    return found


def ring(sock_path: str, token: str, content: str) -> bool:
    """Deliver one line into the session's own socket. Format is Claude Code's own."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(sock_path)
        s.sendall((json.dumps({"type": "auth", "token": token}) + "\n").encode())
        s.sendall((json.dumps({
            "type": "user",
            "message": {"role": "user", "content": content},
        }) + "\n").encode())
        s.close()
        return True
    except OSError:
        return False


def compose(participant: str, msgs: dict[str, dict]) -> str:
    """The line Claude sees. Self-identifying — the socket wrapper calls it a peer."""
    n = len(msgs)
    head = (f"Post: {n} new message{'s' if n > 1 else ''} "
            f"in the inbox of '{participant}'. This is the doorbell, not another project.")
    lines = [head]
    for msg_id, m in sorted(msgs.items()):
        summary = m["summary"][:140] + ("…" if len(m["summary"]) > 140 else "")
        lines.append(f"  • [{m['urgency']}] {m['purpose']} from {m['from']}: {summary}  ({msg_id})")
    lines.append("Show these to the person and ask before acting on any of them; after handling: mark-read.py <msg_id>.")
    return "\n".join(lines)


def read_lease(lease_file: Path) -> float:
    """Expiry epoch written by the Stop hook; 0 when missing."""
    try:
        return float(lease_file.read_text().strip())
    except (OSError, ValueError):
        return 0.0


def socket_inode(sock_path: str) -> int | None:
    """Inode of the socket file — the identity check against PID reuse."""
    try:
        return os.stat(sock_path).st_ino
    except OSError:
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("participant")
    ap.add_argument("session_id")
    ap.add_argument("--lease", type=int, default=1800)
    ap.add_argument("--poll", type=int, default=15)
    args = ap.parse_args()

    sock_path = os.environ.get("CLAUDE_CODE_MESSAGING_SOCKET", "")
    token = os.environ.get("CLAUDE_CODE_MESSAGING_TOKEN", "")
    if not sock_path or not token:
        log(args.session_id, "no socket/token in environment — not started")
        return 0

    RING_DIR.mkdir(parents=True, exist_ok=True)
    lease_file = RING_DIR / f"{args.session_id}.lease"
    pid_file = RING_DIR / f"{args.session_id}.pid"
    pid_file.write_text(f"{os.getpid()}\n")
    if read_lease(lease_file) < time.time():
        lease_file.write_text(f"{time.time() + args.lease:.0f}\n")

    born_inode = socket_inode(sock_path)
    if born_inode is None:
        log(args.session_id, f"socket missing at start: {sock_path} — not started")
        return 0

    # Whatever is unread at spawn was already shown by SessionStart's peek; count it
    # as rung once so the bell is for NEW post, and re-rings only after backoff.
    floor = threshold_rank()
    polls_seen: dict[str, int] = {m: 1 for m in unread_at_or_above(args.participant, floor)}
    log(args.session_id, f"started pid={os.getpid()} participant={args.participant} "
                         f"floor={floor} pre-existing={len(polls_seen)}")

    try:
        while True:
            now = time.time()
            if now > read_lease(lease_file):
                log(args.session_id, "lease expired — exiting")
                break
            if socket_inode(sock_path) != born_inode:
                log(args.session_id, "socket gone or replaced — exiting (PID-reuse guard)")
                break

            floor = threshold_rank()
            unread = unread_at_or_above(args.participant, floor)

            # Forget anything no longer unread: someone read it — that silences it.
            for gone in [m for m in polls_seen if m not in unread]:
                polls_seen.pop(gone, None)

            due: dict[str, dict] = {}
            for msg_id, meta in unread.items():
                polls_seen[msg_id] = polls_seen.get(msg_id, 0) + 1
                if polls_seen[msg_id] in BACKOFF_POLLS:
                    due[msg_id] = meta

            if due:
                ok = ring(sock_path, token, compose(args.participant, due))
                log(args.session_id, f"rang for {sorted(due)} → {'delivered' if ok else 'FAILED'}")

            time.sleep(args.poll)
    finally:
        try:
            pid_file.unlink()
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
