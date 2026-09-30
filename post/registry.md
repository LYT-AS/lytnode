# Post — participants and peers

## Participants: `~/.claude/post/participants.json`

One list per machine, a JSON array of rows:

```json
[
  {"id": "human", "path": "/home/you"},
  {"id": "api", "path": "/home/you/code/api", "kind": "project"},
  {"id": "agentwork-n1", "path": "/data/agentwork"}
]
```

- `id` — stable participant identifier used in envelope `from`/`to`/`cc`.
- `path` — the directory a session runs in. `inbox-peek` resolves the participant
  from `cwd` by the longest matching path; the first row wins a tie.
- `kind: "project"` marks a place the person works, as opposed to a rented node.
- `~` in paths is expanded at read time.

Who writes it:

- lytnode's `setup.sh` writes the first list: `human` at the home directory,
  this project, and one row per rented node.
- `register.py <dir>` adds a project (your agent asks first when it finds a
  project that is not there).
- `~/.claude/skills/lyt-nodes/agentwork.sh start` registers each node on both sides, so the node can
  resolve itself and this machine can address it.

`init-post.py` reads the list and creates `projects/<id>/{inbox,sent}/` for
each row, plus the reserved `human` participant. Re-run it after adding a row
by hand.

## Peers: `~/.claude/post/peers.conf`

Participants say WHO can be written to; peers say WHICH MACHINES post is synced
with (`sync-post.sh`). One `ssh-alias:post-root` per line, `#` comments and
blank lines ignored:

```
n1:/home/agent/.claude/post
```

The path cannot be derived — it differs by OS and by username — so a new
machine needs one line here, not a code change. `~/.claude/skills/lyt-nodes/agentwork.sh start` adds a
line for each node it starts.

- **An unreachable peer is SKIPPED with a warning, never an error.** Post is
  additive and eventually consistent: a machine that was offline picks the
  messages up on the next run. One peer being down must never stop the others.
- **`POST_SYNC_REMOTE` restricts a run to one peer.** A bare alias must be in
  the file; an ad-hoc machine can be given as `alias:path`. An unknown bare
  alias is a hard error, not a silent guess at the path.
