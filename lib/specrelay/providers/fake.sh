#!/usr/bin/env bash
# providers/fake.sh — deterministic executor/reviewer provider for tests
# (spec section 60). Never invokes a real CLI. Behavior per round is driven
# by an optional PLAN FILE (one line per round, 1-indexed), so a test can
# script exact multi-round scenarios (accept-first-round, changes-then-
# accept, executor failure, reviewer failure, max-rounds) without any real
# provider call.
#
# Plan line format: comma-separated key=value pairs.
#   executor plan keys:  exit=<0|N> (default 0), outputs=<0|1> (default 1),
#                        touch=<0|1> (default 1, appends a line to the
#                        configured fixture file to produce a real diff)
#   reviewer plan keys:  exit=<0|N> (default 0),
#                        decision=<accept|request_changes|missing_marker> (default
#                        accept). missing_marker (spec 0019, "Smart Marker
#                        Recovery" fixtures): writes review artifacts as usual
#                        (per marker_artifacts below) but returns rc=2 with NO
#                        decision on stdout, exactly like a real reviewer whose
#                        output was complete except for the final DECISION line.
#                        marker_artifacts=<accept|request_changes|missing|empty|conflicting>
#                        (default accept when decision=missing_marker): controls
#                        which artifacts exist for the marker-recovery fixture:
#                          accept          -> 09+10 written (recovery should succeed as ACCEPT)
#                          request_changes -> 09+11 written (recovery should succeed as REQUEST_CHANGES)
#                          missing         -> no artifacts at all (recovery forbidden)
#                          empty           -> 09 written but empty (recovery forbidden)
#                          conflicting     -> 09 contains BOTH Decision: ACCEPT and
#                                             Decision: REQUEST_CHANGES (recovery forbidden)
#   verify_ops=<op1+op2+...>  (spec 0019, verification ledger fixtures): each
#                        '+'-separated token is a classified operation name
#                        (test_focused|test_targeted|test_full|smoke|doctor|
#                        version); each is recorded as a deterministic
#                        verification event for this round's role, letting
#                        tests exercise ledger counting/duplicate-detection
#                        without any real captured provider transcript.
#
# Env hooks:
#   SPECRELAY_FAKE_EXECUTOR_PLAN   path to the executor plan file (optional)
#   SPECRELAY_FAKE_REVIEWER_PLAN   path to the reviewer plan file (optional)
#   SPECRELAY_FAKE_IMPL_FILE       fixture file the executor "implements"
#                                  into (default: <project-root>/specrelay-fake-impl.txt)
#   SPECRELAY_FAKE_REVIEWER_SELF_TRANSITION
#                                  when =1, the reviewer ALSO enacts its own
#                                  decision transition (accept/request-changes)
#                                  before emitting its DECISION line — exactly
#                                  what a real reviewer agent running under
#                                  `claude --print --dangerously-skip-permissions`
#                                  can do, since accept/request-changes are NOT
#                                  runner-owned. This deterministically
#                                  reproduces the spec 0004 duplicate-transition
#                                  bug (a runner that then transitions AGAIN out
#                                  of an already-final state).
# Missing a plan file (or a line past its end) falls back to the defaults
# above, so a scenario that only cares about round 1 need not specify later
# rounds explicitly.
#
# Capability simulation (spec 0014) — lets tests exercise every provider
# model-discovery/validation level without any live Claude/Codex call:
#   SPECRELAY_FAKE_CAPABILITY_LEVEL    exact | aliases | structural (default) | none
#   SPECRELAY_FAKE_DECLARED_ALIASES    space-separated alias entries; each entry
#                                      is either "<alias>" (resolves to itself)
#                                      or "<alias>=<resolved-model-id>" (resolves
#                                      to that exact id). Empty => no aliases.
#   SPECRELAY_FAKE_DISCOVERED_MODELS   space-separated exact model ids (used
#                                      when level=exact)
#   SPECRELAY_FAKE_DISCOVERY_FAIL      when =1, model discovery FAILS (level
#                                      exact reports a discovery failure instead
#                                      of a list — distinct from an invalid
#                                      user model configuration)
# The default level is "structural" so existing tests that configure arbitrary
# raw model strings keep working unchanged (structural-only providers never
# falsely reject a valid-looking raw id).

# --- provider capability (spec 0014) -----------------------------------------

specrelay::provider::fake::capability_level() {
  case "${SPECRELAY_FAKE_CAPABILITY_LEVEL:-structural}" in
    exact|aliases|structural|none) printf '%s\n' "${SPECRELAY_FAKE_CAPABILITY_LEVEL:-structural}" ;;
    *) printf 'structural\n' ;;
  esac
}

specrelay::provider::fake::capability_supports_explicit_model() {
  [ "$(specrelay::provider::fake::capability_level)" != "none" ]
}

specrelay::provider::fake::capability_declared_aliases() {
  local entry
  for entry in ${SPECRELAY_FAKE_DECLARED_ALIASES:-}; do
    printf '%s\n' "${entry%%=*}"
  done
}

# specrelay::provider::fake::capability_resolve_alias <alias>
# Deterministic: "<alias>" resolves to itself (a provider-recognized alias
# argument); "<alias>=<id>" resolves to that exact model id. Unknown -> fail.
specrelay::provider::fake::capability_resolve_alias() {
  local alias="$1" entry
  for entry in ${SPECRELAY_FAKE_DECLARED_ALIASES:-}; do
    if [ "${entry%%=*}" = "$alias" ]; then
      case "$entry" in
        *=*) printf '%s\n' "${entry#*=}" ;;
        *) printf '%s\n' "$alias" ;;
      esac
      return 0
    fi
  done
  return 1
}

# Prints: "available <source>" | "unavailable" | "failed <reason>".
specrelay::provider::fake::capability_discovery_status() {
  if [ "$(specrelay::provider::fake::capability_level)" != "exact" ]; then
    printf 'unavailable\n'
    return 0
  fi
  if [ "${SPECRELAY_FAKE_DISCOVERY_FAIL:-0}" = "1" ]; then
    printf 'failed simulated discovery failure (SPECRELAY_FAKE_DISCOVERY_FAIL=1)\n'
    return 0
  fi
  printf 'available fake capability fixture (SPECRELAY_FAKE_DISCOVERED_MODELS)\n'
}

# One discovered model id per line; non-zero when discovery is unavailable or
# failed (a discovery FAILURE is never reported as an invalid user model).
specrelay::provider::fake::capability_discovered_models() {
  [ "$(specrelay::provider::fake::capability_level)" = "exact" ] || return 1
  [ "${SPECRELAY_FAKE_DISCOVERY_FAIL:-0}" != "1" ] || return 1
  local m
  for m in ${SPECRELAY_FAKE_DISCOVERED_MODELS:-}; do
    printf '%s\n' "$m"
  done
}

# specrelay::provider::fake::_record_invocation <role> <provider> <model> <agent> <round> <evidence-file> [context]
# Writes deterministic INVOCATION EVIDENCE for the fake provider (spec 0012,
# "Fake Provider Support"): the resolved role, provider, model, and agent for
# this call, plus (spec 0015) the normalized context handoff the invocation
# received. This is what lets a test PROVE model/agent/context forwarding —
# that each configured value actually reached the correct role — without any
# live Claude or Codex call. The file is truncated each round, so it always
# reflects the MOST RECENT invocation of that role (e.g. the post-config-change
# round after a resume). When SPECRELAY_FAKE_INVOCATION_LOG is set, a
# one-line-per-invocation record is ALSO appended there, so a single test can
# watch both roles' history.
specrelay::provider::fake::_record_invocation() {
  local role="$1" provider="$2" model="$3" agent="$4" round="$5" evidence_file="$6" context="${7:-none}"
  {
    printf 'role=%s\n' "$role"
    printf 'provider=%s\n' "$provider"
    printf 'model=%s\n' "$model"
    printf 'agent=%s\n' "$agent"
    printf 'round=%s\n' "$round"
    printf 'context=%s\n' "$context"
  } > "$evidence_file"
  if [ -n "${SPECRELAY_FAKE_INVOCATION_LOG:-}" ]; then
    printf 'role=%s provider=%s model=%s agent=%s round=%s context=%s\n' \
      "$role" "$provider" "$model" "$agent" "$round" "$context" >> "$SPECRELAY_FAKE_INVOCATION_LOG"
  fi
}

# specrelay::provider::fake::_record_verify_ops <plan-line> <role> <task-dir>
# Deterministic verification-ledger fixture (spec 0019): records one
# verification event per '+'-separated `verify_ops=` token, so tests can
# exercise classification/duplicate-detection without a real provider
# transcript. A no-op when the plan line has no verify_ops field.
specrelay::provider::fake::_record_verify_ops() {
  local plan_line="$1" role="$2" task_dir="$3" ops token op reason
  ops="$(specrelay::provider::fake::_field "$plan_line" verify_ops "")"
  [ -n "$ops" ] || return 0
  local IFS='+'
  for token in $ops; do
    [ -n "$token" ] || continue
    op="${token%%@*}"
    reason=""
    case "$token" in *@*) reason="${token#*@}" ;; esac
    specrelay::verification::record_op "$task_dir" "$role" "$op" "fake:$op" "1" "0" "$reason" "fake-plan"
  done
}

specrelay::provider::fake::_plan_line() {
  local file="$1" round="$2"
  [ -n "$file" ] && [ -f "$file" ] || { printf ''; return 0; }
  sed -n "${round}p" "$file"
}

specrelay::provider::fake::_field() {
  local line="$1" key="$2" default="$3" val
  val="$(printf '%s' "$line" | tr ',' '\n' | sed -n "s/^${key}=//p" | head -n1)"
  printf '%s' "${val:-$default}"
}

# Emitted THROUGH specrelay::provider::run_streamed so the fake provider
# exercises the exact same live-streaming + capture path as a real provider
# (spec 0003): its lines appear live on the terminal (prefixed) and are
# captured raw to 12-executor-stdout.txt. Deliberately small and deterministic
# so the test suite stays non-flaky and non-noisy.
specrelay::provider::fake::_executor_emit() {
  local round="$1" prompt_file="$2" exit_code="$3" outputs="$4" touch_flag="$5" model="${6:-provider-default}" agent="${7:-none}" wait_text="${8:-}"
  echo "[fake-executor] round $round"
  echo "[fake-executor] prompt file: $prompt_file"
  echo "[fake-executor] plan: exit=$exit_code outputs=$outputs touch=$touch_flag"
  # Make the resolved model/agent visible in the streamed/captured output too,
  # so operator logs and 12-executor-stdout.txt carry the forwarding evidence.
  echo "[fake-executor] resolved: provider=fake model=$model agent=$agent"
  # Deterministic completion-gate fixture (spec 0021, "Unresolved Waiting
  # Detection"): a test-supplied final-output phrase, written into the SAME
  # captured file (12-executor-stdout.txt) SpecRelay's real completion gate
  # inspects, so no real provider call is needed to exercise it.
  [ -n "$wait_text" ] && echo "$wait_text"
}

specrelay::provider::fake::executor_run() {
  local root="$1" task_dir="$2" round="$3" prompt_file="$4" label="${5:-executor:fake}" model="${6:-provider-default}" agent="${7:-none}" context="${8:-none}"
  local plan_line exit_code outputs touch_flag impl_file missing_artifact wait_text

  # Record the forwarded role/provider/model/agent/context as durable
  # invocation evidence (spec 0012, spec 0015). Written before the streamed
  # emit so it exists even if a later step in this function fails.
  specrelay::provider::fake::_record_invocation executor fake "$model" "$agent" "$round" \
    "$task_dir/fake-executor-invocation.txt" "$context"

  plan_line="$(specrelay::provider::fake::_plan_line "${SPECRELAY_FAKE_EXECUTOR_PLAN:-}" "$round")"
  exit_code="$(specrelay::provider::fake::_field "$plan_line" exit "0")"
  outputs="$(specrelay::provider::fake::_field "$plan_line" outputs "1")"
  touch_flag="$(specrelay::provider::fake::_field "$plan_line" touch "1")"
  # missing_artifact=<filename> (spec 0021 fixtures): after normally writing
  # 03/07/08 (when outputs=1), removes exactly the named file so tests can
  # exercise the completion gate's per-file missing-artifact checks without
  # a real provider call.
  missing_artifact="$(specrelay::provider::fake::_field "$plan_line" missing_artifact "")"
  # wait_text=<phrase> (spec 0021 fixtures): an explicit unresolved-waiting
  # phrase written into 12-executor-stdout.txt (the completion gate's final
  # extracted output).
  wait_text="$(specrelay::provider::fake::_field "$plan_line" wait_text "")"
  specrelay::provider::fake::_record_verify_ops "$plan_line" executor "$task_dir"

  # Test-only: widen the race window for concurrency tests (see
  # concurrent_test.sh) by sleeping AFTER the claim has already happened
  # (this function only runs once claim-task has already claimed the task).
  if [ -n "${SPECRELAY_FAKE_EXECUTOR_SLEEP:-}" ]; then
    sleep "$SPECRELAY_FAKE_EXECUTOR_SLEEP"
  fi

  specrelay::provider::run_streamed "$label" \
    "$task_dir/12-executor-stdout.txt" "$task_dir/13-executor-stderr.txt" "$root" -- \
    specrelay::provider::fake::_executor_emit "$round" "$prompt_file" "$exit_code" "$outputs" "$touch_flag" "$model" "$agent" "$wait_text"

  if [ "$touch_flag" = "1" ]; then
    impl_file="${SPECRELAY_FAKE_IMPL_FILE:-$root/specrelay-fake-impl.txt}"
    echo "round $round change" >> "$impl_file"
  fi

  if [ "$outputs" = "1" ]; then
    printf 'Fake executor log for round %s.\n' "$round" > "$task_dir/03-executor-log.md"
    printf 'Fake test output for round %s: 1 example, 0 failures.\n' "$round" > "$task_dir/07-tests.txt"
    printf 'Fake executor summary for round %s.\n## Input Coverage\nFake coverage: all bundle inputs treated as inspected and used (deterministic test fixture).\n' "$round" > "$task_dir/08-executor-summary.md"
    [ -n "$missing_artifact" ] && rm -f "$task_dir/$missing_artifact"
  fi

  return "$exit_code"
}

specrelay::provider::fake::_reviewer_emit() {
  local round="$1" prompt_file="$2" exit_code="$3" decision="$4" model="${5:-provider-default}" agent="${6:-none}" wait_text="${7:-}"
  echo "[fake-reviewer] round $round"
  echo "[fake-reviewer] prompt file: $prompt_file"
  echo "[fake-reviewer] plan: exit=$exit_code decision=$decision"
  echo "[fake-reviewer] resolved: provider=fake model=$model agent=$agent"
  # Deterministic completion-gate fixture (spec 0021): a test-supplied final-
  # output phrase, written into 15-reviewer-stdout.txt — the SAME file the
  # real completion gate inspects for unresolved waiting.
  [ -n "$wait_text" ] && echo "$wait_text"
}

specrelay::provider::fake::reviewer_run() {
  local root="$1" task_dir="$2" round="$3" prompt_file="$4" label="${5:-reviewer:fake}" model="${6:-provider-default}" agent="${7:-none}" context="${8:-none}"
  local plan_line exit_code decision wait_text

  # Durable invocation evidence for the reviewer role (spec 0012, spec 0015).
  # Recorded before anything else so a failed reviewer round still leaves proof
  # of which model/agent/context was forwarded to it.
  specrelay::provider::fake::_record_invocation reviewer fake "$model" "$agent" "$round" \
    "$task_dir/fake-reviewer-invocation.txt" "$context"

  plan_line="$(specrelay::provider::fake::_plan_line "${SPECRELAY_FAKE_REVIEWER_PLAN:-}" "$round")"
  exit_code="$(specrelay::provider::fake::_field "$plan_line" exit "0")"
  decision="$(specrelay::provider::fake::_field "$plan_line" decision "accept")"
  wait_text="$(specrelay::provider::fake::_field "$plan_line" wait_text "")"
  specrelay::provider::fake::_record_verify_ops "$plan_line" reviewer "$task_dir"

  # Stream the reviewer's log lines live to fd 2 and capture them raw to
  # 15-reviewer-stdout.txt. The ACCEPT/REQUEST_CHANGES decision below is
  # printed to this function's OWN stdout (fd 1), which the lifecycle reads via
  # command substitution — kept strictly separate from the streamed copy.
  specrelay::provider::run_streamed "$label" \
    "$task_dir/15-reviewer-stdout.txt" "$task_dir/16-reviewer-stderr.txt" "$root" -- \
    specrelay::provider::fake::_reviewer_emit "$round" "$prompt_file" "$exit_code" "$decision" "$model" "$agent" "$wait_text"

  if [ "$exit_code" != "0" ]; then
    return "$exit_code"
  fi

  # missing_marker (spec 0019, "Smart Marker Recovery" fixtures): writes the
  # artifact combination named by marker_artifacts=, then returns rc=2 with
  # NO decision on stdout — exactly the "provider succeeded but the marker
  # itself is missing" signal specrelay::provider::claude::reviewer_run
  # produces for a real reviewer (see providers/provider.sh's contract).
  if [ "$decision" = "missing_marker" ]; then
    specrelay::provider::fake::_write_marker_fixture "$task_dir" "$round" \
      "$(specrelay::provider::fake::_field "$plan_line" marker_artifacts "accept")"
    return 2
  fi

  printf 'Fake reviewer notes for round %s.\n## Input Coverage\nFake coverage: Executor input-coverage claim treated as truthful (deterministic test fixture).\n' "$round" > "$task_dir/09-consultant-review.md"
  if [ "$decision" = "accept" ]; then
    printf 'Fake business summary for round %s.\n' "$round" > "$task_dir/10-business-summary.md"
    # Simulate a real reviewer agent that enacts its own decision (accept is
    # NOT runner-owned, so an agent with CLI access can run it directly). Its
    # output goes to the reviewer stdout capture, never to the decision stream
    # the runner reads from this function's own stdout (spec 0004 repro).
    if [ "${SPECRELAY_FAKE_REVIEWER_SELF_TRANSITION:-}" = "1" ]; then
      specrelay::transitions::accept "$root" "$(basename "$task_dir")" fake \
        >> "$task_dir/15-reviewer-stdout.txt" 2>&1 || true
    fi
    echo "ACCEPT"
  else
    printf 'Fake next executor prompt for round %s.\n' "$round" > "$task_dir/11-next-executor-prompt.md"
    if [ "${SPECRELAY_FAKE_REVIEWER_SELF_TRANSITION:-}" = "1" ]; then
      specrelay::transitions::request_changes "$root" "$(basename "$task_dir")" \
        "fake reviewer self-enacted request-changes" fake \
        >> "$task_dir/15-reviewer-stdout.txt" 2>&1 || true
    fi
    echo "REQUEST_CHANGES"
  fi
  return 0
}

# specrelay::provider::fake::_write_marker_fixture <task-dir> <round> <kind>
# Writes the artifact combination deterministic marker-recovery tests need
# (spec 0019, "Smart Marker Recovery" / "When Smart Recovery Is Forbidden").
# Never writes the DECISION marker itself — that is exactly what is missing.
specrelay::provider::fake::_write_marker_fixture() {
  local task_dir="$1" round="$2" kind="$3"
  case "$kind" in
    accept)
      printf 'Fake reviewer notes for round %s.\nDecision: ACCEPT\n' "$round" > "$task_dir/09-consultant-review.md"
      printf 'Fake business summary for round %s.\n' "$round" > "$task_dir/10-business-summary.md"
      rm -f "$task_dir/11-next-executor-prompt.md"
      ;;
    request_changes)
      printf 'Fake reviewer notes for round %s.\nDecision: REQUEST_CHANGES\n' "$round" > "$task_dir/09-consultant-review.md"
      printf 'Fake next executor prompt for round %s.\n' "$round" > "$task_dir/11-next-executor-prompt.md"
      rm -f "$task_dir/10-business-summary.md"
      ;;
    missing)
      rm -f "$task_dir/09-consultant-review.md" "$task_dir/10-business-summary.md" "$task_dir/11-next-executor-prompt.md"
      ;;
    empty)
      : > "$task_dir/09-consultant-review.md"
      rm -f "$task_dir/10-business-summary.md" "$task_dir/11-next-executor-prompt.md"
      ;;
    conflicting)
      printf 'Fake reviewer notes for round %s.\nDecision: ACCEPT\nDecision: REQUEST_CHANGES\n' "$round" > "$task_dir/09-consultant-review.md"
      printf 'Fake business summary for round %s.\n' "$round" > "$task_dir/10-business-summary.md"
      ;;
    *)
      : # unrecognized kind: leave artifacts as-is (test fixture error, not a runtime case)
      ;;
  esac
}

# specrelay::provider::fake::reviewer_recover_marker <root> <task-dir>
#     <narrow-prompt-file> <label> <model> <agent>
# Deterministic corrective-attempt fixture (spec 0019, "Corrective Attempt
# Limits"). Reads the structured `Decision: ...` field FROM
# 09-consultant-review.md itself (mirroring the real recovery contract:
# marker_recovery.sh only invokes this at all once
# specrelay::marker_recovery::eligible has already confirmed a clear,
# consistent decision) — this fixture never invents a decision the caller
# did not already establish, and it writes no repository files, exactly like
# the real corrective attempt.
specrelay::provider::fake::reviewer_recover_marker() {
  local root="$1" task_dir="$2" prompt_file="$3" label="${4:-reviewer-recovery:fake}" model="${5:-provider-default}" agent="${6:-none}"
  local review="$task_dir/09-consultant-review.md" field

  {
    echo "[fake-reviewer-recovery] prompt file: $prompt_file"
    echo "[fake-reviewer-recovery] resolved: provider=fake model=$model agent=$agent"
  } >> "$task_dir/21-marker-recovery-stdout.txt" 2>&1 || true

  if [ -n "${SPECRELAY_FAKE_MARKER_RECOVERY_FAIL:-}" ]; then
    specrelay::out::err "$label: simulated marker-recovery failure (SPECRELAY_FAKE_MARKER_RECOVERY_FAIL=1)"
    return 1
  fi

  field="$(grep -E '^Decision:[[:space:]]*(ACCEPT|REQUEST_CHANGES)[[:space:]]*$' "$review" 2>/dev/null | tail -n1 | sed -E 's/^Decision:[[:space:]]*//; s/[[:space:]]*$//')"
  case "$field" in
    ACCEPT|REQUEST_CHANGES)
      printf '%s\n' "$field"
      return 0
      ;;
    *)
      specrelay::out::err "$label: no structured decision found to recover"
      return 1
      ;;
  esac
}

# --- fake coordinator provider (spec 0025, section 42) ----------------------
#
# Deterministic coordinator fixture: no real AI provider call, ever. Each
# named SCENARIO produces exactly the raw candidate output (valid JSON,
# malformed JSON, or an out-of-policy decision) a test needs to exercise the
# structured validator in coordinator.sh / coordinator_lib.py without any
# live Claude call. `timeout` simulates a provider invocation that never
# returns cleanly (non-zero exit, no output) so the caller's fallback policy
# can be exercised.

specrelay::provider::fake::_coordinator_decision_json() {
  local task_id="$1" invocation_point="$2" decision="$3" reason_code="$4" target_role="$5" human_required="$6"
  python3 -c '
import json, sys
d = {
    "schema_version": 1,
    "task_id": sys.argv[1],
    "invocation_point": sys.argv[2],
    "decision": sys.argv[3],
    "reason_code": sys.argv[4],
    "reason": "deterministic fake coordinator fixture for scenario testing.",
    "target_role": sys.argv[5],
    "target_files": [],
    "requested_verification": [],
    "constraints": {"allow_source_changes": False, "allow_test_execution": False, "allow_state_transition": False},
    "human_decision_required": sys.argv[6] == "1",
    "confidence": "high",
}
print(json.dumps(d))
' "$task_id" "$invocation_point" "$decision" "$reason_code" "$target_role" "$human_required"
}

# specrelay::provider::fake::coordinator_run <task-dir> <prompt-file>
#     <raw-output-file> <label> <model> <agent> <task-id> <invocation-point>
#     <scenario>
# Writes the scenario's raw candidate text to <raw-output-file> and returns
# the fake provider's (never a real CLI's) exit code. `scenario` values
# (spec section 42): valid_start_execution | valid_repair_artifacts |
# valid_send_to_review | valid_request_human | invalid_json |
# forbidden_action | wrong_task_id | path_traversal | timeout.
specrelay::provider::fake::coordinator_run() {
  local task_dir="$1" prompt_file="$2" raw_output_file="$3" label="${4:-coordinator:fake}" \
    model="${5:-provider-default}" agent="${6:-none}" task_id="$7" invocation_point="$8" scenario="${9:-valid_request_human}"

  {
    echo "[fake-coordinator] prompt file: $prompt_file"
    echo "[fake-coordinator] resolved: provider=fake model=$model agent=$agent scenario=$scenario"
  } >> "$task_dir/25-coordinator-stderr.txt" 2>&1 || true

  case "$scenario" in
    valid_start_execution)
      specrelay::provider::fake::_coordinator_decision_json "$task_id" "$invocation_point" \
        "START_EXECUTION" "implementation_required" "executor" "0" > "$raw_output_file"
      ;;
    valid_repair_artifacts)
      specrelay::provider::fake::_coordinator_decision_json "$task_id" "$invocation_point" \
        "REPAIR_ARTIFACTS" "missing_required_section" "executor" "0" > "$raw_output_file"
      ;;
    valid_send_to_review)
      specrelay::provider::fake::_coordinator_decision_json "$task_id" "$invocation_point" \
        "SEND_TO_REVIEW" "verification_failed" "reviewer" "0" > "$raw_output_file"
      ;;
    valid_request_human)
      specrelay::provider::fake::_coordinator_decision_json "$task_id" "$invocation_point" \
        "REQUEST_HUMAN_DECISION" "ambiguous_requirement" "none" "1" > "$raw_output_file"
      ;;
    invalid_json)
      printf 'this is not json at all {' > "$raw_output_file"
      ;;
    forbidden_action)
      # A syntactically valid decision value that is NOT in the engine's
      # allowed_next_actions for this invocation point (the caller's fixture
      # sets up an invocation point where this decision is out of policy).
      specrelay::provider::fake::_coordinator_decision_json "$task_id" "$invocation_point" \
        "SEND_TO_REVIEW" "implementation_required" "reviewer" "0" > "$raw_output_file"
      ;;
    wrong_task_id)
      specrelay::provider::fake::_coordinator_decision_json "wrong-task-id-does-not-exist" "$invocation_point" \
        "REQUEST_HUMAN_DECISION" "ambiguous_requirement" "none" "1" > "$raw_output_file"
      ;;
    path_traversal)
      python3 -c '
import json, sys
d = {
    "schema_version": 1, "task_id": sys.argv[1], "invocation_point": sys.argv[2],
    "decision": "REPAIR_ARTIFACTS", "reason_code": "missing_required_section",
    "reason": "path traversal fixture.", "target_role": "executor",
    "target_files": ["../../../etc/passwd"], "requested_verification": [],
    "constraints": {"allow_source_changes": False, "allow_test_execution": False, "allow_state_transition": False},
    "human_decision_required": False, "confidence": "high",
}
print(json.dumps(d))
' "$task_id" "$invocation_point" > "$raw_output_file"
      ;;
    timeout)
      : > "$raw_output_file"
      return 124
      ;;
    *)
      specrelay::out::err "$label: unknown fake coordinator scenario '$scenario'"
      return 1
      ;;
  esac
  return 0
}
