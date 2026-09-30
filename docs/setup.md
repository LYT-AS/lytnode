# From nothing to a rented node

One command on **your** machine. Everything else is a sentence to your agent.

## 0. Or let your agent do it

[first-node.md](first-node.md) is the same setup as a set of instructions for
your coding agent. Give it that file and answer its questions along the way;
you never open a terminal.

## Before you run it

- an API key (`lyt_live_...`) from <https://node.lyt.no/account/keys>
- Tailscale installed and signed in on this machine: a node joins your own
  Tailscale network, and that is how you reach it
- for each order, a new Tailscale auth key from
  <https://login.tailscale.com/admin/settings/keys> with exactly
  `reusable=false`, `preauthorized=true` and `ephemeral=false`

## 1. Run setup

```bash
git clone https://github.com/LYT-AS/lytnode lytnode
cd lytnode
bash setup.sh --agent claude        # or codex, cursor, opencode, gemini, pi
```

It asks for one thing, your API key (`lyt_live_...`, from
<https://node.lyt.no/account/keys>, pasted without echo), and for Claude Code it opens the browser once for
`claude setup-token`. Have `LYT_NODES_API_KEY` in your shell and it asks
nothing; add `--non-interactive` and it never prompts at all (it then exits 2
without a key, and hands the Claude sign-in to a helper that prints the
address: `lyt-node-core/claude-token.py`, fetched by setup.sh; see
[first-node.md](first-node.md)).

To remove everything it put in place: `bash uninstall.sh`. It names what it
removes and never touches your ssh keys. It asks before it removes the client
setup.sh fetched into the clone; `--yes` skips the question and `--dry-run`
lists every path without removing anything.

## 2. What setup.sh does

In order, and nothing more:

1. checks `git ssh ssh-keygen curl tar jq rsync python3` and the agent you chose, and
   names every missing one at once
2. makes the two ssh key pairs the double lock needs (`~/.ssh/id_ed25519` for
   login, `~/.ssh/lytnode_cert` for the certificate) if they do not exist;
   never over an existing one
3. stores your key in `~/.config/lytnode/api-key` (mode 600), or with
   `--key-scope project` in `<project>/.lytnode/api-key`, kept out of git
4. fetches the licensed part of the package - the skill, the agent adapters
   and `install.sh` - from `<url>/api/package.tar.gz` with your key, and
   unpacks it here beside the files you cloned. This step runs every time, and
   it is how you update: run `setup.sh` again
5. puts `Include ~/.ssh/lytnode.conf` first in `~/.ssh/config`, so
   `ssh <node>` works after a rental
6. runs `install.sh --agent <name> --no-models` (from step 4, not from the
   clone)
7. registers the MCP server as **`lytnode`** at `https://nodes.lyt.no/mcp`
   (Claude Code: `connect.sh` runs `claude mcp add` and makes a real call
   before it says anything went fine; the others read the template
   `install.sh` put in place; pi gets an extension instead)
8. Claude Code only: `claude setup-token`, kept in
   `~/.config/lytnode/claude-token` (mode 600). `~/.claude/skills/lyt-nodes/agentwork.sh start` carries it
   to your node over your own ssh, so a node never asks you to log in. The
   token is yours; it never passes through us
9. remembers the URL, the agent and your answers to the menu in
   `~/.config/lytnode/`

The choices behind 3, 6 and 7 are made in the menu below, first. Every
hook: [hooks.md](hooks.md).

Setup also checks for Tailscale and warns, without stopping, if it is missing.

**Never put the key in a repository.** A key in git history stays there, in
every clone and every fork.

## The menu: what setup asks first

Before it writes anything, setup shows one list with a default for each
choice. Type a number to change one; Enter goes on. Every choice has a flag,
and a flag you give shows as already chosen. With no terminal there is no
menu to show, so setup prints the questions with their flags, names your
agent's own question tool, and stops with exit 5 before writing anything;
the agent asks you, then runs it again with `--non-interactive` and your
answers as flags. `--non-interactive` alone means the defaults, and your flags.

| # | Choice | Default | Flag | What it writes, and where | How to undo |
|---|---|---|---|---|---|
| 1 | Message channel: a node tells your session here when a job is done or blocked | no | `--with-post` / `--without-post` | the `post` skill, a small Python environment beside it, and a participant list in `~/.claude/post/` | `bash uninstall.sh` |
| 2 | Hooks for your agent (with 1 only) | project | `--hooks project` / `--hooks global` | project: Claude Code `.claude/settings.local.json`, Codex `.codex/lyt-hooks.toml` (to append to `.codex/config.toml`), Cursor `.cursor/hooks.json`, OpenCode `.opencode/plugins/lyt.js`, all in the project. global: Claude Code `~/.claude/settings.json`, Codex `~/.codex/lyt-hooks.toml` (to append to `~/.codex/config.toml`), Cursor `~/.cursor/hooks.json`, OpenCode `~/.config/opencode/plugins/lyt.js` | `bash uninstall.sh` |
| 3 | A node may push messages to this machine (with 1 only) | as 1 | `--node-push yes` / `--node-push no` | at each start, the node's key in your `~/.ssh/authorized_keys`, so a message arrives at once. Without it, messages come home with the work | run setup again with `--node-push no`, and remove the node's line from `~/.ssh/authorized_keys` |
| 4 | The node guard on this machine too (with 1 only) | no | `--guard yes` / `--guard no` | your own Cursor and OpenCode also refuse `git push` and similar, as a rented node does | run setup again with `--with-post --guard no`; for Cursor delete our `hooks.json` first, since setup never writes over one |
| 5 | API key for | user | `--key-scope user` / `--key-scope project` | user: `~/.config/lytnode/api-key`, for every project. project: `<project>/.lytnode/api-key`, and the agent's own files for this project with that key: Claude Code's local scope (in `~/.claude.json`, not in the project), Codex `.codex/config.toml`, Cursor `.cursor/mcp.json`, OpenCode `opencode.json`, Gemini `.gemini/settings.json` | `bash uninstall.sh` (`--keep-credentials` keeps the key) |

**Which key is used where.** A key in `LYT_NODES_API_KEY` wins everywhere.
Without it, the node script and `connect.sh` use the nearest
`.lytnode/api-key` above the directory they run in, and otherwise
`~/.config/lytnode/api-key`. So a project with its own key uses it, and every
other project the key for all projects. `.lytnode/` has its own `.gitignore`,
which keeps the key out of git also before anything else is written. In a
project that is not a git repository, no other file may carry the key (a
later `git add` would take it along): there the agent's settings stay in your
home directory and read `LYT_NODES_API_KEY`, and setup prints how to start
the agent with this project's key.

`--project <dir>` names the project; the default is the directory the clone
sits in. If that is your home directory, there is no project: setup says so,
project hooks are left out and the key is kept for all projects.

**Kept out of your git.** Everything setup writes inside the project - the
clone itself, the personal settings file, the project key, the files above -
is listed in `.git/info/exclude`: git's own list for this machine only, never
committed, and not your `.gitignore`. Our lines sit in one marked block, and
`bash uninstall.sh` removes that block and nothing else.

**What setup never touches:** your `.gitignore`, the project's shared
`.claude/settings.json`, your `CLAUDE.md` and `AGENTS.md`, a skill of the same
name that is not ours (setup says so and leaves it), and your ssh keys.

**A settings file of your own is never written over.** Claude Code's hooks
are added to the file they belong in (`.claude/settings.local.json`, or
`~/.claude/settings.json` with `--hooks global`), next to what is already in
it, and `bash uninstall.sh` takes them out again. For the other agents, ours
goes beside a file of yours as `<file>.lyt-new`, for you to merge.

**A post skill an earlier setup installed is copied before it is updated**,
to `~/.config/lytnode-backup/`, with any edits of your own in it. Only a post
skill of ours is updated; one of your own is never touched. `bash uninstall.sh`
leaves the copies; delete them when you no longer need them.

Codex reads a project's `.codex/config.toml` only in a project you trust; it
asks the first time you open the project.

## 3. Codex: one manual step

Codex keeps a single `config.toml`, and pasting over it would take your other
settings with it, so setup leaves two fragments for you to append:

```bash
cat ~/.codex/lyt-mcp.toml   >> ~/.codex/config.toml
cat ~/.codex/lyt-hooks.toml >> ~/.codex/config.toml   # only with the optional extra
```

Read them first - they are short. With `--key-scope project` the MCP
settings are in the project's own `.codex/config.toml` instead, and with
`--hooks project` the hooks are in `<project>/.codex/lyt-hooks.toml`, to append
to that file.

## 4. Check it before you rent anything

```bash
./adapters/verify.sh codex        # or cursor, opencode, gemini
```

Three possible answers, and the middle one matters:

- `PARITY: codex OK` — everything checked, everything passed
- `PARITY: codex PARTIAL` — the files are right, but some checks could not run
- `PARITY: codex FAILED` — something is wrong, and it says which

It never reports OK for a check it skipped. A verifier that does is worse than
none, because it turns an unknown into a belief.

## 5. Ask your agent

```
which nodes do I have
```

The skill should answer. If it does not, [troubleshooting.md](troubleshooting.md)
has the common reasons.

## 6. Rent one

```
rent a Linux node for 8 hours
```

That goes through the MCP tool `provision_node`. **Every node has a
time-to-live** — a forgotten machine is a disputed invoice, so it expires rather
than running until somebody notices. Extend with `extend_node`, release early
with `release_node`.

Headless callers need one flag, or the call is refused without a useful reason:

```bash
codex exec --approve-for-me "rent a Linux node for 8 hours"
cursor-agent -p --force --approve-mcps "rent a Linux node for 8 hours"
```

## 7. Work, then bring it home

```
start the node
send the job to the node
bring the work home
```

Work leaves the node on a branch and **you** publish it. The node has no push
credentials to your origin — see [security.md](security.md) for why that is
the real guarantee rather than the command list.

```bash
~/.claude/skills/lyt-nodes/agentwork.sh send <node_id> "the job, on one line"
~/.claude/skills/lyt-nodes/agentwork.sh return <node_id>   # fetches the node's branch here; merges nothing
```

## 8. Release it

```
release the node
```

Or let the TTL do it. Releasing early stops the meter; the TTL is the safety
net, not the plan.

---

## Which agent should I use?

Any of them. [agents.md](agents.md) has the differences that actually
matter, and there are more of them than you would expect.
