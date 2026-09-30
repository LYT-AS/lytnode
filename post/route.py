#!/usr/bin/env python3
"""Post router (L0 sniffer/router).

Drains ~/.claude/post/outbox/: for each valid .orc + .md pair, copies the
message into every recipient's inbox (to + cc), appends one line to the
append-only log, moves the original into the sender's sent/, and files a copy
of any `brief` into briefs/YYYY/MM/.

Idempotent: dedup keyed on msg_id (won't re-deliver a message already logged).
Crash-robust: skips an .orc whose .md body isn't written yet (half-sent).

Deps: PyYAML (via skill venv) + stdlib.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from validate import EnvelopeError, parse_envelope, validate

POST_ROOT = Path.home() / ".claude" / "post"
OUTBOX = POST_ROOT / "outbox"
PROJECTS = POST_ROOT / "projects"
BRIEFS = POST_ROOT / "briefs"
LOG = POST_ROOT / "log.md"
# The one participant list: {id, path} rows (registry.md).
REGISTRY = POST_ROOT / "participants.json"


def load_known_ids() -> set[str]:
    """Participant ids from the participant list + reserved 'human'."""
    ids = {"human"}
    if REGISTRY.exists():
        try:
            data = json.loads(REGISTRY.read_text())
            ids |= {p["id"] for p in data if isinstance(p, dict) and p.get("id")}
        except (json.JSONDecodeError, OSError, KeyError):
            pass
    return ids


# Participant ids that count as a human authority. A directive may only come
# from one of these — never agent-to-agent.
#
# `human` is always in the set. Add an operator console, or any other id that
# speaks for a person, by listing it in POST_HUMAN_SENDERS, comma-separated:
#     POST_HUMAN_SENDERS=ops-console,desk
# An id you do not list is an agent, and an agent cannot issue a directive.
HUMAN_SENDERS = {"human"} | {
    part.strip() for part in os.environ.get("POST_HUMAN_SENDERS", "").split(",") if part.strip()
}


def sender_type_for(frm: str) -> str:
    """Classify a sender as 'human' or 'agent' — SET by the router, never self-declared.

    This is the anti-spoofing control: the .orc writer cannot set sender_type itself;
    route.py overwrites it at delivery based on the `from` id. Prepares for L4 auth.
    """
    return "human" if frm in HUMAN_SENDERS else "agent"


def created_iso(env: dict) -> str:
    """Return `created` as an ISO string.

    PyYAML auto-parses unquoted ISO timestamps into datetime objects, so the
    value may be either a str or a datetime. Normalize to str for slicing/log.
    """
    val = env.get("created")
    if isinstance(val, datetime):
        return val.isoformat()
    if isinstance(val, str) and val:
        return val
    return datetime.now(timezone.utc).isoformat()


def normalize_created(env: dict) -> str | None:
    """Stamp `created` with real UTC time if missing or future-dated. Returns new value or None.

    Defense in depth: agents hand-write a guessed round time into
    `created` (e.g. 11:00:00 while the clock says 10:22). The router overrides it
    with actual time when the field is absent or dated more than a skew margin in
    the future, so correctness no longer depends on what the writer guessed.
    """
    SKEW_SECONDS = 120  # tolerate minor clock drift on legitimate web-composed messages
    now = datetime.now(timezone.utc)
    val = env.get("created")
    parsed: datetime | None = None
    if isinstance(val, datetime):
        parsed = val
    elif isinstance(val, str) and val:
        try:
            parsed = datetime.fromisoformat(val)
        except ValueError:
            parsed = None
    # Missing/unparseable, or clearly future-dated → restamp.
    if parsed is None:
        return now.isoformat()
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    if (parsed - now).total_seconds() > SKEW_SECONDS:
        return now.isoformat()
    return None


def inject_created(orc: Path, created: str) -> None:
    """Write a corrected `created` value into the .orc frontmatter (stdlib line edit)."""
    try:
        lines = orc.read_text().splitlines()
    except OSError:
        return
    out: list[str] = []
    for line in lines:
        if line.strip().startswith("created:"):
            out.append(f"created: {created}")
            continue
        out.append(line)
    orc.write_text("\n".join(out) + "\n")


def already_logged(msg_id: str) -> bool:
    """Dedup: True if this msg_id already has a log line (idempotency)."""
    if not LOG.exists():
        return False
    return any(f"| {msg_id} |" in line for line in LOG.read_text().splitlines())


ALTERNATION_CAP = 10   # back-and-forth turns between one pair before the thread stops
ACK_RUN_CAP = 2        # consecutive acks between one pair before the next is refused


def _norm_summary(text: str) -> str:
    """Fold a summary to its comparable core, for spotting a message sent twice."""
    return " ".join(str(text).lower().split())


def _created_key(env: dict) -> datetime:
    """Sortable instant for a message, robust to how PyYAML happened to parse it.

    NEVER sort thread history on the raw `created` string. PyYAML turns an unquoted
    ISO timestamp into a datetime whose str() uses a SPACE separator, while a quoted
    one stays a string with a `T`. Space (0x20) sorts before `T` (0x54), so a
    lexicographic sort groups by YAML formatting instead of by time — measured
    2026-09-03 on thread 'flerspraak-2026-09', where every message from one
    participant sorted ahead of every message from the other regardless of clock.
    """
    raw = _isoformat_offset(created_iso(env))
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return datetime.min.replace(tzinfo=timezone.utc)
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _isoformat_offset(raw: str) -> str:
    """Rewrite a `+HHMM` / `Z` UTC offset into the `+HH:MM` form 3.9 can parse.

    `date "+%z"` — what the send flow tells agents to run — emits `+0200`, and
    Python 3.9's `fromisoformat` accepts ONLY what `isoformat()` itself produces.
    Measured 2026-09-03: identical code and tests passed on macOS and Linux
    (3.11+) and failed 4/22 on Python 3.9.6, where every timestamp fell back to
    `datetime.min` and thread ordering collapsed. Keep this until every machine is
    off 3.9 — the router must order threads the same way everywhere.
    """
    if raw.endswith("Z"):
        return raw[:-1] + "+00:00"
    tail = raw[-5:]
    if len(raw) > 5 and tail[0] in "+-" and tail[1:].isdigit():
        return raw[:-5] + tail[:3] + ":" + tail[3:]
    return raw


def pair_history(thread_id: str, a: str, b: str) -> list[dict]:
    """Every message of this thread exchanged between a and b, oldest first.

    Read from the participants' own `sent/` directories, which sync between machines
    additively — unlike `log.md`, which is deliberately machine-local. Counting from
    the log made the same thread pass on one machine and stop on the other (measured
    2026-09-03: 1 on the Mac, 5 on the server, for the same thread).

    Only the two participants' own outboxes are scanned, so cost stays bounded no
    matter how many projects exist, and a broadcast fan-in (many senders acking one
    human message) never inflates a pair's count.
    """
    if not thread_id:
        return []
    history: list[dict] = []
    for sender in {a, b, "human"}:
        sent_dir = PROJECTS / sender / "sent"
        if not sent_dir.exists():
            continue
        for orc in sent_dir.glob("*.orc"):
            try:
                env = parse_envelope(orc)
            except EnvelopeError:
                continue
            if str(env.get("thread_id", "")) != thread_id:
                continue
            recipients = {str(r) for r in (env.get("to") or [])}
            counterpart = b if sender == a else a
            # Keep human messages regardless of direction — they reset the chain.
            if sender != "human" and counterpart not in recipients:
                continue
            history.append({
                "created": _created_key(env),
                "from": str(env.get("from", "")),
                "purpose": str(env.get("purpose", "")),
                "summary": _norm_summary(env.get("summary", "")),
                "decision": env.get("decision"),
            })
    history.sort(key=lambda m: m["created"])

    # A human in the thread re-authorizes it: everything before that is forgiven.
    for i in range(len(history) - 1, -1, -1):
        if sender_type_for(history[i]["from"]) == "human":
            return history[i + 1:]
    return history


def loop_verdict(env: dict, history: list[dict]) -> str | None:
    """Return a refusal reason when this message would continue a runaway loop.

    Three guards, each catching what the others miss:

    - **Alternation cap.** A loop needs BOTH directions. Five one-way briefs are one
      project reporting progress, not a loop — the old counter refused exactly that
      (measured 2026-09-03) while letting an infinite ack↔ack chain through, because
      acks were exempt from counting altogether.
    - **Ack-run cap.** Two agents auto-acking each other is the actual runaway. One
      genuine clarification is allowed; the third consecutive ack is refused. Beyond
      that it is not a reply any more and belongs in a `query`/`info`.
    - **Repeat guard.** The same sender restating the same summary is a loop whatever
      the counters say. Borrowed from Claude Code's own cross-session dedup.

    An ack carrying `decision:` is NEVER refused: that is an approval answering a
    destructive-directive confirmation. Dropping one leaves the holder waiting forever
    for a `yes` that was rejected at the router.
    """
    if env.get("decision") is not None:
        return None

    summary = _norm_summary(env.get("summary", ""))
    sender = str(env.get("from", ""))
    if any(m["from"] == sender and m["summary"] == summary for m in history):
        return "identical summary already sent by this participant in this thread"

    if env.get("purpose") == "ack":
        # Count ALTERNATIONS inside the trailing ack run, not acks. One side answering
        # three separate briefs sends three acks in a row and is not looping — refusing
        # that repeats the very mistake the old one-way hop counter made (measured
        # 2026-09-03 on 'flerspraak-2026-09'). A loop is A-ack → B-ack → A-ack.
        run = []
        for m in reversed(history):
            if m["purpose"] != "ack":
                break
            run.append(m["from"])
        run.reverse()
        senders = run + [sender]
        bounces = sum(1 for i in range(1, len(senders)) if senders[i] != senders[i - 1])
        if bounces >= ACK_RUN_CAP:
            return (f"{bounces} acks bouncing back and forth in this thread — an ack "
                    "answering an ack is a loop; send a query/info with new content instead")

    alternations = sum(1 for i in range(1, len(history))
                       if history[i]["from"] != history[i - 1]["from"])
    if history and history[-1]["from"] != sender:
        alternations += 1
    if alternations >= ALTERNATION_CAP:
        return (f"{alternations} back-and-forth turns with no human in the thread "
                f"(cap {ALTERNATION_CAP})")
    return None


HOP_NOTIFIED_DIR = POST_ROOT / ".hop-notified"


def _hop_marker(thread_id: str) -> Path:
    """Filesystem-safe marker path for a thread's hop-cap notification."""
    safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in thread_id) or "_empty"
    return HOP_NOTIFIED_DIR / safe


def hop_already_notified(thread_id: str) -> bool:
    """True if we've already emailed the user that this thread hit the hop-cap."""
    return _hop_marker(thread_id).exists()


def mark_hop_notified(thread_id: str) -> None:
    """Record that this thread's hop-cap alert was sent, so later hits stay silent."""
    try:
        HOP_NOTIFIED_DIR.mkdir(parents=True, exist_ok=True)
        _hop_marker(thread_id).write_text(thread_id + "\n")
    except OSError:
        pass


def warn_user(message: str) -> None:
    """Says on stderr that a thread was stopped. The hook that runs the router shows stderr to the person; a rejected message stays in the outbox where they see it too."""
    print(f"⚠️  {message}", file=sys.stderr)


def log_line(env: dict) -> None:
    """Append one audit line. Append-only — never rewrites the log.

    thread_id + sender_type are appended LAST so older log lines (which lack them)
    still parse — readers index the leading fields and treat the tail as optional.
    """
    line = " | ".join([
        created_iso(env),
        env["msg_id"],
        str(env["from"]),
        ",".join(env["to"]),
        env["purpose"],
        env["urgency"],
        env["summary"].replace("\n", " "),
        str(env.get("thread_id", "")),
        str(env.get("sender_type", "")),
    ])
    with LOG.open("a") as fh:
        fh.write(line + "\n")


def inject_sender_type(orc: Path, sender_type: str) -> None:
    """Write the router-set sender_type into the .orc frontmatter (anti-spoof stamp).

    Replaces an existing `sender_type:` line or inserts one before the closing `---`.
    Stdlib-only line edit — the .orc stays valid YAML frontmatter.
    """
    try:
        lines = orc.read_text().splitlines()
    except OSError:
        return
    out: list[str] = []
    replaced = False
    fence_count = 0
    for line in lines:
        if line.strip() == "---":
            fence_count += 1
            # Insert before the SECOND fence (end of frontmatter) if not yet written.
            if fence_count == 2 and not replaced:
                out.append(f"sender_type: {sender_type}")
                replaced = True
            out.append(line)
            continue
        if line.strip().startswith("sender_type:"):
            out.append(f"sender_type: {sender_type}")
            replaced = True
            continue
        out.append(line)
    orc.write_text("\n".join(out) + "\n")


def is_tombstoned(rid: str, msg_id: str) -> bool:
    """True if this recipient already archived/trashed this msg_id (tombstone exists).

    Guards re-delivery: a tombstoned message is finished for that recipient — never
    re-land it in their inbox, even if the same msg_id is routed again.
    """
    return (PROJECTS / rid / "tombstones" / f"{msg_id}.tombstone").exists()


def deliver(orc: Path, body: Path, env: dict, known: set[str]) -> list[str]:
    """Copy .orc + .md into each recipient inbox. Returns warnings."""
    warnings: list[str] = []
    recipients = list(env["to"]) + list(env.get("cc") or [])
    for rid in recipients:
        if rid not in known:
            warnings.append(f"unknown recipient '{rid}' — skipped")
            continue
        if is_tombstoned(rid, env["msg_id"]):
            warnings.append(f"tombstoned for '{rid}' — not re-delivered")
            continue
        inbox = PROJECTS / rid / "inbox"
        inbox.mkdir(parents=True, exist_ok=True)
        shutil.copy2(orc, inbox / orc.name)
        shutil.copy2(body, inbox / body.name)
    return warnings


def file_brief(orc: Path, body: Path, env: dict) -> None:
    """File a copy of any `brief` into the shared briefs/ library."""
    if env["purpose"] != "brief":
        return
    created = created_iso(env)
    yyyy, mm = created[:4], created[5:7]
    dest = BRIEFS / yyyy / mm
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copy2(orc, dest / orc.name)
    shutil.copy2(body, dest / body.name)


def move_to_sent(orc: Path, body: Path, env: dict) -> None:
    """Move the original .orc + .md into the sender's sent/."""
    sent = PROJECTS / str(env["from"]) / "sent"
    sent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(orc), sent / orc.name)
    if body.exists():
        shutil.move(str(body), sent / body.name)


def process_one(orc: Path, known: set[str]) -> tuple[bool, list[str]]:
    """Route a single .orc. Returns (delivered, warnings)."""
    try:
        env = parse_envelope(orc)
    except EnvelopeError as exc:
        return False, [f"REJECTED {orc.name}: {exc}"]

    errors = validate(env, source=orc.name)
    if errors:
        return False, [f"REJECTED {orc.name}: " + "; ".join(errors)]

    # Authority control: SET sender_type from `from` (never trust a self-declared
    # value) — anti-spoofing. Then enforce: a `directive` may only come from a human
    # authority (see HUMAN_SENDERS). Agent-to-agent directives are rejected so
    # one project can't command another (the "agent asks agent to delete" case).
    env["sender_type"] = sender_type_for(str(env.get("from", "")))
    if env["purpose"] == "directive" and env["sender_type"] != "human":
        return False, [
            f"REJECTED {orc.name}: directive from '{env['from']}' (sender_type=agent) — "
            "only a human authority may issue directives"
        ]

    # Anti-runaway: stop a genuine agent↔agent loop without muzzling a project that
    # simply has several things to report. A human hop re-authorizes the chain.
    thread_id = str(env.get("thread_id", ""))
    if env["sender_type"] != "human":
        for recipient in [str(r) for r in env["to"]]:
            reason = loop_verdict(env, pair_history(thread_id, str(env["from"]), recipient))
            if not reason:
                continue
            # Warn ONLY the first time this thread trips. Every later message is
            # still refused, but a marker suppresses the repeat — otherwise 15
            # messages to a dead thread means 15 identical warnings.
            if not hop_already_notified(thread_id):
                warn_user(
                    f"Post thread stopped: '{thread_id}' — {reason} "
                    f"(latest: {env['from']} → {recipient}). Send a human hop in the "
                    "thread to reopen it, or let it die."
                )
                mark_hop_notified(thread_id)
            return False, [
                f"REJECTED {orc.name}: thread '{thread_id}' → {recipient}: {reason}. "
                "Reply with new content, or have a human send one message in the thread."
            ]

    # Time control: override a missing/future-dated `created` with real UTC time
    # — agents guess round timestamps; the router stamps the truth.
    corrected = normalize_created(env)
    if corrected is not None:
        env["created"] = corrected
        inject_created(orc, corrected)

    # Crash-robustness: body must exist before we route (half-sent guard).
    body = orc.parent / Path(env["links"]["body"]).name
    if not body.exists():
        return False, [f"DEFERRED {orc.name}: body {body.name} not written yet"]

    if already_logged(env["msg_id"]):
        return False, [f"SKIP {orc.name}: msg_id already delivered (idempotent)"]

    # Stamp the router-set sender_type into the .orc before copying to inboxes,
    # so recipients see the authoritative value (not whatever the writer declared).
    inject_sender_type(orc, env["sender_type"])
    warnings = deliver(orc, body, env, known)
    file_brief(orc, body, env)
    log_line(env)
    move_to_sent(orc, body, env)
    return True, warnings


def main() -> int:
    if not OUTBOX.exists():
        print(f"outbox not found: {OUTBOX} — run init-post.py first", file=sys.stderr)
        return 1

    known = load_known_ids()
    orcs = sorted(OUTBOX.glob("*.orc"))
    if not orcs:
        print("outbox empty — nothing to route.")
        return 0

    delivered = 0
    for orc in orcs:
        ok, msgs = process_one(orc, known)
        for m in msgs:
            print(("  " if ok else "⚠️  ") + m)
        if ok:
            delivered += 1
            print(f"✓ routed {orc.name}")

    print(f"\nRouted {delivered}/{len(orcs)} message(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
