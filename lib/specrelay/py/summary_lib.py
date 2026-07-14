#!/usr/bin/env python3
"""summary_lib.py — concise operator-summary fields (spec 0022, section 7.1
"Summary-first terminal output"). Derives every field from ALREADY-PERSISTED,
honest data (20-execution-timeline.json, state.json) — nothing here re-runs
or re-derives verification; it only summarizes what was recorded. A task
with no recorded data at all reports fields as "not recorded" rather than
fabricating a value.
"""
import json
import os
import sys


def _load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _format_duration(seconds):
    if seconds is None:
        return "not recorded"
    seconds = int(seconds)
    if seconds < 60:
        return "%ds" % seconds
    return "%dm %ds" % (seconds // 60, seconds % 60)


def _role_phase_summary(phases, prefix):
    matched = [p for p in phases if p["name"].startswith(prefix)]
    if not matched:
        return None
    total = 0.0
    have_duration = False
    status = "passed"
    for p in matched:
        if p.get("status") == "failed":
            status = "failed"
        d = p.get("duration_seconds")
        if isinstance(d, (int, float)):
            total += d
            have_duration = True
    return {"status": status, "duration_seconds": total if have_duration else None}


def build(task_dir, task_id, context_required):
    timeline = _load_json(os.path.join(task_dir, "20-execution-timeline.json")) or {}
    state = _load_json(os.path.join(task_dir, "state.json")) or {}

    recorded = bool(timeline.get("phases"))
    phases = timeline.get("phases", [])

    executor = _role_phase_summary(phases, "executor_")
    reviewer = _role_phase_summary(phases, "reviewer_")

    ledger = timeline.get("verification_ledger", [])
    focused = sum(e["count"] for e in ledger if e["operation"] in ("test_focused", "test_targeted"))
    full = sum(e["count"] for e in ledger if e["operation"] == "test_full")
    if not ledger:
        tests_desc = "not recorded"
    elif full > 0:
        tests_desc = "full suite recorded"
    elif focused > 0:
        tests_desc = "focused recorded · full suite not required"
    else:
        tests_desc = "not recorded"

    if not context_required:
        context_desc = "not required"
    else:
        preflight = next((p for p in phases if p["name"] == "executor_context_preflight"), None)
        if preflight is None:
            context_desc = "not recorded"
        elif preflight.get("status") == "passed":
            context_desc = "ready"
        else:
            context_desc = "degraded"

    active_seconds = None
    if phases:
        durs = [p["duration_seconds"] for p in phases if isinstance(p.get("duration_seconds"), (int, float))]
        if durs:
            active_seconds = sum(durs)

    warnings = timeline.get("budget_warnings", []) or []
    # Collapse to one message per distinct phase (spec 7.5) — evaluate_budgets
    # already emits at most one entry per phase per snapshot, so grouping by
    # phase name is already the fully-collapsed form.
    by_phase = {}
    for w in warnings:
        by_phase.setdefault(w["phase"], w)
    warning_lines = [
        "%s exceeded its budget (%ss > %ss)" % (phase, w.get("actual_seconds"), w.get("expected_seconds"))
        for phase, w in sorted(by_phase.items())
    ]

    return {
        "recorded": recorded,
        "task_id": task_id,
        "state": state.get("state", "unknown"),
        "executor": executor,
        "reviewer": reviewer,
        "tests": tests_desc,
        "context": context_desc,
        "active_seconds": active_seconds,
        "active_time": _format_duration(active_seconds),
        "warning_count": len(warning_lines),
        "warning_lines": warning_lines,
    }


def cmd_build(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: summary_lib.py build <task-dir> <task-id> <context-required:0|1>\n")
        return 2
    task_dir, task_id, context_required = argv
    data = build(task_dir, task_id, context_required == "1")
    print(json.dumps(data, indent=2, sort_keys=True))
    return 0


def main(argv):
    if not argv:
        sys.stderr.write("usage: summary_lib.py build ...\n")
        return 2
    if argv[0] == "build":
        return cmd_build(argv[1:])
    sys.stderr.write("unknown subcommand: %s\n" % argv[0])
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
