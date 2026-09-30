#!/usr/bin/env python3
"""Post status overview — who sent what to whom.

Read-only. Reads the append-only log (~/.claude/post/log.md) and every
participant inbox, then prints a who->whom overview grouped by sender, with
unread counts per recipient. The L0 forerunner of the L2 Next.js front — same
read-first principle and fields, terminal instead of webapp.

Never touches messages. Stdlib only.

Usage:
  post-status.py                 # full overview
  post-status.py --by thread     # group by thread_id instead of sender
  post-status.py --unread        # only show unread
"""
from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from pathlib import Path

POST_ROOT = Path.home() / ".claude" / "post"
LOG = POST_ROOT / "log.md"
PROJECTS = POST_ROOT / "projects"


def parse_log() -> list[dict]:
    """Parse the append-only log into records. Tolerates the header line."""
    if not LOG.exists():
        return []
    records = []
    for line in LOG.read_text().splitlines():
        if "|" not in line or line.lstrip().startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 7:
            continue
        created, msg_id, frm, to, purpose, urgency, summary = parts[:7]
        records.append({
            "created": created, "msg_id": msg_id, "from": frm,
            "to": to, "purpose": purpose, "urgency": urgency, "summary": summary,
        })
    return records


def scan_field(text: str, key: str) -> str:
    prefix = key + ":"
    for line in text.splitlines():
        s = line.strip()
        if s.startswith(prefix):
            return s[len(prefix):].strip().strip('"').strip("'")
    return ""


# A message counts as seen once the recipient stamped anything past `unread`.
SEEN_STATES = {"read", "acked", "resolved"}


def delivery_state(msg_id: str, recipient: str) -> str:
    """Answer "has <recipient> seen <msg_id>?" from the synced ledger, not from a reply.

    Looks the message up where the recipient keeps it. inbox/, archive/ and
    tombstones/ all sync additively between machines, so the sender can read the
    recipient's own state off its own disk. This is what makes receipt-acks
    unnecessary: delivery and read-state are a lookup, never a message.
    """
    base = PROJECTS / recipient
    inbox_orc = base / "inbox" / f"{msg_id}.orc"
    if inbox_orc.exists():
        status = scan_field(inbox_orc.read_text(), "status") or "unread"
        return "SEEN" if status in SEEN_STATES else "UNREAD"

    archived = base / "archive" / f"{msg_id}.orc"
    if archived.exists():
        return "HANDLED"

    if (base / "tombstones" / f"{msg_id}.tombstone").exists():
        return "HANDLED"

    if (base / "trash" / f"{msg_id}.orc").exists():
        return "DISCARDED"

    # Not anywhere in the recipient's tree on THIS machine. Either the router
    # rejected it, or the recipient's side has not synced here yet.
    return "NOT-DELIVERED"


STATE_ICON = {
    "SEEN": "👁  seen, not yet handled",
    "UNREAD": "📬 not opened",
    "HANDLED": "✅ handled",
    "DISCARDED": "🗑  discarded",
    "NOT-DELIVERED": "❓ not delivered here (rejected, or not synced yet)",
}


def sent_report(pid: str, only_open: bool = False) -> int:
    """Print each message this participant sent, with the recipient's own state."""
    sent_dir = PROJECTS / pid / "sent"
    if not sent_dir.exists():
        print(f"post-status: no sent/ for '{pid}'", file=sys.stderr)
        return 1

    rows = []
    for orc in sorted(sent_dir.glob("*.orc")):
        text = orc.read_text()
        recipients = [r.strip().strip("[]'\"")
                      for r in scan_field(text, "to").strip("[]").split(",")
                      if r.strip()]
        for recipient in recipients:
            state = delivery_state(orc.stem, recipient)
            if only_open and state in ("HANDLED", "DISCARDED"):
                continue
            rows.append((orc.stem, recipient, scan_field(text, "purpose"),
                         scan_field(text, "urgency"), scan_field(text, "summary"),
                         state))

    if not rows:
        print(f"post-status: nothing sent from '{pid}'"
              + (" that is still open" if only_open else ""))
        return 0

    print(f"📤 Sent by {pid} — {len(rows)} delivery/deliveries\n")
    for msg_id, recipient, purpose, urgency, summary, state in rows:
        print(f"  {STATE_ICON.get(state, state)}")
        print(f"     → {recipient}  [{purpose}/{urgency}]  {msg_id}")
        if summary:
            print(f"     {summary[:100]}")
        print()
    return 0


def unread_by_participant() -> dict[str, int]:
    """Count unread .orc per participant inbox."""
    counts: dict[str, int] = {}
    if not PROJECTS.exists():
        return counts
    for pdir in sorted(PROJECTS.iterdir()):
        inbox = pdir / "inbox"
        if not inbox.exists():
            continue
        n = sum(1 for orc in inbox.glob("*.orc")
                if scan_field(orc.read_text(), "status") == "unread")
        if n:
            counts[pdir.name] = n
    return counts


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--by", choices=["sender", "thread"], default="sender")
    ap.add_argument("--unread", action="store_true", help="only count unread inboxes")
    ap.add_argument("--sent", metavar="PID",
                    help="what PID sent, with each recipient's own read-state")
    ap.add_argument("--open", action="store_true",
                    help="with --sent: hide deliveries already handled")
    args = ap.parse_args()

    if args.sent:
        return sent_report(args.sent, only_open=args.open)

    records = parse_log()
    if not records:
        print("No messages logged yet.")
        return 0

    unread = unread_by_participant()

    if args.unread:
        print("📬 Unread by participant:")
        if not unread:
            print("   (none)")
        for pid, n in sorted(unread.items(), key=lambda kv: -kv[1]):
            print(f"   • {pid}: {n} unread")
        return 0

    # who -> whom edges
    edges: dict[tuple, list[dict]] = defaultdict(list)
    key_field = "from" if args.by == "sender" else "thread"
    for r in records:
        # log doesn't store thread_id; group-by-thread falls back to summary tag
        group = r["from"] if args.by == "sender" else r["from"]
        for recipient in r["to"].split(","):
            edges[(group, recipient.strip())].append(r)

    print(f"📊 Post overview — {len(records)} message(s), grouped by {args.by}\n")
    current = None
    for (group, recipient), msgs in sorted(edges.items()):
        if group != current:
            print(f"{group}:")
            current = group
        by_purpose = defaultdict(int)
        for m in msgs:
            by_purpose[m["purpose"]] += 1
        breakdown = ", ".join(f"{n} {p}" for p, n in sorted(by_purpose.items()))
        ur = f" ({unread[recipient]} unread in inbox)" if recipient in unread else ""
        print(f"   → {recipient}: {breakdown}{ur}")

    if unread:
        total = sum(unread.values())
        print(f"\nTotal unread across all inboxes: {total}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
