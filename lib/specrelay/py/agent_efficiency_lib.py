"""agent_efficiency_lib.py — SpecRelay's own execution-efficiency /
completion-gate reporting engine (spec 0021, "Agent Execution Efficiency and
Completion Gate").

This is SpecRelay's OWN runtime (mirrors timeline_lib.py / command_timing_lib.py's
rationale): a small, dependency-free module invoked as a script. It owns:

  * unresolved-waiting detection over a provider's FINAL EXTRACTED output text
    only (never arbitrary intermediate streaming prose) — spec 0021,
    "Unresolved Waiting Detection";
  * observable-operation classification (exploration / implementation /
    verification / waiting / artifact_writing / inspection / other), reusing
    the SAME append-only command-timing event source spec 0020 already
    records (21-command-timing-events.jsonl) rather than a new one;
  * a DERIVED, machine-readable summary (22-agent-efficiency.json), rebuilt
    from that source plus the existing execution-events log
    (20-execution-events.jsonl, for completion-gate results and phase
    timestamps) and written atomically — never hand-merged;
  * the human-readable terminal report (the "Agent Efficiency" table).

No new top-level runtime directory or event-log namespace is introduced: this
module only reads/derives from files spec 0019/0020 already write under the
existing task directory.
"""
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone

try:
    import command_timing_lib as _ctlib
except Exception:  # pragma: no cover - optional sibling module
    _ctlib = None

SCHEMA_VERSION = 1

EXECUTION_EVENTS_FILENAME = "20-execution-events.jsonl"
EFFICIENCY_FILENAME = "22-agent-efficiency.json"

ARTIFACT_FILES = {
    "executor": ["03-executor-log.md", "07-tests.txt", "08-executor-summary.md"],
    "reviewer": ["09-consultant-review.md", "10-business-summary.md", "11-next-executor-prompt.md"],
}

PROVIDER_PHASE = {
    "executor": "executor_provider_execution",
    "reviewer": "reviewer_provider_execution",
}


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _efficiency_path(task_dir):
    return os.path.join(task_dir, EFFICIENCY_FILENAME)


def _execution_events_path(task_dir):
    return os.path.join(task_dir, EXECUTION_EVENTS_FILENAME)


def _atomic_write(path, text):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".agent-efficiency-", dir=d)
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


# --- unresolved-waiting detection (spec 0021, "Unresolved Waiting Detection") -
#
# Deliberately conservative and word-bounded: only recognizes an explicit
# statement of UNRESOLVED (present/future) waiting, never a past-tense
# narration of waiting that already completed ("I waited for the test, and it
# completed successfully" must never match), and never an unrelated word that
# merely CONTAINS "wait" (e.g. "await", "waiver" — word boundaries make sure
# of that). Applied ONLY to a provider's final extracted output text (the
# caller passes exactly that file's contents — never an events/raw-stream
# transcript), so historical/intermediate narration elsewhere is structurally
# out of scope rather than something this regex set has to disprove.
_WAIT_PATTERNS = [
    re.compile(r"\bi\s+will\s+wait\b", re.IGNORECASE),
    re.compile(r"\bi(?:'|’)ll\s+wait\b", re.IGNORECASE),
    re.compile(r"\bi\s+will\s+continue\s+when\b", re.IGNORECASE),
    re.compile(r"\bi(?:'|’)ll\s+continue\s+when\b", re.IGNORECASE),
    re.compile(r"\bwaiting\s+for\b", re.IGNORECASE),
    re.compile(r"\bi\s+will\s+pick\s+(?:this|it)\s+back\s+up\b", re.IGNORECASE),
    re.compile(r"\bi(?:'|’)ll\s+pick\s+(?:this|it)\s+back\s+up\b", re.IGNORECASE),
]

_STILL_RUNNING_RE = re.compile(r"\bstill\s+running\b", re.IGNORECASE)
_STOPPING_HERE_RE = re.compile(r"\b(?:stopping\s+here|i\s+am\s+stopping)\b", re.IGNORECASE)


def detect_unresolved_wait(final_text):
    """Returns True when the FINAL extracted output text contains an explicit,
    unresolved statement of waiting (spec 0021 examples). Returns False for
    empty/missing text, historical narration ("I waited... and it completed"),
    and unrelated words that merely contain "wait"."""
    if not final_text:
        return False
    for pat in _WAIT_PATTERNS:
        if pat.search(final_text):
            return True
    if _STILL_RUNNING_RE.search(final_text) and _STOPPING_HERE_RE.search(final_text):
        return True
    return False


# --- observable operation classification (spec 0021, "Observable Work
# Classification") -----------------------------------------------------------

_VERIFICATION_BASH_RE = re.compile(
    r"scripts/test|scripts/smoke|bin/specrelay\s+doctor|specrelay\s+doctor|"
    r"bin/specrelay\s+version|specrelay\s+version|\bshellcheck\b|"
    r"\bpy_compile\b|ruby\s+-c\b|\bsyntax\s+check\b",
    re.IGNORECASE,
)
_WAITING_BASH_RE = re.compile(
    r"^\s*sleep\s+[0-9]", re.IGNORECASE,
)
_WAITING_LOOP_RE = re.compile(r"\b(?:until|while)\b.*?\bdo\b.*?\bsleep\b", re.IGNORECASE | re.DOTALL)
_WAITING_JOBS_RE = re.compile(r"\bjobs\s*;\s*wait\b|^\s*wait\b", re.IGNORECASE)
_EXPLORATION_BASH_RE = re.compile(
    r"^\s*find\b|^\s*grep\b|\|\s*grep\b|^\s*ls\b|\bgit\s+log\b", re.IGNORECASE,
)
_INSPECTION_BASH_RE = re.compile(r"\bgit\s+status\b|\bgit\s+diff\b|^\s*cat\b", re.IGNORECASE)

_ARTIFACT_BASENAMES = set(ARTIFACT_FILES["executor"]) | set(ARTIFACT_FILES["reviewer"])


def classify_operation(tool, command):
    """Classifies one observable operation as exploration | implementation |
    verification | waiting | artifact_writing | inspection | other (spec
    0021, "Observable Work Classification"). `command` is the display string
    already recorded by the command-timing ledger (spec 0020) — e.g.
    "Write: path/to/file", "Read: path", "Grep: pattern", or the literal Bash
    command line. Never fabricated: an unrecognized shape is honestly `other`.
    """
    tool = tool or "unknown"
    command = command or ""

    if tool == "Write":
        base = os.path.basename(command.split(":", 1)[1].strip()) if ":" in command else ""
        if base in _ARTIFACT_BASENAMES:
            return "artifact_writing"
        return "implementation"

    if tool in ("Edit", "MultiEdit", "NotebookEdit"):
        return "implementation"

    if tool == "Bash":
        if _VERIFICATION_BASH_RE.search(command):
            return "verification"
        if _WAITING_BASH_RE.search(command) or _WAITING_LOOP_RE.search(command) or _WAITING_JOBS_RE.search(command):
            return "waiting"
        if _EXPLORATION_BASH_RE.search(command):
            return "exploration"
        if _INSPECTION_BASH_RE.search(command):
            return "inspection"
        return "other"

    if tool in ("Grep", "Glob"):
        return "exploration"

    if tool in ("Read", "NotebookRead"):
        path = command.split(":", 1)[1].strip() if ":" in command else ""
        base = os.path.basename(path)
        if base in _ARTIFACT_BASENAMES or re.match(r"^\d{2}-", base):
            return "inspection"
        return "exploration"

    if isinstance(tool, str) and tool.startswith("mcp__"):
        if re.search(r"tree|search|retriev|navigat|context|graph", tool, re.IGNORECASE):
            return "exploration"
        return "other"

    return "other"


# --- reading existing event sources ------------------------------------------

def _read_jsonl(path):
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
                continue
            if isinstance(ev, dict):
                out.append(ev)
    return out


def _read_command_timing_operations(task_dir, task_id):
    if _ctlib is None:
        return []
    try:
        summary = _ctlib.build_summary(task_dir, task_id)
    except Exception:
        return []
    return summary.get("operations", [])


def _role_final_output_path(task_dir, role):
    return os.path.join(task_dir, "12-executor-stdout.txt" if role == "executor" else "15-reviewer-stdout.txt")


def read_final_output(task_dir, role):
    path = _role_final_output_path(task_dir, role)
    if not os.path.isfile(path):
        return ""
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def _last_completion_gate_events(events):
    """The LAST recorded completion_gate event per role (a task may run
    multiple executor/reviewer rounds; the most recent result is
    authoritative for reporting)."""
    last = {}
    for ev in events:
        if ev.get("event_type") != "completion_gate":
            continue
        role = ev.get("role")
        if role:
            last[role] = ev
    return last


def _last_provider_completed_at(events, role):
    phase = PROVIDER_PHASE.get(role)
    if not phase:
        return None
    finished = None
    for ev in events:
        if ev.get("event_type") == "phase_finish" and ev.get("phase") == phase:
            finished = ev.get("recorded_at")
    return finished


def _verification_ledger_by_role(events):
    ledger = {}
    for ev in events:
        if ev.get("event_type") != "verification":
            continue
        role = ev.get("role", "unknown")
        op = ev.get("operation", "agent_tool_execution_unclassified")
        entry = ledger.setdefault((role, op), {"count": 0, "reasons": [], "finished_at": []})
        entry["count"] += 1
        if ev.get("reason"):
            entry["reasons"].append(ev["reason"])
        entry["finished_at"].append(ev.get("recorded_at"))
    return ledger


def _unjustified_repeated_verification(ledger, role):
    total = 0
    for (r, _op), entry in ledger.items():
        if r != role:
            continue
        extra = entry["count"] - 1
        if extra <= 0:
            continue
        unjustified = max(0, extra - len(entry["reasons"]))
        total += unjustified
    return total


def _last_verification_at(ledger, role):
    """The recorded_at of the LAST verification event for this role, used as
    `final_required_verification_at` (spec 0021: "the completion time of the
    last verification operation necessary to satisfy the effective
    verification policy") — best-effort: the last OBSERVED verification
    event for the role, since SpecRelay cannot re-derive which specific run
    was policy-REQUIRED versus advisory from the ledger alone."""
    latest = None
    for (r, _op), entry in ledger.items():
        if r != role:
            continue
        for ts in entry["finished_at"]:
            if ts and (latest is None or ts > latest):
                latest = ts
    return latest


def _wall_diff(a_iso, b_iso):
    try:
        a = datetime.strptime(a_iso, "%Y-%m-%dT%H:%M:%SZ")
        b = datetime.strptime(b_iso, "%Y-%m-%dT%H:%M:%SZ")
        return max(0.0, (b - a).total_seconds())
    except Exception:
        return None


CATEGORIES = ["exploration", "implementation", "verification", "waiting", "artifact_writing", "inspection", "other"]


def _role_summary(task_dir, task_id, role, events, ledger, gate_events):
    ops = [o for o in _read_command_timing_operations(task_dir, task_id) if o.get("role") == role]
    counts = {c: 0 for c in CATEGORIES}
    for o in ops:
        cat = classify_operation(o.get("tool"), o.get("command"))
        counts[cat] = counts.get(cat, 0) + 1

    final_text = read_final_output(task_dir, role)
    unresolved = detect_unresolved_wait(final_text)

    gate_ev = gate_events.get(role)
    completion_gate = gate_ev.get("result") if gate_ev else "not_recorded"
    completion_gate_reason = gate_ev.get("reason") if gate_ev else None

    provider_completed_at = _last_provider_completed_at(events, role)
    final_required_verification_at = _last_verification_at(ledger, role)
    post_verification_seconds = None
    if final_required_verification_at and provider_completed_at:
        post_verification_seconds = _wall_diff(final_required_verification_at, provider_completed_at)

    return {
        "observable_operations": len(ops),
        "exploration_operations": counts["exploration"],
        "implementation_operations": counts["implementation"],
        "verification_operations": counts["verification"],
        "waiting_operations": counts["waiting"],
        "artifact_writing_operations": counts["artifact_writing"],
        "inspection_operations": counts["inspection"],
        "other_operations": counts["other"],
        "unjustified_repeated_verification": _unjustified_repeated_verification(ledger, role),
        "final_required_verification_at": final_required_verification_at,
        "provider_completed_at": provider_completed_at,
        "post_verification_seconds": post_verification_seconds,
        "unresolved_waiting": "detected" if unresolved else "none",
        "background_jobs": "not_verifiable",
        "completion_gate": completion_gate,
        "completion_gate_reason": completion_gate_reason,
    }


def build_summary(task_dir, task_id):
    events = _read_jsonl(_execution_events_path(task_dir))
    ledger = _verification_ledger_by_role(events)
    gate_events = _last_completion_gate_events(events)

    roles = {}
    for role in ("executor", "reviewer"):
        roles[role] = _role_summary(task_dir, task_id, role, events, ledger, gate_events)

    return {
        "schema_version": SCHEMA_VERSION,
        "task_id": task_id,
        "generated_at": _now_iso(),
        "roles": roles,
    }


def efficiency_summary_for_timeline(task_dir, task_id):
    """A SMALL summary reference for 20-execution-timeline.json (spec 0021,
    "Timeline Integration" — extend with a summary reference, mirroring spec
    0020's command_timing_summary hook). Returns None when neither role has
    ever recorded a completion-gate result or any observable operation, so a
    legacy/never-instrumented task's timeline stays exactly as before."""
    if not os.path.isfile(_execution_events_path(task_dir)):
        return None
    summary = build_summary(task_dir, task_id)
    roles = summary["roles"]
    if all(r["completion_gate"] == "not_recorded" and r["observable_operations"] == 0 for r in roles.values()):
        return None
    return {
        "artifact": EFFICIENCY_FILENAME,
        "executor_post_verification_seconds": roles["executor"]["post_verification_seconds"],
        "reviewer_post_verification_seconds": roles["reviewer"]["post_verification_seconds"],
        "executor_completion_gate": roles["executor"]["completion_gate"],
        "reviewer_completion_gate": roles["reviewer"]["completion_gate"],
    }


# --- rendering -----------------------------------------------------------------

def render_report(summary, mode):
    roles = summary["roles"]
    failed = [(name, r) for name, r in roles.items() if r["completion_gate"] == "failed"]

    lines = []
    if failed:
        lines.append("Agent Efficiency -- PARTIAL")
        lines.append("Completion gate:")
        for name, r in failed:
            lines.append("  %s: failed" % name.capitalize())
            lines.append("  Reason: %s" % (r.get("completion_gate_reason") or "unspecified"))
        return "\n".join(lines) + "\n"

    label = "FINAL" if mode == "final" else "PARTIAL"
    lines.append("Agent Efficiency -- %s" % label)
    lines.append("+-- Agent Efficiency " + "-" * 51)
    lines.append("| %-10s %7s %10s %6s %4s %9s %12s" % (
        "Role", "Explore", "Implement", "Verify", "Wait", "Artifacts", "After verify"))
    lines.append("|" + "-" * 72)
    for name in ("executor", "reviewer"):
        r = roles[name]
        lines.append("| %-10s %7d %10d %6d %4d %9d %12s" % (
            name,
            r["exploration_operations"],
            r["implementation_operations"],
            r["verification_operations"],
            r["waiting_operations"],
            r["artifact_writing_operations"],
            _fmt_duration(r["post_verification_seconds"]),
        ))
    lines.append("+" + "-" * 72)

    lines.append("Completion gates:")
    for name in ("executor", "reviewer"):
        lines.append("  %s: %s" % (name.capitalize(), roles[name]["completion_gate"]))

    lines.append("Unjustified repeated verification:")
    for name in ("executor", "reviewer"):
        lines.append("  %s: %d" % (name.capitalize(), roles[name]["unjustified_repeated_verification"]))

    lines.append("Unresolved waiting:")
    for name in ("executor", "reviewer"):
        state = roles[name]["unresolved_waiting"]
        lines.append("  %s: %s" % (name.capitalize(), "none" if state == "none" else "detected"))

    return "\n".join(lines) + "\n"


# --- CLI -----------------------------------------------------------------------

def main(argv):
    if not argv:
        print("usage: agent_efficiency_lib.py <render|report|show-json> ...", file=sys.stderr)
        return 2
    cmd = argv[0]

    if cmd == "render":
        # render <task_dir> <task_id> <mode:final|partial> [--json]
        task_dir, task_id, mode = argv[1], argv[2], argv[3]
        as_json = "--json" in argv[4:]
        summary = build_summary(task_dir, task_id)
        summary["report_mode"] = mode
        _atomic_write(_efficiency_path(task_dir), json.dumps(summary, indent=2, sort_keys=True) + "\n")
        if as_json:
            print(json.dumps(summary, indent=2, sort_keys=True))
        else:
            print(render_report(summary, mode))
        return 0

    if cmd == "report":
        # report <task_dir> <task_id> <mode:final|partial> [--json]
        # READ-ONLY: never writes 22-agent-efficiency.json.
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
        # 22-agent-efficiency.json (or {"recorded": false}) without
        # recomputing/mutating anything.
        task_dir = argv[1]
        path = _efficiency_path(task_dir)
        if os.path.isfile(path):
            with open(path) as f:
                print(f.read(), end="")
        else:
            print(json.dumps({"recorded": False}))
        return 0

    if cmd == "detect-unresolved-wait":
        # detect-unresolved-wait <final-output-file>
        # Prints "detected" or "none" (exit 0 either way; the file's absence
        # is honestly "none", never a failure).
        path = argv[1]
        text = ""
        if os.path.isfile(path):
            with open(path, errors="replace") as f:
                text = f.read()
        print("detected" if detect_unresolved_wait(text) else "none")
        return 0

    print("agent_efficiency_lib.py: unknown command '%s'" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
