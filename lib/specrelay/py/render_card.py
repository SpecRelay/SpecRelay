#!/usr/bin/env python3
"""render_card.py — stream-friendly Unicode "card" renderer for SpecRelay's
CLI presentation (spec 0013).

SpecRelay is a STREAMING CLI, not a dashboard. This renderer only ever writes
complete lines to stdout with `print` — it is strictly APPEND-ONLY. It never
emits cursor movement, clear-screen, alternate-screen, spinners, progress bars,
or any redraw/overwrite sequence, so every line it writes stays permanently
visible in terminal scrollback and is preserved byte-for-byte when the output
is piped or redirected.

Color (via the shared color.py policy) is used ONLY to make the visual
hierarchy easier to scan. The information is ALWAYS present as plain text — the
state names, provider names, titles and results are inside the box regardless —
so a non-TTY / NO_COLOR run is identical apart from the escape sequences, and
the hierarchy stays obvious when color is disabled.

Usage:
  render_card.py card <color> <title> [<body-line> ...]
  render_card.py transition <color> <from-state> <to-state>

<color> is one of green|blue|magenta|yellow|red|none (any unknown value is
treated as none). It is applied only to the box border and title; body text is
left in the default color so meaning is never carried by color alone.
"""

import sys

# Shared color policy (optional sibling module — same one state_lib.py and
# render_agent_events.py use). When it is unavailable, everything degrades to
# plain text; the box characters themselves already carry the whole hierarchy.
try:
    import color as _color
except Exception:  # pragma: no cover - color is an optional sibling module
    _color = None

# Box-drawing set. All glyphs are single display columns on a normal terminal,
# so a code-point count is a correct width for alignment.
TL, TR, BL, BR = "╭", "╮", "╰", "╯"  # ╭ ╮ ╰ ╯
H, V = "─", "│"                                  # ─ │
ARROW = "▶"                                            # ▶

# A floor for the inner content width so short cards do not render as cramped
# little boxes; content longer than this simply widens the card (never
# truncated — nothing must disappear).
MIN_CONTENT = 28

_COLOR_ATTR = {
    "green": "GREEN",
    "blue": "BLUE",
    "magenta": "MAGENTA",
    "yellow": "YELLOW",
    "red": "RED",
}


def _resolve_code(color_name):
    """The ANSI code for a named color, or "" when color is off/unavailable."""
    if _color is None or color_name == "none":
        return ""
    attr = _COLOR_ATTR.get(color_name)
    if attr is None:
        return ""
    return getattr(_color, attr, "")


def _color_enabled():
    if _color is None:
        return False
    on, _invalid = _color.enabled_from_env(sys.stdout)
    return on


def render(title, bodies, color_name):
    """Print an append-only Unicode card. Width adapts to the widest of the
    title and body lines (floored at MIN_CONTENT), so it stays compact and
    readable on an 80-column terminal without ever truncating content."""
    body_widths = [len(b) for b in bodies]
    content = max(body_widths + [len(title) + 2, MIN_CONTENT])

    on = _color_enabled()
    code = _resolve_code(color_name)
    reset = getattr(_color, "RESET", "") if _color is not None else ""

    def paint(text):
        if on and code:
            return "%s%s%s" % (code, text, reset)
        return text

    # Every line is exactly (content + 4) display columns wide:
    #   top:    TL + H + " " + title + " " + H*dashes + TR
    #   body:   V + " " + text + padding + " " + V
    #   bottom: BL + H*(content + 2) + BR
    dashes = content - 1 - len(title)
    if dashes < 1:
        dashes = 1
    top = TL + H + " " + title + " " + (H * dashes) + TR
    print(paint(top))

    for body in bodies:
        pad = content - len(body)
        if pad < 0:
            pad = 0
        # Only the vertical border glyphs carry color; the body text stays in
        # the default color so information never depends on color.
        print("%s %s%s %s" % (paint(V), body, " " * pad, paint(V)))

    print(paint(BL + (H * (content + 2)) + BR))


def main(argv):
    if not argv:
        sys.stderr.write("Usage: render_card.py <card|transition> ...\n")
        return 2

    kind, rest = argv[0], argv[1:]

    if kind == "transition":
        if len(rest) < 3:
            sys.stderr.write("Usage: render_card.py transition <color> <from> <to>\n")
            return 2
        color_name, frm, to = rest[0], rest[1], rest[2]
        body = "%s %s%s %s" % (frm, H * 5, ARROW, to)
        render("Transition", [body], color_name)
        return 0

    if kind == "card":
        if len(rest) < 2:
            sys.stderr.write("Usage: render_card.py card <color> <title> [body ...]\n")
            return 2
        color_name, title, bodies = rest[0], rest[1], rest[2:]
        render(title, list(bodies), color_name)
        return 0

    sys.stderr.write("Unknown render_card kind: %s\n" % kind)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
