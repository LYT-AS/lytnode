# lytnode

lytnode gives your coding agent a rented machine in a country you choose, for
as long as you choose, and brings the work back to this project as a branch.

**If you are an agent reading this:** follow [docs/first-node.md](docs/first-node.md),
in dialogue with the person. Ask before you install anything, and explain what
each step changes on this machine before you run it.

## What to ask the person for

1. **An API key** (`lyt_live_...`), created in their account at
   <https://node.lyt.no/account/keys>. Accounts are by invitation today.
2. **Tailscale on this machine**, installed and signed in. A node is reached
   over the person's own Tailscale network.
3. **A Tailscale auth key** (`tskey-auth-...`) for each order, a new one
   every time, from <https://login.tailscale.com/admin/settings/keys>, with
   exactly: `reusable=false`, `preauthorized=true`, `ephemeral=false`.
4. **Which agent** should work on the node. By default, the one you are:
   claude, codex, cursor, opencode, gemini or pi.

## Where things are kept

The API key is stored in `~/.config/lytnode/api-key` (mode 600), or for one
project only in `.lytnode/api-key` there, kept out of git. Claude Code's MCP server gets it from setup. The other agents
read it from `LYT_NODES_API_KEY`, exported in the shell they start from, unless setup put this project's key in their
settings here ([docs/setup.md](docs/setup.md)). Never print, paste or quote a key or a token.

## What is optional, and what is never touched

`setup.sh` shows one menu before it writes anything: the message channel and
its hooks, and a key for this project only, each with a flag. It never
changes the project's own files; what it writes there is kept out of git.
Each choice: [docs/setup.md](docs/setup.md); each hook:
[docs/hooks.md](docs/hooks.md).

`bash uninstall.sh` takes everything out again. More for people:
[README.md](README.md).
