"""timeline_lib.py — SpecRelay's own execution-timeline / verification-ledger
engine (spec 0019, "Execution Timeline").

This is SpecRelay's OWN runtime (mirrors state_lib.py's rationale): a small,
dependency-free module invoked as a script by timeline.sh. It owns:

  * an APPEND-ONLY, per-task event log (20-execution-events.jsonl) — the
    single source of truth. Every phase start/finish, invocation boundary,
    verification operation, and marker-recovery attempt is one JSON line.
  * a DERIVED, machine-readable summary (20-execution-timeline.json),
    regenerated FROM the event log and written atomically (temp file + os.
    replace) on every render — never hand-merged, so an interrupted write
    can only ever fail to update the file, never corrupt a previously valid
    one, and multiple resume invocations are never lost (the event log is
    never truncated or overwritten, only appended to).
  * the final human-readable report: execution timeline table, verification
    ledger, duplicate-work detection, slowest phases, performance summary,
    and phase-budget warnings — all derived from the same honest data, never
    from parsed prose.

Timing honesty (spec 0019, "Metrics Must Be Honest" / "Timeline Accuracy"):
  * `monotonic` (time.monotonic(), CLOCK_MONOTONIC) pairs a phase's start/
    finish across separate process invocations reliably WITHIN one boot
    session, and is preferred for phase durations.
  * `recorded_at` is always a UTC wall-clock ISO-8601 timestamp, used for the
    total-wall-time span across invocations (monotonic cannot span a reboot
    between resumes; wall clock can, and "how long did the whole task take"
    is a calendar-time question).
  * No timing is ever fabricated from prose or guessed.
"""
import json
import os
import sys
import time
import tempfile
from datetime import datetime, timezone

# The command-timing engine (spec 0020) lives beside this file. Optional: a
# task that predates spec 0020, or a stripped-down install missing the
# sibling module, must still render its execution timeline exactly as before
# — the "command_timing_summary" block below is simply omitted rather than
# failing the whole timeline render.
try:
    import command_timing_lib as _command_timing_lib
except Exception:  # pragma: no cover - command_timing_lib is an optional sibling module
    _command_timing_lib = None

# The agent-efficiency engine (spec 0021) lives beside this file too. Optional
# for the same reason as command_timing_lib above: a task that predates spec
# 0021 (or a stripped-down install missing the sibling module) still renders
# its execution timeline exactly as before — the "agent_efficiency_summary"
# block below is simply omitted rather than failing the whole render.
try:
    import agent_efficiency_lib as _agent_efficiency_lib
except Exception:  # pragma: no cover - agent_efficiency_lib is an optional sibling module
    _agent_efficiency_lib = None

SCHEMA_VERSION = 1

REQUIRED_PHASES = [
    "task_initialization",
    "task_approval",
    "executor_context_preflight",
    "executor_claim",
    "executor_provider_execution",
    "executor_evidence_capture",
    "executor_submission",
    "reviewer_context_preflight",
    "reviewer_start",
    "reviewer_provider_execution",
    "reviewer_marker_recovery",
    "reviewer_transition",
    "finalization",
]

# Secret-shaped substrings that must never be persisted verbatim (spec 0019,
# "Security and Privacy"). Deliberately narrow (name-based), never a claim of
# exhaustive secret detection.
SECRET_MARKERS = (
    "API_KEY", "APIKEY", "SECRET", "TOKEN", "PASSWORD", "AUTHORIZATION",
    "CREDENTIAL", "PRIVATE_KEY",
)


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _events_path(task_dir):
    return os.path.join(task_dir, "20-execution-events.jsonl")


def _timeline_path(task_dir):
    return os.path.join(task_dir, "20-execution-timeline.json")


def _atomic_write(path, text):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".timeline-", dir=d)
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


def redact_command(command):
    """Redact a verification command if it looks like it carries a secret
    (spec 0019, "Security and Privacy" — command lines are redacted, never
    the whole event dropped, so operation counts stay honest)."""
    if not command:
        return command
    upper = command.upper()
    for marker in SECRET_MARKERS:
        if marker in upper:
            return "<redacted: contains sensitive environment assignment>"
    return command


def append_event(task_dir, event_type, fields):
    """Appends one JSON line to the task's append-only event log. `fields`
    is a flat dict of already-sanitized values (no secrets). Deliberately
    does NOT create task_dir: a timed phase that starts before a brand-new
    task directory legitimately exists (e.g. task_initialization, timed from
    before transitions::create's own "must not already exist" guard) simply
    fails to record that one event rather than ever creating the directory
    early and corrupting that guard's exists-check."""
    if not os.path.isdir(task_dir):
        raise FileNotFoundError(task_dir)
    event = {"event_type": event_type, "recorded_at": _now_iso(), "monotonic": time.monotonic()}
    event.update(fields or {})
    path = _events_path(task_dir)
    with open(path, "a") as f:
        f.write(json.dumps(event, sort_keys=True) + "\n")
    return event


def read_events(task_dir):
    path = _events_path(task_dir)
    if not os.path.isfile(path):
        return []
    events = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except Exception:
                continue  # a corrupted/partial trailing line is skipped, never fatal
    return events


# --- phase pairing ------------------------------------------------------------

def _pair_phases(events):
    """Pairs phase_start/phase_finish events (FIFO per phase name) into
    records with a duration. An unmatched (still-open) start becomes a
    'running'/interrupted record with no finish — this is exactly how a
    partial invocation's in-flight phase is retained (spec 0019, "partial
    invocation is retained after failure")."""
    open_starts = {}  # phase -> list of start events (queue)
    records = []
    for ev in events:
        if ev.get("event_type") == "phase_start":
            open_starts.setdefault(ev["phase"], []).append(ev)
        elif ev.get("event_type") == "phase_finish":
            queue = open_starts.get(ev["phase"]) or []
            start = queue.pop(0) if queue else None
            duration = None
            if start is not None:
                if isinstance(start.get("monotonic"), (int, float)) and isinstance(ev.get("monotonic"), (int, float)):
                    duration = max(0.0, ev["monotonic"] - start["monotonic"])
                elif start.get("recorded_at") and ev.get("recorded_at"):
                    duration = _wall_diff(start["recorded_at"], ev["recorded_at"])
            records.append({
                "name": ev["phase"],
                "role": (start or {}).get("role") or ev.get("role"),
                "status": ev.get("status", "unknown"),
                "started_at": (start or {}).get("recorded_at"),
                "finished_at": ev.get("recorded_at"),
                "duration_seconds": duration,
                "source": "orchestrator",
                "complete": True,
            })
    # Any still-open (unfinished) starts are retained as incomplete records.
    for phase, queue in open_starts.items():
        for start in queue:
            records.append({
                "name": phase,
                "role": start.get("role"),
                "status": "interrupted",
                "started_at": start.get("recorded_at"),
                "finished_at": None,
                "duration_seconds": None,
                "source": "orchestrator",
                "complete": False,
            })
    return records


def _wall_diff(a_iso, b_iso):
    try:
        a = datetime.strptime(a_iso, "%Y-%m-%dT%H:%M:%SZ")
        b = datetime.strptime(b_iso, "%Y-%m-%dT%H:%M:%SZ")
        return max(0.0, (b - a).total_seconds())
    except Exception:
        return None


def _invocations(events):
    """Splits the event stream at each invocation_start into per-invocation
    segments. Returns a list of dicts with invocation_id, started_at,
    finished_at, initial_state, final_state, exit_code, and its own events."""
    segments = []
    current = None
    for ev in events:
        if ev.get("event_type") == "invocation_start":
            current = {
                "invocation_id": ev.get("invocation_id"),
                "started_at": ev.get("recorded_at"),
                "initial_state": ev.get("initial_state"),
                "finished_at": None,
                "final_state": None,
                "exit_code": None,
                "events": [],
            }
            segments.append(current)
        elif current is not None:
            current["events"].append(ev)
            if ev.get("event_type") == "invocation_finish":
                current["finished_at"] = ev.get("recorded_at")
                current["final_state"] = ev.get("final_state")
                current["exit_code"] = ev.get("exit_code")
    return segments


# --- verification ledger ------------------------------------------------------

def _verification_ledger(events):
    """Aggregates verification events by (role, operation): count, total
    duration (None entries excluded from the sum but tracked separately),
    and the list of recorded reasons (for duplicate justification)."""
    ledger = {}
    for ev in events:
        if ev.get("event_type") != "verification":
            continue
        key = (ev.get("role", "unknown"), ev.get("operation", "agent_tool_execution_unclassified"))
        entry = ledger.setdefault(key, {"count": 0, "duration_seconds": 0.0, "has_duration": False, "reasons": []})
        entry["count"] += 1
        dur = ev.get("duration_seconds")
        if isinstance(dur, (int, float)):
            entry["duration_seconds"] += dur
            entry["has_duration"] = True
        if ev.get("reason"):
            entry["reasons"].append(ev["reason"])
    return ledger


def _duplicate_work(ledger):
    """Reports operations that ran more than once, per role, and whether a
    reason was recorded for the extra runs (spec 0019, "Repeated
    Verification Reporting" — never claims all duplicates were avoidable)."""
    duplicates = []
    for (role, operation), entry in ledger.items():
        if entry["count"] <= 1:
            continue
        justified = len(entry["reasons"]) >= (entry["count"] - 1)
        duplicates.append({
            "role": role,
            "operation": operation,
            "count": entry["count"],
            "duration_seconds": entry["duration_seconds"] if entry["has_duration"] else None,
            "justified": justified,
            "reasons": entry["reasons"],
        })
    return duplicates


# --- phase budgets -------------------------------------------------------------

def evaluate_budgets(phase_totals, budgets):
    """budgets: {phase_key: seconds}. phase_totals: {phase_name: seconds or None}.
    Returns a list of {phase, status, expected_seconds, actual_seconds}."""
    results = []
    budget_phase_map = {
        "executor_context_preflight_seconds": "executor_context_preflight",
        "executor_evidence_capture_seconds": "executor_evidence_capture",
        "reviewer_context_preflight_seconds": "reviewer_context_preflight",
        "reviewer_provider_seconds": "reviewer_provider_execution",
        "reviewer_marker_recovery_seconds": "reviewer_marker_recovery",
        "finalization_seconds": "finalization",
    }
    for budget_key, phase in budget_phase_map.items():
        expected = budgets.get(budget_key)
        actual = phase_totals.get(phase)
        if expected is None:
            results.append({"phase": phase, "status": "not_configured", "expected_seconds": None, "actual_seconds": actual})
            continue
        if actual is None:
            results.append({"phase": phase, "status": "not_measurable", "expected_seconds": expected, "actual_seconds": None})
            continue
        status = "exceeded" if actual > expected else "within_budget"
        results.append({"phase": phase, "status": status, "expected_seconds": expected, "actual_seconds": actual})
    return results


# --- rendering -----------------------------------------------------------------

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


def build_summary(task_dir, task_id, budgets):
    events = read_events(task_dir)
    phase_records = _pair_phases(events)
    invocations = _invocations(events)
    ledger = _verification_ledger(events)
    duplicates = _duplicate_work(ledger)

    marker_recovery_events = [e for e in events if e.get("event_type") == "marker_recovery"]

    # Phase totals (summed across every occurrence — a multi-round task may
    # run a phase more than once; the report shows the cumulative cost).
    phase_totals = {}
    phase_status = {}
    for rec in phase_records:
        name = rec["name"]
        phase_totals.setdefault(name, 0.0)
        if isinstance(rec["duration_seconds"], (int, float)):
            phase_totals[name] += rec["duration_seconds"]
        phase_status[name] = rec["status"]

    started_at = invocations[0]["started_at"] if invocations else None
    finished_at = None
    for inv in reversed(invocations):
        if inv["finished_at"]:
            finished_at = inv["finished_at"]
            break
    wall_seconds = _wall_diff(started_at, finished_at) if started_at and finished_at else None

    invocation_count = len(invocations)
    resume_count = max(0, invocation_count - 1)

    budget_results = evaluate_budgets(phase_totals, budgets)

    summary = {
        "schema_version": SCHEMA_VERSION,
        "task_id": task_id,
        "started_at": started_at,
        "finished_at": finished_at,
        "wall_seconds": wall_seconds,
        "invocation_count": invocation_count,
        "resume_count": resume_count,
        "phases": [
            {
                "name": name,
                "status": phase_status.get(name, "unknown"),
                "duration_seconds": phase_totals.get(name),
                "source": "orchestrator",
            }
            for name in REQUIRED_PHASES
            if name in phase_totals
        ],
        "invocations": [
            {
                "invocation_id": inv["invocation_id"],
                "started_at": inv["started_at"],
                "finished_at": inv["finished_at"],
                "initial_state": inv["initial_state"],
                "final_state": inv["final_state"],
                "exit_code": inv["exit_code"],
            }
            for inv in invocations
        ],
        "verification_ledger": [
            {
                "operation": operation,
                "role": role,
                "count": entry["count"],
                "duration_seconds": entry["duration_seconds"] if entry["has_duration"] else None,
            }
            for (role, operation), entry in sorted(ledger.items())
        ],
        "duplicate_work": duplicates,
        "marker_recovery": {
            "attempted": len(marker_recovery_events) > 0,
            "attempts": len(marker_recovery_events),
            "outcome": marker_recovery_events[-1].get("outcome") if marker_recovery_events else "not_used",
        },
        "budget_warnings": [b for b in budget_results if b["status"] == "exceeded"],
        "budgets": budget_results,
    }

    # Command-timing summary reference (spec 0020, "Existing Timeline
    # Integration" — "extend with a summary reference rather than duplicating
    # every operation"). Computed fresh every time (cheap: it is a single pass
    # over one append-only JSONL file), so both the mutating `render` and the
    # read-only `report`/`task timeline` paths always reflect the CURRENT
    # command-timing event log rather than a possibly-stale persisted
    # artifact. A task with no recorded command-timing events at all (a
    # legacy task, or one that never ran a real Claude renderer) gets no
    # block at all — existing timeline JSON stays exactly as before.
    if _command_timing_lib is not None:
        try:
            cts = _command_timing_lib.timeline_summary(task_dir)
            if cts:
                summary["command_timing_summary"] = cts
        except Exception:
            pass

    # Agent-efficiency summary reference (spec 0021, "Timeline Integration" —
    # "extend with a summary reference" — mirrors command_timing_summary
    # above). Omitted entirely for a task with no recorded efficiency
    # evidence at all, so a legacy task's timeline JSON stays exactly as
    # before.
    if _agent_efficiency_lib is not None:
        try:
            aes = _agent_efficiency_lib.efficiency_summary_for_timeline(task_dir, task_id)
            if aes:
                summary["agent_efficiency_summary"] = aes
        except Exception:
            pass

    return summary


def render_table(summary, mode):
    lines = []
    label = "FINAL" if mode == "final" else "PARTIAL"
    lines.append("Execution Timeline -- %s" % label)
    if mode == "partial":
        lines.append("Task remains in a non-terminal state.")
    lines.append("")

    total = summary["wall_seconds"]
    lines.append("+-- Execution Timeline " + "-" * 50)
    lines.append("| %-34s %-8s %10s %8s" % ("Phase", "Status", "Duration", "Share"))
    lines.append("|" + "-" * 70)
    for ph in summary["phases"]:
        dur = ph["duration_seconds"]
        share = "n/a"
        if isinstance(dur, (int, float)) and isinstance(total, (int, float)) and total > 0:
            share = "%.1f%%" % (100.0 * dur / total)
        lines.append("| %-34s %-8s %10s %8s" % (ph["name"], ph["status"], _fmt_duration(dur), share))
    lines.append("|" + "-" * 70)
    lines.append("| %-34s %-8s %10s %8s" % ("Total wall time", "", _fmt_duration(total), "100.0%" if total else "n/a"))
    lines.append("+" + "-" * 70)

    lines.append("")
    lines.append("Invocations: %d" % summary["invocation_count"])
    lines.append("Resume count: %d" % summary["resume_count"])

    lines.append("")
    lines.append("+-- Verification Ledger " + "-" * 46)
    lines.append("| %-24s %-10s %8s %14s" % ("Operation", "Role", "Count", "Total Duration"))
    lines.append("|" + "-" * 66)
    if summary["verification_ledger"]:
        for row in summary["verification_ledger"]:
            lines.append("| %-24s %-10s %8d %14s" % (
                row["operation"], row["role"], row["count"], _fmt_duration(row["duration_seconds"])
            ))
    else:
        lines.append("| (no verification operations recorded)")
    lines.append("+" + "-" * 66)

    lines.append("")
    if summary["duplicate_work"]:
        lines.append("Duplicate work detected:")
        for d in summary["duplicate_work"]:
            justified = "justified" if d["justified"] else "unjustified (no recorded reason)"
            lines.append("  %s executed %d times by %s (%s)" % (d["operation"], d["count"], d["role"], justified))
            lines.append("    Measured duplicate duration: %s" % _fmt_duration(d["duration_seconds"]))
            lines.append("    Avoidability: %s" % ("unknown" if d["justified"] else "the additional run had no recorded justification"))
    else:
        lines.append("Duplicate work detected: none")

    lines.append("")
    measurable = [p for p in summary["phases"] if isinstance(p["duration_seconds"], (int, float))]
    slowest = sorted(measurable, key=lambda p: p["duration_seconds"], reverse=True)[:5]
    lines.append("Slowest phases:")
    if slowest:
        for i, p in enumerate(slowest, 1):
            lines.append("  %d. %-32s %s" % (i, p["name"], _fmt_duration(p["duration_seconds"])))
    else:
        lines.append("  (no measured phases)")

    lines.append("")
    mr = summary["marker_recovery"]
    lines.append("Performance Summary:")
    lines.append("  Total wall time:      %s" % _fmt_duration(total))
    lines.append("  Invocations:          %d" % summary["invocation_count"])
    lines.append("  Resume count:         %d" % summary["resume_count"])
    lines.append("  Marker recovery:      %s" % (mr["outcome"] if mr["attempted"] else "not used"))
    dup_full = next((d["count"] for d in summary["duplicate_work"] if d["operation"] == "test_full"), 0)
    lines.append("  Duplicate full suites: %d" % dup_full)
    lines.append("  Budget warnings:      %d" % len(summary["budget_warnings"]))

    lines.append("")
    if summary["budget_warnings"]:
        lines.append("Budget warnings:")
        for w in summary["budget_warnings"]:
            lines.append("  %s:" % w["phase"])
            lines.append("    expected <= %s" % _fmt_duration(w["expected_seconds"]))
            lines.append("    actual    %s" % _fmt_duration(w["actual_seconds"]))
    else:
        lines.append("Budget warnings: none")

    return "\n".join(lines) + "\n"


# --- CLI -----------------------------------------------------------------------

def _read_stdin_json():
    raw = sys.stdin.read()
    return json.loads(raw) if raw.strip() else {}


def main(argv):
    if not argv:
        print("usage: timeline_lib.py <emit|render> ...", file=sys.stderr)
        return 2
    cmd = argv[0]

    if cmd == "emit":
        # emit <task_dir> <event_type>   (fields as JSON on stdin)
        task_dir, event_type = argv[1], argv[2]
        fields = _read_stdin_json()
        append_event(task_dir, event_type, fields)
        return 0

    if cmd == "render":
        # render <task_dir> <task_id> <mode:final|partial> <budgets-json-on-stdin> [--json]
        # WRITES the derived 20-execution-timeline.json (atomic replace) —
        # used only by the orchestrator's own finalization step, never by a
        # read-only inspection command.
        task_dir, task_id, mode = argv[1], argv[2], argv[3]
        budgets = _read_stdin_json()
        as_json = "--json" in argv[4:]
        summary = build_summary(task_dir, task_id, budgets)
        summary["report_mode"] = mode
        _atomic_write(_timeline_path(task_dir), json.dumps(summary, indent=2, sort_keys=True) + "\n")
        if as_json:
            print(json.dumps(summary, indent=2, sort_keys=True))
        else:
            print(render_table(summary, mode))
        return 0

    if cmd == "report":
        # report <task_dir> <task_id> <mode:final|partial> <budgets-json-on-stdin> [--json]
        # READ-ONLY: recomputes the same summary in memory and prints it, but
        # NEVER writes 20-execution-timeline.json (spec 0019, "read-only
        # commands do not mutate task files" — used by `task timeline`).
        task_dir, task_id, mode = argv[1], argv[2], argv[3]
        budgets = _read_stdin_json()
        as_json = "--json" in argv[4:]
        summary = build_summary(task_dir, task_id, budgets)
        summary["report_mode"] = mode
        if as_json:
            print(json.dumps(summary, indent=2, sort_keys=True))
        else:
            print(render_table(summary, mode))
        return 0

    if cmd == "next-invocation-id":
        # next-invocation-id <task_dir> — read-only: 1 + the number of
        # invocation_start events already recorded.
        task_dir = argv[1]
        count = sum(1 for e in read_events(task_dir) if e.get("event_type") == "invocation_start")
        print(count + 1)
        return 0

    if cmd == "show-json":
        # show-json <task_dir>  — read-only: prints the CURRENT timeline.json
        # (or {} if never recorded) without recomputing/mutating anything.
        task_dir = argv[1]
        path = _timeline_path(task_dir)
        if os.path.isfile(path):
            with open(path) as f:
                print(f.read(), end="")
        else:
            print(json.dumps({"recorded": False}))
        return 0

    print("timeline_lib.py: unknown command '%s'" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
