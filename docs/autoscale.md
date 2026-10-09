# Autoscale mode

Autoscale mode sizes the job before you order, checks the node while the job
runs, and gives the job a bigger machine before it runs out of room, or one
more machine when a list of tasks goes slowly. It is part of the `lyt-nodes`
skill and is on by default. Every bigger machine, and every extra one, is your
yes, given when your agent asks or in advance as a budget.

## Before the order

If you name a class, your agent orders what you asked for. You have made that
choice already.

If you describe a job without naming a class, the agent recommends one first:

1. It keeps only the classes that can be ordered now. If the one that fits is
   sold out, it says so and suggests the nearest one that is not.
2. It sizes the job from your project: the languages and the build tool, the
   size of the repository, the data or model files the job loads, and how many
   agents will work at once. If it knows the peak from an earlier run of the
   same job, it uses that.
3. It chooses a class with room to spare above that estimate, and tells you the
   estimate and what it rests on.
4. It recommends one class: which class and where, why it fits this job, and
   the price. It names a second choice only when there is a real trade-off,
   such as cheaper but slower. Then it asks before it orders.

The starting points it matches the job to:

| The job | Starting point |
|---|---|
| One coding agent: write code, run tests, open a pull request | the smallest shared node |
| CI, or builds whose times you compare | a dedicated node, size M: the same speed on every run |
| Large builds, or several agents on one machine | size L; XL for heavy builds and data work |
| Data that must stay in one country | that country first, then the size |
| Apple builds: Xcode, TestFlight, iOS | a Mac |
| A local language model | the cheapest class that runs it, which the model list names |
| Needs a GPU | a class whose GPU memory fits the model |

These are starting points, not rules. If you have a reason to choose
differently, your choice wins.

## Nothing runs on your machine unless you allow it

Sizing reads your project; it does not run the job. That is the default,
because keeping the work off your own machine may be the reason you rent one.

With `local-sizing` set to `yes`, the agent may run a small part of the job on
your machine first, to measure how much memory it takes.

## While the job runs

A job you hand over with `~/.claude/skills/lyt-nodes/agentwork.sh run` is
watched for you: every status
message carries the node's fit, and the first time the node is tight or too
small you get a message of its own, at once. Nothing is ordered without your
yes.

## Before the job runs out

On a Linux node, a job you hand over with `run` is stopped before it runs out
of memory or disk, and its work is saved. Your agent then moves it to a bigger
machine where the job may stand (see "Where a job may go" below), where it
continues from the saved work, and releases the old one. It does so on its own
when the new machine costs no more than the budget you have set in the console (Billing, "Budget for automatic work", per job), and the order
is charged to your card like any other; otherwise it recommends one machine
with its price and waits for your answer. There is no deadline: the job stays
stopped until you answer, at the latest until the node's rental ends, and you
are reminded meanwhile. If you say no, the job goes on where it was, and if it
heads for the limit again it is stopped again and you are told. A Mac is never
moved this way.

When the budget covers it, your agent orders the bigger machine as soon as the
node is tight, before the job has to be stopped, and the job finishes its step
and saves its work while the new machine starts.

Among the machines that fit, your agent chooses the one that is ready
soonest, and then the cheapest.

## Where a job may go

| `move-to` | A job may be moved, or get help, in |
|---|---|
| `standard` (default) | its own jurisdiction; Norway and the EU also count as one for this |
| `origin` | its own jurisdiction only |
| `country` | its own country only |
| `none` | nowhere: the job is never moved, and you are only told |

Set it for all your projects with
`~/.claude/skills/lyt-nodes/agentwork.sh autoscale move-to country`, or for one
project, from its directory, with `... move-to country --project`. A project
can only make it stricter than what you set for all of them. Somewhere else
than this allows: only your yes moves a job there.

## A list of tasks

If a job is a list of tasks that do not depend on each other, such as films to
render, test shards or datasets, put them in `TASKS.md` in the project, one
per line:

```markdown
- [ ] Render film 01
- [ ] Render film 02
- [ ] Render film 03
```

The agent on the node works through the list from the top and checks each task
off (`- [x]`) when it is done. When the list goes slowly, or the results fill
the disk, autoscale gives the job one more machine that takes tasks from the
end of the list, while the first one keeps going. Nothing stops, and both
results come home as branches. Without a list, the answer is a bigger machine.

In a session your agent drives, it checks the node when the job fails or
stalls, when the agent on the node stops because the machine is too small, and
about every half hour while it follows a long job. You can also ask it at any
time: "does the node fit the job?" The check is
`~/.claude/skills/lyt-nodes/agentwork.sh fit <node_id>`, and it ends with one
verdict:

| Verdict | What it means | What your agent does |
|---|---|---|
| `fits` | The machine is big enough for the job | Nothing |
| `busy` | The job runs slower than it could; the verdict names the cause and what would help | Tells you, and offers a change only if time matters to you |
| `tight` | Memory, disk or GPU memory is close to its limit | Tells you, and offers one size up before it becomes `too small` |
| `too small` | Processes were killed because memory ran out, or less than 1 GB of disk is free | Stops the job, offers one size up with its price, and asks |

The agent on the node has the same rule from its side. When a command there is
killed because memory ran out, or the disk fills up, it does not run the same
thing again and hope: it commits what it has, notes what happened, stops, and
says so. A retry that dies the same way only keeps the rental running.

When the job is done, your agent tells you how much memory it used at its peak
(on Linux nodes), so the next order of the same job starts from a measurement
instead of an estimate.

## One size up, or a split

One size up is not the only answer. When the job has parts that can run apart,
such as test shards, independent modules or separate datasets, two or four
machines of the current size can give the same power or more. Your agent
prices both, offers the cheaper one that gives at least the same power, and
says why. The price decides, not a rule.

A split also helps when one size up is sold out: two smaller machines can
often be ordered when one bigger one cannot.

A split does not help one process that runs out of memory or GPU memory: that
process needs a bigger machine. And each machine is billed on its own, so
splitting a short job pays the minimum billing period more than once.

Nothing is ordered until you say yes.

## Settings

Show the settings, or change one, with
`~/.claude/skills/lyt-nodes/agentwork.sh autoscale`, followed by `on`, `off`,
`local-sizing yes` or `no`, or a setting and a whole number. Your agent can do
it for you.

```bash
~/.claude/skills/lyt-nodes/agentwork.sh autoscale                      # show them all
~/.claude/skills/lyt-nodes/agentwork.sh autoscale off
~/.claude/skills/lyt-nodes/agentwork.sh autoscale memory-peak-pct 80
```

| Setting | Default | What it means |
|---|---|---|
| `on` / `off` | `on` | Whether the agent sizes, checks and offers at all |
| `local-sizing` | `no` | `yes` lets the agent run a small part of the job on your machine to measure it |
| `memory-free-pct` | `10` | `tight` when less memory than this is free (Linux) |
| `memory-peak-pct` | `85` | `tight` when the job's peak has reached this share of the memory: the early warning, before anything is killed (Linux) |
| `memory-pressure-pct` | `10` | `tight` when processes waited for memory this share of the last 10 seconds (Linux) |
| `swap-full-pct` | `80` | `tight` when swap is this full (Linux) |
| `disk-free-mb` | `2048` | `tight` when less disk than this is free |
| `load-per-core` | `2` | `busy` when the load is higher than this per core |
| `cpu-steal-pct` | `20` | `busy` when other tenants take this share of a shared CPU; a dedicated class runs at full speed (Linux) |
| `io-wait-pct` | `20` | `busy` when the CPU waits for the disk this share of the time (Linux) |
| `gpu-memory-pct` | `90` | `tight` when this share of the GPU memory is in use |
| `gpu-busy-pct` | `95` | `busy` when the GPU is this busy |
| `hard-memory-pct` | `95` | A job handed over with `run` is stopped and its work saved when memory and swap together are this full (Linux) |
| `hard-pressure-full-pct` | `5` | ... or when the machine spends this share of the time waiting for memory (Linux) |
| `death-horizon-min` | `15` | ... or when memory or disk will be full within this many minutes at the current pace (Linux) |
| `pause-max-min` | `0` | `0`: a stopped job waits for your answer, at the latest until the node's rental ends. Above `0`: it goes on where it was after this many minutes |
| `help-after-min` | `60` | A job with a `TASKS.md` list tells you when more than this many minutes of tasks are left at its pace |
| `move-to` | `standard` | Where a job may be moved or get help (see "Where a job may go") |

A share is a whole number from 1 to 99. `disk-free-mb`, `load-per-core`,
`death-horizon-min` and `help-after-min` take any whole number from 1 up, and
`pause-max-min` any whole number from 0 up.

Swap in use is not a warning on its own; waiting for memory is. On a Mac,
memory is `tight` when macOS itself reports critical memory pressure.

The settings are saved in `~/.config/lytnode/`, and `bash uninstall.sh`
removes them. For one run, the environment wins over the saved setting:
`LYT_NODES_AUTOSCALE=off`, `LYT_NODES_LOCAL_SIZING=yes`, and for a limit
`LYT_NODES_AUTOSCALE_` followed by its name in capitals with `_` for `-`, such
as `LYT_NODES_AUTOSCALE_MEMORY_PEAK_PCT=80`. What you tell your agent, such as
"no autoscale for this job", wins over both.

## With autoscale off

Your agent recommends from the starting points above without sizing the job,
and checks the node only when you ask.
