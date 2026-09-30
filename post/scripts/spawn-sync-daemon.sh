#!/usr/bin/env bash
# spawn-sync-daemon.sh — idempotent SessionStart spawner for the post sync daemon.
#
# Reads `cwd` from stdin JSON (it's a SessionStart hook), resolves the spawning
# session's transcript dir, writes the lifecycle marker, and nohup-spawns
# sync-daemon.py. Idempotent: if a daemon is already running, it's a no-op
# (anti-stacking guard via PID file + kill -0).
#
# All state under ~/.claude/post/sync/ — $HOME-resolved, runs on macOS and Linux.
#
#                  → copied to ~/.claude/hooks/post-spawn-sync.sh by install-hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve where sync-daemon.py actually lives. install-hooks.sh copies THIS
# spawner to ~/.claude/hooks/, where SCRIPT_DIR no longer holds the daemon —
# so prefer the canonical skill scripts dir, fall back to SCRIPT_DIR (repo run).
if [ -f "${HOME}/.claude/skills/post/scripts/sync-daemon.py" ]; then
    DAEMON_DIR="${HOME}/.claude/skills/post/scripts"
else
    DAEMON_DIR="${SCRIPT_DIR}"
fi
SYNC_DIR="${HOME}/.claude/post/sync"
MARKER="${SYNC_DIR}/active"
PIDFILE="${SYNC_DIR}/daemon.pid"

# NO PEERS, NO DAEMON (2026-09-25). The daemon syncs with the machines named in
# ~/.claude/post/peers.conf. With no such machine there is nothing to sync, and
# a process running in the background for nothing is exactly what the optional
# extra promised not to do. On a rented node the file is written before the
# session starts, so a node is unaffected. The outbox is still routed by the
# Stop hook (outbox-drain.sh) without the daemon.
PEERS_CONF="${HOME}/.claude/post/peers.conf"
if [ ! -f "${PEERS_CONF}" ] || ! grep -qvE '^[[:space:]]*(#|$)' "${PEERS_CONF}"; then
    exit 0
fi

mkdir -p "${SYNC_DIR}"

# Anti-stacking: if a live daemon already owns the PID file, do nothing.
if [ -f "${PIDFILE}" ]; then
    pid="$(cat "${PIDFILE}" 2>/dev/null || true)"
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
        echo "post sync daemon already running (pid ${pid})"
        exit 0
    fi
fi

# Resolve cwd from stdin JSON (same contract as inbox-peek.py / post-sniffer.sh).
CWD=""
if [ ! -t 0 ]; then
    INPUT="$(cat || true)"
    if [ -n "${INPUT}" ] && command -v jq >/dev/null 2>&1; then
        CWD="$(printf '%s' "${INPUT}" | jq -r '.cwd // empty' 2>/dev/null || true)"
    fi
fi
[ -z "${CWD}" ] && CWD="${PWD}"

# Encode cwd → ~/.claude/projects/<slug> (context-monitor convention: '/' → '-').
ENCODED="$(printf '%s' "${CWD}" | sed 's|/|-|g')"
PROJECTS_DIR="${HOME}/.claude/projects/${ENCODED}"

# Lifecycle marker — body mirrors the sidekick style for debuggability.
{
    echo "cwd: ${CWD}"
    echo "projects_dir: ${PROJECTS_DIR}"
    echo "started: $(date '+%Y-%m-%d %H:%M:%S')"
} > "${MARKER}"

# Prefer the post skill venv (stdlib-only daemon, but stay consistent).
DAEMON_PY="python3"
for candidate in \
    "${HOME}/.claude/skills/post/venv/bin/python3" \
    "${SCRIPT_DIR}/../venv/bin/python3"; do
    if [ -x "${candidate}" ]; then
        DAEMON_PY="${candidate}"
        break
    fi
done

nohup "${DAEMON_PY}" "${DAEMON_DIR}/sync-daemon.py" \
    --interval 30 \
    --projects-dir "${PROJECTS_DIR}" \
    > "${SYNC_DIR}/daemon.out" 2>&1 &
DAEMON_PID=$!
echo "${DAEMON_PID}" > "${PIDFILE}"

sleep 0.3
if kill -0 "${DAEMON_PID}" 2>/dev/null; then
    echo "post sync daemon started (pid ${DAEMON_PID})"
else
    echo "post sync daemon failed to start — see ${SYNC_DIR}/daemon.out" >&2
fi
exit 0
