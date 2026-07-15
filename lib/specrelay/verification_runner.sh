#!/usr/bin/env bash
# verification_runner.sh — execution entrypoint for the verification-policy
# ENGINE (spec 0026). This is the ONLY code path that shells out to a
# project-configured `command:` string — never AI-supplied text (spec
# section 37, "Security rules"). Planning/config/reporting live in
# verification_policy.sh; this file is deliberately small.

SPECRELAY_VERIFICATION_POLICY_LIB_PY="${SPECRELAY_VERIFICATION_POLICY_LIB_PY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/verification_policy_lib.py}"

specrelay::verification_runner::_available() {
  command -v python3 >/dev/null 2>&1 && [ -f "$SPECRELAY_VERIFICATION_POLICY_LIB_PY" ]
}

# specrelay::verification_runner::run <root> <task-dir> <task-id> <iteration>
#     <phase> <requested-level> <changed-paths-json> [<requested-checks-json>]
#     [--json]
# Plans (writing 26-verification-plan.json + verification/selection.json),
# THEN executes the selected checks with bounded, dependency-respecting
# parallelism, writing per-check evidence and
# 27-verification-summary.json / 28-verification-summary.md. Returns 0 only
# when the overall status is PASSED or NOT_REQUIRED (spec section 32) —
# non-zero for FAILED/BLOCKED, so callers (the Executor/Reviewer's own shell,
# the Coordinator dispatcher, `specrelay verification run`) see an honest
# exit code and never mistake a failed required check for success.
specrelay::verification_runner::run() {
  local root="$1" task_dir="$2" task_id="$3" iteration="$4" phase="$5" level="$6" changed_json="$7" requested_checks_json="${8:-[]}"
  shift 8 || true
  specrelay::verification_runner::_available || { specrelay::out::err "verification run: python3 or verification_policy_lib.py unavailable"; return 1; }

  local raw
  raw="$(specrelay::verification_policy::_raw_config "$root")"

  local prior_summary_json="null"
  if [ -f "$task_dir/27-verification-summary.json" ]; then
    prior_summary_json="$(cat "$task_dir/27-verification-summary.json")"
  fi

  RAW="$raw" ROOT="$root" TASKDIR="$task_dir" TASKID="$task_id" ITER="$iteration" \
  PHASE="$phase" LEVEL="$level" CHANGED="$changed_json" REQCHECKS="$requested_checks_json" \
  PRIOR="$prior_summary_json" python3 -c '
import json, os
level = os.environ["LEVEL"] or None
print(json.dumps({
    "raw_config": json.loads(os.environ["RAW"]),
    "root": os.environ["ROOT"],
    "task_dir": os.environ["TASKDIR"],
    "task_id": os.environ["TASKID"],
    "iteration": int(os.environ["ITER"] or "1"),
    "phase": os.environ["PHASE"] or None,
    "requested_level": level,
    "changed_paths": json.loads(os.environ["CHANGED"] or "[]"),
    "requested_checks": json.loads(os.environ["REQCHECKS"] or "[]"),
    "prior_summary": json.loads(os.environ["PRIOR"]),
}))
' | python3 "$SPECRELAY_VERIFICATION_POLICY_LIB_PY" execute "$@"
}

# specrelay::verification_runner::check_request <root> <phase>
#     <requested-level> <changed-paths-json> <requested-checks-json>
# Validates a role's (Executor/Reviewer/Coordinator) requested check
# identities against configured policy WITHOUT executing anything (spec
# section 23). Prints {"valid": true, "plan": {...}} or
# {"valid": false, "error": "..."} and returns a matching exit code.
specrelay::verification_runner::check_request() {
  local root="$1" phase="$2" level="$3" changed_json="$4" requested_checks_json="$5"
  specrelay::verification_runner::_available || { printf '{"valid": false, "error": "python3 or verification_policy_lib.py unavailable"}\n'; return 1; }
  local raw
  raw="$(specrelay::verification_policy::_raw_config "$root")"
  RAW="$raw" PHASE="$phase" LEVEL="$level" CHANGED="$changed_json" REQCHECKS="$requested_checks_json" python3 -c '
import json, os
level = os.environ["LEVEL"] or None
print(json.dumps({
    "raw_config": json.loads(os.environ["RAW"]),
    "phase": os.environ["PHASE"] or None,
    "requested_level": level,
    "changed_paths": json.loads(os.environ["CHANGED"] or "[]"),
    "requested_checks": json.loads(os.environ["REQCHECKS"] or "[]"),
}))
' | python3 "$SPECRELAY_VERIFICATION_POLICY_LIB_PY" check-request
}
