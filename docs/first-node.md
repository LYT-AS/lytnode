# Your first node, done by your agent

Give this file to your coding agent and let it do the setup. In Claude Code,
Codex, Cursor, OpenCode, Gemini or Pi, in the project where the work should land:

```
read lytnode/docs/first-node.md and do what it says
```

Or paste everything below the line as your first message. Along the way you
create an API key in your account, give your agent a Tailscale auth key when it
orders, and, in Claude Code, sign in to Claude once in a browser. Nothing else
needs a terminal.

---

You are the coding agent. The person you work for wants a rented machine from
lytnode, a job run on it, and the result brought back here. This is a
conversation with them, not a script you run alone: before each step, say in
one or two sentences what it does and what it changes on this machine, and
wait for a yes wherever a step says ASK. Run one command at a time and read its
output before the next.

Four rules throughout:

- Do every step, in order, even when its result seems to be there already.
  Each one is cheap and safe to repeat. A leftover from an earlier attempt
  looks like a finished step and is not one; do not survey the machine first
  and skip what looks done.
- Never print, paste or quote an API key or a token, and never put one in a
  file the person did not name. Keys go to the files the scripts choose, and
  never into this project.
- Use only the `lytnode` MCP server and the `lyt-nodes` skill for this.
- If something in the package seems broken, stop and tell the person what you
  saw. Do not write probes, patches or workarounds for it; a fix comes with
  the next version of the package, and a sign-in you start for a test opens
  a real browser tab for the person.

## 1. Where the work lands

Stay in the current directory. It must be a git repository with at least one
commit, because the finished work comes back as a branch here. If it is not
one yet, ASK before you make it one: `git init`, add a README, commit.

## 2. The client package

If `./lytnode` is not here: `git clone https://github.com/LYT-AS/lytnode`. If
it is here, it may be old: `git -C lytnode pull`. Then check that
`lytnode/setup.sh` exists; if it does not, the copy is too old to use.

Do NOT expect `lytnode/install.sh` or `lytnode/lyt-node-core/` in a fresh
clone. They are the licensed part and are not published: step 6 fetches them
with the key. A clone that has them is one setup.sh has already run in, and
running it again refreshes them - that is the whole upgrade path.

## 3. Start clean

If `~/.config/lytnode`, `~/.claude/skills/lyt-nodes` or `~/.agents/skills/lyt-nodes`
exists, an earlier installation is on this machine. ASK the person whether to
remove it and start over. On yes:

```
bash lytnode/uninstall.sh
```

It names everything it removes and never touches ssh keys.

## 4. The API key

The key starts with `lyt_live_`. The person creates it in their account at
https://node.lyt.no/account/keys (accounts are by invitation today). It is
kept in `~/.config/lytnode/api-key`, mode 600, outside every project. Look, in
this order:

1. `~/.config/lytnode/api-key` exists and is not empty: nothing to do.
2. `LYT_NODES_API_KEY` is set in your environment: nothing to do, setup stores it.
3. Neither: ASK the person. The cleanest way is for them to start you again
   with the key in the environment, `LYT_NODES_API_KEY=lyt_live_... <your command>`,
   and then say "continue from step 5". If they would rather give you the key
   here, write it to `~/.config/lytnode/api-key` (directory mode 700, file
   mode 600) and do not repeat it in any message.

## 5. Tailscale, and the menu

**Tailscale.** A node joins the person's own Tailscale network, and this
machine reaches it there. Check with `tailscale status`. If the command is
missing or says it is logged out, ASK the person to install Tailscale and sign
in on this machine (https://tailscale.com/download). You may go on with setup
meanwhile, but not with an order.

**The menu.** Setup has one list of choices. Show it to the person here, in
the chat, with the default and one sentence for each, and ASK which they want.
Say that nothing is written before they answer. Ask with your own question
tool, so the person gets the same menu as at a terminal: Claude Code
(also inside VS Code) has `AskUserQuestion`; Cursor has the ask question tool;
VS Code Copilot has `askQuestions`; Codex has `request_user_input` in Plan mode;
OpenCode has the `question` tool; Gemini CLI has `ask_user`. Where you have none
(Codex in its default mode, Gemini headless, pi), ask in plain words, one
question at a time. Never answer for them. If you run setup without the
answers, it prints these same questions and stops with exit 5 (see step 6):

1. **Message channel** (default no): a node tells this session when a job is
   done or blocked. It installs the `post` skill, a small Python environment
   and a participant list. Nothing of it is needed to rent a node.
2. **Hooks** (only with 1; default: this project only, in a personal settings
   file kept out of git; or: every project).
3. **A node may push messages here** (only with 1; default no, the person
   chooses it): at each start the node's key is added to
   `~/.ssh/authorized_keys` on this machine, so a message arrives at once.
   Without it the node never connects here: this machine fetches its
   messages every minute while a job runs, and at status and return.
4. **The node guard here too** (only with 1; default no): this machine's
   Cursor and OpenCode would also refuse `git push` and similar.
5. **API key**: for all projects (default), or for this project only, kept in
   `.lytnode/api-key` here, out of git. For this project only, ASK which key
   it should use: one made for it at https://node.lyt.no/account/keys, or the
   one from step 4. Setup never picks it for them.
6. **Capacity watch** (Claude Code; default yes): when this machine is over
   its limits, you ask once whether the job should move to a rented node, and
   recommend one. It measures this machine and sends nothing anywhere.

Their answers become flags in step 6: `--with-post` or `--without-post`,
`--hooks project` or `--hooks global`, `--node-push yes` or `--node-push no`,
`--guard yes` or `--guard no`, `--key-scope user` or `--key-scope project`,
and `--watch yes` or `--watch no`.
Setup never changes the project's own files (`.gitignore`,
`.claude/settings.json`, `CLAUDE.md`, `AGENTS.md`); what it writes there is kept
out of git in `.git/info/exclude`, and it tells you so.

If a session here later says **"This project is not in the post system"**,
ASK the person whether to add it; on a yes, run the one command it names.

## 6. Setup

Tell the person what this does before you run it: it makes two ssh key pairs
in `~/.ssh` if they are missing (never over an existing one), stores the key,
fetches the client with it, installs the skill for you, registers the
`lytnode` MCP server, and adds one `Include` line at the top of `~/.ssh/config`.
Your own safety checks may ask the person to approve it; that is right.

```
bash lytnode/setup.sh --agent <claude | codex | cursor | opencode | gemini | pi> --non-interactive <the flags from the menu>
```

Use the name of the agent you are. Add `--url <address>`
only if the person gave you an address other than the default. Read the output:

- `setup: ready`: go on.
- exit 2, "no API key": step 4.
- exit 2, "no key for this project": ASK the person which key this project
  uses, then do what the message says: put that key in the file it names
  (the same way as step 4), or copy the key for all projects there with the
  two commands it prints. Then run setup again.
- exit 1, "missing:": tell the person which tools to install, then run it again.
- exit 3, "could not fetch": the key was rejected or revoked, or the address is
  wrong. Tell the person; a new key is needed, do not retry with the same one.
- exit 5, "no terminal to show the menu in": you ran setup without the
  answers from the menu. Ask the person the five questions it printed, with
  your question tool, then run it again with `--non-interactive` and each
  answer as a flag. Nothing was written.
- exit 4, "a lyt-nodes skill that is not ours is in the way": a folder of that
  name that setup did not make is where your skill would go. Show the person
  the path it names and ASK whether to rename or remove it; never do either on
  your own. Then run setup again.
- exit 64: a flag or a value was spelled wrong; the message names it.
- A line that starts with `note:` is something setup chose not to do, and
  why. Read it to the person.
- "is not a git repository, so no file in it may carry the key": setup printed
  the line that starts the agent with this project's key. Show it to the
  person.
- A line that starts with `left alone:` or `no hooks:` names something the
  person chose that was not installed, and why: a skill of the same name that
  is not ours is in the way. Setup still ends `setup: ready` for the rest.
  Read the line to the person and ASK whether to rename or remove what is in
  the way; never do either on your own.
- "the key was REJECTED": the same, found when the MCP server was registered.
- Claude Code: the last step prints a sign-in address. That is expected, not
  an error; step 7 is what to do with it.

**Codex only:** setup cannot safely edit `~/.codex/config.toml`, so it leaves
the MCP settings in `~/.codex/lyt-mcp.toml` (and, with the extra, the hooks in
`~/.codex/lyt-hooks.toml`, or `<project>/.codex/lyt-hooks.toml` for project
hooks). With a key for this project only, the MCP settings are in the project's
own `.codex/config.toml` instead, and Codex reads that only in a project you
trust. Show the person the files, and on their yes append them:

```
cat ~/.codex/lyt-mcp.toml >> ~/.codex/config.toml
```

**The person's own CLAUDE.md or AGENTS.md.** If this project has one, ASK:
"Shall I add one line at the end of your CLAUDE.md (or AGENTS.md) pointing to
lytnode/AGENTS.md, so your agent finds it next time?" Only on a yes, and only
that one line, at the end. Never change anything else in their file.

## 7. Sign in to Claude, once (Claude Code only)

Setup ended with the sign-in helper's message: a browser tab with the Claude
sign-in has opened on this machine by itself. ASK the person to sign in in
that tab. Give them the printed address only if no tab opened; it is the same
sign-in, and it can be completed once, so one tab, not two. Then, every 15
seconds until it says `done`:

```
python3 lytnode/lyt-node-core/claude-token.py status
```

The token is collected without any code. Only if the page shows the person a
code, pass it on: `python3 lytnode/lyt-node-core/claude-token.py code <the code>`.
If setup said the token file already exists, skip this step. The token is the
person's own: it travels to their node over their own ssh when a session
starts and is removed from the node when the session stops.

Other agents: nothing to sign in to here. Their keys reach the node from
`~/.config/lytnode/agent-env` if the person made one (see `agents.md`, next to
this file). But their connection to the `lytnode` MCP server reads the API key
from `LYT_NODES_API_KEY`, not from the file. Tell the person to start you
from a shell where it is exported, for instance after
`export LYT_NODES_API_KEY="$(cat ~/.config/lytnode/api-key)"`, and to keep
that line out of any file they share.

## 8. See the service

Call the MCP tool `list_offers` on the server named `lytnode`, or ask in the
skill's words: "which nodes do I have". Show what it returns as the table the
skill describes under "Showing the catalogue". If you cannot see any tools from a
server named `lytnode`, the registration setup made is newer than your
session: tell the person to restart you in this directory (for any agent but
Claude Code, with `LYT_NODES_API_KEY` exported, see step 7), then continue
here. A server with another name, such as `lyt`, is from an earlier attempt
and is not this one.

## 9. Rent, work, bring home, release

Follow the `lyt-nodes` skill (`~/.claude/skills/lyt-nodes/SKILL.md`, or
`~/.agents/skills/lyt-nodes/SKILL.md` for the other agents; the script named
below lives next to it). In order, and say what you are doing:

1. **Rent.** ASK the person what the job is. If they name a class and hours,
   use those. If not, recommend one class with its price, the way autoscale
   mode sizes a job ([autoscale.md](autoscale.md)); for a first try with no
   job in mind, that is the smallest Linux class for one hour. Never start from
   a Mac by default: a Mac is billed for at least a day. `list_offers` shows
   the classes this account can order. ASK also for a Tailscale auth key: a
   new one for every order, since each key
   admits one node. It comes from
   https://login.tailscale.com/admin/settings/keys and needs exactly these
   settings: `reusable=false`, `preauthorized=true`, `ephemeral=false`. The
   last one matters most: an ephemeral node drops off their network at its
   first reboot, and nobody can get it back. Then call `provision_node` with
   the class and hours, `tailscale_authkey`, `agent` set to the agent you are,
   `ssh_public_key` from `~/.ssh/id_ed25519.pub` and `ssh_cert_public_key`
   from `~/.ssh/lytnode_cert.pub`. Renting costs money, so your own safety
   checks may ask the person to confirm; that is right. Order exactly what the
   person approved. If Claude Code stops the order with
   `Reason: [Real-World Transactions]`, ask the person to name the class and
   the hours, and do not change them yourself. How they can let orders run
   without a stop is in [troubleshooting.md](troubleshooting.md).
2. **Save the certificate, before anything else touches ssh.** Fetch it:
   `~/.claude/skills/lyt-nodes/agentwork.sh cert <node_id>`. Never copy it out
   of the order reply by hand: it is 1 kB of base64, and one wrong character
   makes it worthless. Skip it and the first `ssh` fails with
   `Permission denied (publickey)` — an error that reads like a key problem
   rather than a missing step.

   Then follow the setup without being asked: run
   `~/.claude/skills/lyt-nodes/agentwork.sh wait <node_id>` again and again.
   Each run ends when the setup moves to a new step, or after a minute. A line
   that starts with `step` is news: tell the person. A line that starts with
   `still:` is the same step as last time: say nothing and run it again — a
   step can take ten minutes, and the person wants each one once. A line that
   starts with `late:` means the setup is past its estimate with no failure
   reported: tell the person once that it is taking longer, that nothing is
   billed until the node is ready, and that they can wait or say "release it
   and order again"; then keep waiting. A `failed:` line (exit 1) carries the
   machine's own reason: tell the person and offer to order again. When a line
   starts with `ready:`, say so
   at once. Then run `~/.claude/skills/lyt-nodes/agentwork.sh nodes` once and
   note the HOSTNAME and WORKDIR columns. It also lists any node that is
   missing a certificate.

   *Want to sit on the machine yourself rather than delegate?* The ssh host is
   the node's HOSTNAME, `node-<something>`, never an IP. `setup.sh` put an
   `Include ~/.ssh/lytnode.conf` at the top of your ssh config and every
   `nodes` call rewrites that file, so `ssh node-xxxxxxxx` works with no setup
   of your own — and so does VS Code's Remote-SSH: Cmd+Shift+P, "Connect to
   Host", pick the node. The certificate lives exactly as long as the rental,
   so access ends when the rental does, even if the machine is still up.

3. **Start.** `~/.claude/skills/lyt-nodes/agentwork.sh start <node_id>`. The
   session on the node runs on the person's own token.

   **If the job is about code that already exists, add `--seed`:**
   `~/.claude/skills/lyt-nodes/agentwork.sh start <node_id> --seed`, run from the project directory.
   It sends the current branch (or, outside a repository, the directory
   itself) into the node's job directory before the session starts, so the
   agent there reads the real project instead of building from nothing.
   `~/.claude/skills/lyt-nodes/agentwork.sh seed <node_id>` does the same on its own, before or after
   `start`. ASK before you seed: it copies the project to the node.

   **What travels.** From a git repository: the branch you are on, with its
   history — so whatever your own `.gitignore` keeps out of the repository
   stays behind, and a secret you have already committed travels with the
   branch, exactly as it would to any other clone. From a directory that is
   not a repository: the files, minus everything a `.gitignore` in any
   directory names and minus the package's own list of things that must never
   travel (`.env`, keys, build output).
4. **Send the job.** `~/.claude/skills/lyt-nodes/agentwork.sh send <node_id> "<the job, on one line>"`.

   *Optional, Claude Code only: the node in your own list of agents.*
   - **Remote Control** is Claude Code's way to reach a running session from
     elsewhere; the sign-in token setup kept can make model requests but
     cannot open one, so by default the node is not in your list.
   - **ListAgents** is the Claude Code tool that lists the sessions you can
     reach; with Remote Control on, the node appears there.
   - **SendMessage** is the Claude Code tool that writes to a listed session;
     it then reaches the node as well as `send` does.

   To turn it on, before you start the node: run
   `~/.claude/skills/lyt-nodes/agentwork.sh login <node_id>`. It prints a
   sign-in address; ASK the person to open it in one browser tab, sign in with
   their own Claude account, and give you the code, then run
   `~/.claude/skills/lyt-nodes/agentwork.sh login <node_id> --code <code>`.
   Start the node with `LYT_NODES_RC=1 ~/.claude/skills/lyt-nodes/agentwork.sh start <node_id>`.
   The sign-in stays on the node. Skip all of this and everything below
   still works: `send`, `peek` and `return` do not need it.
5. **Wait, and look.** Right after sending, `~/.claude/skills/lyt-nodes/agentwork.sh peek <node_id>`
   shows the session's screen on the node: the agent there should be
   working on the job. If the job text is sitting in its input box unsent,
   send it again. Then every few minutes: `~/.claude/skills/lyt-nodes/agentwork.sh peek <node_id>` and
   `ssh <HOSTNAME> "git -C <WORKDIR> log --oneline --all -5"`. The node never
   pushes; it is done when the job's commit is on a branch there. With the
   optional message channel it also tells this session when it is done or
   blocked. Give it time: a build from nothing can take a while.
6. **Bring the work home.** `~/.claude/skills/lyt-nodes/agentwork.sh return <node_id>`. It fetches the
   node's branch into this repository under the name it prints, and merges
   nothing. Check the result the way the job defines it, for instance in a
   worktree of that name: install, build.
7. **Check that everything is home, then release.** Run
   `~/.claude/skills/lyt-nodes/agentwork.sh check-home <node_id>` first. It compares every branch the
   node has committed with what `return` fetched here, and says `all fetched`
   only when nothing is missing and nothing is uncommitted on the node. ASK
   the person before you release. Call `release_node` with the node id only on
   `all fetched`, or when the person explicitly says discard. Anything else it
   prints is work that would be lost: run
   `~/.claude/skills/lyt-nodes/agentwork.sh return <node_id>` and check again.
   Releasing early stops the meter; releasing unfetched work loses it.

## 10. Report

Tell the person, in a few lines: the times (rented, ready, started, committed,
home, released), which way the job text went, and everything you had to ask
for or work around. That is what improves the next run.
