#!/usr/bin/env bash
# outbox-drain.sh — Stop hook: route whatever is sitting in the post outbox.
#
# WHY THIS EXISTS, and why it does not match on a tool name:
#
# `post-sniffer.sh` routes on PostToolUse:Write and keys on `tool_input.file_path`.
# A message written with a Bash heredoc therefore never triggers it — measured
# 2026-09-03 in a real project, where a correctly-formed ack sat unrouted in the
# outbox for twelve minutes. The envelope was textbook (all twelve template fields,
# three reply_to refs), so the skill HAD been followed; SKILL.md simply never said
# which tool to write with.
#
# That is the failure class: routing was coupled to HOW the file was created rather
# than to the fact that a file is waiting. Any fix that still matches a tool name
# keeps the same hole open for the next way of writing a file. So this hook asks one
# question — is the outbox non-empty? — and answers it at a moment that arrives no
# matter how the message got there.
#
# Stop fires when Claude finishes a turn. Its blind spot is the autonomous loop,
# where a turn stays open for a long time; `sync-daemon.py` covers that by draining
# on its own tick. Neither costs a process per tool call, which a Bash matcher would.
#
# Fail-open and async: never blocks the agent, never delays a turn ending.
#
#                  → installed to ~/.claude/hooks/ by install-hooks.sh

OUTBOX="$HOME/.claude/post/outbox"
[ -d "$OUTBOX" ] || exit 0

# Cheap state check: nothing staged → instant return, no interpreter spawned.
# A lone .orc whose .md has not landed yet is deferred by route.py, so it is safe
# to fire on any .orc present.
set -- "$OUTBOX"/*.orc
[ -e "$1" ] || exit 0

PY="$HOME/.claude/skills/post/venv/bin/python3"
ROUTE="$HOME/.claude/skills/post/route.py"
SYNC="$HOME/.claude/skills/post/sync-post.sh"

[ -x "$PY" ] || exit 0
[ -f "$ROUTE" ] || exit 0

# Detached so the hook returns immediately; routing and cross-machine sync run
# off the agent loop exactly as in post-sniffer.sh.
(
  cd "$HOME/.claude/skills/post" || exit 0
  "$PY" "$ROUTE" >/dev/null 2>&1
  [ -x "$SYNC" ] && bash "$SYNC" both >/dev/null 2>&1
) &

exit 0
