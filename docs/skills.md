# The two skills

A skill is a folder with a `SKILL.md` in it. The file starts with a short
description, and your agent reads the rest only when a task matches that
description. Nothing runs until then; a skill costs your agent a line of
attention until it is needed.

Skills became an open standard on 2025-12-18 (<https://agentskills.io>). Claude
Code, Codex, Cursor, OpenCode, Gemini and pi all read the same `SKILL.md`. Both skills here
use only the fields the standard defines, so one copy works in all of them.

| Skill | What it does for you | Say something like | Installed to | Licence |
|---|---|---|---|---|
| `lyt-nodes` | Rents a machine, starts your agent on it, sends it a job, brings the work home on a branch, and releases the machine | "rent a node for two hours", "send this job to the node", "bring the work home", "release the node" | `~/.claude/skills/lyt-nodes/` for Claude Code, `~/.agents/skills/lyt-nodes/` for the others | [LYT Node Client License](https://github.com/LYT-AS/lytnode/blob/main/LICENSE.md) |
| `post` | A mailbox between your agents and your projects: a blocked agent says so, and one project can ask another without you in the middle | "check my inbox", "send a blocker to web", "who has sent what" | `~/.claude/skills/post/` | [Apache-2.0](https://github.com/LYT-AS/lytnode/blob/main/post/LICENSE) |

You do not have to use the exact words. The agent matches on meaning, in any
language.

## lyt-nodes

Comes with `setup.sh`, which installs it for the agent you name. It needs an
API key from your account, and it is what the rest of this package is for.
Setup: [setup.md](setup.md). Each agent's quirks: [agents.md](agents.md).

## post

Needs nothing from us: no account, no key, no network. It is here because the
nodes use it to tell you when a job is finished or stuck, but it works just as
well between two projects on your own laptop. Why you might want it, and your
first message: [post/README.md](https://github.com/LYT-AS/lytnode/blob/main/post/README.md). It is an optional extra of
`setup.sh` (`--with-post`); every hook it adds, what it does and how to switch
it off: [hooks.md](hooks.md).
