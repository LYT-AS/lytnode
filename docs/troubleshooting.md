# Troubleshooting

Every entry here is something that actually happened, with the exact symptom you
will see. They are ordered by how long they waste before you find the cause.

The common shape: **the symptom points at the configuration, and the
configuration is usually fine.** Read the symptom column before you start
editing files.

---

## The agent does not use the skill

**You see:** the agent answers from general knowledge and never mentions
`lyt-nodes`, or says it cannot find your nodes.

| Check | How |
|---|---|
| Is the skill where this agent looks? | Claude Code reads `~/.claude/skills/`. Codex, Cursor and Gemini read `~/.agents/skills/`. OpenCode reads both |
| Is `name` equal to the directory? | The standard requires it. `name: lyt-nodes` must sit in a folder called `lyt-nodes` |
| Running Gemini headless? | See the next entry — this one is different |

An agent that answers *correctly* without loading the skill looks identical to
one that loaded it. If you need to be sure, ask it which skill it used.

---

## Gemini finds the skill and then refuses to open it

**You see:**

```
Path not in workspace: "/home/you/.agents/skills/lyt-nodes/SKILL.md"
resolves outside the allowed workspace directories
```

Gemini's sandbox is scoped to the project when it runs headless, and the global
skill sits outside it. It is not a permissions bug on your machine.

**Fix:** install the skill into the project as well. The installer does this for
you whenever you pass `--agent gemini`, and you repeat it per repository:

```bash
bash install.sh --agent gemini      # install.sh is fetched by setup.sh
```

---

## Codex will not start at all

**You see:**

```
Error loading config.toml: missing field `type` in `hooks`
```

A hooks block is missing `type = "command"` on one of its entries. Codex
validates the whole file at startup and refuses to run, so this takes your agent
down rather than merely disabling the hook.

**Fix:** every entry under `[[hooks.<Event>.hooks]]` needs `type = "command"`.
Our template has it; if you hand-edited, compare against
`adapters/codex/config.hooks.toml.template`.

---

## Nothing happens on session start — no post, no inbox

**You see:** nothing. That is the whole problem.

Codex does not run a hook until you have **trusted** it. Trust-on-first-use, and
it fails silently.

**Fix:** trust them once interactively, or in automation that already vets its
own hook sources:

```bash
codex exec --dangerously-bypass-hook-trust …
```

---

## The agent finds the MCP server and refuses to call it

**You see, on Codex:**

```
MCP tool call requires approval, but approval policy is never
```

**You see, on Cursor:** the agent tells you no lytnode server is attached, even
though `cursor-agent mcp list` says `lytnode: ready`.

Both are the same thing: the *call* needs approval, not the *connection*. On
Codex no configuration key changes this — `codex exec` sets the session's
approval policy itself and overrides the file, which is why editing
`approval_policy`, per-server `approval_mode` or the granular form all appear to
do nothing.

**Fix:**

```bash
codex exec --approve-for-me …            # routes approval through automatic review
cursor-agent -p --force --approve-mcps … # Cursor's equivalent
```

`--approve-for-me` is preferable to `--dangerously-bypass-approvals-and-sandbox`,
which switches off the sandbox as well.

---

## `Connection failed` from the MCP server

**You see:**

```
lytnode: Error: Connection failed
```

This reads like a broken endpoint and usually is not. The configuration
references your key as `${env:LYT_NODES_API_KEY}`; if the variable is not
exported in the shell you are running from, there is nothing to interpolate and
the request goes out unauthenticated.

**Fix:**

```bash
export LYT_NODES_API_KEY='lyt_live_...'
```

Then `cursor-agent mcp list` should say `lytnode: ready`.

---

## OpenCode fails with a missing Google key

**You see:** a complaint about `GOOGLE_GENERATIVE_AI_API_KEY`, on a run where
you never mentioned Google.

With no model configured, OpenCode selects one on your behalf — and it may
select an image model, whose provider you have no key for. The error names the
missing key rather than the wrong choice.

**Fix:** name a model, or set a default:

```bash
opencode run --model openai/gpt-5.2 "..."
opencode models
```

We deliberately do not choose a model for you: which one you run is your spend.

---

## Cursor refuses every shell command

**You see:** `Rejected:` on everything, including harmless commands.

This looks exactly like the lytnode guard blocking your work, and it is not. Cursor
requires `--force` in print mode before it will run a shell at all.

**Fix:**

```bash
cursor-agent -p --force "..."
```

To tell the two apart: if it *is* our guard, the refusal names the command and
gives a reason — "the node never publishes; a human does".

---

## Your agent refuses, and the node is not the reason

Four different layers can answer "denied" on a node, and in a terminal they look
much alike. Read the wording before you change any configuration — most of the
time the refusal comes from the tool you are running, on your own machine,
under your own account, and nothing we control is involved.

| What you see | Who refused | Where it is fixed |
|---|---|---|
| `auto mode classifier`, with a `Reason: [...]` in brackets | Your agent's own safety classifier | Your agent, not a file on the node |
| A rule quoted back at you from a settings file | Your agent's permission rules | That settings file |
| `Refused`, `NoCapacity`, `QuotaExceeded` from a lytnode tool | Us | Contact us — these are ours |
| `Operation not permitted`, `EACCES`, `Permission denied` from a command | The operating system | File ownership or the user you are running as |

**A classifier is not the same thing as a permission rule.** Rules match command
strings; a classifier judges what an action would *result in*. Allow-listing the
command therefore does not necessarily clear the classifier, and the classifier's
message usually does not mention your settings file at all — which is why people
spend a long time editing the wrong thing.

Measured on 2026-09-19: Claude Code refused a command that wrote an API key to a
file, with `Reason: [Secret-Store Writes]`. No permission rule was involved, and
no rule change would have been visible in that message.

Two notes worth having:

- **`pi` has no permission system at all.** It runs with the rights of the user
  who started it and never refuses on its own. On a node running `pi`, a refusal
  is always the operating system or us.
- **The cheapest fix is often not to ask for permission.** Before working around
  a refusal, check whether the action is needed. In the case above the key
  already existed, and the whole obstacle disappeared without changing a single
  setting.

### An order stops at `Reason: [Real-World Transactions]` (Claude Code)

An order costs money, and Claude Code's auto mode stops a purchase you did not
ask for in so many words. That is your protection, and it works: when we
measured it on 2026-09-26, the agent had chosen the number of hours itself.

There are two ways on:

- **Name the order.** Give the class and the hours, for example "order linux_s
  for 3 hours, discard". Claude Code lets through an action you described
  exactly.
- **Let orders run without a stop.** This is your choice, and setup never makes
  it for you. Add an allow rule: Claude Code settles allow rules before its
  classifier looks at the call. Merge the rule into the file if the file exists,
  then restart Claude Code (in VS Code: "Developer: Reload Window").

| Put the rule in | It applies to |
|---|---|
| `.claude/settings.local.json` in the project | This project only. The file is personal and kept out of git |
| `~/.claude/settings.json` | Every project on this machine |

```json
{ "permissions": { "allow": ["mcp__lytnode__provision_node", "mcp__lytnode__extend_node"] } }
```

With the rule in place, the agent may also choose the class and the hours on
its own. Every node still ends at the time it was ordered for, and your
account's spending limit still applies to every order and every extension.

Source: Claude Code's documentation, "How the classifier evaluates actions"
(<https://code.claude.com/docs/en/permission-modes>).

---

## The node cannot push, and that is deliberate

**You see:** a refusal naming `git push`.

Work leaves a node on a branch and a person publishes it. The node holds no push
credentials to your origin, so this is structural rather than a setting to
change: even with the guard bypassed there is nothing to push to.

Bring work home with `~/.claude/skills/lyt-nodes/agentwork.sh return <node_id>`
and publish from your own machine.

---

## I opened the node in VS Code and Claude Code is not there

You installed the extension on the node, it says Enabled, and no Spark icon
appears. Three things, in the order that resolves it fastest.

**Open a FILE, not just a folder.** The icon does not render in an empty
workspace view. A freshly rented node's project directory is empty by
definition, so this is the normal case here rather than an edge case — it cost
the first person through this path a good twenty minutes. Create anything, open
it, and the icon appears.

**Reload the window.** `View → Command Palette → Developer: Reload Window`. The
extension registers its commands as VS Code restores the UI, and on a slow
first connection the icon can lose that race.

**Look in the other two places.** The Spark icon is also in the editor toolbar,
top right, and there is a `✻ Claude Code` item in the status bar at the bottom
right. Either one starts it without the Activity Bar icon.

Still nothing: check that VS Code is 1.94 or newer, and that `which claude`
answers on the node. The extension is a thin wrapper around the CLI — we
install that CLI at provisioning and refuse to hand over a node where it is
missing, so an empty answer there means something changed after handover.

**A note on signing in.** The extension asks for YOUR Claude account. The
sign-in token that travels with `~/.claude/skills/lyt-nodes/agentwork.sh start`
is read only by the
session that command launches — a VS Code terminal and the extension never see
it. Signing in here is a separate, ordinary sign-in, it lives on the node, and
it goes when the node is wiped.

---

## Something else

Two commands worth running before asking us:

```bash
./adapters/verify.sh codex     # or cursor, opencode, gemini; fetched by setup.sh
```

It reports what it checked, what failed, and — importantly — what it could
**not** check. It never reports OK for something it skipped.

```bash
cat ~/.lytnode/hook-trace/*.json
```

The shape of the first payload of each hook event each agent sent us, written by
`adapters/hook-shim.sh` for Codex, Cursor and OpenCode (Claude Code's hooks do
not write it). Field names only, never values. If a hook is firing but nothing happens, this shows whether the payload
looks the way our scripts expect.
