# Windows Server nodes

A Windows node is a clean Windows Server 2025 machine in your own Tailscale
network. It works differently from a Linux or Mac node, and this page is about
those differences. Everything not mentioned here (expiry, hold, extend,
release, prices per hour) is the same as for every other node.

## How it differs from a Linux or Mac node

| | Linux and Mac nodes | Windows nodes |
|---|---|---|
| What is on it | Your agent, the message channel, the agentwork session | Nothing of ours. A clean Windows Server |
| How you work on it | `start`, `run`, `status`, the agent does the work | Remote Desktop or ssh. You or your agent set it up yourselves |
| How you log in | Your ssh keys, with a certificate that expires with the node | User `Administrator` with a password, and ssh with your key |
| Shell over ssh | bash or zsh | PowerShell |
| Ready after | Seconds to a few minutes | A few minutes, at most 40. Windows installs itself first |
| Tools and models at order time | `toolchain` and `models` | Not offered. Install what you need on the node |
| Work comes home | As a git branch, by `agentwork.sh` | You copy it home yourself, over ssh or Remote Desktop |

`~/.claude/skills/lyt-nodes/agentwork.sh start` and `status <node>` refuse a Windows node
and say how to reach it. `status` without a node lists it as
`WINDOWS`.

## Classes

| Class | vCPU | Memory | Disk |
|---|---|---|---|
| S | 2 | 8 GB | 128 GB |
| M | 4 | 16 GB | 128 GB |
| L | 8 | 32 GB | 256 GB |
| XL | 16 | 64 GB | 256 GB |

In the EU the classes are `win_s` to `win_xl`. In other countries they carry
the country first, such as `uk_win_s` or `jp_win_m`. `list_offers` shows every
country that has them and the price in each, and the catalogue on
<https://node.lyt.no/pricing> has a **Windows** filter.

## Order

Order as for any node: `provision_node` with the class and hours, a new
Tailscale auth key (`reusable=false`, `preauthorized=true`, `ephemeral=false`)
and your two ssh public keys. `agent`, `toolchain` and `models` do not apply.

**The answer carries the administrator password once**, as `windows_user` and
`windows_password`. Save it at once, for example:

```bash
umask 077
printf '%s\n' '<the password>' > ~/.ssh/lytnode/<node-id>-windows.txt
```

We keep no copy. If the password is lost, release the node and order a new
one.

## Connect

Both ways work only over your Tailscale network. The node's public address is
closed.

**Remote Desktop.** Connect to the node's Tailscale address with user
`Administrator` and the password. On a Mac or an iPhone, use Microsoft's
**Windows App**. On Windows, use Remote Desktop Connection. Two Remote Desktop
sessions can be open at a time, which is Windows Server's own limit for
administration.

**ssh.** Run `~/.claude/skills/lyt-nodes/agentwork.sh nodes` once after the order. It writes the node
into your ssh config, so this works:

```bash
ssh node-xxxxxxxx
```

You log in as `Administrator` with the key you ordered with, and land in
PowerShell. Copy work home with `scp` over the same name.

## Microsoft's licence

Windows Server on a rented node is licensed to us by Microsoft for the time
you rent it, and Microsoft's conditions are passed on to you. Read them in the
section "Windows machines and Microsoft's licence" of the Terms of Service:
<https://node.lyt.no/terms>.
