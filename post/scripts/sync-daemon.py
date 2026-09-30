#!/usr/bin/env python3
"""Post activity-gated adaptive cross-machine sync daemon.

Spawned by the SessionStart hook (spawn-sync-daemon.sh), controlled by a marker
file (lifecycle) and gated per-tick by transcript-jsonl freshness (activity).
Computes a target cadence from log.md mtime (backoff) and only invokes the
existing sync-post.sh when both gates pass and enough time has elapsed.

Lifecycle:  self-exits when the marker file is deleted (Stop hook removes it).
Activity:   skips ssh entirely if no Claude transcript has been touched recently.
Backoff:    syncs ~30s after a fresh message exchange, stretching to ~15min when
            quiet — pure arithmetic off log.md mtime, no external scheduler.

All paths are $HOME-resolved, so the same script runs on macOS and Linux.
Stdlib only (no PyYAML) — runs even if the skill venv is absent.

"""
from __future__ import annotations

import argparse
import glob
import os
import subprocess
import time
from datetime import datetime
from pathlib import Path

HOME = Path.home()
POST_DIR = HOME / ".claude" / "post"
SYNC_DIR = POST_DIR / "sync"
MARKER = SYNC_DIR / "active"
PIDFILE = SYNC_DIR / "daemon.pid"
LAST_SYNC = SYNC_DIR / "last-sync"
LOGFILE = SYNC_DIR / "daemon.out"
LOG_MD = POST_DIR / "log.md"
OUTBOX = POST_DIR / "outbox"
SCRIPT_DIR = Path(__file__).resolve().parent
SYNC_SCRIPT = SCRIPT_DIR.parent / "sync-post.sh"
ROUTE_SCRIPT = SCRIPT_DIR.parent / "route.py"
VENV_PY = HOME / ".claude" / "skills" / "post" / "venv" / "bin" / "python3"
ALL_PROJECTS = HOME / ".claude" / "projects"

BASE_TICK = 30           # seconds between loop iterations
ACTIVITY_TTL = 300       # transcript considered "active" if touched within 5 min
SYNC_TIMEOUT = 60        # hard cap on a single sync-post.sh run


def ts() -> str:
    """Human-readable timestamp for the daemon log."""
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def log(msg: str) -> None:
    """Append one line to the daemon's append-only out-log."""
    try:
        SYNC_DIR.mkdir(parents=True, exist_ok=True)
        with LOGFILE.open("a", encoding="utf-8") as fh:
            fh.write(f"[{ts()}] {msg}\n")
    except OSError:
        pass


def newest_jsonl(projects_dir: str | None) -> Path | None:
    """Return the most recently modified transcript jsonl, or None.

    Prefers the spawning session's project dir; falls back to the newest jsonl
    across ALL projects so the gate degrades to "is any session on this machine
    active" — the correct semantics for a machine-global sync (handles a remote
    sessions whose slug differs from the spawning cwd).
    """
    candidates: list[Path] = []
    if projects_dir:
        candidates = [Path(p) for p in glob.glob(os.path.join(projects_dir, "*.jsonl"))]
    if not candidates and ALL_PROJECTS.exists():
        candidates = [Path(p) for p in glob.glob(str(ALL_PROJECTS / "*" / "*.jsonl"))]
    if not candidates:
        return None
    return max(candidates, key=lambda p: p.stat().st_mtime)


def mtime_age(path: Path) -> float:
    """Seconds since `path` was last modified; +inf if it doesn't exist."""
    try:
        return time.time() - path.stat().st_mtime
    except OSError:
        return float("inf")


def target_cadence(age_s: float) -> int:
    """Sync cadence (s) given seconds since the last message exchange (log.md mtime)."""
    if age_s < 300:          # < 5 min since last message — hot
        return 30
    elif age_s < 1800:       # 5–30 min
        return 120
    elif age_s < 7200:       # 30 min – 2 h
        return 300
    else:                    # > 2 h — coldest (also the no-log.md default)
        return 900


def run_sync() -> None:
    """Invoke sync-post.sh both. Never raises — sync-post.sh is already fail-open."""
    try:
        result = subprocess.run(
            ["bash", str(SYNC_SCRIPT), "both"],
            timeout=SYNC_TIMEOUT,
            capture_output=True,
            text=True,
        )
        tail = (result.stdout or "").strip().splitlines()
        last = tail[-1] if tail else "(no output)"
        log(f"sync ran — {last}")
    except subprocess.TimeoutExpired:
        log(f"sync timed out after {SYNC_TIMEOUT}s — skipping")
    except OSError as exc:
        log(f"sync invocation failed — {exc}")


def drain_outbox() -> bool:
    """Route anything waiting in the outbox. Returns True if a run was attempted.

    The PostToolUse sniffer only fires on the Write tool, so a message written with
    a Bash heredoc never triggers it — measured 2026-09-03, where a correctly-formed
    ack sat unrouted for twelve minutes. The `Stop` hook covers ordinary turns; this
    covers the two cases it cannot: an autonomous run whose turn stays open for a
    long time, and a session that ended right after writing the file.

    Asks about the outbox's STATE, never about which tool produced the file — that
    coupling is what created the gap in the first place.
    """
    try:
        pending = any(OUTBOX.glob("*.orc"))
    except OSError:
        return False
    if not pending:
        return False
    try:
        result = subprocess.run(
            [str(VENV_PY), str(ROUTE_SCRIPT)],
            cwd=str(SCRIPT_DIR.parent),
            timeout=SYNC_TIMEOUT,
            capture_output=True,
            text=True,
        )
        tail = (result.stdout or "").strip().splitlines()
        log(f"outbox drained — {tail[-1] if tail else '(no output)'}")
    except subprocess.TimeoutExpired:
        log(f"outbox drain timed out after {SYNC_TIMEOUT}s — skipping")
    except OSError as exc:
        log(f"outbox drain failed — {exc}")
    return True


def read_last_sync() -> float:
    """Epoch seconds of the last successful sync, or 0 if unknown."""
    try:
        return float(LAST_SYNC.read_text().strip())
    except (OSError, ValueError):
        return 0.0


def write_last_sync(now: float) -> None:
    """Persist the last-sync timestamp (single scalar, the only external state)."""
    try:
        LAST_SYNC.write_text(f"{now:.0f}\n")
    except OSError:
        pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--interval", type=int, default=BASE_TICK,
                        help="Base poll interval in seconds")
    parser.add_argument("--projects-dir", default="",
                        help="Spawning session's ~/.claude/projects/<slug> dir")
    args = parser.parse_args()
    projects_dir = args.projects_dir or None

    log(f"daemon started (tick={args.interval}s, projects-dir={projects_dir or 'global'})")

    while True:
        # 1. Lifecycle gate — marker gone means the session ended.
        if not MARKER.exists():
            log("daemon stopping (marker gone)")
            break

        now = time.time()

        # 2. Outbox drain — BEFORE the activity gate, and on every tick.
        # A pending .orc is a definite signal, not a guess, so it is not subject to
        # the idle gate or the backoff cadence: the case that matters most is a
        # message written just before the session went quiet. Forcing a sync right
        # after a drain gets it onto the other machine without waiting for cadence.
        if drain_outbox():
            run_sync()
            write_last_sync(now)

        # 3. Activity gate — no fresh transcript means the human is idle.
        jsonl = newest_jsonl(projects_dir)
        if jsonl is None or mtime_age(jsonl) > ACTIVITY_TTL:
            time.sleep(args.interval)
            continue

        # 4. Backoff — cadence from time since last message exchange.
        cadence = target_cadence(mtime_age(LOG_MD))

        # 5. Sync decision (clock-skew guarded).
        last = read_last_sync()
        if last > now or (now - last) >= cadence:
            run_sync()
            write_last_sync(now)

        time.sleep(args.interval)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
