# Which agent, and what differs

lyt-nodes works with Claude Code, Codex, Cursor, OpenCode, Gemini and pi. The
skill itself is identical for all six — Agent Skills is an open standard and
every one of them reads the same `SKILL.md`. What differs is the plumbing around it,
and it differs more than you would expect.

This page exists so you can look up the one row you need instead of debugging
it. Everything in it was measured against a real installation, not read off a
vendor page.

## At a glance

| | Claude Code | Codex | Cursor | OpenCode | Gemini | pi |
|---|---|---|---|---|---|---|
| Reads the skill from | `~/.claude/skills/` | `~/.agents/skills/` | `~/.agents/skills/`, `~/.cursor/skills/` | all of them | `~/.agents/skills/`, and the project | `~/.agents/skills/` |
| MCP config lives in | `claude mcp add` (user scope) | `~/.codex/config.toml` | `~/.cursor/mcp.json` | `opencode.json` | `~/.gemini/settings.json` | no MCP client: an extension in `~/.pi/agent/extensions/` |
| The URL key is called | `url` | `url` | `url` | `url` | **`httpUrl`** | — (`LYT_NODES_URL` overrides) |
| Your key stays out of the file | no | yes | yes | yes | yes | yes — read from `LYT_NODES_API_KEY` |
| Hook events | `SessionStart`, `PostToolUse` | same names | `sessionStart`, `postToolUse` | `session.created`, `tool.execute.*` | — | — |
| Hooks are | commands | commands, and must be **trusted** first | commands | a JavaScript module | — | — |
| Command deny-list | `permissions.deny` | **none** — OS sandbox | via hook | via plugin | — | **none** — no permission system |
| Headless flag for MCP | — | `--approve-for-me` | `--approve-mcps` | — | — | — |
| Project-local files (setup's menu) | `.claude/settings.local.json` (hooks); a project key in the local scope, in `~/.claude.json` | `.codex/config.toml` (read only in a trusted project), `.codex/lyt-hooks.toml` | `.cursor/mcp.json`, `.cursor/hooks.json` | `opencode.json`, `.opencode/plugins/lyt.js` | `.gemini/settings.json`, `.agents/skills/lyt-nodes/` | none: the key comes from `LYT_NODES_API_KEY` |

## The five things that catch people

**Claude Code is the only one that ignores `~/.agents/skills/`.** Everything
else reads it. The installer puts the skill there once and links
`~/.claude/skills/lyt-nodes` to it, so there is one directory to keep correct
rather than six copies.

**Gemini spells the MCP URL `httpUrl`.** `url` is the older SSE transport. Using
it connects to nothing and does not say so in a way that helps.

**Gemini will not read a global skill when headless.** Its sandbox is scoped to
the project. Install it per repository with `--agent gemini`.

**Codex has no command deny-list at all.** It confines a process with an
operating-system sandbox instead. That stops a wider class of things than a list
of patterns — including the ones nobody thought to list — but it cannot express
"everything except `git push`".

**Approval, not configuration, is what blocks MCP calls** on Codex and Cursor.
Both connect happily and then refuse to call. See
[troubleshooting.md](troubleshooting.md).

## What protects a node, and what does not

The deny-list is the cheap first line and nothing more. Prefix matching only
ever sees the outer command string, so `bash -c 'git push'` and
`git -C <path> push` walk straight past it.

**What actually prevents a node publishing is that it holds no push credentials
to your origin, and your own machine pulls the work home.** That is true in all
six agents, because it does not depend on the agent. Bypass every guard we
ship and there is still nothing to push to.

We say this plainly because a guard described as a boundary is a guard somebody
will eventually rely on as one.

## Choosing

Any of the six below will do the job. If you have no preference:

- **Claude Code** is the most complete integration, and the one with the longest
  history behind it here.
- **Codex** is the closest second: the same hook event names, and the key stays
  in your environment rather than in a file.
- **OpenCode** is the most open, and the only one where our plugin is code
  rather than configuration.
- **Cursor** shares its skills with Claude Code and Codex, so a skill you have
  already written works unchanged.
- **Gemini** works, with the two caveats above.
- **pi** works through its own extension rather than an MCP file. It has no
  permission system, so it never refuses on its own; export
  `LYT_NODES_API_KEY` in the shell you start it from.
