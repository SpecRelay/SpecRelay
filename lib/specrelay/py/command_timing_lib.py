"""command_timing_lib.py — SpecRelay's own agent-command timing ledger (spec
0020, "Agent Command Timing Ledger").

This is SpecRelay's OWN runtime (mirrors timeline_lib.py's rationale): a
small, dependency-free module that owns:

  * secret redaction and conservative command normalization, shared by the
    live renderer (py/render_agent_events.py, which redacts BEFORE it ever
    persists a command line) and this module's own aggregation (a defense-in-
    depth second pass over already-redacted text — idempotent, never a
    second chance for a raw secret to reach disk);
  * an APPEND-ONLY, task-scoped source of completed tool-call observations
    (21-command-timing-events.jsonl) — each line is already a fully paired
    operation (the render_agent_events.py process pairs a tool_use with its
    tool_result itself, in memory, using its OWN local monotonic clock,
    because it is the one live process that actually observes both moments;
    see that module's "command timing" section);
  * a DERIVED, machine-readable summary (21-command-timings.json), rebuilt
    from the event source and written atomically (temp file + os.replace) —
    never hand-merged, so an interrupted write can only fail to update the
    file, never corrupt a previously valid one;
  * the human-readable terminal report: slowest observed commands, the
    command-timing summary line, repeated commands, and waiting/polling
    commands — all derived from the same honest data, never from parsed
    prose.

Timing honesty (spec 0020, "Core Principle" / "Timing Sources"):
  * Every operation recorded here was PAIRED by render_agent_events.py from
    real start/finish events it directly observed while streaming a live
    provider process — never inferred from prose, never guessed because two
    lines "looked close together".
  * `timing_source` is always one of `local_renderer_monotonic_clock` (the
    renderer paired a real tool_use with its real tool_result) or
    `not_measurable` (an unmatched/incomplete tool call — never given a
    fabricated duration). `provider_event_timestamps` and
    `existing_test_timing_artifact` are recognized values in the schema but
    are NOT produced by this implementation: today's Claude Code stream-json
    events do not timestamp the *start* of a tool call (only some `tool_result`
    events carry a `timestamp` field), so a duration computed purely from
    provider-supplied timestamps is not reliably available. Reporting this
    honestly (rather than claiming a source that is not truly in use) is the
    spec's own "Core Principle".
"""
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone

SCHEMA_VERSION = 1

TIMING_EVENTS_FILENAME = "21-command-timing-events.jsonl"
TIMINGS_FILENAME = "21-command-timings.json"

# Default bound on rows shown in the "Slowest Agent Commands" terminal
# section (spec 0020, "Rendering" — "default maximum row count is bounded").
DEFAULT_SLOWEST_ROWS = 10


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _events_path(task_dir):
    return os.path.join(task_dir, TIMING_EVENTS_FILENAME)


def _timings_path(task_dir):
    return os.path.join(task_dir, TIMINGS_FILENAME)


def _atomic_write(path, text):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".command-timings-", dir=d)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# --- secret redaction (spec 0020, "Secret Redaction") -----------------------
#
# Deliberately narrow and name-based (mirrors timeline_lib.py's own
# redact_command — never a claim of exhaustive secret detection). Two tiers:
#   1. targeted: a recognizable `NAME=value` secret-shaped assignment or an
#      `Authorization:` header keeps the rest of the command readable and
#      redacts only the value (spec's own examples: "OPENAI_API_KEY=<redacted>
#      command").
#   2. fallback: a secret-shaped marker keyword survives targeted redaction in
#      an unrecognized shape (e.g. embedded in a quoted blob) -> the whole
#      command is replaced rather than risk leaking part of it.
_SECRET_MARKERS = (
    "API_KEY", "APIKEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD",
    "CREDENTIAL", "AUTHORIZATION", "PRIVATE_KEY", "ACCESS_KEY", "CLIENT_SECRET",
)

_SECRET_ASSIGNMENT_RE = re.compile(
    r'\b([A-Za-z0-9_]*(?:API_?KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|'
    r'PRIVATE_KEY|ACCESS_KEY|CLIENT_SECRET)[A-Za-z0-9_]*)=(\S+)',
    re.IGNORECASE,
)
_AUTH_HEADER_RE = re.compile(r'(authorization)\s*:\s*[^"\']*', re.IGNORECASE)


def redact_command(command):
    """Returns (redacted_text, was_redacted). Never mutates a command with
    nothing secret-shaped in it."""
    if not command:
        return command, False

    redacted_flag = [False]

    def _assign_repl(m):
        redacted_flag[0] = True
        return "%s=<redacted>" % m.group(1)

    out = _SECRET_ASSIGNMENT_RE.sub(_assign_repl, command)

    def _auth_repl(m):
        redacted_flag[0] = True
        return "%s: <redacted>" % m.group(1)

    out = _AUTH_HEADER_RE.sub(_auth_repl, out)

    if redacted_flag[0]:
        return out, True

    upper = command.upper()
    if any(marker in upper for marker in _SECRET_MARKERS):
        return "<redacted: command may contain sensitive data>", True

    return command, False


# --- command normalization (spec 0020, "Command Normalization") ------------
#
# Conservative: collapses whitespace runs OUTSIDE quoted content into a single
# space and trims the ends. Never removes a token (test filenames, git refs,
# model names, flags all survive verbatim), so two commands are only ever
# grouped as duplicates when they are byte-for-byte identical apart from
# incidental whitespace.

def normalize_command(command):
    if not command:
        return command
    in_squote = False
    in_dquote = False
    out = []
    prev_space = False
    for ch in command.strip():
        if ch == "'" and not in_dquote:
            in_squote = not in_squote
        elif ch == '"' and not in_squote:
            in_dquote = not in_dquote
        if ch.isspace() and not in_squote and not in_dquote:
            if prev_space:
                continue
            out.append(" ")
            prev_space = True
            continue
        prev_space = False
        out.append(ch)
    return "".join(out)


# --- waiting / polling detection (spec 0020, "Polling and Sleep Detection") -
#
# Deliberately narrow: only a BARE `sleep N` command, or a loop that visibly
# contains `do ... sleep ...` (an until/while polling idiom), is classified as
# waiting. An ordinary long-running command (e.g. the full test suite) is
# never reclassified as "waiting" merely because it took a long time.
_BARE_SLEEP_RE = re.compile(r'^sleep\s+[0-9]+(?:\.[0-9]+)?\s*;?\s*$', re.IGNORECASE)
_POLL_LOOP_RE = re.compile(r'\b(?:until|while)\b.*?\bdo\b.*?\bsleep\b', re.IGNORECASE | re.DOTALL)


def classify_waiting(command):
    if not command:
        return False
    stripped = command.strip()
    if _BARE_SLEEP_RE.match(stripped):
        return True
    if _POLL_LOOP_RE.search(stripped):
        return True
    return False


def _tool_category(tool):
    """Groups every mcp__<server>__<tool> call under one 'MCP' row for the
    per-tool totals table (spec 0020, "Non-Bash Tool Timing" example)."""
    if isinstance(tool, str) and tool.startswith("mcp__"):
        return "MCP"
    return tool or "unknown"


def _fmt_duration(seconds):
    if seconds is None:
        return "n/a"
    seconds = int(round(seconds))
    if seconds < 60:
        return "%ds" % seconds
    m, s = divmod(seconds, 60)
    if m < 60:
        return "%dm %ds" % (m, s)
    h, m = divmod(m, 60)
    return "%dh %dm %ds" % (h, m, s)


# --- reading the append-only source ------------------------------------------

def read_timing_events(task_dir):
    """Reads every completed/incomplete operation record appended by every
    executor/reviewer renderer invocation across every run/resume for this
    task (spec 0020, "Support tasks spanning multiple run and resume
    invocations") — the file is NEVER truncated, only appended to, so prior
    invocations' history is never lost."""
    path = _events_path(task_dir)
    if not os.path.isfile(path):
        return []
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue  # a corrupted/partial trailing line is skipped, never fatal
            if isinstance(ev, dict):
                out.append(ev)
    return out


# --- aggregation --------------------------------------------------------------

def build_summary(task_dir, task_id):
    raw_ops = read_timing_events(task_dir)

    operations = []
    role_counters = {}
    for ev in raw_ops:
        role = ev.get("role") or "unknown"
        role_counters[role] = role_counters.get(role, 0) + 1
        idx = role_counters[role]

        raw_command = ev.get("command") or ""
        # Defense-in-depth: the renderer already redacts before persisting,
        # but this second pass never trusts the source file blindly. It is
        # idempotent against already-redacted text.
        redacted_command, was_redacted = redact_command(raw_command)
        normalized = normalize_command(redacted_command)

        duration = ev.get("duration_seconds")
        if not isinstance(duration, (int, float)):
            duration = None
        exit_code = ev.get("exit_code")
        if not isinstance(exit_code, int):
            exit_code = None

        tool = ev.get("tool") or "unknown"
        op = {
            "operation_id": "%s-%d" % (role, idx),
            "invocation_id": str(ev.get("invocation_id") if ev.get("invocation_id") is not None else "1"),
            "role": role,
            "provider": ev.get("provider") or "unknown",
            "tool": tool,
            "command": redacted_command,
            "normalized_command": normalized,
            "started_at": ev.get("started_at"),
            "finished_at": ev.get("finished_at"),
            "duration_seconds": duration,
            "status": ev.get("status") or "unknown",
            "exit_code": exit_code,
            "timing_source": ev.get("timing_source") or "not_measurable",
            "redacted": bool(ev.get("redacted")) or was_redacted,
            "waiting": bool(tool == "Bash" and classify_waiting(raw_command)),
        }
        operations.append(op)

    operation_count = len(operations)
    measurable_ops = [
        o for o in operations
        if isinstance(o["duration_seconds"], (int, float)) and o["timing_source"] != "not_measurable"
    ]
    measurable_operation_count = len(measurable_ops)

    tool_totals = {}
    for o in operations:
        cat = _tool_category(o["tool"])
        t = tool_totals.setdefault(cat, {"count": 0, "duration_seconds": 0.0, "measurable_count": 0})
        t["count"] += 1
        if isinstance(o["duration_seconds"], (int, float)):
            t["duration_seconds"] += o["duration_seconds"]
            t["measurable_count"] += 1

    bash_wall_seconds = sum(
        o["duration_seconds"] for o in operations
        if o["tool"] == "Bash" and isinstance(o["duration_seconds"], (int, float))
    )

    # Duplicate detection: grouped by (tool, normalized_command) — never just
    # normalized_command alone, so an operation from a different tool can
    # never be merged with a superficially similar Bash command (spec 0020,
    # "Command Normalization must not merge semantically different commands").
    groups = {}
    for o in operations:
        key = (o["tool"], o["normalized_command"])
        g = groups.setdefault(key, {"operations": [], "roles": {}})
        g["operations"].append(o)
        g["roles"][o["role"]] = g["roles"].get(o["role"], 0) + 1

    duplicate_commands = []
    for (tool, norm), g in groups.items():
        if len(g["operations"]) <= 1:
            continue
        durations = [o["duration_seconds"] for o in g["operations"] if isinstance(o["duration_seconds"], (int, float))]
        duplicate_commands.append({
            "tool": tool,
            "normalized_command": norm,
            "count": len(g["operations"]),
            "roles": g["roles"],
            # Informational only (spec 0020, "Duplicate Commands" — "a
            # repeated command is informational... do not automatically claim
            # it was unnecessary").
            "duration_seconds": sum(durations) if durations else None,
        })
    duplicate_commands.sort(key=lambda d: (-d["count"], d["normalized_command"]))

    waiting_ops = [o for o in operations if o["waiting"]]
    waiting_durations = [o["duration_seconds"] for o in waiting_ops if isinstance(o["duration_seconds"], (int, float))]
    waiting_summary = {
        "count": len(waiting_ops),
        "duration_seconds": sum(waiting_durations) if waiting_durations else 0.0,
        "operation_ids": [o["operation_id"] for o in waiting_ops],
    }

    return {
        "schema_version": SCHEMA_VERSION,
        "task_id": task_id,
        "generated_at": _now_iso(),
        "operation_count": operation_count,
        "measurable_operation_count": measurable_operation_count,
        "unmeasurable_operation_count": operation_count - measurable_operation_count,
        "operations": operations,
        "tool_totals": [
            {
                "tool": k,
                "count": v["count"],
                "duration_seconds": v["duration_seconds"] if v["measurable_count"] else None,
                "measurable_count": v["measurable_count"],
            }
            for k, v in sorted(tool_totals.items())
        ],
        "bash_wall_seconds": bash_wall_seconds,
        "duplicate_commands": duplicate_commands,
        "waiting": waiting_summary,
    }


def timeline_summary(task_dir):
    """A SMALL summary reference for 20-execution-timeline.json (spec 0020,
    "Existing Timeline Integration" — "extend with a summary reference rather
    than duplicating every operation"). Returns None when this task has no
    recorded command-timing events at all, so a legacy/never-instrumented
    task's timeline stays exactly as before (no fabricated block)."""
    if not os.path.isfile(_events_path(task_dir)):
        return None
    summary = build_summary(task_dir, "")
    if summary["operation_count"] == 0:
        return None
    return {
        "artifact": TIMINGS_FILENAME,
        "operation_count": summary["operation_count"],
        "measurable_operation_count": summary["measurable_operation_count"],
        "bash_wall_seconds": summary["bash_wall_seconds"],
        "duplicate_command_count": len(summary["duplicate_commands"]),
    }


# --- rendering -----------------------------------------------------------------

def render_report(summary, mode, max_rows=DEFAULT_SLOWEST_ROWS):
    lines = []
    label = "FINAL" if mode == "final" else "PARTIAL"
    lines.append("Command Timing -- %s" % label)
    if mode == "partial":
        lines.append("Task remains in a non-terminal state.")
    lines.append("")

    measurable_ops = [o for o in summary["operations"] if isinstance(o["duration_seconds"], (int, float))]
    slowest = sorted(measurable_ops, key=lambda o: o["duration_seconds"], reverse=True)[:max_rows]

    lines.append("+-- Slowest Agent Commands " + "-" * 46)
    lines.append("| %-10s %-6s %-8s %10s  %s" % ("Role", "Tool", "Status", "Duration", "Command"))
    lines.append("|" + "-" * 72)
    if slowest:
        for o in slowest:
            cmd_display = o["command"] or ""
            if len(cmd_display) > 42:
                cmd_display = cmd_display[:41] + "…"
            if o["status"] == "passed":
                status_disp = "PASS"
            elif o["status"] == "failed":
                status_disp = "FAIL"
            else:
                status_disp = (o["status"] or "unknown").upper()[:8]
            lines.append("| %-10s %-6s %-8s %10s  %s" % (
                o["role"], o["tool"][:6], status_disp, _fmt_duration(o["duration_seconds"]), cmd_display
            ))
    else:
        lines.append("| (no measurable commands recorded)")
    lines.append("+" + "-" * 72)

    lines.append("")
    lines.append("Command timing summary:")
    lines.append("  Observable operations:     %d" % summary["operation_count"])
    lines.append("  Measurable operations:     %d" % summary["measurable_operation_count"])
    lines.append("  Unmeasurable operations:   %d" % summary["unmeasurable_operation_count"])
    lines.append("  Bash command time:         %s" % _fmt_duration(summary["bash_wall_seconds"]))
    lines.append("  Repeated commands:         %d" % len(summary["duplicate_commands"]))

    lines.append("")
    if summary["duplicate_commands"]:
        lines.append("Repeated agent commands:")
        for d in summary["duplicate_commands"]:
            lines.append("  %d× %s" % (d["count"], d["normalized_command"]))
            for role, cnt in sorted(d["roles"].items()):
                lines.append("     %s: %d run%s" % (role, cnt, "" if cnt == 1 else "s"))
            lines.append("     total: %s (informational only; not necessarily avoidable)" % _fmt_duration(d["duration_seconds"]))
    else:
        lines.append("Repeated agent commands: none")

    lines.append("")
    w = summary["waiting"]
    lines.append("Waiting/polling commands:")
    lines.append("  Count:      %d" % w["count"])
    lines.append("  Total time: %s" % _fmt_duration(w["duration_seconds"]))

    if summary.get("tool_totals"):
        lines.append("")
        lines.append("Tool       Count    Total time")
        for t in summary["tool_totals"]:
            dur = _fmt_duration(t["duration_seconds"]) if t["duration_seconds"] is not None else "not_measurable"
            lines.append("%-10s %5d    %s" % (t["tool"], t["count"], dur))

    return "\n".join(lines) + "\n"


# --- CLI -----------------------------------------------------------------------

def main(argv):
    if not argv:
        print("usage: command_timing_lib.py <render|report|show-json> ...", file=sys.stderr)
        return 2
    cmd = argv[0]

    if cmd == "render":
        # render <task_dir> <task_id> <mode:final|partial> [--json]
        # WRITES 21-command-timings.json (atomic replace) — used only by the
        # orchestrator's own finalization step, never by a read-only
        # inspection command.
        task_dir, task_id, mode = argv[1], argv[2], argv[3]
        as_json = "--json" in argv[4:]
        summary = build_summary(task_dir, task_id)
        summary["report_mode"] = mode
        _atomic_write(_timings_path(task_dir), json.dumps(summary, indent=2, sort_keys=True) + "\n")
        if as_json:
            print(json.dumps(summary, indent=2, sort_keys=True))
        else:
            print(render_report(summary, mode))
        return 0

    if cmd == "report":
        # report <task_dir> <task_id> <mode:final|partial> [--json]
        # READ-ONLY: recomputes the same summary in memory and prints it, but
        # NEVER writes 21-command-timings.json (spec 0020, "Task Inspection" —
        # "read-only... does not mutate task state").
        task_dir, task_id, mode = argv[1], argv[2], argv[3]
        as_json = "--json" in argv[4:]
        summary = build_summary(task_dir, task_id)
        summary["report_mode"] = mode
        if as_json:
            print(json.dumps(summary, indent=2, sort_keys=True))
        else:
            print(render_report(summary, mode))
        return 0

    if cmd == "show-json":
        # show-json <task_dir> — read-only: prints the CURRENT
        # 21-command-timings.json (or {"recorded": false} for a legacy task)
        # without recomputing/mutating anything.
        task_dir = argv[1]
        path = _timings_path(task_dir)
        if os.path.isfile(path):
            with open(path) as f:
                print(f.read(), end="")
        else:
            print(json.dumps({"recorded": False}))
        return 0

    print("command_timing_lib.py: unknown command '%s'" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
