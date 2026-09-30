# post

A mailbox for coding agents. Files in a folder, not a server.

## The problem

If you run more than one agent, two things go wrong sooner or later.

**You cannot tell whether a long job is done, stuck or waiting for you.** You
start an agent on something that takes an hour. It finishes, or hits a question
it cannot answer, or stops on a permission prompt. From the outside those three
look the same: a quiet window. The only way to know is to go and look.

**Your projects cannot tell each other anything.** The API project changes an
endpoint, and the web project needs to know. Today the channel between them is
you, remembering to say it.

## What post does

Every project gets an inbox and an outbox, as plain files. An agent that is
blocked writes a `blocker` and carries on or stops; you see it the next time you
are there, and so does the agent in the other project. One project can ask
another a question without you in the middle.

A message is two files: a short envelope (`.orc`, YAML) that says who it is
from, who it is for and what kind of message it is, and a body (`.md`) that a
person reads. A router copies each message from the outbox into the right
inboxes. In Claude Code, hooks route on write and show unread mail when a
session starts; with any other agent you run the router yourself.

## Why it gives you control

Agents that can message each other can also talk each other into things. Three
limits are enforced by the router, in code, not left to the agent's judgement:

- **An agent cannot give another agent an order.** The router works out
  `sender_type` from the sender's id itself; a message cannot declare it. A
  `directive` from any id that is not a person is refused at delivery. This
  stops agents that follow the rules, not a hostile one: anything that can
  write to your outbox can also write `from: human`.
- **Loops stop on their own.** Three guards (back-and-forth turns between a
  pair, consecutive acks, and the same sender repeating itself) stop two agents
  answering each other for ever. A person joining the thread resets them.
  `tests/test_loop_guards.py` covers all three.

Two more rules live in the skill's instructions, not the router, and an
instruction is weaker than code:

- **Replies carry outcomes, not receipts.** The skill tells the agent never to
  send an `ack` that only says "received". Whether a message was read is looked
  up with `post-status.py`, not sent as another message.
- **An old task is not carried out blind.** A task older than six hours is
  summarised and asked about first, because the situation may have moved on
  since it was written.

## Your first message

Run in an empty home directory on 2026-09-23, with Python 3 and `venv`.

```bash
mkdir -p ~/.claude/skills
cp -r post ~/.claude/skills/post
bash ~/.claude/skills/post/setup_venv.sh
PY=~/.claude/skills/post/venv/bin/python3
```

List the projects that take part in `~/.claude/post/participants.json`:

```json
[
  {"id": "api", "name": "API", "path": "~/code/api"},
  {"id": "web", "name": "Web", "path": "~/code/web"}
]
```

```bash
$PY ~/.claude/skills/post/init-post.py
```

```
Post runtime initialized at /home/you/.claude/post
  Participants: 3 (2 registered + 1 reserved)
```

Write a message into `~/.claude/post/outbox/`: the envelope
`2026-09-23T17-44-41_api_a1b2.orc` (the template is in `SKILL.md`, with
`from: api`, `to: [web]`, `purpose: blocker`) and a body with the same name
ending in `.md`. Then route it:

```bash
$PY ~/.claude/skills/post/route.py
$PY ~/.claude/skills/post/post-status.py
```

```
✓ routed 2026-09-23T17-44-41_api_a1b2.orc
📊 Post overview — 1 message(s), grouped by sender
api:
   → web: 1 blocker (1 unread in inbox)
```

The same envelope with `purpose: directive` is refused:

```
⚠️  REJECTED ...: directive from 'api' (sender_type=agent) — only a human authority may issue directives
```

In Claude Code, `install-hooks.sh --project <dir>` makes routing and the inbox
check automatic in that one project, and `--project <dir> --remove` takes it
out again. A project gets its own inbox when it is in the participant
list: `python3 ~/.claude/skills/post/register.py <dir>` adds it (your agent asks
first when it finds a project that is not there). What each hook does, and how to switch it off:
[docs/hooks.md](../docs/hooks.md).

## What post is not

No server, no network protocol, no encryption, no accounts: files in a folder.
Between machines it syncs over ssh, only when you ask (`sync-post.sh`).

## Licence

Apache-2.0 ([LICENSE](LICENSE), [NOTICE](NOTICE)). It needs no LYT account and
makes no call to any LYT service, so use it in your own projects, with or
without the rest of this package, which is under a narrower licence.
