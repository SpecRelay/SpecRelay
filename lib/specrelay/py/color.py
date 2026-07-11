#!/usr/bin/env python3
"""color.py — shared, dependency-free ANSI color policy for SpecRelay's Python
runtimes (render_agent_events.py, state_lib.py).

This is the SINGLE source of color policy for the Python side; the shell side
lives in lib/specrelay/output.sh. Keeping the rules here means the mode
resolution (SPECRELAY_COLOR), the NO_COLOR handling, and the escape codes are
defined once, not sprinkled across runtimes.

This module only answers "should color be emitted for this stream?" and hands
out the escape codes. It NEVER decides what is evidence and what is not — each
caller colorizes only its human-facing streams and leaves evidence files plain.
"""

import os

# Raw ANSI escape sequences. Chosen to stay readable on dark terminal themes.
RESET = "\033[0m"
DIM = "\033[2m"
BOLD = "\033[1m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
BLUE = "\033[34m"
MAGENTA = "\033[35m"
CYAN = "\033[36m"

_ALLOWED = ("auto", "always", "never")


def resolve_mode(raw):
    """Normalize a raw SPECRELAY_COLOR value to (mode, invalid).

    `mode` is always one of auto|always|never (empty or unrecognized input
    yields "auto"). `invalid` is True only when a non-empty, unrecognized value
    was supplied, so the caller may warn about it exactly once."""
    normalized = (raw or "").strip().lower()
    if not normalized:
        return "auto", False
    if normalized in _ALLOWED:
        return normalized, False
    return "auto", True


def enabled(mode, stream):
    """Decide whether to emit ANSI color for `mode` writing to `stream`.

    always -> True; never -> False; auto -> `stream` must be a TTY and NO_COLOR
    must be unset. NO_COLOR (present with any value, per https://no-color.org)
    disables color in auto and never, but an explicit SPECRELAY_COLOR=always
    still wins."""
    if mode == "always":
        return True
    if mode == "never":
        return False
    if "NO_COLOR" in os.environ:
        return False
    try:
        return bool(stream.isatty())
    except Exception:
        return False


def enabled_from_env(stream):
    """Resolve SPECRELAY_COLOR from the environment and decide for `stream`.
    Returns (is_enabled, invalid) so the caller can both act and warn once."""
    mode, invalid = resolve_mode(os.environ.get("SPECRELAY_COLOR"))
    return enabled(mode, stream), invalid


def paint(text, code, on):
    """Wrap `text` in `code`...RESET when `on`, else return `text` unchanged."""
    if not on or not code:
        return text
    return "%s%s%s" % (code, text, RESET)
