#!/usr/bin/env bash
# ring-stop.sh — SessionEnd hook: kill this session's doorbell watcher.
#
# The primary defence against the PID-reuse hazard: sockets live at
# /tmp/cc-socks/<pid>.sock and the OS recycles PIDs, so a watcher that outlives its
# session could one day ring a stranger's door. The watcher also self-checks the
# socket's inode every poll; this hook is the belt to that brace.
#
# Fail-open, idempotent.
#                  → installed to ~/.claude/hooks/post-ring-stop.sh by install-hooks.sh

RING_DIR="$HOME/.claude/post/ring"
[ -d "$RING_DIR" ] || exit 0

INPUT="$(cat 2>/dev/null || true)"
SESSION_ID=""
CWD=""
if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
    SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
    CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
[ -z "$CWD" ] && CWD="$PWD"
if [ -z "$SESSION_ID" ] && [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ]; then
    SESSION_ID="sock-$(basename "$CWD")-$(basename "$CLAUDE_CODE_MESSAGING_SOCKET" .sock)"
fi
[ -n "$SESSION_ID" ] || exit 0

PID_FILE="$RING_DIR/$SESSION_ID.pid"
if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
fi
rm -f "$RING_DIR/$SESSION_ID.lease"
exit 0
