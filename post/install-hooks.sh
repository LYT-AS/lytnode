#!/usr/bin/env bash
# install-hooks.sh — idempotent hook registration for Post.
#
# Registers these hook events in ~/.claude/settings.json:
#   PostToolUse(Write) → post-sniffer.sh      (auto-route outbox writes)
#   SessionStart       → inbox-peek.py        (surface unread on startup)
#   SessionStart       → spawn-sync-daemon.sh (start activity-gated sync daemon)
#   Stop               → sync-stop.sh         (teardown daemon + final flush)
#   Stop               → outbox-drain.sh      (route the outbox however it was written)
#   Stop               → ring-spawn.sh        (keep the doorbell watcher alive)
#   SessionEnd         → ring-stop.sh         (kill the watcher — PID-reuse guard)
#
# Also copies the hook scripts from the skill dir into ~/.claude/hooks/.
# Idempotent: running twice is a no-op. Hooks fast-exit when irrelevant
# (sniffer: path not in outbox; peek: empty inbox / unresolved participant).
#
# Usage:
#   install-hooks.sh           — copy scripts + register hooks
#   install-hooks.sh --check   — report which hooks are registered
#   install-hooks.sh --remove  — unregister post hooks
#
#   install-hooks.sh --project <dir> [--local] [--check | --remove]
#                              — the same, in <dir>/.claude/settings.json
#                                instead of ~/.claude/settings.json. Nothing
#                                is copied to ~/.claude/hooks/: the hooks run
#                                from the skill directory. <dir> must not be
#                                your home directory, whose .claude/settings.json
#                                IS the global file.
#                                --local: <dir>/.claude/settings.local.json,
#                                Claude Code's personal file for one project,
#                                which it applies over the shared settings.json
#                                and which is not meant to be committed.
#
# Run once after `sync skills`, then RESTART Claude Code for settings to apply.

set -euo pipefail

PROJECT_DIR=""
if [ "${1:-}" = "--project" ]; then
    # Added 2026-09-25 for the optional extra: hooks for ONE project. Without
    # --project nothing below changes — a rented node calls this script with
    # no argument and relies on the global behaviour.
    [ -n "${2:-}" ] || { echo "error: --project needs a directory" >&2; exit 64; }
    PROJECT_DIR="$(cd "$2" 2>/dev/null && pwd)" || { echo "error: no such directory: $2" >&2; exit 64; }
    if [ "${PROJECT_DIR}" = "$(cd "${HOME}" && pwd)" ]; then
        echo "error: --project is your home directory, whose .claude/settings.json is the" >&2
        echo "       global one. Name the project the hooks are for." >&2
        exit 64
    fi
    shift 2
fi
LOCAL=0
if [ "${1:-}" = "--local" ]; then
    [ -n "${PROJECT_DIR}" ] || { echo "error: --local needs --project <dir> first" >&2; exit 64; }
    LOCAL=1
    shift
fi
MODE="${1:-install}"
SETTINGS_PATH="${HOME}/.claude/settings.json"
SKILL_DIR="${HOME}/.claude/skills/post"
HOOKS_DIR="${HOME}/.claude/hooks"

if [ -n "${PROJECT_DIR}" ]; then
    SETTINGS_PATH="${PROJECT_DIR}/.claude/settings.json"
    [ "${LOCAL}" = 1 ] && SETTINGS_PATH="${PROJECT_DIR}/.claude/settings.local.json"
    if [ ! -f "${SETTINGS_PATH}" ] && [ "${MODE}" = "install" ]; then
        mkdir -p "${PROJECT_DIR}/.claude"
        printf '{}\n' > "${SETTINGS_PATH}"
        echo "created ${SETTINGS_PATH}"
    fi
    if [ ! -f "${SETTINGS_PATH}" ]; then
        echo "no ${SETTINGS_PATH} — no project hooks to ${MODE#--}"
        exit 0
    fi
fi

if [ ! -f "${SETTINGS_PATH}" ]; then
    echo "error: ${SETTINGS_PATH} not found — run Claude Code first" >&2
    exit 2
fi

# Copy hook scripts into ~/.claude/hooks/ (skip on --check, and in project
# mode, where the hooks run from the skill directory itself).
if [ "${MODE}" != "--check" ] && [ -z "${PROJECT_DIR}" ]; then
    mkdir -p "${HOOKS_DIR}"
    if [ "${MODE}" != "--remove" ]; then
        cp "${SKILL_DIR}/hooks/post-sniffer.sh"        "${HOOKS_DIR}/post-sniffer.sh"
        cp "${SKILL_DIR}/hooks/inbox-peek.py"          "${HOOKS_DIR}/post-inbox-peek.py"
        cp "${SKILL_DIR}/scripts/spawn-sync-daemon.sh" "${HOOKS_DIR}/post-spawn-sync.sh"
        cp "${SKILL_DIR}/hooks/sync-stop.sh"           "${HOOKS_DIR}/post-sync-stop.sh"
        cp "${SKILL_DIR}/hooks/outbox-drain.sh"        "${HOOKS_DIR}/post-outbox-drain.sh"
        cp "${SKILL_DIR}/hooks/ring-spawn.sh"          "${HOOKS_DIR}/post-ring-spawn.sh"
        cp "${SKILL_DIR}/hooks/ring-stop.sh"           "${HOOKS_DIR}/post-ring-stop.sh"
        chmod +x "${HOOKS_DIR}/post-sniffer.sh" \
                 "${HOOKS_DIR}/post-spawn-sync.sh" \
                 "${HOOKS_DIR}/post-sync-stop.sh" \
                 "${HOOKS_DIR}/post-outbox-drain.sh" \
                 "${HOOKS_DIR}/post-ring-spawn.sh" \
                 "${HOOKS_DIR}/post-ring-stop.sh"
    fi
fi

# On --remove: tear down a running sync daemon BEFORE unregistering its hooks,
# so no orphan keeps ssh-ing to the remote host forever.
if [ "${MODE}" = "--remove" ]; then
    SYNC_DIR="${HOME}/.claude/post/sync"
    rm -f "${SYNC_DIR}/active" 2>/dev/null || true
    if [ -f "${SYNC_DIR}/daemon.pid" ]; then
        DPID="$(cat "${SYNC_DIR}/daemon.pid" 2>/dev/null || true)"
        if [ -n "${DPID}" ] && kill -0 "${DPID}" 2>/dev/null; then
            kill "${DPID}" 2>/dev/null || true
        fi
    fi
    rm -f "${SYNC_DIR}/daemon.pid" "${SYNC_DIR}/last-sync" 2>/dev/null || true
fi

# THE VALUES TRAVEL IN THE ENVIRONMENT, never pasted into the program text
# (security finding 2026-09-25): a directory called `it's "mine"` broke the
# program it was pasted into, and a crafted name could have run code. The
# heredoc is quoted, so the shell expands nothing inside it.
SETTINGS_PATH="${SETTINGS_PATH}" HOOKS_DIR="${HOOKS_DIR}" MODE="${MODE}" \
PROJECT_DIR="${PROJECT_DIR}" SKILL_DIR="${SKILL_DIR}" python3 - <<'PYEOF'
import json
import os
import sys
from pathlib import Path

settings_path = Path(os.environ["SETTINGS_PATH"])
hooks_dir = os.environ["HOOKS_DIR"]
mode = os.environ["MODE"].lstrip("-")
project = os.environ["PROJECT_DIR"]
skill_dir = os.environ["SKILL_DIR"]

with open(settings_path) as f:
    settings = json.load(f)

settings.setdefault("hooks", {})
hooks = settings["hooks"]

# (event, matcher, command, timeout)
PY = f"{Path.home()}/.claude/skills/post/venv/bin/python3"
TARGETS = [
    ("PostToolUse", "Write", f"{hooks_dir}/post-sniffer.sh", 3000),
    ("SessionStart", "",     f"{PY} {hooks_dir}/post-inbox-peek.py", 5000),
    ("SessionStart", "",     f"{hooks_dir}/post-spawn-sync.sh", 5000),
    ("Stop", "",             f"{hooks_dir}/post-sync-stop.sh", 5000),
    # Routes whatever is in the outbox regardless of HOW it was written. The
    # PostToolUse sniffer above only sees the Write tool, so a message written with
    # a Bash heredoc never reached the router — measured 2026-09-03, unrouted for
    # twelve minutes. Matching on a tool name leaves the same hole for the next
    # writing method; this asks about the outbox's state instead.
    ("Stop", "",             f"{hooks_dir}/post-outbox-drain.sh", 5000),
    # The doorbell. Stop extends a per-session watcher's lease (and spawns it the
    # first time); SessionEnd kills it. The watcher rings the session's OWN socket
    # when new post lands — verified 2026-09-03 that own-child injection is
    # delivered mid-turn, also from a nohup'd process, using the token.
    ("Stop", "",             f"{hooks_dir}/post-ring-spawn.sh", 5000),
    ("SessionEnd", "",       f"{hooks_dir}/post-ring-stop.sh", 5000),
]
if project:
    # Project mode: the same seven hooks, run from the skill directory.
    # inbox-peek.py needs only the standard library, so without the skill's
    # environment the system python3 runs it rather than a missing path.
    if not Path(PY).exists():
        PY = "python3"
    TARGETS = [
        ("PostToolUse", "Write", f"{skill_dir}/hooks/post-sniffer.sh", 3000),
        ("SessionStart", "",     f"{PY} {skill_dir}/hooks/inbox-peek.py --ask-first", 5000),
        ("SessionStart", "",     f"{skill_dir}/scripts/spawn-sync-daemon.sh", 5000),
        ("Stop", "",             f"{skill_dir}/hooks/sync-stop.sh", 5000),
        ("Stop", "",             f"{skill_dir}/hooks/outbox-drain.sh", 5000),
        ("Stop", "",             f"{skill_dir}/hooks/ring-spawn.sh", 5000),
        ("SessionEnd", "",       f"{skill_dir}/hooks/ring-stop.sh", 5000),
    ]

def find_entry(event, matcher, command):
    for entry in hooks.get(event, []):
        if entry.get("matcher", "") != matcher:
            continue
        for h in entry.get("hooks", []):
            if h.get("command", "") == command:
                return h
    return None

def add_entry(event, matcher, command, timeout):
    hooks.setdefault(event, [])
    matching = next((e for e in hooks[event] if e.get("matcher", "") == matcher), None)
    new_hook = {"type": "command", "command": command, "timeout": timeout}
    if matching is None:
        hooks[event].append({"matcher": matcher, "hooks": [new_hook]})
    else:
        matching.setdefault("hooks", [])
        if command not in {h.get("command") for h in matching["hooks"]}:
            matching["hooks"].append(new_hook)

def remove_entry(event, matcher, command):
    entries = hooks.get(event, [])
    for entry in entries:
        if entry.get("matcher", "") != matcher:
            continue
        entry["hooks"] = [h for h in entry.get("hooks", []) if h.get("command") != command]
    hooks[event] = [e for e in entries if e.get("hooks")]
    if not hooks[event]:
        hooks.pop(event, None)

if mode == "check":
    print("Post hook registration status:")
    found = 0
    for event, matcher, command, _ in TARGETS:
        ok = find_entry(event, matcher, command) is not None
        print(f"  [{'OK' if ok else 'MISSING'}] {event} matcher={matcher!r}")
        found += 1 if ok else 0
    print(f"\n{found}/{len(TARGETS)} hooks registered")
    sys.exit(0)

if mode == "remove":
    removed = 0
    for event, matcher, command, _ in TARGETS:
        if find_entry(event, matcher, command) is not None:
            remove_entry(event, matcher, command)
            removed += 1
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print(f"removed {removed} post hook entries")
    sys.exit(0)

# install
added = 0
for event, matcher, command, timeout in TARGETS:
    if find_entry(event, matcher, command) is None:
        add_entry(event, matcher, command, timeout)
        added += 1

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print(f"installed {added} new post hook entries into {settings_path}")
print("RESTART Claude Code for settings.json changes to take effect")
PYEOF
