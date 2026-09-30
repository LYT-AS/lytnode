#!/usr/bin/env bash
# Removes what setup.sh and install.sh put on this machine. The way to start over.
#
#   bash uninstall.sh                     # remove it all, say what went
#   bash uninstall.sh --dry-run           # say what would go, remove nothing
#   bash uninstall.sh --keep-credentials  # keep the API key file and the Claude token
#   bash uninstall.sh --yes               # also remove the fetched client from this
#                                         # folder without asking (lyt-node-core/,
#                                         # adapters/, install.sh)
#
# What it never touches, whatever the flags:
#   * your ssh key pairs (~/.ssh/id_ed25519*, ~/.ssh/lytnode_cert*) - a running
#     node is opened with them, and the login key is often your own
#   * a `post` skill, a participants file or hook entries it did not install
#     itself (install.sh records what it created in ~/.config/lytnode/installed-files;
#     without that record those three are left alone)
#   * anything of yours next to the files it wrote (a config file we could not
#     write because yours existed got a `.lyt-new` twin; the twin goes, yours stays)
#   * anything outside your home directory and the projects setup.sh was run
#     for, whatever the record says
#   * a lyt-nodes skill that is not ours (ours carries our mark, or is an
#     install from before the mark)
#   * your .gitignore; only our own marked block in .git/info/exclude goes
#
# Everything it removes is named on the way out, one line each.
set -euo pipefail

DRY_RUN=0
KEEP_CREDENTIALS=0
ASSUME_YES=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --keep-credentials) KEEP_CREDENTIALS=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        -h | --help) sed -n '2,23p' "$0"; exit 0 ;;
        *) echo "uninstall: unknown argument $1" >&2; exit 64 ;;
    esac
done

CONF_DIR="$HOME/.config/lytnode"
RECORD="$CONF_DIR/installed-files"
# Rows naming a customer's PROJECT live in a file of their own (2026-09-25):
# the project, hooks in its settings, files we put in it. This script reads it
# with a loop that has NO delete-anything branch - an unknown row there is
# left alone, never removed.
PROJECT_RECORD="$CONF_DIR/project-records"
CLAUDE_SKILL="$HOME/.claude/skills/lyt-nodes"
AGENTS_SKILL="$HOME/.agents/skills/lyt-nodes"
# This folder (the clone) and the project it was cloned into. The project copy
# of the skill (Gemini's) is looked for there and nowhere else: the directory
# someone happens to run this from may be any project of theirs.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_OF_CLONE="$(dirname "$HERE")"
HOME_REAL="$(cd "$HOME" && pwd)"
SSH_CONF="$HOME/.ssh/lytnode.conf"
CERT_DIR="$HOME/.ssh/lytnode"
REMOVED=0

# One-line description: prints a step heading.
step() { echo ""; echo "== $*"; }

# One-line description: true when a path lies inside the home directory.
under_home() {
    # A path that climbs (`..`) can leave home while still starting with it.
    case "$1" in
        *"/../"* | *"/..") return 1 ;;
    esac
    case "$1" in
        "$HOME"/* | "$HOME_REAL"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# One-line description: removes a path (file, directory or link) and says so.
gone() {
    local path="$1"
    if [ -L "$path" ] || [ -e "$path" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            echo "  would remove $path"
        else
            rm -rf "$path"
            echo "  removed $path"
        fi
        REMOVED=$((REMOVED + 1))
    fi
}

# ── 1. The MCP registration in Claude Code ───────────────────────────────────
# Both names: `lytnode` is the one setup.sh uses; `lyt` was the name an older
# connect.sh registered, and a machine that saw both has two entries pointing
# at the same service.
step "MCP registration"
if command -v claude >/dev/null 2>&1; then
    for name in lytnode lyt; do
        for scope in user local; do
            if claude mcp get "$name" >/dev/null 2>&1; then
                if [ "$DRY_RUN" = 1 ]; then
                    echo "  would run: claude mcp remove --scope $scope $name"
                    REMOVED=$((REMOVED + 1))
                    break
                elif claude mcp remove --scope "$scope" "$name" >/dev/null 2>&1; then
                    echo "  removed MCP server '$name' ($scope scope)"
                    REMOVED=$((REMOVED + 1))
                fi
            fi
        done
    done
else
    echo "  claude is not installed here; nothing to unregister"
fi

# The markers around our block in a project's .git/info/exclude (setup.sh).
EXCLUDE_BEGIN="# >>> lytnode: kept out of git on this machine only (bash uninstall.sh removes this block)"
EXCLUDE_END="# <<< lytnode"

# The projects setup.sh was run for, read before anything goes. A file we
# wrote inside one of them may be removed; nothing else there.
PROJECT_ROOTS=()
for record_file in "$PROJECT_RECORD" "$RECORD"; do
    [ -f "$record_file" ] || continue
    while IFS=' ' read -r kind path; do
        if [ "$kind" = project ] && [ -n "$path" ]; then PROJECT_ROOTS+=("$path"); fi
    done < "$record_file"
done

# One-line description: true when a lyt-nodes skill directory is ours: our mark, or an install from before the mark.
lytnode_skill_is_ours() {
    [ -e "$1/.installed-by-lytnode" ] && return 0
    [ -f "$1/agentwork.sh" ] && grep -q '^name: lyt-nodes' "$1/SKILL.md" 2>/dev/null
}

# One-line description: true when a path lies inside a project setup.sh was run for, without climbing out.
under_project() {
    local root
    case "$1" in
        *"/../"* | *"/..") return 1 ;;
    esac
    for root in ${PROJECT_ROOTS[@]+"${PROJECT_ROOTS[@]}"}; do
        case "$1" in "$root"/*) return 0 ;; esac
    done
    return 1
}

# One-line description: removes our marked block from a project's .git/info/exclude, and nothing else in it.
remove_exclude_block() {
    local dir="$1" file tmp
    file="$(git -C "$dir" rev-parse --git-path info/exclude 2>/dev/null)" || return 0
    case "$file" in /*) ;; *) file="$dir/$file" ;; esac
    if [ ! -f "$file" ] || ! grep -qxF "$EXCLUDE_BEGIN" "$file"; then
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        echo "  would remove the lytnode block from $file"
    else
        tmp="$file.lytnode-tmp"
        awk -v b="$EXCLUDE_BEGIN" -v e="$EXCLUDE_END" \
            '$0 == b { skip = 1; next } skip && $0 == e { skip = 0; next } !skip' "$file" > "$tmp"
        cat "$tmp" > "$file"
        rm -f "$tmp"
        echo "  removed the lytnode block from $file"
    fi
    REMOVED=$((REMOVED + 1))
}

# One-line description: removes a lyt-nodes skill directory, or a link to one, only when it is ours.
gone_if_ours() {
    if [ -L "$1" ] || [ -e "$1" ]; then
        if lytnode_skill_is_ours "$1"; then
            gone "$1"
        else
            echo "  left alone: $1 is not ours"
        fi
    fi
}

# One-line description: handles the project record rows of one phase: "hooks" first, then "rest".
project_records() {
    local phase="$1" kind path
    [ -f "$PROJECT_RECORD" ] || return 0
    while IFS=' ' read -r kind path; do
        [ -n "$kind" ] || continue
        case "$phase:$kind" in
            hooks:project-hooks)
                # The optional extra's hooks, in ONE project's settings file.
                if [ -x "$HOME/.claude/skills/post/install-hooks.sh" ] && [ -f "$path/.claude/settings.json" ]; then
                    if [ "$DRY_RUN" = 1 ]; then
                        echo "  would unregister the post hooks from $path/.claude/settings.json"
                    else
                        bash "$HOME/.claude/skills/post/install-hooks.sh" --project "$path" --remove >/dev/null 2>&1 \
                            && echo "  unregistered the post hooks from $path/.claude/settings.json" \
                            || echo "  could not unregister the post hooks; check $path/.claude/settings.json yourself"
                    fi
                    REMOVED=$((REMOVED + 1))
                fi
                ;;
            hooks:project-hooks-local)
                # The hooks in ONE project's personal settings.local.json.
                if [ -x "$HOME/.claude/skills/post/install-hooks.sh" ] && [ -f "$path/.claude/settings.local.json" ]; then
                    if [ "$DRY_RUN" = 1 ]; then
                        echo "  would unregister the post hooks from $path/.claude/settings.local.json"
                    else
                        bash "$HOME/.claude/skills/post/install-hooks.sh" --project "$path" --local --remove >/dev/null 2>&1 \
                            && echo "  unregistered the post hooks from $path/.claude/settings.local.json" \
                            || echo "  could not unregister the post hooks; check $path/.claude/settings.local.json yourself"
                    fi
                    REMOVED=$((REMOVED + 1))
                fi
                ;;
            rest:project)
                # The project itself: a place the person works, never removed.
                # Only our marked block in its local git ignore file goes, and
                # a project key's registration in Claude Code's local scope.
                remove_exclude_block "$path"
                if command -v claude >/dev/null 2>&1 && [ -d "$path" ]; then
                    if [ "$DRY_RUN" = 1 ]; then
                        echo "  would run in $path: claude mcp remove --scope local lytnode"
                    elif (cd "$path" && claude mcp remove --scope local lytnode) >/dev/null 2>&1; then
                        echo "  removed MCP server 'lytnode' (local scope, $path)"
                        REMOVED=$((REMOVED + 1))
                    fi
                fi
                ;;
            rest:project-file)
                # A file setup wrote inside a project. Removed only inside a
                # project it was run for, or the home directory. A project's
                # key stays with --keep-credentials, like the user key.
                if [ "$KEEP_CREDENTIALS" = 1 ] && [ "$(basename "$path")" = .lytnode ]; then
                    echo "  kept $path (--keep-credentials)"
                elif under_project "$path" || under_home "$path"; then
                    gone "$path"
                else
                    echo "  left alone: $path is outside the projects setup.sh was run for"
                fi
                ;;
            hooks:* | rest:*)
                ;;
        esac
    done < "$PROJECT_RECORD"
}

# ── 2. What install.sh recorded ──────────────────────────────────────────────
# Hooks first: the remover lives in the post skill, which goes right after.
step "recorded installations"
# Hooks named in the project record go first, while the post skill that
# removes them is still here.
project_records hooks
if [ -f "$RECORD" ]; then
    # TWO PASSES. The hooks are taken out by install-hooks.sh, which lives in
    # the post skill - and the record lists the skill BEFORE the hooks, so a
    # single pass removed the remover first and left every hook pointing at a
    # deleted path (QC 2026-09-25, run in a sandbox home). Hooks go first now.
    # The reordered copy is a temporary file, so a dry run still writes nothing
    # of ours.
    ORDERED="$(mktemp)"
    { grep -E '^(hooks|project-hooks)( |$)' "$RECORD" || true
      grep -vE '^(hooks|project-hooks)( |$)' "$RECORD" || true; } > "$ORDERED"
    while IFS=' ' read -r kind path; do
        [ -n "$kind" ] || continue
        case "$kind" in
            hooks)
                if [ -x "$HOME/.claude/skills/post/install-hooks.sh" ]; then
                    if [ "$DRY_RUN" = 1 ]; then
                        echo "  would unregister the post hooks from ~/.claude/settings.json"
                    else
                        bash "$HOME/.claude/skills/post/install-hooks.sh" --remove >/dev/null 2>&1 \
                            && echo "  unregistered the post hooks from ~/.claude/settings.json" \
                            || echo "  could not unregister the post hooks; check ~/.claude/settings.json yourself"
                    fi
                    REMOVED=$((REMOVED + 1))
                fi
                for hook in post-sniffer.sh post-inbox-peek.py post-spawn-sync.sh post-sync-stop.sh post-outbox-drain.sh post-ring-spawn.sh post-ring-stop.sh; do
                    gone "$HOME/.claude/hooks/$hook"
                done
                ;;
            project)
                # The PROJECT the extra was installed for (2026-09-25). A place
                # the person works, never ours to remove: it names where the
                # project's own files live, and nothing more. The generic
                # branch below would have deleted the whole directory.
                ;;
            project-hooks)
                # The optional extra's hooks, in ONE project's settings file.
                if [ -x "$HOME/.claude/skills/post/install-hooks.sh" ] && [ -f "$path/.claude/settings.json" ]; then
                    if [ "$DRY_RUN" = 1 ]; then
                        echo "  would unregister the post hooks from $path/.claude/settings.json"
                    else
                        bash "$HOME/.claude/skills/post/install-hooks.sh" --project "$path" --remove >/dev/null 2>&1 \
                            && echo "  unregistered the post hooks from $path/.claude/settings.json" \
                            || echo "  could not unregister the post hooks; check $path/.claude/settings.json yourself"
                    fi
                    REMOVED=$((REMOVED + 1))
                fi
                ;;
            *)
                # A record is a file anyone can edit. Whatever it says, nothing
                # outside the home directory is removed.
                if under_home "$path"; then
                    gone "$path"
                else
                    echo "  left alone: $path is outside your home directory"
                fi
                ;;
        esac
    done < "$ORDERED"
    rm -f "$ORDERED"
else
    echo "  no record at $RECORD - a post skill, a participants file or hook"
    echo "  entries are left alone, because they may be yours"
fi
project_records rest

# ── 3. Ours by name, record or not ───────────────────────────────────────────
step "the skill and the per-agent files"
gone_if_ours "$CLAUDE_SKILL"
gone_if_ours "$AGENTS_SKILL"
gone_if_ours "$HERE/.agents/skills/lyt-nodes"
gone_if_ours "$PROJECT_OF_CLONE/.agents/skills/lyt-nodes"
gone "$HOME/.codex/lyt-mcp.toml"
gone "$HOME/.codex/lyt-hooks.toml"
gone "$HOME/.config/opencode/plugins/lyt.js"
for twin in "$HOME/.codex/lyt-mcp.toml" "$HOME/.codex/lyt-hooks.toml" "$HOME/.cursor/mcp.json" \
            "$HOME/.cursor/hooks.json" "$HOME/.config/opencode/opencode.json" "$HOME/.gemini/settings.json"; do
    gone "$twin.lyt-new"
done

# ── 4. ssh: the Include line and the node entries ────────────────────────────
step "ssh configuration"
if [ -f "$HOME/.ssh/config" ] && grep -qxF "Include $SSH_CONF" "$HOME/.ssh/config"; then
    if [ "$DRY_RUN" = 1 ]; then
        echo "  would remove the line 'Include $SSH_CONF' from ~/.ssh/config"
    else
        # grep -v exits 1 when nothing is left, which is a valid outcome here.
        # The comment line setup.sh writes above the Include goes with it.
        grep -vxF "Include $SSH_CONF" "$HOME/.ssh/config" \
            | grep -vxF "# lytnode: rented nodes. Keep this first - ssh keeps the first value it sees." \
            > "$HOME/.ssh/config.lytnode-tmp" || true
        cat "$HOME/.ssh/config.lytnode-tmp" > "$HOME/.ssh/config"
        rm -f "$HOME/.ssh/config.lytnode-tmp"
        echo "  removed the line 'Include $SSH_CONF' from ~/.ssh/config"
    fi
    REMOVED=$((REMOVED + 1))
fi
if [ -e "$CERT_DIR" ]; then
    echo "  note: $CERT_DIR holds certificates for nodes you rented; a node still"
    echo "  running is out of reach after this until you rent again"
fi
gone "$SSH_CONF"
gone "$CERT_DIR"

# ── 5. The config directory, credentials included unless told otherwise ─────
step "configuration in $CONF_DIR"
if [ -d "$CONF_DIR" ]; then
    if [ "$KEEP_CREDENTIALS" = 1 ]; then
        for f in url agent post hooks node-push guard key-scope installed-files project-records agent-env token-flow autoscale local-sizing autoscale-memory-free-pct autoscale-memory-peak-pct autoscale-disk-free-mb autoscale-load-per-core autoscale-cpu-steal-pct autoscale-io-wait-pct autoscale-gpu-memory-pct autoscale-gpu-busy-pct autoscale-memory-pressure-pct autoscale-swap-full-pct; do gone "$CONF_DIR/$f"; done
        echo "  kept $CONF_DIR/api-key and $CONF_DIR/claude-token (--keep-credentials)"
    else
        if [ -s "$CONF_DIR/api-key" ]; then
            echo "  note: the API key file goes, but the key itself stays valid until you"
            echo "  revoke it in your account (https://node.lyt.no/account/keys)"
        fi
        gone "$CONF_DIR"
    fi
fi

# Copies install.sh made before it updated an earlier post skill of ours
# (2026-09-25). Never removed here: they may hold edits of the person's own.
if [ -d "$HOME/.config/lytnode-backup" ]; then
    echo "  kept $HOME/.config/lytnode-backup: copies made before an update;"
    echo "  delete it yourself when you no longer need them"
fi

# ── 6. The client setup.sh fetched into this folder ──────────────────────────
# The licensed part: fetched with the key, and the licence asks that it goes
# when you stop using the service. Asked for, since it sits in a folder you own.
step "the fetched client in $HERE"
FETCHED=()
for item in lyt-node-core adapters install.sh; do
    [ -e "$HERE/$item" ] || continue
    # FETCHED means not tracked by git here. In the public clone these three
    # are never committed; where git tracks them, this folder is their SOURCE
    # (the developers' own repository), and removing them would be data loss.
    if command -v git >/dev/null 2>&1 \
            && git -C "$HERE" ls-files --error-unmatch "$item" >/dev/null 2>&1; then
        echo "  left alone: $HERE/$item is tracked by git here, so it was not fetched"
        continue
    fi
    FETCHED+=("$HERE/$item")
done
if [ "${#FETCHED[@]}" = 0 ]; then
    echo "  nothing fetched here"
elif [ "$DRY_RUN" = 1 ]; then
    for item in "${FETCHED[@]}"; do echo "  would remove $item"; REMOVED=$((REMOVED + 1)); done
else
    answer=""
    if [ "$ASSUME_YES" = 1 ]; then
        answer=y
    elif [ -t 0 ]; then
        printf '  remove lyt-node-core/, adapters/ and install.sh from %s? [y/N] ' "$HERE"
        read -r answer
    fi
    case "$answer" in
        y | Y | yes | YES) for item in "${FETCHED[@]}"; do gone "$item"; done ;;
        *) echo "  kept; run again with --yes to remove them" ;;
    esac
fi

# ── 7. What stays, on purpose ────────────────────────────────────────────────
step "left alone"
echo "  ~/.ssh/id_ed25519* and ~/.ssh/lytnode_cert* - your ssh keys are never removed"
for key in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/lytnode_cert"; do
    if [ -L "$key" ]; then
        echo "  note: $key is a link to $(readlink "$key") - not a key pair of its own;"
        echo "  setup.sh keeps whatever it points at"
    fi
done

step "done"
if [ "$DRY_RUN" = 1 ]; then
    echo "  $REMOVED thing(s) would be removed. Nothing was."
else
    echo "  $REMOVED thing(s) removed. Run setup.sh to start over."
fi
