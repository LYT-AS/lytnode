#!/usr/bin/env python3
"""Initialize the Post runtime layout under ~/.claude/post/.

Reads the participant list (~/.claude/post/participants.json) and creates an
inbox/sent pair for each participant. Idempotent: safe to run repeatedly —
existing dirs and the append-only log are never clobbered.

No third-party deps (stdlib only).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

POST_ROOT = Path.home() / ".claude" / "post"
# The one participant list: {"id", "path"} rows, written by lytnode's setup,
# register.py and register-participant.py. See registry.md.
REGISTRY = POST_ROOT / "participants.json"

# Reserved synthetic participants that are not in the project registry but are
# first-class in the substrate from day 1 (brief §11.7 forward-compat).
RESERVED_PARTICIPANTS = ["human"]


def load_registry() -> list[dict]:
    """Return the list of registered participants, or [] if registry missing."""
    if not REGISTRY.exists():
        print(f"⚠️  Registry not found: {REGISTRY} — creating empty substrate.")
        return []
    try:
        data = json.loads(REGISTRY.read_text())
    except (json.JSONDecodeError, OSError) as exc:
        print(f"⚠️  Could not read registry ({exc}); creating empty substrate.")
        return []
    if not isinstance(data, list):
        print("⚠️  Registry is not a JSON array; creating empty substrate.")
        return []
    return data


def main() -> int:
    # Core runtime dirs.
    (POST_ROOT / "outbox").mkdir(parents=True, exist_ok=True)
    (POST_ROOT / "briefs").mkdir(parents=True, exist_ok=True)
    projects_dir = POST_ROOT / "projects"
    projects_dir.mkdir(parents=True, exist_ok=True)

    # Append-only global log — create empty, never overwrite.
    log = POST_ROOT / "log.md"
    if not log.exists():
        log.write_text("# Post — global message log (append-only)\n")

    created, existing = [], []
    participants = load_registry()
    ids = [p.get("id") for p in participants if isinstance(p, dict) and p.get("id")]
    ids += RESERVED_PARTICIPANTS

    for pid in ids:
        for sub in ("inbox", "sent"):
            d = projects_dir / pid / sub
            if d.exists():
                existing.append(str(d))
            else:
                d.mkdir(parents=True, exist_ok=True)
                created.append(str(d))

    print(f"Post runtime initialized at {POST_ROOT}")
    print(f"  Participants: {len(ids)} ({len(ids) - len(RESERVED_PARTICIPANTS)} registered + {len(RESERVED_PARTICIPANTS)} reserved)")
    print(f"  Created {len(created)} dirs, {len(existing)} already existed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
