"""coordinator_lib.py — AI Coordinator decision contract (spec 0025, "AI
Coordinator and Decision Contract").

This module is the deterministic core of the coordinator contract: it never
calls a provider and never mutates canonical task state. It only:

  * computes the engine-owned allowed-next-actions/forbidden-next-actions set
    for a given invocation point + situation (section 15, "Allowed-next-
    actions contract");
  * validates a coordinator's structured decision output strictly against the
    closed vocabulary, the engine-computed allowlist, and the security rules
    in section 38 ("Security rules") — an invalid decision is NEVER treated
    as valid, and validation never trusts free-form text alone (section 12);
  * renders the durable decision-history record, current-state artifact, and
    human-decision packet (sections 23, 24, 26).

Every accessor here mirrors state_lib.py's CLI conventions (small argv
subcommands, atomic writes, plain-text stdout) so coordinator.sh's bash
wrapper can shell out exactly like state.sh/timeline.sh do for their own
python modules.
"""

import json
import os
import sys
import tempfile

SCHEMA_VERSION = 1

DECISIONS = [
    "START_EXECUTION",
    "REPAIR_ARTIFACTS",
    "RUN_TARGETED_VERIFICATION",
    "SEND_TO_REVIEW",
    "RETURN_TO_EXECUTOR",
    "BLOCK_TASK",
    "REQUEST_HUMAN_DECISION",
    "NO_ACTION",
]

REASON_CODES = [
    "implementation_required",
    "artifact_missing",
    "artifact_empty",
    "missing_required_section",
    "invalid_artifact_structure",
    "verification_missing",
    "verification_failed",
    "review_changes_requested",
    "working_tree_conflict",
    "recovery_needed",
    "ambiguous_requirement",
    "external_dependency_unavailable",
    "unsafe_to_continue",
    "human_policy_decision",
    "no_safe_action",
]

CONFIDENCES = ["low", "medium", "high"]

TARGET_ROLES = ["none", "executor", "reviewer"]

# The SAME classified verification-operation vocabulary verification.sh /
# timeline.sh already use (spec 0019) — the coordinator may only recommend
# from this closed set, never an arbitrary command string.
VERIFICATION_CATEGORIES = [
    "test_focused",
    "test_targeted",
    "test_full",
    "smoke",
    "doctor",
    "version",
]

INVOCATION_POINTS = [
    "before_executor",
    "executor_completion_failed",
    "executor_completed",
    "reviewer_completed",
    "changes_requested",
    "recovery_requested",
    "human_handoff_preparation",
]

REQUIRED_FIELDS = [
    "schema_version",
    "task_id",
    "invocation_point",
    "decision",
    "reason_code",
    "reason",
    "target_role",
    "target_files",
    "requested_verification",
    "constraints",
    "human_decision_required",
    "confidence",
]

CONSTRAINT_KEYS = ["allow_source_changes", "allow_test_execution", "allow_state_transition"]

# Deterministic engine-side mapping (spec section 31, "Deterministic state-
# transition mapping" — "implemented as deterministic logic, not prompt text
# alone"). Describes what the engine WOULD do for a decision; coordinator.sh's
# dispatch function is the code that actually enacts the safe subset of this
# (BLOCK_TASK / REQUEST_HUMAN_DECISION / NO_ACTION) through existing
# transition functions only — see coordinator.sh's dispatch header comment for
# exactly which decisions are enacted immediately vs. recorded as a deferred
# recommendation in this initial scope (spec section 8: "does not yet
# implement unrestricted automatic artifact repair or a fully autonomous
# multi-round workflow").
ENGINE_ACTION_DESCRIPTIONS = {
    "START_EXECUTION": "Invoke the Executor only if task state and guards allow it",
    "REPAIR_ARTIFACTS": "Record recommendation; route to supported repair/recovery policy or human decision",
    "RUN_TARGETED_VERIFICATION": "Run only configured allowlisted verification if supported",
    "SEND_TO_REVIEW": "Proceed only if completion gates already pass",
    "RETURN_TO_EXECUTOR": "Requeue only through a valid transition and valid feedback artifact",
    "BLOCK_TASK": "Block only from an allowed state with recorded reason",
    "REQUEST_HUMAN_DECISION": "Stop automation and create a human decision packet",
    "NO_ACTION": "Stop safely and report no safe step",
}

_SECRET_KEY_MARKERS = ("token", "secret", "password", "credential", "authorization", "cookie", "apikey", "api_key")


def _now_iso():
    import datetime

    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _atomic_write(path, text):
    dir_name = os.path.dirname(path) or "."
    os.makedirs(dir_name, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dir_name, prefix=".coordinator.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(text)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def redact_snapshot(value):
    """Recursively strips any key that LOOKS like a secret (spec section 25,
    "Secrets must not be copied into coordinator artifacts"; section 38,
    "redact secrets from snapshots"). Defense in depth: the snapshot builder
    only ever includes metadata/booleans/counts/paths/strings by construction,
    but this still runs on every snapshot before it is written to disk."""
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            lowered = str(k).lower()
            if any(marker in lowered for marker in _SECRET_KEY_MARKERS):
                out[k] = "REDACTED"
            else:
                out[k] = redact_snapshot(v)
        return out
    if isinstance(value, list):
        return [redact_snapshot(v) for v in value]
    return value


# --- allowed-next-actions computation (spec section 15) ---------------------

def compute_allowed_actions(invocation_point, situation):
    """Deterministic engine-side computation of the closed set the
    coordinator may choose from at this invocation point (section 15). The
    coordinator never infers this from documentation — the engine always
    provides it explicitly (section 14)."""
    situation = situation or {}
    allowed = []

    if invocation_point == "before_executor":
        allowed = ["START_EXECUTION", "REQUEST_HUMAN_DECISION", "BLOCK_TASK", "NO_ACTION"]

    elif invocation_point == "executor_completion_failed":
        failure_kind = situation.get("failure_kind", "ambiguous")
        if failure_kind == "artifact_only":
            allowed = ["REPAIR_ARTIFACTS", "REQUEST_HUMAN_DECISION", "BLOCK_TASK"]
        elif failure_kind == "verification_failure":
            allowed = ["RETURN_TO_EXECUTOR", "REQUEST_HUMAN_DECISION", "BLOCK_TASK"]
        elif failure_kind == "unsafe":
            allowed = ["BLOCK_TASK", "REQUEST_HUMAN_DECISION"]
        else:
            # Unknown/ambiguous failure kind: the narrowest possible set —
            # never a repair or requeue the engine cannot justify (spec
            # section 22, "Narrowest-safe-action principle").
            allowed = ["REQUEST_HUMAN_DECISION", "BLOCK_TASK"]

    elif invocation_point == "executor_completed":
        if situation.get("completion_gate_passed") is True:
            allowed = ["SEND_TO_REVIEW", "REQUEST_HUMAN_DECISION"]
        else:
            allowed = ["REPAIR_ARTIFACTS", "RETURN_TO_EXECUTOR", "REQUEST_HUMAN_DECISION", "BLOCK_TASK"]

    elif invocation_point == "reviewer_completed":
        reviewer_decision = situation.get("reviewer_decision")
        if reviewer_decision == "ACCEPT":
            # The coordinator can never reinterpret ACCEPT (section 30) and
            # can never decide human acceptance (section 17) — human final
            # review remains mandatory, so the only safe choices here are to
            # hand off to the human or report nothing further to do.
            allowed = ["REQUEST_HUMAN_DECISION", "NO_ACTION"]
        elif reviewer_decision == "REQUEST_CHANGES":
            allowed = ["RETURN_TO_EXECUTOR", "REQUEST_HUMAN_DECISION"]
        else:
            allowed = ["REQUEST_HUMAN_DECISION"]

    elif invocation_point == "changes_requested":
        allowed = ["RETURN_TO_EXECUTOR", "REQUEST_HUMAN_DECISION", "BLOCK_TASK"]

    elif invocation_point == "recovery_requested":
        allowed = ["START_EXECUTION", "REQUEST_HUMAN_DECISION", "BLOCK_TASK"]

    elif invocation_point == "human_handoff_preparation":
        allowed = ["REQUEST_HUMAN_DECISION"]

    else:
        # Unknown invocation point: the engine grants nothing but the safe
        # fallback (never silently permissive).
        allowed = ["REQUEST_HUMAN_DECISION"]

    forbidden = [d for d in DECISIONS if d not in allowed]
    return {"allowed_next_actions": allowed, "forbidden_next_actions": forbidden}


# --- path safety (spec section 38, "reject path traversal") -----------------

def _path_is_safe(rel_path):
    if not isinstance(rel_path, str) or not rel_path:
        return False
    if rel_path.startswith("/") or rel_path.startswith("~"):
        return False
    # Reject Windows-style absolute/drive paths and raw backslashes too, so a
    # traversal attempt is not just POSIX-blind.
    if "\\" in rel_path:
        return False
    if ":" in rel_path.split("/")[0]:
        return False
    parts = rel_path.split("/")
    if any(p == ".." for p in parts):
        return False
    if any(p == "" for p in parts[1:-1]):
        # embedded empty segment from "//"; harmless but reject for strictness
        return False
    return True


# --- structured decision validation (spec sections 12-16, 38-39) -----------

def validate_decision(raw_text, expected_task_id, expected_invocation_point, allowed_actions):
    """Returns (ok, errors, normalized_decision_or_None).

    Never partially trusts a decision: any single violation makes the WHOLE
    decision invalid (decision is None), so an invalid coordinator response
    can never mutate task state (section 16, "An invalid coordinator response
    must not mutate task state.")."""
    errors = []

    try:
        data = json.loads(raw_text)
    except Exception as exc:  # noqa: BLE001
        return False, [f"invalid JSON: {exc}"], None

    if not isinstance(data, dict):
        return False, [f"decision must be a JSON object (got {type(data).__name__})"], None

    unknown = [k for k in data.keys() if k not in REQUIRED_FIELDS]
    if unknown:
        errors.append(f"unknown top-level field(s): {', '.join(sorted(unknown))}")

    missing = [f for f in REQUIRED_FIELDS if f not in data]
    if missing:
        errors.append(f"missing required field(s): {', '.join(missing)}")
        # Field-by-field checks below assume presence; bail out early with
        # what we already know rather than raising on a missing key.
        return False, errors, None

    if data.get("schema_version") != SCHEMA_VERSION:
        errors.append(f"unsupported schema_version: {data.get('schema_version')!r} (expected {SCHEMA_VERSION})")

    if data.get("task_id") != expected_task_id:
        errors.append(f"task_id mismatch: decision task_id={data.get('task_id')!r}, expected={expected_task_id!r}")

    if data.get("invocation_point") != expected_invocation_point:
        errors.append(
            f"invocation_point mismatch: decision invocation_point={data.get('invocation_point')!r}, "
            f"expected={expected_invocation_point!r}"
        )
    elif data.get("invocation_point") not in INVOCATION_POINTS:
        errors.append(f"unknown invocation_point: {data.get('invocation_point')!r}")

    decision = data.get("decision")
    if decision not in DECISIONS:
        errors.append(f"unknown decision value: {decision!r} (must be one of {DECISIONS})")
    elif decision not in (allowed_actions or []):
        errors.append(
            f"decision '{decision}' is not in engine-computed allowed_next_actions {allowed_actions!r}"
        )

    reason_code = data.get("reason_code")
    if reason_code not in REASON_CODES:
        errors.append(f"unknown reason_code: {reason_code!r}")

    reason = data.get("reason")
    if not isinstance(reason, str) or not reason.strip():
        errors.append("reason must be a non-empty string")
    elif len(reason) > 4000:
        errors.append("reason exceeds the maximum length (4000 characters) for a concise operational explanation")

    target_role = data.get("target_role")
    if target_role not in TARGET_ROLES:
        errors.append(f"invalid target_role: {target_role!r} (must be one of {TARGET_ROLES})")

    target_files = data.get("target_files")
    if not isinstance(target_files, list) or not all(isinstance(f, str) for f in target_files):
        errors.append("target_files must be a list of strings")
    else:
        unsafe = [f for f in target_files if not _path_is_safe(f)]
        if unsafe:
            errors.append(f"target_files contains unsafe path(s): {unsafe!r}")

    requested_verification = data.get("requested_verification")
    if not isinstance(requested_verification, list) or not all(isinstance(v, str) for v in requested_verification):
        errors.append("requested_verification must be a list of strings")
    else:
        unknown_ops = [v for v in requested_verification if v not in VERIFICATION_CATEGORIES]
        if unknown_ops:
            errors.append(f"requested_verification contains unknown categor(y/ies): {unknown_ops!r}")

    constraints = data.get("constraints")
    if not isinstance(constraints, dict):
        errors.append("constraints must be a JSON object")
    else:
        unknown_constraints = [k for k in constraints.keys() if k not in CONSTRAINT_KEYS]
        if unknown_constraints:
            errors.append(f"constraints has unknown key(s): {unknown_constraints!r}")
        missing_constraints = [k for k in CONSTRAINT_KEYS if k not in constraints]
        if missing_constraints:
            errors.append(f"constraints is missing key(s): {missing_constraints!r}")
        for k in CONSTRAINT_KEYS:
            if k in constraints:
                v = constraints[k]
                if v is not True and v is not False:
                    errors.append(f"constraints.{k} must be a boolean (got {v!r})")
                elif v is True:
                    # The engine never grants ANY of these to the coordinator
                    # (spec section 18, read-only adapter). A decision that
                    # claims otherwise requests more permission than the
                    # engine granted (section 16) and must be rejected.
                    errors.append(f"constraints.{k}=true requests permission the engine never grants")

    human_decision_required = data.get("human_decision_required")
    if human_decision_required is not True and human_decision_required is not False:
        errors.append("human_decision_required must be a boolean")
    elif decision in DECISIONS:
        expected_flag = decision == "REQUEST_HUMAN_DECISION"
        if human_decision_required != expected_flag:
            errors.append(
                f"human_decision_required={human_decision_required!r} is inconsistent with decision={decision!r}"
            )

    confidence = data.get("confidence")
    if confidence not in CONFIDENCES:
        errors.append(f"invalid confidence: {confidence!r} (must be one of {CONFIDENCES})")

    if errors:
        return False, errors, None
    return True, [], data


# --- CLI ----------------------------------------------------------------

def cmd_allowed_actions(argv):
    invocation_point = argv[0]
    situation_raw = sys.stdin.read().strip()
    situation = json.loads(situation_raw) if situation_raw else {}
    result = compute_allowed_actions(invocation_point, situation)
    print(json.dumps(result, sort_keys=True))
    return 0


def cmd_validate(argv):
    raw_output_file, task_id, invocation_point, allowed_actions_json = argv[0], argv[1], argv[2], argv[3]
    with open(raw_output_file, "r", encoding="utf-8") as fh:
        raw_text = fh.read()
    parsed = json.loads(allowed_actions_json) if allowed_actions_json else []
    # Accept either the plain list of allowed decisions, or the full
    # {"allowed_next_actions": [...], "forbidden_next_actions": [...]} object
    # coordinator.sh's allowed_actions() call actually produces — this is the
    # single place that distinction is normalized, so every caller can pass
    # either shape without silently validating against the wrong thing.
    if isinstance(parsed, dict):
        allowed_actions = parsed.get("allowed_next_actions", [])
    else:
        allowed_actions = parsed
    ok, errors, decision = validate_decision(raw_text, task_id, invocation_point, allowed_actions)
    print(json.dumps({"valid": ok, "errors": errors, "decision": decision}, sort_keys=True))
    return 0 if ok else 1


def cmd_record(argv):
    jsonl_path, record_json = argv[0], argv[1]
    record = json.loads(record_json)
    if not isinstance(record, dict):
        sys.stderr.write("record must be a JSON object\n")
        return 3
    os.makedirs(os.path.dirname(jsonl_path) or ".", exist_ok=True)
    with open(jsonl_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, sort_keys=True))
        fh.write("\n")
    return 0


def cmd_state_get(argv):
    path, field = argv[0], argv[1]
    if not os.path.isfile(path):
        print("")
        return 0
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    value = data.get(field)
    if value is None:
        print("")
    elif isinstance(value, (dict, list)):
        print(json.dumps(value))
    else:
        print(value)
    return 0


def cmd_state_write(argv):
    path, fields_json = argv[0], argv[1]
    fields = json.loads(fields_json)
    if not isinstance(fields, dict):
        sys.stderr.write("state-write fields must be a JSON object\n")
        return 3
    existing = {}
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                existing = json.load(fh)
            if not isinstance(existing, dict):
                existing = {}
        except Exception:  # noqa: BLE001
            existing = {}
    existing.update(fields)
    _atomic_write(path, json.dumps(existing, indent=2, sort_keys=True) + "\n")
    return 0


def cmd_engine_action(argv):
    decision = argv[0]
    print(ENGINE_ACTION_DESCRIPTIONS.get(decision, "unknown decision"))
    return 0


def cmd_redact_snapshot(argv):
    raw = sys.stdin.read().strip()
    data = json.loads(raw) if raw else {}
    print(json.dumps(redact_snapshot(data), indent=2, sort_keys=True))
    return 0


def cmd_human_packet(argv):
    """Renders the human-decision packet (spec section 26). Context JSON on
    stdin with keys: task_id, state, invocation_point, what_happened,
    why_stopped, recommendation_decision, recommendation_reason,
    human_choices (list of {choice, effect}), evidence_paths (list),
    source_changes_exist (bool), tests_passed (true|false|null),
    retry_count (int), cost_summary (string, optional)."""
    out_path = argv[0]
    raw = sys.stdin.read().strip()
    ctx = json.loads(raw) if raw else {}

    lines = []
    lines.append("# Human Decision Required")
    lines.append("")
    lines.append(f"- Task: {ctx.get('task_id', '(unknown)')}")
    lines.append(f"- Current state: {ctx.get('state', '(unknown)')}")
    lines.append(f"- Invocation point: {ctx.get('invocation_point', '(unknown)')}")
    lines.append(f"- Generated at: {_now_iso()}")
    lines.append("")
    lines.append("## What happened")
    lines.append("")
    lines.append(ctx.get("what_happened") or "(not recorded)")
    lines.append("")
    lines.append("## Why automatic progress stopped")
    lines.append("")
    lines.append(ctx.get("why_stopped") or "(not recorded)")
    lines.append("")
    lines.append("## Coordinator recommendation")
    lines.append("")
    lines.append(f"- Decision: {ctx.get('recommendation_decision', '(none)')}")
    lines.append(f"- Reason: {ctx.get('recommendation_reason', '(none)')}")
    lines.append("")
    lines.append("## Available human choices")
    lines.append("")
    choices = ctx.get("human_choices") or []
    if choices:
        lines.append("| Choice | Effect |")
        lines.append("|---|---|")
        for c in choices:
            lines.append(f"| {c.get('choice', '')} | {c.get('effect', '')} |")
    else:
        lines.append("(no choices recorded)")
    lines.append("")
    lines.append("## Relevant evidence paths")
    lines.append("")
    evidence_paths = ctx.get("evidence_paths") or []
    if evidence_paths:
        for p in evidence_paths:
            lines.append(f"- {p}")
    else:
        lines.append("(none recorded)")
    lines.append("")
    lines.append("## Status summary")
    lines.append("")
    lines.append(f"- Source changes already exist: {ctx.get('source_changes_exist', '(unknown)')}")
    lines.append(f"- Tests passed: {ctx.get('tests_passed', '(unknown)')}")
    lines.append(f"- Retry count: {ctx.get('retry_count', '(unknown)')}")
    if ctx.get("cost_summary"):
        lines.append(f"- Cost/time summary: {ctx.get('cost_summary')}")
    lines.append("")

    _atomic_write(out_path, "\n".join(lines) + "\n")
    return 0


def main(argv):
    if not argv:
        sys.stderr.write(
            "Usage: coordinator_lib.py <allowed-actions|validate|record|state-get|state-write|"
            "engine-action|redact-snapshot|human-packet> ...\n"
        )
        return 2
    cmd, rest = argv[0], argv[1:]
    dispatch = {
        "allowed-actions": cmd_allowed_actions,
        "validate": cmd_validate,
        "record": cmd_record,
        "state-get": cmd_state_get,
        "state-write": cmd_state_write,
        "engine-action": cmd_engine_action,
        "redact-snapshot": cmd_redact_snapshot,
        "human-packet": cmd_human_packet,
    }
    fn = dispatch.get(cmd)
    if fn is None:
        sys.stderr.write(f"Unknown coordinator_lib command: {cmd}\n")
        return 2
    try:
        return fn(rest)
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(f"coordinator_lib.py {cmd}: {exc}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
