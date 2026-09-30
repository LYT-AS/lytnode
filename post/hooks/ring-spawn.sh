#!/usr/bin/env bash
# ring-spawn.sh — Stop hook: keep a doorbell watcher alive for this session.
#
# Runs when Claude finishes a turn. Two jobs, both cheap:
#   1. Extend the watcher's lease (one file write). Talking to the session keeps
#      its watcher alive; stop talking and it expires on its own.
#   2. If no watcher is running for this session, spawn one.
#
# The watcher (scripts/ring-watch.py) inherits CLAUDE_CODE_MESSAGING_SOCKET and
# CLAUDE_CODE_MESSAGING_TOKEN from THIS hook's environment — Claude Code exports
# both to every hook — and never writes either to disk. Verified 2026-09-03 that a
# nohup'd child re-parented to init can still deliver with the token.
#
# Fail-open: any missing piece means "no doorbell this session", never a stalled
# turn. Anti-stacking via a per-session PID file plus kill -0.
#
#                  → installed to ~/.claude/hooks/post-ring-spawn.sh by install-hooks.sh

[ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ] || exit 0
[ -n "${CLAUDE_CODE_MESSAGING_TOKEN:-}" ] || exit 0

RING_DIR="$HOME/.claude/post/ring"
WATCH="$HOME/.claude/skills/post/scripts/ring-watch.py"
PY="$HOME/.claude/skills/post/venv/bin/python3"
LEASE_SECONDS="${POST_RING_LEASE:-1800}"

[ -f "$WATCH" ] || exit 0
[ -x "$PY" ] || PY="$(command -v python3 || true)"
[ -n "$PY" ] || exit 0

INPUT="$(cat 2>/dev/null || true)"
SESSION_ID=""
CWD=""
if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
    SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
    CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
[ -z "$CWD" ] && CWD="$PWD"
# No session id → derive a stable one from the socket path (its PID) so the lease
# and PID files still key per session.
[ -z "$SESSION_ID" ] && SESSION_ID="sock-$(basename "$CWD")-$(basename "$CLAUDE_CODE_MESSAGING_SOCKET" .sock)"

# Resolve this cwd to a Post participant; no participant → no inbox → no bell.
PARTICIPANT="$("$PY" - "$CWD" <<'PYRES' 2>/dev/null || true
import sys
sys.path.insert(0, __import__("os").path.expanduser("~/.claude/skills/post"))
from archive import resolve_participant
print(resolve_participant(sys.argv[1]) or "")
PYRES
)"
[ -n "$PARTICIPANT" ] || exit 0

mkdir -p "$RING_DIR"
LEASE_FILE="$RING_DIR/$SESSION_ID.lease"
PID_FILE="$RING_DIR/$SESSION_ID.pid"

# 1. Extend the lease — wall clock, so a closed lid does not leave a zombie.
printf '%s\n' "$(( $(date +%s) + LEASE_SECONDS ))" > "$LEASE_FILE"

# 2. Already running? Then the lease extension was the whole job.
if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        exit 0
    fi
fi

# Spawn detached. Socket and token ride along in the environment, not in argv —
# argv is visible in `ps` to the same user; the environment of a foreign process is not.
nohup "$PY" "$WATCH" "$PARTICIPANT" "$SESSION_ID" --lease "$LEASE_SECONDS" \
    > /dev/null 2>&1 < /dev/null &
disown 2>/dev/null || true

exit 0
