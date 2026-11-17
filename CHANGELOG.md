# Changelog

What changed for you in each release of lytnode, newest first. Changes made
before the first entry here are in the repository's history.

## 2026-11-16

### New

- **`run <node_id> --seed`** sends the project in this directory before the
  job starts, as `start --seed` does. `--branch <name>` picks the branch.
- **The first line of `run --status` is always `state: <word>`**, with
  `exit=N` once the agent has ended and `left=N` while what it started still
  runs. `--status --short` prints only that line, for a loop that waits.
- **`pause <node_id>`** freezes a running job until `resume`, on Linux and Mac
  nodes. Nothing is lost from memory and nothing is committed.

### Changed

- **`run` refuses an empty job directory.** It used to warn and start
  anyway, and the agent found an empty folder. Send the project with
  `--seed`, or say `--empty` when the job builds everything from nothing.
- **`resume` works on Mac nodes too.**
- **This machine fetches a job's messages until "done" has come home**, also
  when the node may push them itself. Before, a "done" the node could not
  push waited on the node until somebody asked.
- **A new Linux node accepts connections only over your Tailscale network,**
  ssh included. Reach a service you start on the node over Tailscale, not on
  its public address.
- **A new round of the same work goes into the same job.** Run `update`, then
  `run` with the same `--name`. The agent prunes a job whose work is already
  home before the next one starts, and asks first only when that work is not
  merged here yet. `prune` still refuses until everything is home.
- **Anyone can register.** Accounts no longer need an invitation.

## 2026-11-12

### New

- **`--effort <level>`** on `run` (`low`, `medium`, `high`, `xhigh` or `max`,
  or `AGENTWORK_EFFORT`) sets how hard the agent on the node thinks. It is
  optional: without it the job starts exactly as before and the model keeps
  its own default, which differs per model. A level that does not exist is
  refused before anything reaches the node.
- **`Model used:`** in the job's status, its messages home and `run --status`
  names the model the agent really ran. `--model opus` is a name for the
  newest Opus; this line shows which one that was. Nothing changes in how
  `--model` is passed.

## 2026-11-11

### New

- **`~/.claude/skills/lyt-nodes/agentwork.sh update <node_id> [--job <job>]`** sends new commits from your
  branch into a job between runs and shows the commit the job now stands at.
  It refuses, and changes nothing, while the job runs, when the node has
  uncommitted work, and when the node has commits of its own that are not
  home yet. Use it instead of copying files into a job.
- **`~/.claude/skills/lyt-nodes/agentwork.sh prune <node_id> [--job <job>] [--yes]`** lists the build
  folders in a job (`target/`, `node_modules/`) and their size. With `--yes`
  it frees them, but only when everything is home and nothing of the job is
  running. Source files and history are never touched.
- **`--shared-build-cache`** on `start` and `run` lets every job of the same
  project share one Rust build folder on the node, instead of building from
  scratch in each job.

### Changed

- **`run` without `--name` picks the job you seeded** when you start it from
  the directory you seeded from. From any other directory it uses that
  directory's name, as before, and `--name` always wins. A job seeded under its
  own name no longer starts in an empty folder.

### Fixed

- Mac nodes no longer say "has no commits yet" right after a successful seed.
- The job's agent finds tools in `~/.cargo/bin`, `~/.local/bin` and Homebrew,
  so a build no longer fails for a missing PATH entry.
- A project that keeps its own files under `.claude/` in git no longer has
  that folder ignored after the work comes home.

### Docs

- The Tailscale auth key for an order should have an expiry of 1 day: it is
  used once, when the node starts.
- `postgres` (PostgreSQL 17 with `psql` and an empty database) is available
  as a toolchain on every class.
- [docs/first-node.md](docs/first-node.md) has a new section on jobs with
  nobody attached: `run`, `update` and `prune`.
