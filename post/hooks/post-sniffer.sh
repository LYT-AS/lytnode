#!/usr/bin/env bash
# Post sniffer — PostToolUse:Write hook.
#
# When a Write lands in ~/.claude/post/outbox/, drain the outbox by running
# route.py. Early-exits on every other Write (narrow matching — a hook that
# runs work on every Write would slow the whole agent down).
#
# Fail-open + async: never blocks the agent. route.py runs detached so the
# hook returns in <100ms regardless of routing time. After routing, the same
# detached subshell fires sync-post.sh so the message reaches the other machine
# at send-time (not on the next daemon tick) — the daemon is the backup, this is
# the primary cross-machine path. Tailscale rsync (~1s) stays off the agent loop.
#
#                  → installed to ~/.claude/hooks/ by install-hooks.sh

INPUT=$(cat)

# Parse the written file path. PostToolUse provides tool_input.file_path.
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# Early exit: only react to writes inside the post outbox.
OUTBOX="$HOME/.claude/post/outbox"
case "$FILE_PATH" in
  "$OUTBOX"/*) ;;            # match — fall through to routing
  *) exit 0 ;;              # everything else — instant return
esac

PY="$HOME/.claude/skills/post/venv/bin/python3"
ROUTE="$HOME/.claude/skills/post/route.py"
SYNC="$HOME/.claude/skills/post/sync-post.sh"

# Skill not deployed / venv missing → fail open silently.
[ -x "$PY" ] || exit 0
[ -f "$ROUTE" ] || exit 0

# Route, then sync — both detached so the hook never blocks the agent loop.
# Sync runs only if route delivered something (route.py exits 0 on "nothing to
# route" too, but sync-post.sh is a cheap no-op rsync when nothing changed).
# sync-post.sh is fail-open; absent → skip silently.
(
  cd "$HOME/.claude/skills/post" || exit 0
  "$PY" "$ROUTE" >/dev/null 2>&1
  [ -x "$SYNC" ] && bash "$SYNC" both >/dev/null 2>&1
) &

exit 0
