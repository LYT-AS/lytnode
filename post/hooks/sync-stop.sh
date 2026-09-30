#!/usr/bin/env bash
# sync-stop.sh — Stop hook: tear down the post sync daemon + final flush.
#
# Deletes the lifecycle marker (the daemon self-exits on its next tick),
# proactively kills the daemon PID for a clean state, then runs ONE final
# sync-post.sh to flush this session's outgoing messages before exit.
#
# Fail-open everywhere — never blocks session shutdown.
#
#                  → copied to ~/.claude/hooks/post-sync-stop.sh by install-hooks.sh

SYNC_DIR="${HOME}/.claude/post/sync"
MARKER="${SYNC_DIR}/active"
PIDFILE="${SYNC_DIR}/daemon.pid"
SYNC_SCRIPT="${HOME}/.claude/skills/post/sync-post.sh"

# 1. Delete marker → daemon exits on next tick.
rm -f "${MARKER}" 2>/dev/null || true

# 2. Proactively kill the daemon for immediate clean state.
if [ -f "${PIDFILE}" ]; then
    pid="$(cat "${PIDFILE}" 2>/dev/null || true)"
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}" 2>/dev/null || true
    fi
fi
rm -f "${PIDFILE}" 2>/dev/null || true

# 3. One final flush so this session's last messages reach the other machine.
if [ -x "${SYNC_SCRIPT}" ]; then
    bash "${SYNC_SCRIPT}" both >/dev/null 2>&1 || true
fi

exit 0
