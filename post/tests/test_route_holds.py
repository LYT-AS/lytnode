#!/usr/bin/env python3
"""A message stays in the outbox until it has somewhere to go.

Run with the skill venv (PyYAML is required by validate.py):

    ~/.claude/skills/post/venv/bin/python3 -m unittest discover -s packages/post/tests -v

Until 2026-10-02 a valid message to a recipient this machine did not know was
logged, warned about, and moved to the sender's sent/ — out of the outbox and
delivered to nobody. On a rented node that was a message home that never came
home. The owner's rule: nothing leaves the outbox before it is actually sent.
"""
from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SKILL_DIR))

import route  # noqa: E402


def write_pair(outbox: Path, msg_id: str, to: list[str]) -> Path:
    """Write a schema-valid .orc and its .md body into the outbox."""
    (outbox / f"{msg_id}.md").write_text("# body\n")
    orc = outbox / f"{msg_id}.orc"
    orc.write_text("\n".join([
        f"msg_id: {msg_id}",
        "from: agentwork-n1",
        "to: [" + ", ".join(to) + "]",
        'created: "2026-10-02T11:00:00+0200"',
        "purpose: info",
        "urgency: normal",
        "status: unread",
        f"thread_id: node:{msg_id}",
        f'summary: "{msg_id}"',
        "links:",
        f"  body: {msg_id}.md",
        "",
    ]))
    return orc


class TestRouteHoldsUndeliverable(unittest.TestCase):
    """The post tree is redirected at a throwaway directory."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="posttest-"))
        self.outbox = self.tmp / "outbox"
        self.outbox.mkdir()
        self._saved = (route.PROJECTS, route.LOG, route.BRIEFS)
        route.PROJECTS = self.tmp / "projects"
        route.LOG = self.tmp / "log.md"
        route.BRIEFS = self.tmp / "briefs"

    def tearDown(self) -> None:
        route.PROJECTS, route.LOG, route.BRIEFS = self._saved
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_unknown_recipient_stays_in_outbox(self) -> None:
        orc = write_pair(self.outbox, "m-unknown", ["customer-x"])
        ok, msgs = route.process_one(orc, {"human", "agentwork-n1"})
        self.assertFalse(ok)
        self.assertTrue(msgs[0].startswith("HELD m-unknown.orc: no recipient is known"), msgs)
        self.assertTrue(orc.exists())
        self.assertTrue((self.outbox / "m-unknown.md").exists())
        self.assertFalse((route.PROJECTS / "agentwork-n1" / "sent").exists())

    def test_known_recipient_is_routed_as_before(self) -> None:
        orc = write_pair(self.outbox, "m-known", ["human"])
        ok, _ = route.process_one(orc, {"human", "agentwork-n1"})
        self.assertTrue(ok)
        self.assertFalse(orc.exists())
        self.assertTrue((route.PROJECTS / "human" / "inbox" / "m-known.orc").exists())
        self.assertTrue((route.PROJECTS / "agentwork-n1" / "sent" / "m-known.orc").exists())

    def test_one_known_recipient_is_enough(self) -> None:
        # Unchanged behaviour: deliver to whoever is known, warn about the rest.
        orc = write_pair(self.outbox, "m-mixed", ["human", "customer-x"])
        ok, msgs = route.process_one(orc, {"human", "agentwork-n1"})
        self.assertTrue(ok)
        self.assertIn("unknown recipient 'customer-x' — skipped", msgs)


if __name__ == "__main__":
    unittest.main()
