# What we can see, and what we cannot

A rented node runs your code on a machine you did not build. That deserves a
plain answer rather than a reassuring one, so this page says what is actually
true — including the parts that are weaker than you might hope.

## The node is yours, including from us

Everything we prepare happens **before** you receive the node. At handover it
joins your Tailscale network, and we are no longer on the network it sits in.
After that we reach it only through what it fetches from us.

Getting access back is your action, never ours. On a Mac you are never given
administrator rights on the machine, because we do not have them to give.

Your Claude, OpenAI or Cursor subscription is used on the node, never through
us. For Claude Code, `setup.sh` runs `claude setup-token` once on your own
machine and keeps the token in `~/.config/lytnode/claude-token`;
`~/.claude/skills/lyt-nodes/agentwork.sh start` carries it to the node over your own ssh, into a file only the node's
agent account can read, and removes it when the session stops. Without that
file you sign in **on the node** instead. Either way the credential travels
between two machines that are yours.
We never store those tokens.

## What we hold

| Thing | Where it lives | What we can read |
|---|---|---|
| Your API key for lytnode | our database | only a hash — we cannot recover the key, and if you lose it we issue a new one |
| Your node list, hostnames, expiry | our database | yes; that is what the catalogue and billing run on |
| What runs *on* the node | the node | nothing, after handover |
| Your provider keys, if you bring your own | a vault | encrypted; used to provision, never logged |

## The guard on a node, honestly

A node is configured to refuse `git push`, `sudo`, `rm -rf`, `git reset --hard`
and a few others. That list is real and it works for the direct case.

**It is not a boundary.** Prefix matching only sees the outer command string, so
`bash -c 'git push'`, an absolute path to a binary, and `git -C <path> push` all
get past it. Under Codex there is no command list at all — an operating-system
sandbox confines writes to the job directory instead, which stops more than a
list can, but cannot express a single exception.

**What actually prevents a node publishing your work is that it has no push
credentials to your origin.** Work leaves on a branch; your machine pulls it
home; a person publishes. Defeat every guard we ship and there is still nothing
to push to.

We describe it this way deliberately. A guard presented as a boundary is one
somebody eventually leans on.

## What the node is told

Every node carries `AGENTS.md`, and `CLAUDE.md` is a symlink to the same file so
every agent reads one text. It tells the agent it never publishes, never
writes outside the job directory, keeps a decision log, and says so when it is
blocked rather than going quiet.

If a node already carries instructions — from your own bootstrap, or from a
previous job — we never overwrite them.

## The transcript

Each agent writes a session log on the node. When work comes home, that log is
rendered to a readable summary so a reviewer can see what the node actually did,
not only what its own report claimed.

**The agent's reasoning is not in it.** Agents store their internal reasoning in
forms nobody can read back — in Claude Code's case as empty blocks carrying only
a signature. That is why the node is told to write decisions down as it works: a
decision not written down is gone for everyone but the agent that made it.

## Rented machines, and the ones we never touch

Only machines this tool created can be released by it — the label, the database
row and the tenant must all agree. No flag overrides that. A machine you created
by other means is not ours to delete, and we do not.

Every provisioning carries a time-to-live. A forgotten machine is a disputed
invoice, so a node expires rather than running until somebody notices.

## Reporting something

If you find a way past any of this, tell us: `node@lyt.no`. We would rather hear
it from you than from an invoice.
