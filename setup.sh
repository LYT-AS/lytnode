#!/usr/bin/env bash
# One command from nothing to a working lytnode client on YOUR machine.
#
#   bash setup.sh --agent claude            # or codex, cursor, opencode, gemini, pi
#   bash setup.sh --agent claude --url https://nodes.lyt.no
#   bash setup.sh --agent claude --non-interactive   # never prompts; exits 2 without a key
#   bash setup.sh --agent claude --with-post         # add the optional message channel
#
# THE MENU. Before anything is written, setup shows one list of choices with
# their defaults, and a number changes one; Enter goes on. Every choice has a
# flag, and a flag you give is shown as already chosen. Without a terminal
# (an agent runs this) there is no menu to show, so setup prints the questions
# with their flags, names the agent's own question tool, and stops with exit 5
# before writing anything; the agent asks, then runs setup again. With
# --non-interactive there is no menu and no stop: the defaults below, and
# whatever flags were given.
#
#   1  message channel         --with-post | --without-post     default: no
#   2  hooks for your agent    --hooks project | global          default: project
#   3  node may push to you    --node-push yes | no              default: no (opt-in)
#   4  node guard here too     --guard yes | no                  default: no
#   5  API key for             --key-scope user | project        default: user
#
# 2-4 only apply with the message channel. "project" hooks go in a personal
# file in the project (Claude Code: .claude/settings.local.json), kept out of
# git on this machine only; "global" means every project. --project <dir>
# names the project (default: the directory this clone sits in).
#
# What it does, in order, and nothing more:
#   1. checks the tools it needs and names every missing one at once
#   2. makes the two ssh key pairs the double lock needs (login + certificate)
#      if they do not exist - never over an existing one
#   3. stores your API key in ~/.config/lytnode/api-key (0600) from the
#      LYT_NODES_API_KEY variable, an existing file, or a prompt that does not echo;
#      with --key-scope project in <project>/.lytnode/api-key instead, out of git
#   4. fetches the licensed part of the package with your key; run setup.sh
#      again to update - this step always runs, and there is no separate
#      --update flag
#   5. puts the ssh Include in place so `ssh <node>` works after a rental
#   6. installs the package for the agent you chose (install.sh)
#   7. registers the MCP server under its one name, lytnode (connect.sh),
#      which makes a real call before it says anything went fine
#   8. for Claude Code: runs `claude setup-token` once and keeps the token in
#      ~/.config/lytnode/claude-token (0600), so a node never asks you to log in.
#      With no terminal (an agent runs this, or --non-interactive) the sign-in
#      is opened by lyt-node-core/claude-token.py, which prints the address;
#      the code from the browser goes back with `claude-token.py code <code>`
#   9. remembers the URL, the agent and your answers to the menu in
#      ~/.config/lytnode/
#
# Bonus: talk with your nodes. The message channel (the `post` skill, a small
# Python environment and hooks for your agent) lets a node tell your session
# when a job is done or blocked. It is optional and never needed to rent a
# node.
#
# What this never touches in your project: .gitignore, .claude/settings.json,
# CLAUDE.md, AGENTS.md, and a skill of the same name that is not ours. What it
# writes there is kept out of git in .git/info/exclude, a file git never
# commits, inside a marked block that bash uninstall.sh removes.
#
# This script never prints a key or a token and never passes one as an
# argument. One exception it cannot remove: `claude mcp add` (run by
# connect.sh) takes the key as an argument, so it is visible in `ps` for the
# moment that command runs; the tool has no other way.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS="claude codex cursor opencode gemini pi"
AGENT="claude"
URL="${LYT_NODES_URL:-https://nodes.lyt.no}"
INTERACTIVE=1
WITH_POST=""
PROJECT_DIR=""
HOOKS=""
NODE_PUSH=""
GUARD=""
KEY_SCOPE=""

CONF_DIR="$HOME/.config/lytnode"
KEY_FILE="${LYT_NODES_KEY_FILE:-$CONF_DIR/api-key}"
TOKEN_FILE="$CONF_DIR/claude-token"
LOGIN_KEY="${LYT_NODES_SSH_KEY:-$HOME/.ssh/id_ed25519}"
CERT_KEY="${LYT_NODES_CERT_KEY:-$HOME/.ssh/lytnode_cert}"
SSH_CONF="$HOME/.ssh/lytnode.conf"

# Passes text through as it arrives, with anything shaped like a Claude token
# replaced. A token split across two reads is held back until it is complete.
# >>> mask-token
MASK_TOKEN='
import os, re, sys
TOKEN = re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}")
PREFIX = "sk-ant-"
def mask(text):
    return TOKEN.sub("[token stored, not shown]", text)
def split(buf):
    m = re.search(r"sk-ant-[A-Za-z0-9_-]*$", buf)
    if m:
        return buf[:m.start()], buf[m.start():]
    for k in range(min(len(PREFIX), len(buf)), 0, -1):
        if PREFIX.startswith(buf[-k:]):
            return buf[:-k], buf[-k:]
    return buf, ""
held = ""
while True:
    chunk = os.read(0, 4096)
    if not chunk:
        break
    ready, held = split(held + chunk.decode("utf-8", "replace"))
    sys.stdout.write(mask(ready))
    sys.stdout.flush()
sys.stdout.write(mask(held))
sys.stdout.flush()
'
# <<< mask-token

# One-line description: prints a step heading.
step() { printf '\n== %s\n' "$*"; }
# One-line description: prints a failure and exits with the given code.
die() { local code="$1"; shift; printf 'setup: %s\n' "$*" >&2; exit "$code"; }

usage() {
    # The header comment, up to the first line of code, whatever its length.
    sed -n '2,/^set -euo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --agent) [ -n "${2:-}" ] || die 64 "--agent needs a name (${AGENTS// /, })"; AGENT="$2"; shift 2 ;;
        --url) [ -n "${2:-}" ] || die 64 "--url needs an address"; URL="$2"; shift 2 ;;
        --non-interactive) INTERACTIVE=0; shift ;;
        --with-post) WITH_POST=yes; shift ;;
        --without-post) WITH_POST=no; shift ;;
        --project) [ -n "${2:-}" ] || die 64 "--project needs a directory"; PROJECT_DIR="$2"; shift 2 ;;
        --hooks)
            case "${2:-}" in project | global) HOOKS="$2" ;; *) die 64 "--hooks must be project or global" ;; esac
            shift 2 ;;
        --node-push)
            case "${2:-}" in yes | no) NODE_PUSH="$2" ;; *) die 64 "--node-push must be yes or no" ;; esac
            shift 2 ;;
        --guard)
            case "${2:-}" in yes | no) GUARD="$2" ;; *) die 64 "--guard must be yes or no" ;; esac
            shift 2 ;;
        --key-scope)
            case "${2:-}" in user | project) KEY_SCOPE="$2" ;; *) die 64 "--key-scope must be user or project" ;; esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die 64 "unknown option $1 (see --help)" ;;
    esac
done

case " $AGENTS " in
    *" $AGENT "*) ;;
    *) die 64 "unknown agent \"$AGENT\" (${AGENTS// /, })" ;;
esac
[ -n "$URL" ] || die 64 "--url must not be empty"

# ── 1. Tools ─────────────────────────────────────────────────────────────────
step "checking the tools this needs"
case "$AGENT" in
    claude) AGENT_BIN=claude ;;
    codex) AGENT_BIN=codex ;;
    cursor) AGENT_BIN=cursor-agent ;;
    opencode) AGENT_BIN=opencode ;;
    gemini) AGENT_BIN=gemini ;;
    pi) AGENT_BIN=pi ;;
esac
MISSING=""
for tool in git ssh ssh-keygen curl tar jq rsync python3 "$AGENT_BIN"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        MISSING="$MISSING $tool"
    fi
done
if [ -n "$MISSING" ]; then
    printf 'setup: missing:%s\n' "$MISSING" >&2
    printf '  install them first; %s is the agent you chose with --agent\n' "$AGENT_BIN" >&2
    exit 1
fi
echo "  all present"

# Tailscale is not needed to install, only to reach a node, so a missing one is
# a warning and never a stop. The macOS app keeps its command inside the app
# bundle rather than on PATH, so that path is looked at too.
if command -v tailscale >/dev/null 2>&1 \
        || [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    echo "  tailscale present"
else
    echo "  note: a node is reached over your Tailscale network; install and sign in"
    echo "  on this machine before your first order (https://tailscale.com/download)"
fi

# ── The project, and the menu ────────────────────────────────────────────────
# The project is the directory this clone was cloned into, unless --project
# says otherwise. Resolved physically (`pwd -P`), because git reports its top
# level that way and the paths kept out of git are counted from there.
if [ -z "$PROJECT_DIR" ]; then
    PROJECT_DIR="$(dirname "$HERE")"
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)" || die 64 "--project: no such directory"
HOME_REAL="$(cd "$HOME" && pwd -P)"

# Defaults for what no flag set. A node may push to you only when you choose
# it: push lets a node log in to this machine, so it is opt-in, and without
# it this machine fetches the messages itself (owner, 2026-10-02: "an option,
# so they must choose it of their own accord"; until then it followed 1).
NODE_PUSH_SET=0
[ -n "$NODE_PUSH" ] && NODE_PUSH_SET=1
[ -n "$WITH_POST" ] || WITH_POST=no
[ -n "$HOOKS" ] || HOOKS=project
[ -n "$GUARD" ] || GUARD=no
[ -n "$KEY_SCOPE" ] || KEY_SCOPE=user
[ "$NODE_PUSH_SET" = 1 ] || NODE_PUSH=no

# One-line description: prints the menu with the choices as they stand.
show_menu() {
    printf '\n== What to install. Enter keeps these; type a number to change one.\n'
    printf '  1  message channel ......... %s\n' "$WITH_POST"
    printf '       a node tells your session here when a job is done or blocked\n'
    if [ "$WITH_POST" = yes ]; then
        printf '  2  hooks for your agent .... %s\n' "$HOOKS"
        printf '       project: this project only, in a personal file kept out of git; global: every project\n'
        printf '  3  node may push to you .... %s\n' "$NODE_PUSH"
        printf '       yes: the node'"'"'s key goes into ~/.ssh/authorized_keys, so a message arrives at once\n'
        printf '       no: the node never connects here; this machine fetches its messages every minute while a job runs\n'
        printf '  4  node guard here too ..... %s\n' "$GUARD"
        printf '       yes: this machine'"'"'s Cursor and OpenCode also refuse git push and similar\n'
    fi
    printf '  5  API key for ............. %s\n' "$KEY_SCOPE"
    printf '       user: all your projects; project: this project only, kept in .lytnode/ and out of git\n'
}

if [ "$INTERACTIVE" = 1 ] && [ -t 0 ]; then
    while true; do
        show_menu
        printf '  Change (1-5), or Enter to continue: '
        read -r choice || choice=""
        case "$choice" in
            "") break ;;
            1)
                # Push is never switched on by choosing the channel: it is
                # opt-in, chosen with 3 (2026-10-02). Without the channel it
                # cannot apply, so switching the channel off takes it off too.
                if [ "$WITH_POST" = yes ]; then WITH_POST=no; else WITH_POST=yes; fi
                [ "$WITH_POST" = yes ] || NODE_PUSH=no ;;
            2 | 3 | 4)
                if [ "$WITH_POST" != yes ]; then
                    echo "  2 to 4 apply only with the message channel; choose 1 first"
                    continue
                fi
                case "$choice" in
                    2) if [ "$HOOKS" = project ]; then HOOKS=global; else HOOKS=project; fi ;;
                    3) if [ "$NODE_PUSH" = yes ]; then NODE_PUSH=no; else NODE_PUSH=yes; fi; NODE_PUSH_SET=1 ;;
                    4) if [ "$GUARD" = yes ]; then GUARD=no; else GUARD=yes; fi ;;
                esac ;;
            5) if [ "$KEY_SCOPE" = user ]; then KEY_SCOPE=project; else KEY_SCOPE=user; fi ;;
            *) echo "  type a number from 1 to 5, or press Enter" ;;
        esac
    done
elif [ "$INTERACTIVE" = 1 ]; then
    # No terminal, and nobody said --non-interactive: an agent is running this
    # bare. The menu cannot be shown here, and installing with the defaults in
    # silence is not what a person at a terminal gets (owner, 2026-09-30: "it
    # should work the same as in the terminal"). So the questions go out as
    # text, with the flag each answer becomes and the agent's own question
    # tool named, and setup stops before it writes anything. --non-interactive
    # is the agent saying "I have asked".
    case "$AGENT" in
        claude) ASK_TOOL="AskUserQuestion (Claude Code, also inside VS Code)" ;;
        cursor) ASK_TOOL="the ask question tool (Cursor)" ;;
        codex) ASK_TOOL="request_user_input (Codex, Plan mode); in the default mode, ask in plain words" ;;
        opencode) ASK_TOOL="the question tool (OpenCode)" ;;
        gemini) ASK_TOOL="ask_user (Gemini CLI); headless has none, then ask in plain words" ;;
        *) ASK_TOOL="plain words, one question at a time" ;;
    esac
    show_menu
    printf '\n== setup: no terminal to show the menu in, so nothing was written.\n'
    printf '  Ask the person the choices above, with your own question tool: %s.\n' "$ASK_TOOL"
    printf '  Then run setup again with --non-interactive and each answer as a flag:\n'
    printf '    1  --with-post | --without-post\n'
    printf '    2  --hooks project | global      (with 1 only)\n'
    printf '    3  --node-push yes | no           (with 1 only)\n'
    printf '    4  --guard yes | no               (with 1 only)\n'
    printf '    5  --key-scope user | project\n'
    printf '  A choice you do not pass keeps the default shown above.\n'
    exit 5
fi

# The home directory is no project: its .claude/ IS the global settings, and
# a key "for this project only" there would be a key for everything. Said, and
# the choice falls back rather than doing something the menu did not promise.
if [ "$PROJECT_DIR" = "$HOME_REAL" ]; then
    if [ "$WITH_POST" = yes ] && [ "$HOOKS" = project ]; then
        echo "  note: this clone sits in your home directory, so there is no project for"
        echo "  project hooks; they are left out (run again with --project <dir>, or --hooks global)"
        HOOKS=none
    fi
    if [ "$KEY_SCOPE" = project ]; then
        echo "  note: no project here either for a project key; the key is kept for all projects"
        KEY_SCOPE=user
    fi
fi

# A KEY FOR THIS PROJECT ONLY lives in the project, in .lytnode/api-key,
# kept out of git (owner, 2026-09-25: several keys, and each project chooses).
# agentwork.sh and connect.sh look there first, walking up from where they run.
# A key file named in LYT_NODES_KEY_FILE still wins, and is never treated as
# ours to protect or remove.
PROJECT_KEY_DIR=""
if [ "$KEY_SCOPE" = project ] && [ -z "${LYT_NODES_KEY_FILE:-}" ]; then
    PROJECT_KEY_DIR="$PROJECT_DIR/.lytnode"
    KEY_FILE="$PROJECT_KEY_DIR/api-key"
fi

# One-line description: stops with exit 2 and says where the missing key belongs.
#
# A key for one project is never taken from ~/.config/lytnode/api-key on its
# own: which key a project uses is the person's choice (owner, 2026-09-25).
# The message names the file, and how to use the key for all projects here
# too when that is what they want (QC 2026-09-25: from "no API key" an agent
# was sent back to a step that stores the key for all projects).
no_key() {
    if [ -n "$PROJECT_KEY_DIR" ]; then
        local same=""
        if [ -s "$CONF_DIR/api-key" ]; then
            same="
  To use your key for all projects here too:
    mkdir -p -m 700 $PROJECT_KEY_DIR
    install -m 600 $CONF_DIR/api-key $KEY_FILE"
        fi
        die 2 "no key for this project. Put the key this project should use in
  $KEY_FILE (mode 600), or give it in LYT_NODES_API_KEY.$same"
    fi
    die 2 "no API key. Put it in LYT_NODES_API_KEY or ~/.config/lytnode/api-key"
}

# The choices, remembered for the scripts that act on them later (agentwork.sh
# reads node-push at every start). With no message channel, 2-4 are "no".
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"
if [ "$WITH_POST" != yes ]; then
    HOOKS=none
    NODE_PUSH=no
    GUARD=no
fi
(umask 077
 printf '%s' "$WITH_POST" > "$CONF_DIR/post"
 printf '%s' "$HOOKS" > "$CONF_DIR/hooks"
 printf '%s' "$NODE_PUSH" > "$CONF_DIR/node-push"
 printf '%s' "$GUARD" > "$CONF_DIR/guard"
 printf '%s' "$KEY_SCOPE" > "$CONF_DIR/key-scope")
echo "  chosen: message channel $WITH_POST, hooks $HOOKS, node push $NODE_PUSH, guard $GUARD, key for $KEY_SCOPE"

# ── 2. The two ssh key pairs ─────────────────────────────────────────────────
# Two SEPARATE pairs are required. Sending the same key for both is rejected.
step "ssh keys"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
for pair in "$LOGIN_KEY:lytnode login" "$CERT_KEY:lytnode certificate"; do
    path="${pair%%:*}"
    comment="${pair#*:}"
    if [ -f "$path" ]; then
        echo "  $path exists - kept"
    else
        ssh-keygen -t ed25519 -f "$path" -N "" -C "$comment" -q
        echo "  $path created"
    fi
done
echo "  login key: $LOGIN_KEY (LYT_NODES_SSH_KEY chooses another)"
echo "  certificate key: $CERT_KEY (LYT_NODES_CERT_KEY chooses another)"
if cmp -s "$LOGIN_KEY.pub" "$CERT_KEY.pub"; then
    die 1 "$LOGIN_KEY and $CERT_KEY are the same key; the certificate key must be its own pair"
fi

# ── 3. The API key ───────────────────────────────────────────────────────────
step "API key"
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"
if [ -n "$PROJECT_KEY_DIR" ]; then
    # Private, and out of git in two ways: its own .gitignore ("*") keeps the
    # key out of any repository at once, also if a later step fails; our block
    # in .git/info/exclude follows below. Recorded in the project record, which
    # no older uninstall.sh reads as a list of paths to delete.
    mkdir -p "$PROJECT_KEY_DIR"
    chmod 700 "$PROJECT_KEY_DIR"
    [ -e "$PROJECT_KEY_DIR/.gitignore" ] || (umask 077; printf '*\n' > "$PROJECT_KEY_DIR/.gitignore")
    for row in "project $PROJECT_DIR" "project-file $PROJECT_KEY_DIR"; do
        grep -qxF "$row" "$CONF_DIR/project-records" 2>/dev/null \
            || (umask 077; printf '%s\n' "$row" >> "$CONF_DIR/project-records")
    done
    echo "  this project's key: $KEY_FILE (other projects keep their own, or the one in $CONF_DIR)"
fi
if [ -n "${LYT_NODES_API_KEY:-}" ]; then
    (umask 077; printf '%s' "$LYT_NODES_API_KEY" > "$KEY_FILE")
    echo "  stored from LYT_NODES_API_KEY in $KEY_FILE"
elif [ -s "$KEY_FILE" ]; then
    chmod 600 "$KEY_FILE"
    echo "  using $KEY_FILE"
elif [ "$INTERACTIVE" = 1 ]; then
    printf '  paste your lytnode API key (lyt_live_..., not shown): '
    IFS= read -rs PASTED
    echo
    [ -n "$PASTED" ] || no_key
    (umask 077; printf '%s' "$PASTED" > "$KEY_FILE")
    unset PASTED
    echo "  stored in $KEY_FILE"
else
    no_key
fi

# ── 4. The licensed part of the package ──────────────────────────────────────
# WHY THIS STEP EXISTS. The public repository carries what you can read before
# you buy: this script, the docs, the message channel and the licences. The
# client itself - the skill, the agent adapters and their installer - is served
# from the service to a caller holding a key. Owner's decision 2026-09-22.
#
# IT RUNS EVERY TIME, and that is the upgrade path. There is no --update flag:
# running setup.sh again fetches the current client and overwrites the previous
# one in place. Everything else in this script already behaves that way - keys,
# key file, ssh Include and token are all kept rather than replaced.
#
# The key is read from the FILE, never passed as an argument. `ps` shows every
# argument of a running command to every user on the machine.
step "fetching the licensed part of the package"
# The header goes to curl as a FILE (`-H @file`), so the key is never an
# argument of any process. `echo` is a shell builtin: writing the file starts
# no process either. The file is private (mktemp makes it 0600) and removed
# on every way out of this script.
#
# Unpacked into a staging directory first and moved in only when the whole
# archive arrived: a download that breaks halfway must not leave a half-new
# client beside the clone, and "Nothing has been installed" must be true.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
HEADER="$WORK/header"
(umask 077; echo "Authorization: Bearer $(tr -d '\n' < "$KEY_FILE")" > "$HEADER")
mkdir "$WORK/package"
if ! curl -fsSL -H @"$HEADER" "$URL/api/package.tar.gz" | tar xz -C "$WORK/package"; then
    die 3 "could not fetch the licensed part of the package from $URL.
  Check that the key in $KEY_FILE is valid and not revoked, and that the
  address is right (--url). Nothing has been installed."
fi
rm -f "$HEADER"
rsync -a "$WORK/package/" "$HERE/"
echo "  unpacked into $HERE"

# ── 5. ssh Include ───────────────────────────────────────────────────────────
# The same line agentwork.sh keeps for itself; first, because ssh keeps the
# first value it sees for an option.
step "ssh config"
touch "$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"
if grep -qF "Include $SSH_CONF" "$HOME/.ssh/config"; then
    echo "  Include already present"
else
    tmp="$(mktemp)"
    {
        printf '# lytnode: rented nodes. Keep this first - ssh keeps the first value it sees.\n'
        printf 'Include %s\n\n' "$SSH_CONF"
        cat "$HOME/.ssh/config"
    } > "$tmp"
    cat "$tmp" > "$HOME/.ssh/config"
    rm -f "$tmp"
    touch "$SSH_CONF"
    chmod 600 "$SSH_CONF"
    echo "  Include added"
fi

# ── Bonus: talk with your nodes ──────────────────────────────────────────────
step "bonus: talk with your nodes (optional)"
# The menu's choices need a client that knows them. The client comes from the
# service and this script from the clone, and an older client would put the
# hooks in the project's SHARED settings or keep the guard the person said no
# to (QC 2026-09-25). Then the channel is left out this time, and said.
CLIENT_KNOWS_MENU=1
grep -q -- '--hooks project|global' "$HERE/install.sh" || CLIENT_KNOWS_MENU=0
if [ "$AGENT" != claude ]; then
    grep -q -- '--hooks project|global|none' "$HERE/adapters/install-agent.sh" 2>/dev/null || CLIENT_KNOWS_MENU=0
    grep -q -- '--guard yes|no' "$HERE/adapters/install-agent.sh" 2>/dev/null || CLIENT_KNOWS_MENU=0
fi
if [ "$WITH_POST" = yes ] && [ "$CLIENT_KNOWS_MENU" = 0 ]; then
    echo "  note: this version of the client cannot put the message channel where the"
    echo "  menu says, so it is left out this time; run setup.sh again when the service is updated"
    WITH_POST=no
    HOOKS=none
    NODE_PUSH=no
    GUARD=no
    (umask 077
     printf '%s' "$WITH_POST" > "$CONF_DIR/post"
     printf '%s' "$HOOKS" > "$CONF_DIR/hooks"
     printf '%s' "$NODE_PUSH" > "$CONF_DIR/node-push"
     printf '%s' "$GUARD" > "$CONF_DIR/guard")
fi
if [ "$WITH_POST" = yes ]; then
    echo "  yes: the message channel will be installed"
else
    echo "  no: nothing of the message channel is installed (--with-post adds it later)"
fi

# A key for one project needs a client that knows it, like the channel above:
# an older node script reads only $CONF_DIR/api-key, and an older installer for
# the other agents writes no project files. Then the project's key stays where
# it is, for when the service is updated, and the key for all projects is
# filled from it only if there is none - never overwritten.
CLIENT_KNOWS_KEY_SCOPE=1
if [ "$KEY_SCOPE" = project ]; then
    if [ -n "$PROJECT_KEY_DIR" ]; then
        grep -qF '.lytnode/api-key' "$HERE/lyt-node-core/agentwork.sh" || CLIENT_KNOWS_KEY_SCOPE=0
    fi
    if [ "$AGENT" != claude ]; then
        grep -q -- '--key-scope user|project' "$HERE/adapters/install-agent.sh" 2>/dev/null || CLIENT_KNOWS_KEY_SCOPE=0
    fi
    if [ "$CLIENT_KNOWS_KEY_SCOPE" = 0 ]; then
        echo "  note: this version of the client cannot use a key for one project yet; it"
        echo "  reads $CONF_DIR/api-key. Run setup.sh again when the service is updated"
        if [ -n "$PROJECT_KEY_DIR" ] && [ ! -s "$CONF_DIR/api-key" ]; then
            (umask 077; cat "$KEY_FILE" > "$CONF_DIR/api-key")
            echo "  $CONF_DIR/api-key did not exist: it now holds this project's key too"
        fi
    fi
fi

# ── 6. The package ───────────────────────────────────────────────────────────
step "installing the package for $AGENT"
# The URL and the key travel in the environment: install.sh renders the
# adapter templates with the URL and registers this machine's post participant
# with the key. Both are read from variables, never from arguments.
#
# The choice about the extra is passed on only to a client that knows it. The
# client comes from the service and this script from the clone, so the two can
# be of different ages; an older client would refuse the flag (the non-Claude
# installer stops on an unknown argument) or ignore it.
POST_ARGS=()
if grep -q -- '--without-post' "$HERE/install.sh"; then
    if [ "$WITH_POST" = yes ]; then
        # The client knows every choice here: checked in the bonus step.
        POST_ARGS=(--with-post --project "$PROJECT_DIR" --hooks "$HOOKS" --guard "$GUARD")
    else
        POST_ARGS=(--without-post)
        # The project matters without the channel too: Gemini's project copy
        # of the skill goes there, recorded and kept out of git (QC 2026-09-25).
        if grep -q -- '--project <dir>' "$HERE/install.sh"; then
            POST_ARGS+=(--project "$PROJECT_DIR")
        fi
    fi
    # A key for this project only, to a client that knows the choice.
    if [ "$KEY_SCOPE" = project ] && [ "$CLIENT_KNOWS_KEY_SCOPE" = 1 ]; then
        POST_ARGS+=(--key-scope project)
    fi
else
    echo "  note: this version of the client always installs the message channel;"
    echo "  your answer applies from the next version (run setup.sh again then)"
fi
set +e
LYT_NODES_URL="$URL" LYT_NODES_API_KEY="$(tr -d '\n' < "$KEY_FILE")" \
    bash "$HERE/install.sh" --agent "$AGENT" --no-models "${POST_ARGS[@]+"${POST_ARGS[@]}"}"
INSTALL_RC=$?
set -e
# Exit 4 from the installer: a lyt-nodes skill that is not ours is in the way,
# and nothing was installed for this agent. Not a ready setup (QC 2026-09-25).
if [ "$INSTALL_RC" = 4 ]; then
    die 4 "a lyt-nodes skill that is not ours is in the way (named above); nothing was installed for $AGENT.
  Remove or rename it, then run setup.sh again."
fi
# Any other failure stops setup AFTER the step below: an installer that failed
# halfway may already have written a file with the key in the project, and it
# is kept out of git first (QC 2026-09-25).

# ── Kept out of the project's git, on this machine only ─────────────────────
# What this setup wrote INSIDE the project - the clone itself, a personal
# settings file, a project key, per-agent files - goes into .git/info/exclude:
# git's own local ignore file, which is never committed and never changes the
# project's .gitignore. Our lines sit in one marked block, rewritten as a
# whole each run and removed whole by uninstall.sh. Exactly the paths we
# created, nothing of the person's own.
step "keeping what setup wrote out of your git"
EXCLUDE_PATHS=()
HERE_REAL="$(cd "$HERE" && pwd -P)"
case "$HERE_REAL" in "$PROJECT_DIR"/*) EXCLUDE_PATHS+=("$HERE_REAL/") ;; esac
if [ -n "$PROJECT_KEY_DIR" ]; then
    EXCLUDE_PATHS+=("$PROJECT_KEY_DIR/")
fi
# Only when our hooks are in it: a post skill that is not ours gets no hooks,
# and a path we did not write must not hide a file the person makes later.
if [ "$AGENT" = claude ] && [ "$WITH_POST" = yes ] && [ "$HOOKS" = project ] \
        && grep -q "inbox-peek.py" "$PROJECT_DIR/.claude/settings.local.json" 2>/dev/null; then
    EXCLUDE_PATHS+=("$PROJECT_DIR/.claude/settings.local.json")
fi
# Files the installers put in the project are in the project record.
if [ -f "$CONF_DIR/project-records" ]; then
    while IFS=' ' read -r kind path; do
        [ "$kind" = project-file ] || continue
        # The key directory is in the list already, as a directory.
        if [ -n "$PROJECT_KEY_DIR" ] && [ "$path" = "$PROJECT_KEY_DIR" ]; then continue; fi
        case "$path" in "$PROJECT_DIR"/*) EXCLUDE_PATHS+=("$path") ;; esac
    done < "$CONF_DIR/project-records"
fi
if ! TOP="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
    echo "  $PROJECT_DIR is not a git repository; nothing to keep out of git"
elif [ "${#EXCLUDE_PATHS[@]}" = 0 ]; then
    echo "  nothing was written inside the project"
else
    TOP="$(cd "$TOP" && pwd -P)"
    EXCLUDE_FILE="$(git -C "$PROJECT_DIR" rev-parse --git-path info/exclude)"
    case "$EXCLUDE_FILE" in /*) ;; *) EXCLUDE_FILE="$PROJECT_DIR/$EXCLUDE_FILE" ;; esac
    # The block is merged in python: a text file rewritten whole, from values
    # passed as arguments, never pasted into the program.
    python3 - "$EXCLUDE_FILE" "$TOP" "${EXCLUDE_PATHS[@]}" <<'PY'
import os
import sys

path, top, wanted = sys.argv[1], sys.argv[2], sys.argv[3:]
BEGIN = "# >>> lytnode: kept out of git on this machine only (bash uninstall.sh removes this block)"
END = "# <<< lytnode"
new = []
for p in wanted:
    if p.startswith(top + "/"):
        new.append("/" + p[len(top) + 1:])
try:
    with open(path) as f:
        lines = f.read().splitlines()
except FileNotFoundError:
    lines = []
kept, block, inside = [], [], False
for line in lines:
    if line == BEGIN:
        inside = True
    elif inside and line == END:
        inside = False
    elif inside:
        block.append(line)
    else:
        kept.append(line)
merged = []
for line in block + new:
    if line and line not in merged:
        merged.append(line)
out = kept + ([BEGIN] + merged + [END] if merged else [])
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".lytnode-tmp"
with open(tmp, "w") as f:
    f.write("\n".join(out) + "\n")
os.replace(tmp, path)
for line in merged:
    print(f"  kept out of your git locally: {line}")
PY
    # uninstall.sh finds the block through the project it is recorded under,
    # in the project record - never in installed-files, which an older
    # uninstall.sh reads as a list of paths to delete.
    if ! grep -qxF "project $PROJECT_DIR" "$CONF_DIR/project-records" 2>/dev/null; then
        (umask 077; printf 'project %s\n' "$PROJECT_DIR" >> "$CONF_DIR/project-records")
    fi
fi

if [ "$INSTALL_RC" != 0 ]; then
    exit "$INSTALL_RC"
fi

# ── 7. The MCP server, one name ──────────────────────────────────────────────
step "registering the MCP server (lytnode)"
if [ "$AGENT" = claude ] && [ "$KEY_SCOPE" = project ]; then
    # THIS PROJECT'S KEY, in Claude Code's LOCAL scope: it applies in this
    # project only and wins over a user-scope lytnode there. Claude Code keeps
    # it in ~/.claude.json, never in the project. Run from the project,
    # because that is what "local" means.
    (cd "$PROJECT_DIR" && LYT_NODES_URL="$URL" LYT_NODES_MCP_NAME=lytnode LYT_NODES_MCP_SCOPE=local \
        LYT_NODES_KEY_FILE="$KEY_FILE" bash "$HERE/lyt-node-core/connect.sh")
elif [ "$AGENT" = claude ]; then
    LYT_NODES_URL="$URL" LYT_NODES_MCP_NAME=lytnode LYT_NODES_KEY_FILE="$KEY_FILE" \
        bash "$HERE/lyt-node-core/connect.sh"
elif [ "$AGENT" = pi ]; then
    # pi has no MCP client and verify.sh does not know it (QC D, 2026-09-23):
    # install.sh gave it an extension instead, and there is nothing to verify here.
    echo "  pi reads the lytnode extension install.sh put in ~/.pi/agent/extensions;"
    echo "  ask pi \"which nodes do I have\" to prove it connects"
    if [ "$KEY_SCOPE" = project ]; then
        echo "  pi reads the key only from LYT_NODES_API_KEY: start it in this project with"
        echo "    LYT_NODES_API_KEY=\"\$(cat .lytnode/api-key)\" pi"
    fi
else
    echo "  $AGENT reads its MCP configuration from the template install.sh put in place;"
    echo "  run ./adapters/verify.sh $AGENT to prove it connects"
fi

# ── 8. Claude's token, once ──────────────────────────────────────────────────
# `claude setup-token` needs a browser, so it only runs when someone is here.
# The token is yours; agentwork.sh carries it to your node over your own ssh.
step "Claude login token"
if [ "$AGENT" != claude ]; then
    echo "  not needed for $AGENT"
elif [ -s "$TOKEN_FILE" ]; then
    chmod 600 "$TOKEN_FILE"
    echo "  $TOKEN_FILE exists - kept"
elif [ "$INTERACTIVE" = 0 ] || [ ! -t 0 ]; then
    # Nobody at a terminal: an agent is running this, or --non-interactive was
    # given. `claude setup-token` needs a terminal and a person for the browser
    # (measured 2026-09-17: without a terminal it prints nothing and waits), so
    # the helper opens it in the background and prints the sign-in address. The
    # code the browser shows comes back through `claude-token.py code <code>`.
    echo "  no terminal to sign in at, so the sign-in is handed to the helper:"
    if ! python3 "$HERE/lyt-node-core/claude-token.py" start; then
        echo "  no token stored yet. A node will ask you to log in until one is saved in $TOKEN_FILE;"
        echo "  run: python3 $HERE/lyt-node-core/claude-token.py start"
    fi
else
    echo "  running 'claude setup-token' - follow the browser flow it shows"
    captured="$(mktemp)"
    chmod 600 "$captured"
    # Copied to a private file so the token can be picked out afterwards, and
    # shown to the person through a filter: the link and the prompt are theirs
    # to act on, the token is not theirs to see scroll past. The filter passes
    # text on as it arrives, so a prompt without a line ending still shows.
    if ! claude setup-token 2>&1 | tee "$captured" | python3 -u -c "$MASK_TOKEN"; then
        echo "  'claude setup-token' did not finish cleanly"
    fi
    token="$(grep -oE 'sk-ant-[A-Za-z0-9_-]{20,}' "$captured" | tail -1 || true)"
    rm -f "$captured"
    if [ -z "$token" ]; then
        printf '  paste the token it showed (not echoed): '
        IFS= read -rs token
        echo
    fi
    if [ -n "$token" ]; then
        (umask 077; printf '%s' "$token" > "$TOKEN_FILE")
        unset token
        echo "  stored in $TOKEN_FILE"
    else
        echo "  no token stored; a node will ask you to log in until you save one in $TOKEN_FILE"
    fi
fi

# ── 9. Remember ──────────────────────────────────────────────────────────────
(umask 077; printf '%s' "$URL" > "$CONF_DIR/url"; printf '%s' "$AGENT" > "$CONF_DIR/agent")

step "setup: ready"
WHERE="any project"
if [ "$KEY_SCOPE" = project ]; then WHERE="this project ($PROJECT_DIR)"; fi
cat <<DONE
  Open $AGENT_BIN in $WHERE and say, in your own words:
    rent a node for this job               (your agent recommends one, with its price)
    start the node and send it this job: ...
    bring the work home
    release the node
DONE
