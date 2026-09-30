#!/usr/bin/env bash
# sync-post.sh — cross-machine message sync over ssh (rsync).
#
# Makes ~/.claude/post/ a shared substrate between this machine and the
# machines it exchanges post with, WITHOUT corrupting state. The rule: sync only ADDITIVE dirs
# (inbox/sent/briefs — append-only, unique msg_id), never the mutable ones.
#
#   SYNCED  (additive, union-merge, no --delete):
#     projects/*/inbox/   projects/*/sent/   projects/*/archive/
#     projects/*/trash/   projects/*/tombstones/   briefs/
#   NOT SYNCED (machine-local — would race):
#     outbox/    each machine routes its OWN outbox
#     log.md     per-machine append-only audit (post-status reads each locally)
#
# Two-way = two additive passes (push then pull). msg_id dedup in route.py means
# a message that round-trips is never delivered twice.
#
# TOMBSTONES (the archive-resurrection fix): archiving/trashing a message moves
# it out of inbox LOCALLY, but additive (no --delete) sync would copy the other
# machine's still-present inbox copy right back. So archive/trash also drops a
# projects/<id>/tombstones/<msg_id>.tombstone marker. Tombstones sync both ways;
# after every sync we sweep inbox on BOTH machines, removing any .orc/.md whose
# msg_id has a tombstone. That kills the zombie everywhere, no --delete needed.
#
# Transport: SSH + rsync to every machine in the NODES list below (their
# HostNames are already Tailscale 100.x IPs). No new software.
#
# Usage:
#   sync-post.sh            push + pull against every node
#   sync-post.sh push       Mac -> nodes only
#   sync-post.sh pull       nodes -> Mac only
#   sync-post.sh --dry-run  show what would transfer, change nothing
#
#   POST_SYNC_REMOTE=<alias> sync-post.sh         restrict to one known node
#   POST_SYNC_REMOTE=host:/path sync-post.sh      ad-hoc machine not in the list
#

set -euo pipefail

# --- Node list -------------------------------------------------------------
# One entry per machine that participates in Post, as `alias:remote-path`.
# The alias must resolve in ~/.ssh/config; the path is that machine's post root
# (it differs per OS and per user, so it cannot be derived).
#
# Was a single hardcoded remote until 2026-09-04. A second machine had Claude Code and a
# ~/.claude/post directory but received no mail at all, because the script could
# only ever talk to one machine.
#
# A node that does not answer is SKIPPED with a warning, never an error: post is
# additive and eventually consistent, so a machine that was offline simply syncs
# on the next run. Losing one node must never stop the others.
# The peers are read from peers.conf below; with no file there is nothing to
# sync to, which is the correct answer on a machine that has not been told
# about any peers.
NODES=()

# A rented node has none of those machines. If ~/.claude/post/peers.conf exists,
# it REPLACES the list above: one `alias:path` per line, `#` comments and blank
# lines ignored. Default is unchanged — no file, no difference.
PEERS_CONF="${HOME}/.claude/post/peers.conf"
if [ -f "$PEERS_CONF" ]; then
    NODES=()
    while IFS= read -r LINE; do
        LINE="${LINE%%#*}"
        LINE="$(printf '%s' "$LINE" | tr -d '[:space:]')"
        [ -n "$LINE" ] || continue
        NODES+=("$LINE")
    done < "$PEERS_CONF"
    echo "post: peers from $PEERS_CONF (${#NODES[@]} entries)" >&2
fi

# POST_SYNC_REMOTE restricts the run to ONE node. Accepts a bare alias from the
# list above, or an explicit `alias:path` for a machine not in it.
if [ -n "${POST_SYNC_REMOTE:-}" ]; then
    case "${POST_SYNC_REMOTE}" in
        *:*)
            NODES=("${POST_SYNC_REMOTE}")
            ;;
        *)
            _match=""
            for _n in ${NODES[@]+"${NODES[@]}"}; do
                [ "${_n%%:*}" = "${POST_SYNC_REMOTE}" ] && _match="${_n}"
            done
            if [ -z "${_match}" ]; then
                echo "error: POST_SYNC_REMOTE='${POST_SYNC_REMOTE}' is not a known node." >&2
                echo "       Known: $(printf '%s ' ${NODES[@]+"${NODES[@]%%:*}"})" >&2
                echo "       For an ad-hoc machine, pass alias:path instead." >&2
                exit 2
            fi
            NODES=("${_match}")
            ;;
    esac
fi

# --- Node-spec validation --------------------------------------------------
# Both halves of a node entry end up inside a REMOTE shell command, so they are
# validated at parse time rather than quoted defensively at every use site.
# Measured 2026-09-04: with the path interpolated unvalidated,
# `POST_SYNC_REMOTE='<alias>:/tmp && hostname'` executed `hostname` on the
# remote and pointed rsync at /tmp. The path used to be a hardcoded constant,
# so this surface is new as of the multi-node change — it is closed here.
valid_alias() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}
valid_path() {
    case "$1" in
        /*) ;;
        *) return 1 ;;                      # must be absolute
    esac
    case "$1" in
        *[!A-Za-z0-9/._-]*) return 1 ;;     # no spaces, quotes, $, ;, &, |, backticks
    esac
    return 0
}
for _n in ${NODES[@]+"${NODES[@]}"}; do
    if ! valid_alias "${_n%%:*}" || ! valid_path "${_n#*:}"; then
        echo "error: invalid node spec '${_n}'." >&2
        echo "       Expected <ssh-alias>:<absolute-path>, where the alias is" >&2
        echo "       [A-Za-z0-9._-] and the path is [A-Za-z0-9/._-] only." >&2
        exit 2
    fi
done

# Every loop over NODES below uses ${NODES[@]+"${NODES[@]}"}: bash 3.2, the
# one macOS ships, treats an empty array as unset under `set -u`, so the plain
# form aborted with "unbound variable" on a machine with no peers - silently,
# from a hook. The +-form expands to nothing instead (2026-09-25).
LOCAL_POST="${HOME}/.claude/post"

MODE="${1:-both}"
DRY=""
[ "${MODE}" = "--dry-run" ] && { DRY="--dry-run"; MODE="both"; }
[ "${2:-}" = "--dry-run" ] && DRY="--dry-run"

# Additive dirs only. No --delete: a union merge that never removes the other
# side's messages. Excludes guarantee outbox/ and log.md never cross machines.
RSYNC_OPTS=(-az --stats --exclude='outbox/***' --exclude='log.md')
SAFE_DIRS=(projects briefs)

require_local() {
    if [ ! -d "${LOCAL_POST}" ]; then
        echo "error: ${LOCAL_POST} missing — run init-post.py first" >&2
        exit 1
    fi
}

# All four take $1 = ssh alias, $2 = that node's post root. Both are validated
# above, so single-quoting them in the remote command is sufficient.
reachable() {
    ssh -o ConnectTimeout=8 "$1" "test -d '$2' || mkdir -p '$2'" 2>/dev/null
}

# push/pull return non-zero when ANY directory failed to transfer, so the caller
# can tell "node answered but nothing moved" from "node synced".
push() {
    local rc=0
    echo "→ push (Mac → $1): ${SAFE_DIRS[*]}"
    for d in "${SAFE_DIRS[@]}"; do
        [ -d "${LOCAL_POST}/${d}" ] || continue
        rsync ${DRY} "${RSYNC_OPTS[@]}" \
            "${LOCAL_POST}/${d}/" "$1:$2/${d}/" || { echo "  ⚠️  push $d → $1 failed"; rc=1; }
    done
    return $rc
}

pull() {
    local rc=0
    echo "← pull ($1 → Mac): ${SAFE_DIRS[*]}"
    for d in "${SAFE_DIRS[@]}"; do
        # stderr is dropped (a missing dir on a fresh node is normal and noisy),
        # but the exit code is NOT swallowed any more: a node that answers ssh
        # and then transfers nothing used to report a clean "✓ complete".
        rsync ${DRY} "${RSYNC_OPTS[@]}" \
            "$1:$2/${d}/" "${LOCAL_POST}/${d}/" 2>/dev/null || { echo "  ⚠️  pull $d ← $1 failed"; rc=1; }
    done
    return $rc
}

# Remove every inbox .orc/.md whose msg_id has a tombstone, under $1 = projects root.
# Pure shell (no pipes/regex into other tools) — safe for ssh and local both.
# A tombstone file is named <msg_id>.tombstone; the matching inbox files are
# <msg_id>.orc and <msg_id>.md. Idempotent: re-running finds nothing to do.
TOMBSTONE_SWEEP='
for tdir in "$0"/*/tombstones; do
    [ -d "$tdir" ] || continue
    pid_dir="${tdir%/tombstones}"
    inbox="$pid_dir/inbox"
    [ -d "$inbox" ] || continue
    for ts in "$tdir"/*.tombstone; do
        [ -e "$ts" ] || continue
        base="$(basename "$ts" .tombstone)"
        rm -f "$inbox/$base.orc" "$inbox/$base.md"
    done
done
'

sweep_local() {
    [ -n "${DRY}" ] && { echo "  (dry-run: skip tombstone sweep)"; return 0; }
    echo "⌫ tombstone sweep (Mac inbox)"
    sh -c "${TOMBSTONE_SWEEP}" "${LOCAL_POST}/projects"
}

sweep_remote() {
    [ -n "${DRY}" ] && return 0
    echo "⌫ tombstone sweep ($1 inbox)"
    ssh "$1" "sh -c '${TOMBSTONE_SWEEP}' '$2/projects'" 2>/dev/null || true
}

# One node, start to finish.
#   0 = synced, 1 = unreachable, 2 = reachable but a transfer failed.
# The 0/2 distinction matters: counting reachability alone reported "✓ complete"
# for a node where every rsync had failed.
sync_node() {
    local alias="$1" rpath="$2" rc=0
    if ! reachable "${alias}" "${rpath}"; then
        echo "⚠️  ${alias} unreachable — skipped (fail-open, syncs on next run)."
        return 1
    fi
    case "${MODE}" in
        push) push "${alias}" "${rpath}" || rc=2 ;;
        pull) pull "${alias}" "${rpath}" || rc=2 ;;
        both)
            push "${alias}" "${rpath}" || rc=2
            pull "${alias}" "${rpath}" || rc=2
            ;;
    esac
    # After tombstones have crossed (push+pull both carry projects/*/tombstones/),
    # sweep this node's inbox so an archived/trashed message is gone there too.
    case "${MODE}" in
        push|both) sweep_remote "${alias}" "${rpath}" ;;
    esac
    return $rc
}

main() {
    require_local
    case "${MODE}" in
        push|pull|both) ;;
        *) echo "usage: sync-post.sh [push|pull|both] [--dry-run]" >&2; exit 2 ;;
    esac

    local synced=0 skipped=0 degraded=0 rc=0
    for node in ${NODES[@]+"${NODES[@]}"}; do
        echo "── ${node%%:*} ──"
        rc=0
        sync_node "${node%%:*}" "${node#*:}" || rc=$?
        case "${rc}" in
            0) synced=$((synced + 1)) ;;
            1) skipped=$((skipped + 1)) ;;
            *) degraded=$((degraded + 1)) ;;
        esac
    done

    # The local sweep is machine-wide, not per node: run it once, after every
    # node has had a chance to deliver its tombstones.
    case "${MODE}" in
        pull|both) sweep_local ;;
    esac

    if [ "${skipped}" -eq 0 ] && [ "${degraded}" -eq 0 ]; then
        echo "✓ post sync (${MODE}) complete — ${synced} node(s)."
    else
        echo "✓ post sync (${MODE}): ${synced} synced, ${skipped} unreachable, ${degraded} with failed transfers."
    fi
}

main
