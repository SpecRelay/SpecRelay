"""finalization_lib.py — engine-owned executor finalization (spec 0029,
"Engine-Owned Executor Finalization and Supervised Verification").

Owns deterministic record generation, digest comparison, and human-readable
artifact rendering for the durable finalization record
(30-executor-finalization.json). This module NEVER shells out, NEVER invokes
a provider, and NEVER decides whether to run verification — it only reads
already-produced evidence and durable facts the bash layer (finalization.sh)
hands it, and renders/records them honestly. It never fabricates an action,
a test result, or an AI claim: every value not actually observed is either
omitted or explicitly labelled "unavailable" (section 12.2).

Engine-observed facts, AI-reported text, and unavailable information are
kept in clearly separate zones wherever this module renders text for a human
(03-executor-log.md, 07-tests.txt, the operator card) — see
render_executor_log / render_tests_txt / render_card below.

CLI usage: one subcommand per finalization phase concern; see main() at the
bottom for the full list. Every subcommand prints on success; a bad/missing
argument is a plain error on stderr with a non-zero exit.
"""

import datetime
import hashlib
import json
import os
import re
import sys
import tempfile

SCHEMA_VERSION = 1
PIPELINE_VERSION = 1

REQUIRED_SUMMARY_SECTIONS = [
    "Finalization Pipeline",
    "Supervised Verification",
    "Evidence Provenance",
    "Interrupted-Round Recovery",
    "Backward Compatibility",
    "Input Coverage",
]

FINALIZATION_OUTCOMES = [
    "PROVIDER_FAILED",
    "PROVIDER_EXITED_WITH_PENDING_WORK",
    "VERIFICATION_FAILED",
    "VERIFICATION_BLOCKED",
    "FINALIZATION_FAILED",
    "COMPLETION_CONTRACT_FAILED",
    "FINALIZATION_RECORD_CONFLICT",
    "READY_FOR_REVIEW",
]


def _now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _record_path(task_dir):
    return os.path.join(task_dir, "30-executor-finalization.json")


def _atomic_write(path, text):
    dir_name = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=dir_name, prefix=".finalization.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _load(task_dir):
    path = _record_path(task_dir)
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def _save(task_dir, data):
    data["updated_at"] = _now_iso()
    _atomic_write(_record_path(task_dir), json.dumps(data, indent=2, sort_keys=True) + "\n")


def sha256_file(path):
    if not path or not os.path.isfile(path):
        return ""
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()


def sha256_text(text):
    h = hashlib.sha256()
    h.update(text.encode("utf-8"))
    return "sha256:" + h.hexdigest()


# --- record lifecycle -------------------------------------------------------

def cmd_init(argv):
    """init <task_dir> <task_id> <iteration> <mode>
    Creates 30-executor-finalization.json if absent; otherwise updates
    iteration/mode/task_id in place (idempotent — never resets phase results).
    """
    task_dir, task_id, iteration, mode = argv[0], argv[1], int(argv[2]), argv[3]
    data = _load(task_dir)
    if data is None:
        data = {
            "schema_version": SCHEMA_VERSION,
            "pipeline_version": PIPELINE_VERSION,
            "task_id": task_id,
            "iteration": iteration,
            "mode": mode,
            "provider_execution": None,
            "phases": {},
            "outcome": None,
            "background": {
                "pending_required_jobs": 0,
                "surviving_children_terminated": 0,
                "text_wait_warning": False,
                "supervision": "unknown",
            },
            "provenance": {"log": None, "tests": None, "summary": None},
        }
    else:
        if data.get("pipeline_version") != PIPELINE_VERSION:
            sys.stderr.write(
                f"unsupported finalization pipeline_version {data.get('pipeline_version')} "
                f"(this engine supports {PIPELINE_VERSION}); refusing to reinterpret with current semantics\n"
            )
            return 1
        data["iteration"] = iteration
        data["mode"] = mode
        data["task_id"] = task_id
    _save(task_dir, data)
    print("ok")
    return 0


def cmd_get(argv):
    """get <task_dir> <dotted.field>
    Prints the value at a dotted field path (e.g. phases.executor_verification.result),
    or nothing if absent/record missing."""
    task_dir, field = argv[0], argv[1]
    data = _load(task_dir)
    if data is None:
        return 0
    cur = data
    for part in field.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return 0
        cur = cur[part]
    if cur is None:
        return 0
    if isinstance(cur, (dict, list)):
        print(json.dumps(cur))
    elif isinstance(cur, bool):
        print("true" if cur else "false")
    else:
        print(cur)
    return 0


# --- provider terminal result (section 11.1) --------------------------------

def cmd_record_provider_execution(argv):
    """record-provider-execution <task_dir> <iteration> <invocation_id>
        <prompt_file> <exit_code> <process_group_terminated(true|false)>
    Atomically records the durable provider terminal result BEFORE any
    finalization phase runs (section 11.1) and sets the
    executor_provider_execution phase result.
    """
    task_dir, iteration, invocation_id, prompt_file, exit_code, pg_terminated = (
        argv[0], int(argv[1]), argv[2], argv[3], int(argv[4]), argv[5] == "true"
    )
    data = _load(task_dir) or {}
    data.setdefault("phases", {})
    data["provider_execution"] = {
        "iteration": iteration,
        "invocation_id": invocation_id,
        "prompt_digest": sha256_file(prompt_file),
        "exit_code": exit_code,
        "completed_at": _now_iso(),
        "process_group_terminated": pg_terminated,
    }
    data["phases"]["executor_provider_execution"] = {
        "result": "passed" if exit_code == 0 else "failed",
    }
    _save(task_dir, data)
    print("ok")
    return 0


def cmd_resume_decision(argv):
    """resume-decision <task_dir> <iteration> <prompt_file>
    Prints exactly one of (section 11.2/11.3):
      rerun:no-terminal-result | rerun:prompt-changed | rerun:previous-failure
      finalization-only
    """
    task_dir, iteration, prompt_file = argv[0], int(argv[1]), argv[2]
    data = _load(task_dir)
    if not data or not data.get("provider_execution"):
        print("rerun:no-terminal-result")
        return 0
    pe = data["provider_execution"]
    current_digest = sha256_file(prompt_file)
    if pe.get("iteration") != iteration or pe.get("prompt_digest") != current_digest:
        print("rerun:prompt-changed")
        return 0
    if pe.get("exit_code") != 0:
        print("rerun:previous-failure")
        return 0
    print("finalization-only")
    return 0


# --- phase results (section 10.2) -------------------------------------------

def cmd_set_phase(argv):
    """set-phase <task_dir> <phase> <result> [reason] [extra_json]
    MERGES into the phase's existing entry (never replaces it wholesale) —
    a phase's fields are often written by more than one call (e.g.
    record-verification-digests then set-phase for executor_verification),
    and a full replacement would silently drop earlier fields.
    """
    task_dir, phase, result = argv[0], argv[1], argv[2]
    reason = argv[3] if len(argv) > 3 and argv[3] else None
    extra = json.loads(argv[4]) if len(argv) > 4 and argv[4] else {}
    data = _load(task_dir) or {}
    phases = data.setdefault("phases", {})
    entry = dict(phases.get(phase) or {})
    entry.update(extra)
    entry["result"] = result
    if reason:
        entry["reason"] = reason
    elif "reason" in entry and not reason and len(argv) > 3:
        # An explicit empty reason argument clears a stale reason from a
        # prior failed attempt (e.g. a retry that now passes).
        entry.pop("reason", None)
    phases[phase] = entry
    _save(task_dir, data)
    print("ok")
    return 0


def cmd_get_phase_result(argv):
    """get-phase-result <task_dir> <phase> — prints result or "pending"."""
    task_dir, phase = argv[0], argv[1]
    data = _load(task_dir) or {}
    print(data.get("phases", {}).get(phase, {}).get("result", "pending"))
    return 0


def cmd_set_outcome(argv):
    """set-outcome <task_dir> <outcome>"""
    task_dir, outcome = argv[0], argv[1]
    if outcome not in FINALIZATION_OUTCOMES:
        sys.stderr.write(f"unknown finalization_outcome: {outcome}\n")
        return 1
    data = _load(task_dir) or {}
    data["outcome"] = outcome
    _save(task_dir, data)
    print("ok")
    return 0


def cmd_set_background(argv):
    """set-background <task_dir> <pending_required_jobs> <surviving_terminated> <text_wait_warning> <supervision>"""
    task_dir, pending, terminated, warning, supervision = argv[0], int(argv[1]), int(argv[2]), argv[3] == "true", argv[4]
    data = _load(task_dir) or {}
    data["background"] = {
        "pending_required_jobs": pending,
        "surviving_children_terminated": terminated,
        "text_wait_warning": warning,
        "supervision": supervision,
    }
    _save(task_dir, data)
    print("ok")
    return 0


def cmd_set_provenance(argv):
    """set-provenance <task_dir> <log> <tests> <summary>"""
    task_dir, log, tests, summary = argv[0], argv[1] or None, argv[2] or None, argv[3] or None
    data = _load(task_dir) or {}
    prov = data.get("provenance") or {}
    if log:
        prov["log"] = log
    if tests:
        prov["tests"] = tests
    if summary:
        prov["summary"] = summary
    data["provenance"] = prov
    _save(task_dir, data)
    print("ok")
    return 0


# --- verification reuse digests (section 14.2 / 27) -------------------------

def cmd_record_verification_digests(argv):
    """record-verification-digests <task_dir> <effective_config_digest> <diff_digest> <level>"""
    task_dir, cfg_digest, diff_digest, level = argv[0], argv[1], argv[2], argv[3]
    data = _load(task_dir) or {}
    phases = data.setdefault("phases", {})
    entry = phases.setdefault("executor_verification", {})
    entry["effective_config_digest"] = cfg_digest
    entry["diff_digest"] = diff_digest
    entry["level"] = level
    data["phases"] = phases
    _save(task_dir, data)
    print("ok")
    return 0


def cmd_verification_fresh(argv):
    """verification-fresh <task_dir> <effective_config_digest> <diff_digest> <level>
    Prints "true" iff a prior recorded executor_verification result exists and
    ALL THREE digests match (section 14.2) — the caller may reuse it.
    """
    task_dir, cfg_digest, diff_digest, level = argv[0], argv[1], argv[2], argv[3]
    data = _load(task_dir) or {}
    entry = data.get("phases", {}).get("executor_verification") or {}
    if entry.get("result") != "passed" and entry.get("result") != "skipped":
        print("false")
        return 0
    fresh = (
        entry.get("effective_config_digest") == cfg_digest
        and entry.get("diff_digest") == diff_digest
        and entry.get("level") == level
    )
    print("true" if fresh else "false")
    return 0


# --- degraded-legacy guard (section 26) -------------------------------------

def cmd_degraded_check(argv):
    """degraded-check <mode> <required_verification(true|false)> <required_ui(true|false)>
    Prints "ok" or "refused: <message>" (section 26 — degraded-legacy must
    never silently permit a task with required verification/UI to bypass
    engine-owned finalization).
    """
    mode, required_verification, required_ui = argv[0], argv[1] == "true", argv[2] == "true"
    if mode != "degraded-legacy":
        print("ok")
        return 0
    if required_verification or required_ui:
        print(
            "refused: refusing degraded-legacy finalization: task has required "
            "verification/UI that must be engine-finalized"
        )
        return 0
    print("ok")
    return 0


# --- digests -----------------------------------------------------------------

def cmd_digest_file(argv):
    """digest-file <path> — prints sha256:<hex> or nothing if unreadable."""
    d = sha256_file(argv[0])
    if d:
        print(d)
    return 0


def cmd_tree_fingerprint(argv):
    """tree-fingerprint <dir> — a portable (path, size, mtime) fingerprint of
    every file under <dir>, for the sandboxed-finalizer post-call diff check
    (section 17.3): "no repository or task path changed during the finalizer
    call". Prints a single sha256 hex digest; empty dir -> a stable constant.
    """
    root = argv[0]
    entries = []
    if os.path.isdir(root):
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in filenames:
                full = os.path.join(dirpath, name)
                try:
                    st = os.stat(full)
                except OSError:
                    continue
                rel = os.path.relpath(full, root)
                entries.append(f"{rel}:{st.st_size}:{st.st_mtime_ns}")
    entries.sort()
    h = hashlib.sha256()
    h.update("\n".join(entries).encode("utf-8"))
    print(h.hexdigest())
    return 0


# --- engine-generated 03-executor-log.md (section 12) ------------------------

def _read_text(path, limit=20000):
    if not path or not os.path.isfile(path):
        return ""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read(limit)
    except Exception:
        return ""


def _count_lines(path):
    if not path or not os.path.isfile(path):
        return 0
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return sum(1 for _ in fh)
    except Exception:
        return 0


def _count_jsonl(path):
    if not path or not os.path.isfile(path):
        return 0
    n = 0
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.strip():
                    n += 1
    except Exception:
        pass
    return n


ENGINE_FACTS_HEADING = "## Engine-Observed Facts"


def render_engine_facts_block(exit_code, changed_files_path, timing_events_path, verification_note):
    lines = [ENGINE_FACTS_HEADING]
    lines.append(f"- Provider exit status: {exit_code if exit_code is not None else 'unavailable'}")
    if changed_files_path and os.path.isfile(changed_files_path):
        lines.append(f"- Changed files (from 05-changed-files.txt): {_count_lines(changed_files_path)}")
    else:
        lines.append("- Changed files: unavailable (05-changed-files.txt not present)")
    if timing_events_path and os.path.isfile(timing_events_path):
        lines.append(f"- Tool operations observed (from 21-command-timing-events.jsonl): {_count_jsonl(timing_events_path)}")
    else:
        lines.append("- Tool operations observed: unavailable (21-command-timing-events.jsonl not present)")
    lines.append(f"- Verification: {verification_note}")
    return "\n".join(lines) + "\n"


def cmd_generate_log(argv):
    """generate-log <task_dir> <exit_code_or_empty> <final_stdout_file>
        <changed_files_file> <timing_events_file> <verification_note>
    Generates 03-executor-log.md from observed durable sources ONLY when it
    is missing or empty (section 12.1/12.3): a non-empty Executor-written log
    is preserved, with the Engine-Observed Facts zone appended if absent.
    """
    task_dir = argv[0]
    exit_code = argv[1] if argv[1] != "" else None
    final_stdout_file = argv[2]
    changed_files_file = argv[3]
    timing_events_file = argv[4]
    verification_note = argv[5] if len(argv) > 5 else "see 07-tests.txt"

    log_path = os.path.join(task_dir, "03-executor-log.md")
    existing = _read_text(log_path) if os.path.isfile(log_path) else ""

    facts = render_engine_facts_block(exit_code, changed_files_file, timing_events_file, verification_note)

    if existing.strip():
        if ENGINE_FACTS_HEADING not in existing:
            with open(log_path, "a", encoding="utf-8") as fh:
                fh.write("\n\n" + facts)
        print("preserved")
        return 0

    ai_text = _read_text(final_stdout_file, limit=4000).strip()
    parts = [facts, ""]
    parts.append("## Reported by the AI (unverified)")
    if ai_text:
        quoted = "\n".join("> " + line for line in ai_text.splitlines()[-40:])
        parts.append(quoted)
    else:
        parts.append("> (no captured provider stdout available)")
    parts.append("")
    parts.append("## Unavailable")
    unavailable = []
    if not (final_stdout_file and os.path.isfile(final_stdout_file)):
        unavailable.append("provider stdout capture")
    if not (changed_files_file and os.path.isfile(changed_files_file)):
        unavailable.append("changed-file evidence (05-changed-files.txt)")
    if not unavailable:
        unavailable.append("(none — all sources listed above were inspected)")
    for item in unavailable:
        parts.append(f"- {item}")

    _atomic_write(log_path, "\n".join(parts) + "\n")
    print("generated")
    return 0


# --- engine-generated 07-tests.txt (section 16) ------------------------------

def _load_json(path):
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def render_tests_txt(verification_summary, ui_summary, plan):
    lines = []
    if verification_summary is None:
        lines.append("Engine-owned multi-service verification: NOT_REQUIRED (no spec 0026 policy configured, or nothing selected for this round).")
    else:
        overall = verification_summary.get("overall_status", "UNKNOWN")
        lines.append(f"Engine-owned verification overall status: {overall}")
        if overall == "PASSED" and (verification_summary.get("level") == "full" or (plan or {}).get("level") == "full"):
            lines.append("Full standalone suite: observed PASSED at level=full.")
        for result in verification_summary.get("results", []) or []:
            identity = f"{result.get('service')}.{result.get('check')}"
            status = result.get("status", "UNKNOWN")
            reused = result.get("reused", False)
            duration = result.get("duration_seconds")
            lines.append(
                f"- {identity}: {status}"
                f"{' (reused)' if reused else ''}"
                f"{f' [{duration}s]' if duration is not None else ''}"
                f" cwd={result.get('cwd', '?')}"
            )
            evidence = result.get("evidence_path")
            if evidence:
                lines.append(f"    evidence: {evidence}")
    lines.append("")
    if ui_summary is None:
        lines.append("UI runtime verification: not applicable to this round (no UI-impact detected, or disabled).")
    else:
        lines.append(f"UI runtime verification overall status: {ui_summary.get('overall', 'UNKNOWN')}")
        for sr in ui_summary.get("scenarios", []) or []:
            lines.append(f"- scenario {sr.get('name', '?')}: {sr.get('status', 'UNKNOWN')}")
    lines.append("")
    lines.append("Pre-existing-failure classification: evidence-only (no base-commit checkout performed — spec 0029 section 16.3).")
    return "\n".join(lines) + "\n"


def cmd_generate_tests(argv):
    """generate-tests <task_dir> <verification_summary_path_or_empty>
        <ui_summary_path_or_empty> <plan_path_or_empty>
    """
    task_dir = argv[0]
    verification_summary = _load_json(argv[1]) if argv[1] else None
    ui_summary = _load_json(argv[2]) if argv[2] else None
    plan = _load_json(argv[3]) if len(argv) > 3 and argv[3] else None
    text = render_tests_txt(verification_summary, ui_summary, plan)
    _atomic_write(os.path.join(task_dir, "07-tests.txt"), text)
    print("generated")
    return 0


# --- summary structural validation (section 17, 35.1) -----------------------

def cmd_validate_summary(argv):
    """validate-summary <path> <bundle_manifest_present(true|false)>
    Prints "valid" or "invalid: <reason>". <path> may be the real
    08-executor-summary.md OR a sandboxed finalizer candidate file — this
    command never assumes a task_dir layout, only a single markdown path.
    """
    path, bundle_present = argv[0], argv[1] == "true"
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        print("invalid: 08-executor-summary.md is missing or empty")
        return 0
    text = _read_text(path, limit=200000)
    missing = []
    for section in REQUIRED_SUMMARY_SECTIONS:
        if section == "Input Coverage" and not bundle_present:
            continue
        if not re.search(rf"^#+\s*{re.escape(section)}\b", text, re.IGNORECASE | re.MULTILINE):
            missing.append(section)
    if missing:
        print(f"invalid: missing required section(s): {', '.join(missing)}")
        return 0
    print("valid")
    return 0


# --- operator visibility card (section 29) -----------------------------------

def cmd_render_card(argv):
    """render-card <task_dir> — prints the provider-vs-executor-completion
    operator card. Driven entirely by 30-executor-finalization.json, so it
    can never contradict the completion gate (section 29)."""
    task_dir = argv[0]
    data = _load(task_dir)
    if data is None:
        print("Finalization: not recorded (task created before spec 0029, or before its first executor round)")
        return 0

    phases = data.get("phases", {})

    def line(label, phase, extra=""):
        entry = phases.get(phase, {})
        result = entry.get("result", "pending")
        reason = entry.get("reason", "")
        detail = extra
        if result == "failed" and reason:
            detail = f"failed: {reason}"
        elif not detail:
            detail = result
        print(f"{label:<24} {detail}")

    pe = data.get("provider_execution") or {}
    exit_code = pe.get("exit_code")
    print(f"{'Provider execution:':<24} {'complete' if exit_code is not None else 'not recorded'}" + (f" (exit {exit_code})" if exit_code is not None else ""))
    line("Evidence capture:", "executor_evidence_capture")
    ver = phases.get("executor_verification", {})
    ver_detail = ver.get("result", "pending")
    if ver.get("overall_status"):
        ver_detail = f"{ver.get('result')} ({ver.get('overall_status')}{' · UI ' + ver.get('ui_status') if ver.get('ui_status') else ''})"
    print(f"{'Verification:':<24} {ver_detail}")
    line("Summary finalization:", "executor_summary_finalization")
    gate = phases.get("executor_completion_validation", {})
    gate_detail = gate.get("result", "pending")
    if gate.get("result") == "failed" and gate.get("reason"):
        gate_detail = f"failed: {gate.get('reason')}"
    print(f"{'Completion gate:':<24} {gate_detail}")
    outcome = data.get("outcome") or "(pending)"
    print(f"{'Finalization outcome:':<24} {outcome}")
    mode = data.get("mode", "enabled")
    print(f"{'Mode:':<24} {'enabled' if mode == 'enabled' else 'DEGRADED (degraded-legacy mode)'}")
    stop_reason = gate.get("reason") if gate.get("result") == "failed" else "—"
    print(f"{'Stop reason:':<24} {stop_reason or '—'}")
    safe_next = "—" if outcome == "READY_FOR_REVIEW" else f"specrelay resume {data.get('task_id', '<task>')}"
    print(f"{'Safe next command:':<24} {safe_next}")
    return 0


def main(argv):
    if not argv:
        sys.stderr.write("Usage: finalization_lib.py <subcommand> ...\n")
        return 2
    cmd, rest = argv[0], argv[1:]
    dispatch = {
        "init": cmd_init,
        "get": cmd_get,
        "record-provider-execution": cmd_record_provider_execution,
        "resume-decision": cmd_resume_decision,
        "set-phase": cmd_set_phase,
        "get-phase-result": cmd_get_phase_result,
        "set-outcome": cmd_set_outcome,
        "set-background": cmd_set_background,
        "set-provenance": cmd_set_provenance,
        "record-verification-digests": cmd_record_verification_digests,
        "verification-fresh": cmd_verification_fresh,
        "degraded-check": cmd_degraded_check,
        "digest-file": cmd_digest_file,
        "tree-fingerprint": cmd_tree_fingerprint,
        "generate-log": cmd_generate_log,
        "generate-tests": cmd_generate_tests,
        "validate-summary": cmd_validate_summary,
        "render-card": cmd_render_card,
    }
    fn = dispatch.get(cmd)
    if fn is None:
        sys.stderr.write(f"Unknown finalization_lib command: {cmd}\n")
        return 2
    try:
        return fn(rest)
    except IndexError:
        sys.stderr.write(f"finalization_lib.py {cmd}: missing argument(s)\n")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
