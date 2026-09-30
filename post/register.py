#!/usr/bin/env python3
"""Adds a project directory to the post participant list, so its inbox is found and its doorbell rings."""
#
#   python3 register.py <project dir> [id]    add it (idempotent)
#   python3 register.py --check <project dir>  say whether it is registered
#
# The list is ~/.claude/post/participants.json: one {"id", "path"} per
# participant, the same file lytnode's setup writes and every post reader
# uses. A session in a directory resolves
# to the participant whose path is the LONGEST prefix of it, so registering a
# project gives that project its own inbox, while everything else in the home
# directory stays with "human".
#
# Nothing here asks anything: the agent asks the person first ("this project is
# not in the post system - shall I add it?") and runs this only on a yes.
# Added 2026-09-25 (owner: the doorbell never rang on a customer's machine,
# because no list it could read named their project).
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

POST_ROOT = Path.home() / ".claude" / "post"
PARTICIPANTS = POST_ROOT / "participants.json"
RESERVED = {"human"}


def die(code: int, message: str) -> None:
    """Prints a failure on stderr and exits with the given code."""
    print(f"register: {message}", file=sys.stderr)
    sys.exit(code)


def load() -> list[dict]:
    """Returns the participant list, or an empty list when there is none yet."""
    if not PARTICIPANTS.exists():
        return []
    try:
        data = json.loads(PARTICIPANTS.read_text())
    except (json.JSONDecodeError, OSError) as exc:
        die(1, f"cannot read {PARTICIPANTS}: {exc}")
    if not isinstance(data, list):
        die(1, f"{PARTICIPANTS} is not a list")
    return data


def save(entries: list[dict]) -> None:
    """Writes the list atomically: a reader never sees half a file."""
    POST_ROOT.mkdir(parents=True, exist_ok=True)
    tmp = PARTICIPANTS.with_name(PARTICIPANTS.name + ".tmp")
    tmp.write_text(json.dumps(entries, indent=2) + "\n")
    os.replace(tmp, PARTICIPANTS)


def resolved(path: str) -> Path | None:
    """The absolute, resolved form of a path, or None when it cannot be resolved."""
    try:
        return Path(path).expanduser().resolve()
    except OSError:
        return None


def entry_for(entries: list[dict], directory: Path) -> dict | None:
    """The entry whose path is exactly this directory, if any."""
    for e in entries:
        if isinstance(e, dict) and "path" in e and resolved(str(e["path"])) == directory:
            return e
    return None


def main(argv: list[str]) -> int:
    """Registers a directory, or checks whether one is registered."""
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        print("usage: register.py <project dir> [id]  |  register.py --check <project dir>")
        return 0 if argv else 64

    check = argv[0] == "--check"
    args = argv[1:] if check else argv
    if not args:
        die(64, "name the project directory")
    directory = resolved(args[0])
    if directory is None or not directory.is_dir():
        die(64, f"no such directory: {args[0]}")

    # The home directory is not a project: every session under it already
    # resolves to "human", which is listed first. A project row at the same
    # path would tie with it, the readers would pick "human", and a node told
    # to report to the project would write to an inbox nobody reads (QC
    # 2026-09-25).
    if directory == Path.home().resolve():
        die(64, "the home directory is not a project; sessions there already use the general inbox")

    entries = load()
    existing = entry_for(entries, directory)

    if check:
        if existing:
            print(f"registered as {existing['id']}")
            return 0
        print("not registered")
        return 1

    if existing:
        print(f"already registered as {existing['id']}: {directory}")
        return 0

    wanted = args[1] if len(args) > 1 else directory.name
    if not wanted or wanted in RESERVED or any(c in wanted for c in "/\\ \t\n"):
        die(64, f'"{wanted}" cannot be a participant id; give another: register.py {directory} <id>')
    taken = next((e for e in entries if isinstance(e, dict) and e.get("id") == wanted), None)
    if taken:
        die(1, f'the id "{wanted}" is taken by {taken.get("path")}; give another: register.py {directory} <id>')

    # "human" at the home directory first, if the list has no such row yet:
    # it is what every other directory resolves to, and what lytnode's setup
    # writes first.
    home = Path.home().resolve()
    if not any(isinstance(e, dict) and e.get("id") == "human" for e in entries):
        entries.insert(0, {"id": "human", "path": str(home)})
    # "kind": "project" marks a row as a place the person works, as opposed to
    # the rows naming rented nodes (path /data/agentwork on the node). The post
    # readers use only id and path; agentwork.sh uses the mark to choose which
    # inbox a node reports to.
    entries.append({"id": wanted, "path": str(directory), "kind": "project"})
    save(entries)
    for sub in ("inbox", "sent"):
        (POST_ROOT / "projects" / wanted / sub).mkdir(parents=True, exist_ok=True)
    print(f"registered {directory} as {wanted}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
