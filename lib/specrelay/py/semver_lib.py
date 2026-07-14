#!/usr/bin/env python3
"""semver_lib.py — strict MAJOR.MINOR.PATCH parsing/compare (spec 0022,
section 8 "Release-impact metadata"). Deliberately narrow: anything that is
not exactly three non-negative integers separated by dots is INVALID —
never guessed at.
"""
import re
import sys

_PATTERN = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")


def parse(value):
    m = _PATTERN.match((value or "").strip())
    if not m:
        return None
    return tuple(int(g) for g in m.groups())


def is_valid(value):
    return parse(value) is not None


def compare(a, b):
    """-1, 0, 1 like cmp(); raises ValueError if either is invalid."""
    pa, pb = parse(a), parse(b)
    if pa is None or pb is None:
        raise ValueError("invalid semantic version(s): %r, %r" % (a, b))
    if pa < pb:
        return -1
    if pa > pb:
        return 1
    return 0


def cmd_validate(argv):
    if not argv or not is_valid(argv[0]):
        print("invalid")
        return 1
    print("valid")
    return 0


def cmd_compare(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: semver_lib.py compare <a> <b>\n")
        return 2
    try:
        print(compare(argv[0], argv[1]))
    except ValueError as exc:
        sys.stderr.write("%s\n" % exc)
        return 1
    return 0


def cmd_max(argv):
    valid = [v for v in argv if is_valid(v)]
    if not valid:
        return 1
    best = valid[0]
    for v in valid[1:]:
        if compare(v, best) > 0:
            best = v
    print(best)
    return 0


def main(argv):
    if not argv:
        sys.stderr.write("usage: semver_lib.py <validate|compare|max> ...\n")
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "validate":
        return cmd_validate(rest)
    if cmd == "compare":
        return cmd_compare(rest)
    if cmd == "max":
        return cmd_max(rest)
    sys.stderr.write("unknown subcommand: %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
