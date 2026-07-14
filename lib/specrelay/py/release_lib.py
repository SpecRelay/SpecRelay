#!/usr/bin/env python3
"""release_lib.py — release-impact metadata + version-bump planning (spec
0022, sections 8 "Release-impact metadata" and 9 "Release commands").

Every spec.md created AFTER spec 0022 is expected to carry a top-level YAML
block of the form:

    release:
      impact: none|patch|minor|major
      rationale: <non-empty explanation>

Historical specs (0022 and earlier) are NOT required to have this block and
are never rewritten automatically (section 8.3) — they are simply excluded
from "pending impact" discovery.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import semver_lib  # noqa: E402

VALID_IMPACTS = ("none", "patch", "minor", "major")
_RELEASE_BLOCK = re.compile(
    r"^release:\s*\n"
    r"(?:^[ \t]+.*\n?)+",
    re.MULTILINE,
)
_IMPACT_LINE = re.compile(r"^[ \t]+impact:\s*(\S+)\s*$", re.MULTILINE)
_RATIONALE_LINE = re.compile(r"^[ \t]+rationale:\s*(.+?)\s*$", re.MULTILINE)


def _spec_number(spec_dir_name):
    m = re.match(r"^(\d+)-", spec_dir_name)
    return int(m.group(1)) if m else None


def parse_release_block(text):
    """Returns (impact, rationale) or (None, None) if no release: block, or
    ("INVALID", reason) if a block exists but is malformed/empty."""
    m = _RELEASE_BLOCK.search(text)
    if not m:
        return (None, None)
    block = m.group(0)
    impact_m = _IMPACT_LINE.search(block)
    rationale_m = _RATIONALE_LINE.search(block)
    impact = impact_m.group(1).strip().strip('"\'') if impact_m else ""
    rationale = rationale_m.group(1).strip().strip('"\'') if rationale_m else ""
    if impact not in VALID_IMPACTS:
        return ("INVALID", "impact must be one of none|patch|minor|major (got %r)" % impact)
    if not rationale:
        return ("INVALID", "rationale must be a non-empty explanation")
    return (impact, rationale)


def discover_pending(specs_root, boundary_spec_number=22):
    """Scans <specs_root>/NNNN-*/spec.md for specs numbered STRICTLY greater
    than boundary_spec_number. Returns (pending, errors): pending is a list of
    {"spec": name, "impact": ..., "rationale": ...}; errors is a list of
    {"spec": name, "reason": ...} for a present-but-malformed block."""
    pending, errors = [], []
    if not os.path.isdir(specs_root):
        return pending, errors
    for name in sorted(os.listdir(specs_root)):
        full = os.path.join(specs_root, name)
        spec_md = os.path.join(full, "spec.md")
        if not os.path.isdir(full) or not os.path.isfile(spec_md):
            continue
        number = _spec_number(name)
        if number is None or number <= boundary_spec_number:
            continue
        with open(spec_md, "r", encoding="utf-8") as fh:
            text = fh.read()
        impact, rationale = parse_release_block(text)
        if impact is None:
            errors.append({"spec": name, "reason": "missing required release: impact/rationale metadata"})
        elif impact == "INVALID":
            errors.append({"spec": name, "reason": rationale})
        elif impact != "none":
            pending.append({"spec": name, "impact": impact, "rationale": rationale})
    return pending, errors


_RANK = {"patch": 1, "minor": 2, "major": 3}


def highest_impact(pending):
    if not pending:
        return None
    return max((p["impact"] for p in pending), key=lambda i: _RANK[i])


def bump(current_version, impact):
    """Pre-1.0 policy (section 8.2): patch -> +patch; minor -> +minor,
    resets patch; major -> requires at least a minor bump pre-1.0 (this
    function performs that minor-equivalent bump; an explicit human-approved
    1.0.0 is a deliberate, separate decision this function never makes)."""
    major, minor, patch = semver_lib.parse(current_version)
    if impact == "patch":
        return "%d.%d.%d" % (major, minor, patch + 1)
    if impact in ("minor", "major"):
        return "%d.%d.0" % (major, minor + 1)
    return current_version


def cmd_discover(argv):
    if len(argv) != 1:
        sys.stderr.write("usage: release_lib.py discover <specs-root>\n")
        return 2
    pending, errors = discover_pending(argv[0])
    print(json.dumps({"pending": pending, "errors": errors}, indent=2, sort_keys=True))
    return 0


def cmd_bump(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: release_lib.py bump <current-version> <impact>\n")
        return 2
    current, impact = argv
    if not semver_lib.is_valid(current):
        sys.stderr.write("invalid current version: %r\n" % current)
        return 1
    if impact not in VALID_IMPACTS:
        sys.stderr.write("invalid impact: %r\n" % impact)
        return 1
    print(bump(current, impact))
    return 0


def main(argv):
    if not argv:
        sys.stderr.write("usage: release_lib.py <discover|bump> ...\n")
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "discover":
        return cmd_discover(rest)
    if cmd == "bump":
        return cmd_bump(rest)
    sys.stderr.write("unknown subcommand: %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
