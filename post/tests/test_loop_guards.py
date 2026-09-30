#!/usr/bin/env python3
"""Tests for the Post loop guards and read-state stamping.

Run with the skill venv (PyYAML is required by validate.py):

    ~/.claude/skills/post/venv/bin/python3 -m unittest discover -s skills/post/tests -v

Every case here is anchored in a real failure, not in a hypothetical:

  * `test_one_way_reporting_is_not_a_loop` is the false positive that muzzled
    a real project on 2026-09-03 — five one-way briefs refused as a "runaway
    agent loop" when nothing had looped.
  * `test_third_consecutive_ack_refused` is the false NEGATIVE from the same day:
    the old counter skipped acks entirely, so an infinite ack↔ack chain — the exact
    thing the guard was built for — passed straight through.
  * `test_pair_history_ignores_other_pairs` guards the broadcast fan-in case: many
    projects acking ONE human message must not inflate any single pair's count.
  * `test_decision_ack_never_refused` protects the destructive-directive approval
    flow. Dropping one of those leaves the holder waiting forever for a `yes`.
"""
from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SKILL_DIR))

import archive  # noqa: E402
import route  # noqa: E402


def orc_text(msg_id: str, frm: str, to: list[str], purpose: str, summary: str,
             thread: str, created: str, status: str = "unread",
             decision: str | None = None) -> str:
    """Render a minimal but schema-valid .orc envelope."""
    lines = [
        "---",
        f"msg_id: {msg_id}",
        f"thread_id: {thread}",
        f"from: {frm}",
        "to: [" + ", ".join(to) + "]",
        f"purpose: {purpose}",
        "urgency: normal",
        f"status: {status}",
        f'summary: "{summary}"',
        f"created: {created}",
    ]
    if decision is not None:
        lines.append(f"decision: {decision}")
    lines.append("---")
    return "\n".join(lines) + "\n"


class GuardTestCase(unittest.TestCase):
    """Base case that redirects the post tree at a throwaway directory."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="posttest-"))
        self.projects = self.tmp / "projects"
        self._saved = (route.PROJECTS, archive.PROJECTS)
        route.PROJECTS = self.projects
        archive.PROJECTS = self.projects

    def tearDown(self) -> None:
        route.PROJECTS, archive.PROJECTS = self._saved
        shutil.rmtree(self.tmp, ignore_errors=True)

    def send(self, seq: int, frm: str, to: list[str], purpose: str, summary: str,
             thread: str = "t1", decision: str | None = None) -> None:
        """Drop a message into `frm`'s sent/ — the synced record the guards read."""
        sent = self.projects / frm / "sent"
        sent.mkdir(parents=True, exist_ok=True)
        msg_id = f"m{seq}_{frm}"
        created = f"2026-09-03T10:{seq:02d}:00+0200"
        (sent / f"{msg_id}.orc").write_text(
            orc_text(msg_id, frm, to, purpose, summary, thread, created,
                     decision=decision))

    def history(self, a: str = "A", b: str = "B", thread: str = "t1") -> list[dict]:
        return route.pair_history(thread, a, b)

    @staticmethod
    def msg(frm: str, purpose: str, summary: str, to: list[str] | None = None,
            decision: str | None = None) -> dict:
        env = {"from": frm, "to": to or ["B"], "purpose": purpose, "summary": summary}
        if decision is not None:
            env["decision"] = decision
        return env


class TestPairHistory(GuardTestCase):

    def test_reads_both_directions_in_time_order(self) -> None:
        self.send(1, "A", ["B"], "info", "first")
        self.send(2, "B", ["A"], "info", "second")
        self.send(3, "A", ["B"], "info", "third")
        self.assertEqual([m["summary"] for m in self.history()],
                         ["first", "second", "third"])

    def test_ignores_other_pairs(self) -> None:
        """Broadcast fan-in: C acking the same thread must not enter A/B's history."""
        self.send(1, "A", ["B"], "info", "to b")
        self.send(2, "A", ["C"], "info", "to c")
        self.send(3, "C", ["A"], "ack", "from c")
        self.assertEqual([m["summary"] for m in self.history()], ["to b"])

    def test_ignores_other_threads(self) -> None:
        self.send(1, "A", ["B"], "info", "thread one", thread="t1")
        self.send(2, "A", ["B"], "info", "thread two", thread="t2")
        self.assertEqual([m["summary"] for m in self.history()], ["thread one"])

    def test_human_hop_resets_the_chain(self) -> None:
        """A human in the thread re-authorizes it — everything before is forgiven."""
        for i in range(1, 6):
            self.send(i, "A", ["B"], "brief", f"brief {i}")
        self.send(6, "human", ["A", "B"], "directive", "carry on")
        self.send(7, "A", ["B"], "info", "after the human")
        self.assertEqual([m["summary"] for m in self.history()], ["after the human"])

    def test_empty_thread_id_yields_nothing(self) -> None:
        self.send(1, "A", ["B"], "info", "x")
        self.assertEqual(route.pair_history("", "A", "B"), [])

    def test_parses_offset_without_colon(self) -> None:
        """`date "+%z"` writes `+0200`; Python 3.9's fromisoformat rejects that.

        Measured 2026-09-03: the same code passed on 3.11+ (macOS, Linux) and failed
        4/22 on Python 3.9.6, where every timestamp fell back to datetime.min and
        ordering collapsed. This asserts the parse, not just the ordering, so the
        cause is named when it breaks again.
        """
        self.assertEqual(
            route._created_key({"created": "2026-09-03T08:00:00+0200"}),
            route._created_key({"created": "2026-09-03T08:00:00+02:00"}))
        self.assertNotEqual(
            route._created_key({"created": "2026-09-03T08:00:00+0200"}),
            datetime.min.replace(tzinfo=timezone.utc))
        self.assertEqual(
            route._created_key({"created": "2026-09-03T06:00:00Z"}),
            route._created_key({"created": "2026-09-03T08:00:00+02:00"}))

    def test_orders_by_instant_not_by_yaml_formatting(self) -> None:
        """PyYAML parses an UNQUOTED timestamp to a datetime whose str() uses a space.

        A quoted one stays a string with a `T`. Space (0x20) sorts before `T` (0x54),
        so sorting the raw string groups by formatting instead of by clock — measured
        2026-09-03 on 'flerspraak-2026-09', where every message from one participant
        sorted ahead of every message from the other regardless of time.
        """
        sent_a = self.projects / "A" / "sent"
        sent_b = self.projects / "B" / "sent"
        sent_a.mkdir(parents=True, exist_ok=True)
        sent_b.mkdir(parents=True, exist_ok=True)
        # A is LATER in time, but its quoted `T` form sorts later as a string too —
        # so make B the later one while giving A the form that would sort last.
        (sent_a / "a.orc").write_text(
            orc_text("a", "A", ["B"], "info", "earlier",
                     "t1", '"2026-09-03T08:00:00+02:00"'))
        (sent_b / "b.orc").write_text(
            orc_text("b", "B", ["A"], "info", "later",
                     "t1", "2026-09-03 09:00:00+02:00"))
        self.assertEqual([m["summary"] for m in self.history()], ["earlier", "later"])


class TestLoopVerdict(GuardTestCase):

    def test_one_way_reporting_is_not_a_loop(self) -> None:
        """Five one-way briefs are a project reporting progress. The old cap refused this."""
        for i in range(1, 6):
            self.send(i, "A", ["B"], "brief", f"framdrift {i}")
        self.assertIsNone(
            route.loop_verdict(self.msg("A", "brief", "framdrift 6"), self.history()))

    def test_second_consecutive_ack_allowed(self) -> None:
        """One genuine clarification round survives."""
        self.send(1, "A", ["B"], "ack", "answer")
        self.assertIsNone(
            route.loop_verdict(self.msg("B", "ack", "clarification"), self.history()))

    def test_third_bouncing_ack_refused(self) -> None:
        """Two agents auto-acking EACH OTHER is the actual runaway: A→B→A."""
        self.send(1, "A", ["B"], "ack", "answer")
        self.send(2, "B", ["A"], "ack", "noted")
        verdict = route.loop_verdict(self.msg("A", "ack", "noted too"), self.history())
        self.assertIsNotNone(verdict)
        self.assertIn("bouncing", verdict)

    def test_one_sided_ack_run_allowed(self) -> None:
        """One side answering three separate briefs sends three acks. Not a loop.

        Measured 2026-09-03 on a real thread: one participant sent
        three briefs, ai-voice acked each one, and the first version of this guard
        refused the third — repeating the exact one-way false positive it replaced.
        """
        self.send(1, "B", ["A"], "brief", "punkt h")
        self.send(2, "B", ["A"], "brief", "punkt h tillegg")
        self.send(3, "B", ["A"], "brief", "punkt i")
        self.send(4, "A", ["B"], "ack", "ack h: ferdig")
        self.send(5, "A", ["B"], "ack", "ack h-tillegg: ferdig")
        self.assertIsNone(
            route.loop_verdict(self.msg("A", "ack", "ack i: ferdig"), self.history()))

    def test_ack_run_broken_by_content_message(self) -> None:
        """A real message between acks resets the run — that is a conversation."""
        self.send(1, "A", ["B"], "ack", "answer")
        self.send(2, "B", ["A"], "ack", "noted")
        self.send(3, "A", ["B"], "info", "new finding")
        self.assertIsNone(
            route.loop_verdict(self.msg("B", "ack", "understood, doing X"), self.history()))

    def test_identical_summary_refused(self) -> None:
        self.send(1, "A", ["B"], "info", "Samme  Sak")
        verdict = route.loop_verdict(self.msg("A", "info", "samme sak"), self.history())
        self.assertIsNotNone(verdict)
        self.assertIn("identical summary", verdict)

    def test_identical_summary_from_other_sender_allowed(self) -> None:
        """B quoting A back is a reply, not A repeating itself."""
        self.send(1, "A", ["B"], "info", "samme sak")
        self.assertIsNone(
            route.loop_verdict(self.msg("B", "info", "samme sak"), self.history()))

    def test_alternation_cap_refuses_at_ten(self) -> None:
        for i in range(1, 11):
            frm, to = ("A", ["B"]) if i % 2 else ("B", ["A"])
            self.send(i, frm, to, "info", f"runde {i}")
        verdict = route.loop_verdict(self.msg("A", "info", "runde 11"), self.history())
        self.assertIsNotNone(verdict)
        self.assertIn("back-and-forth", verdict)

    def test_four_alternations_allowed(self) -> None:
        """A real clarification round is four or five turns — it must survive."""
        for i in range(1, 5):
            frm, to = ("A", ["B"]) if i % 2 else ("B", ["A"])
            self.send(i, frm, to, "info", f"runde {i}")
        self.assertIsNone(
            route.loop_verdict(self.msg("A", "info", "runde 5"), self.history()))

    def test_decision_ack_never_refused(self) -> None:
        """An approval answering a destructive-directive confirmation always gets through."""
        self.send(1, "A", ["B"], "ack", "a")
        self.send(2, "B", ["A"], "ack", "b")
        self.send(3, "A", ["B"], "ack", "c")
        self.assertIsNone(route.loop_verdict(
            self.msg("B", "ack", "ja", decision="yes"), self.history()))

    def test_decision_ack_survives_identical_summary(self) -> None:
        self.send(1, "B", ["A"], "ack", "ja", decision="yes")
        self.assertIsNone(route.loop_verdict(
            self.msg("B", "ack", "ja", decision="yes"), self.history()))


class TestMarkRead(GuardTestCase):
    """The read-state stamp that replaces the receipt-ack."""

    def setUp(self) -> None:
        super().setUp()
        import importlib.util
        spec = importlib.util.spec_from_file_location("mr", SKILL_DIR / "mark-read.py")
        self.mr = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mr)
        self.mr.PROJECTS = self.projects

    def deliver(self, msg_id: str, purpose: str, pid: str = "B") -> Path:
        inbox = self.projects / pid / "inbox"
        inbox.mkdir(parents=True, exist_ok=True)
        orc = inbox / f"{msg_id}.orc"
        orc.write_text(orc_text(msg_id, "A", [pid], purpose, "s", "t1",
                                "2026-09-03T10:00:00+0200"))
        (inbox / f"{msg_id}.md").write_text("# body\n")
        return orc

    def test_no_reply_purpose_archives_at_read(self) -> None:
        self.deliver("m1", "info")
        self.mr.stamp("m1", "B", "read")
        self.assertFalse((self.projects / "B" / "inbox" / "m1.orc").exists())
        self.assertTrue((self.projects / "B" / "archive" / "m1.orc").exists())
        self.assertTrue((self.projects / "B" / "tombstones" / "m1.tombstone").exists())

    def test_reply_purpose_stays_in_inbox_at_read(self) -> None:
        """A brief needs an answer — reading it is not handling it."""
        orc = self.deliver("m2", "brief")
        self.mr.stamp("m2", "B", "read")
        self.assertTrue(orc.exists())
        self.assertIn("status: read", orc.read_text())

    def test_reply_purpose_archives_at_acked(self) -> None:
        self.deliver("m3", "brief")
        self.mr.stamp("m3", "B", "acked")
        self.assertTrue((self.projects / "B" / "archive" / "m3.orc").exists())

    def test_status_never_moves_backwards(self) -> None:
        orc = self.deliver("m4", "brief")
        self.mr.stamp("m4", "B", "acked")
        # m4 archived at acked; a fresh acked message must not be downgraded to read.
        orc = self.deliver("m5", "brief")
        self.mr.stamp("m5", "B", "acked")
        self.assertFalse(orc.exists(), "acked brief should have been archived")

    def test_missing_message_is_a_no_op(self) -> None:
        self.assertEqual(self.mr.stamp("nope", "B", "read"), 0)


class TestRingWatch(GuardTestCase):
    """The doorbell watcher: what rings, what it says, and the exact wire format."""

    def setUp(self) -> None:
        super().setUp()
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "rw", SKILL_DIR / "scripts" / "ring-watch.py")
        self.rw = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.rw)
        self.rw.PROJECTS = self.projects
        self.rw.RING_DIR = self.tmp / "ring"
        self.rw.THRESHOLD_FILE = self.rw.RING_DIR / "threshold"

    def deliver(self, msg_id: str, urgency: str, status: str = "unread",
                purpose: str = "info", pid: str = "B") -> None:
        inbox = self.projects / pid / "inbox"
        inbox.mkdir(parents=True, exist_ok=True)
        text = orc_text(msg_id, "A", [pid], purpose, f"om {msg_id}", "t1",
                        "2026-09-03T10:00:00+0200", status=status)
        text = text.replace("urgency: normal", f"urgency: {urgency}")
        (inbox / f"{msg_id}.orc").write_text(text)

    def test_threshold_defaults_to_normal_and_reads_file(self) -> None:
        self.assertEqual(self.rw.threshold_rank(), self.rw.URGENCY_RANK["normal"])
        self.rw.RING_DIR.mkdir(parents=True, exist_ok=True)
        self.rw.THRESHOLD_FILE.write_text("high\n")
        self.assertEqual(self.rw.threshold_rank(), self.rw.URGENCY_RANK["high"])
        self.rw.THRESHOLD_FILE.write_text("nonsense\n")
        self.assertEqual(self.rw.threshold_rank(), self.rw.URGENCY_RANK["normal"])

    def test_only_unread_at_or_above_floor(self) -> None:
        """The sender advises via urgency; the recipient's floor decides."""
        self.deliver("m-low", "low")
        self.deliver("m-normal", "normal")
        self.deliver("m-high", "high")
        self.deliver("m-read", "crisis", status="read")
        floor = self.rw.URGENCY_RANK["normal"]
        self.assertEqual(set(self.rw.unread_at_or_above("B", floor)),
                         {"m-normal", "m-high"})
        self.assertEqual(set(self.rw.unread_at_or_above("B", self.rw.URGENCY_RANK["high"])),
                         {"m-high"})

    def test_missing_inbox_is_empty(self) -> None:
        self.assertEqual(self.rw.unread_at_or_above("nobody", 0), {})

    def test_compose_identifies_itself_and_names_msg_ids(self) -> None:
        """Claude Code wraps every socket line as a peer message — the content must
        say it is the doorbell, or an autonomous run will think another project sent it."""
        msgs = {"m1": {"from": "A", "purpose": "brief", "urgency": "high", "summary": "x" * 200}}
        text = self.rw.compose("B", msgs)
        self.assertIn("doorbell", text)
        self.assertIn("(m1)", text)
        self.assertIn("mark-read.py", text)
        self.assertIn("…", text, "long summaries are truncated, never dumped whole")

    def test_backoff_schedule_widens(self) -> None:
        """Rings on the 1st sighting, then ever more rarely while still unread."""
        gaps = [b - a for a, b in zip(self.rw.BACKOFF_POLLS, self.rw.BACKOFF_POLLS[1:])]
        self.assertEqual(self.rw.BACKOFF_POLLS[0], 1)
        self.assertEqual(gaps, sorted(gaps), "gaps must never shrink")
        self.assertNotIn(2, self.rw.BACKOFF_POLLS, "no back-to-back polls ring")

    def test_ring_sends_auth_then_user_line(self) -> None:
        """Exact wire format, taken from Claude Code's own uds-messaging debug line.

        Three guessed shapes were swallowed silently on 2026-09-03; the socket gives
        no schema feedback, so this is the only place the format is pinned down.
        """
        import socket
        import threading
        sock_path = str(self.tmp / "fake.sock")
        received: list[bytes] = []
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(sock_path)
        server.listen(1)

        def accept_once() -> None:
            conn, _ = server.accept()
            conn.settimeout(2)
            chunks = []
            try:
                while True:
                    data = conn.recv(4096)
                    if not data:
                        break
                    chunks.append(data)
            except OSError:
                pass
            received.append(b"".join(chunks))
            conn.close()

        t = threading.Thread(target=accept_once, daemon=True)
        t.start()
        ok = self.rw.ring(sock_path, "tok-123", "hei")
        t.join(3)
        server.close()

        self.assertTrue(ok)
        lines = received[0].decode().strip().split("\n")
        self.assertEqual(len(lines), 2, "exactly two lines: auth, then the message")
        import json
        self.assertEqual(json.loads(lines[0]), {"type": "auth", "token": "tok-123"})
        self.assertEqual(json.loads(lines[1]),
                         {"type": "user", "message": {"role": "user", "content": "hei"}})

    def test_ring_returns_false_when_socket_missing(self) -> None:
        self.assertFalse(self.rw.ring(str(self.tmp / "nope.sock"), "t", "x"))


if __name__ == "__main__":
    unittest.main()
