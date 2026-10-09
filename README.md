# lytnode

Give your AI agent a computer. Or five.

One integration gives Claude Code, Codex, Cursor, OpenCode, Gemini or Pi a rented
machine in a country you choose, for as long as you choose, that hands your
work back and never outlives its rental.

When the hours run out, the node is held rather than destroyed, so work you
have not fetched is not lost: it stays reachable for up to 48 hours, at twice
the price for the first day and three times for the second, and you are
reminded by mail. The nodes your account has on hold may cost 200 EUR
together, tax not included, or less if your own spending limit is lower; when
that is reached they are released at once. Release it yourself and it stops
billing at once. Order it with `exit_policy: discard` and it is released the
moment the time is up, with no hold and no grace.

## Before you start

- **An account.** Accounts are by invitation today:
  <https://node.lyt.no/register>.
- **An API key** (`lyt_live_...`), created in your account at
  <https://node.lyt.no/account/keys>. It is stored in
  `~/.config/lytnode/api-key`, never in your project.
- **Tailscale on this machine**, installed and signed in. A node joins your own
  Tailscale network, and that is how you reach it.
- **A Tailscale auth key** (`tskey-auth-...`) for each order, a new one every
  time, from <https://login.tailscale.com/admin/settings/keys>, with exactly
  `reusable=false`, `preauthorized=true` and `ephemeral=false`. The last one
  matters most: an ephemeral node drops off your network at its first reboot.
- **The tools `setup.sh` checks for:** `git ssh ssh-keygen curl tar jq rsync
  python3`, and the agent you use.

Two addresses, two jobs. The site, where your account and keys live, is
<https://node.lyt.no/account>. The service your agent talks to is
`nodes.lyt.no`, with an s.

## Two ways in: yourself, or with your agent

**With your agent.** In the project where the work should land (a git
repository with at least one commit, because the work comes back as a branch):

1. Download the setup into the project:

   ```bash
   git clone https://github.com/LYT-AS/lytnode
   ```

2. Create an API key in your account: <https://node.lyt.no/account/keys>
3. Open the project in your agent and say:

   ```
   read lytnode/docs/first-node.md and do what it says
   ```

The agent does the rest. It asks before each step that changes your machine,
and it needs three things from you: the key, a Tailscale auth key when it
orders, and, in Claude Code, one sign-in in the browser. An agent that
opens this folder finds [AGENTS.md](AGENTS.md) (and `CLAUDE.md`, the same text)
first.

**Yourself.** The same setup is one command:

```bash
cd lytnode
bash setup.sh --agent claude        # or codex, cursor, opencode, gemini, pi
```

It makes the ssh keys, stores your API key (pasted without echo), **fetches the
client itself with that key**, installs it for the agent you chose, registers
the `lytnode` MCP server, and for Claude Code keeps a login token so a node
never asks you to log in. What it does step by step: [docs/setup.md](docs/setup.md).

What you cloned is what you can read before you buy: this file, the docs, the
message channel and the licences. The client - the skill, the agent adapters
and their installer - is served to your key by the service, and `setup.sh`
unpacks it here. Run `setup.sh` again to update it; there is no separate
update command. Then, in your agent, in your own words:

```
rent a node for this job
start the node and send it this job: ...
bring the work home
release the node
```

The developer reference, with the configuration for each agent, is at
<https://node.lyt.no/developers>. `bash uninstall.sh` takes everything out
again.

A node can come with developer tools and local language models already in
place: name them on the order (`toolchain`, `models`), and the machine is
prepared before you get it. Models are pulled on Mac classes today. Of the
tools, `ollama` and `eas` run on every class; the others need a Mac. For a model you accept its licence in the order,
because you are the licensee, not us - and on the node, `lyt-models` shows
each licence and pulls only after your yes. The whole story, including why we
never serve a model ourselves, is in `lyt-node-core/README.md` (fetched by
setup.sh), section 4c.

## Autoscale: the right machine for the job

Describe a job without naming a class, and your agent suggests one: it sizes
the job from your project, keeps to classes that can be ordered now, and tells
you why its choice fits and what it costs. While the job runs, it checks
whether the node still fits. When the node gets tight, the job gets one size
up before it runs out, on the machine that is ready soonest, in a place the
job may stand. With a budget set, that happens without asking you; without
one, your agent asks, with the price, and the job waits safely for your answer.

Every bigger machine is your yes, given when asked or in advance as a budget.
Nothing of the job runs on your own machine unless you allow it. Autoscale
mode is on by default, you can switch it off, and every limit is a setting you
can change: [docs/autoscale.md](docs/autoscale.md).

### Jobs that are a list of tasks: use `TASKS.md`

If you often run jobs that are many tasks of the same kind (films to render,
test shards, datasets to process), write them in `TASKS.md` in the project,
one task per line:

```markdown
- [ ] Render film 01
- [ ] Render film 02
```

Then a slow job is not moved but helped: one more machine takes tasks from the
end of the list while the first keeps going, and both results come home.
Without a list, the only answer to a slow or full machine is a bigger one.
More in [docs/autoscale.md](docs/autoscale.md#a-list-of-tasks).

## Two skills

- **`lyt-nodes`** rents a machine, runs your agent on it, and brings the work
  home. It is what the rest of this package is for.
- **`post`** is a mailbox between your agents and your projects, so a blocked
  agent can say so. It needs no LYT account, and you can use it on its own:
  [post/README.md](post/README.md).

What a skill is, which agents read them, and where each is installed:
[docs/skills.md](docs/skills.md).

## What is in here

| Path | What |
|---|---|
| `setup.sh` | the one command above |
| `uninstall.sh` | removes what `setup.sh` put in place; never your ssh keys |
| `AGENTS.md`, `CLAUDE.md` | where an agent that opens this folder starts; the same text twice |
| `install.sh` | puts the skills in place for one agent; `setup.sh` calls it (fetched by setup.sh) |
| `lyt-node-core/` | the skill, `connect.sh`, `agentwork.sh` (start, stop, status, cert), the guarded return (fetched by setup.sh) |
| `adapters/` | per-agent configuration templates and `verify.sh` (fetched by setup.sh) |
| `post/` | the message channel between your machine and your nodes |
| `docs/` | setup, agents, autoscale, security, troubleshooting |

## License

Two licences, because two different things are in here.

**`post/` is Apache-2.0** ([post/LICENSE](post/LICENSE)). It is a general
message channel between coding agents — no LYT account, no call to our service
— so use it in your own projects, with or without lytnode.

**Everything else is the [LYT Node Client License](LICENSE.md).** In plain
words: install it, read it, change your own copy, run it on as many of your own
machines as you like — to use LYT Node. Not to reach other providers, not to
pass on to anyone else, and not to serve to others.

Each `LICENSE` file is the terms; these paragraphs are not.
