#!/usr/bin/env python3
"""Envelope parsing + validation for Post .orc files.

Shared module used by route.py and post-status.py. Parses the YAML frontmatter
of an .orc file and validates required fields + enum values against the
canonical schema.

Uses PyYAML — never regex for YAML (per project convention).
"""
from __future__ import annotations

from pathlib import Path

import yaml

REQUIRED = ["msg_id", "from", "to", "purpose", "urgency", "status", "summary"]

ENUMS = {
    "purpose": {"info", "brief", "blocker", "query", "knowledge", "directive", "ack", "chat"},
    "urgency": {"crisis", "high", "normal", "low", "backlog"},
    "status": {"unread", "read", "acked", "resolved"},
}
# importance + consent + sender_type are optional; validate only if present.
# sender_type is SET BY route.py at delivery (not self-declared) — see route.py.
OPTIONAL_ENUMS = {
    "importance": {"high", "normal", "low"},
    "sender_type": {"human", "agent"},
    # `decision` marks an ack that ANSWERS an approval request (the destructive-directive
    # confirmation flow). It carries a decision, never a receipt, so route.py exempts it
    # from every loop guard: silently dropping one leaves the holder waiting forever for
    # a `yes` that was refused at the router.
    "decision": {"yes", "no"},
}


class EnvelopeError(ValueError):
    """Raised when an envelope is malformed or fails validation."""


def parse_envelope(orc_path: Path) -> dict:
    """Read an .orc file and return its frontmatter as a dict.

    Supports both a fenced frontmatter block (--- ... ---) and a bare YAML
    document. Raises EnvelopeError on unreadable/invalid YAML.
    """
    try:
        text = orc_path.read_text()
    except OSError as exc:
        raise EnvelopeError(f"cannot read {orc_path}: {exc}") from exc

    body = text
    stripped = text.lstrip()
    if stripped.startswith("---"):
        # Fenced frontmatter: take content between the first two '---' lines.
        parts = stripped.split("---", 2)
        if len(parts) >= 3:
            body = parts[1]
        else:
            raise EnvelopeError(f"{orc_path.name}: unterminated frontmatter block")

    try:
        data = yaml.safe_load(body)
    except yaml.YAMLError as exc:
        raise EnvelopeError(f"{orc_path.name}: invalid YAML ({exc})") from exc

    if not isinstance(data, dict):
        raise EnvelopeError(f"{orc_path.name}: envelope is not a mapping")
    return data


def validate(env: dict, source: str = "<envelope>") -> list[str]:
    """Return a list of validation error strings. Empty list == valid."""
    errors: list[str] = []

    for field in REQUIRED:
        if field not in env or env[field] in (None, "", []):
            errors.append(f"missing required field: {field}")

    # `to` must be a non-empty list.
    to = env.get("to")
    if to is not None and not isinstance(to, list):
        errors.append("field 'to' must be a list")

    # links.body is required (relative path to the .md body).
    links = env.get("links")
    if not isinstance(links, dict) or not links.get("body"):
        errors.append("missing required field: links.body")

    for field, allowed in ENUMS.items():
        val = env.get(field)
        if val is not None and val not in allowed:
            errors.append(f"field '{field}'='{val}' not in {sorted(allowed)}")

    for field, allowed in OPTIONAL_ENUMS.items():
        val = env.get(field)
        if val is not None and val not in allowed:
            errors.append(f"field '{field}'='{val}' not in {sorted(allowed)}")

    return errors


def parse_and_validate(orc_path: Path) -> dict:
    """Parse + validate in one call. Raises EnvelopeError if invalid."""
    env = parse_envelope(orc_path)
    errors = validate(env, source=orc_path.name)
    if errors:
        raise EnvelopeError(f"{orc_path.name}: " + "; ".join(errors))
    return env


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 2:
        print("usage: validate.py <path-to.orc>", file=sys.stderr)
        sys.exit(2)
    try:
        env = parse_and_validate(Path(sys.argv[1]))
    except EnvelopeError as exc:
        print(f"INVALID: {exc}", file=sys.stderr)
        sys.exit(1)
    print(f"VALID: {env['msg_id']} ({env['purpose']}/{env['urgency']}) "
          f"{env['from']} -> {env['to']}")
