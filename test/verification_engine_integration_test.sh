#!/usr/bin/env bash
# verification_engine_integration_test.sh — Coordinator/RUN_TARGETED_VERIFICATION
# dispatch, task show/report integration, historical-task honesty, effective-
# configuration-drift refusal, and duplicate-execution detection for the
# verification-policy ENGINE (spec 0026). Selection/config parsing is covered
# by verification_policy_engine_test.sh; execution mechanics (dependencies,
# timeouts, evidence isolation) by verification_multi_service_test.sh.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/config.sh
. "$SPECRELAY_ROOT/lib/specrelay/config.sh"
# shellcheck source=../lib/specrelay/state.sh
. "$SPECRELAY_ROOT/lib/specrelay/state.sh"
# shellcheck source=../lib/specrelay/task.sh
. "$SPECRELAY_ROOT/lib/specrelay/task.sh"
# shellcheck source=../lib/specrelay/timeline.sh
. "$SPECRELAY_ROOT/lib/specrelay/timeline.sh"
# shellcheck source=../lib/specrelay/verification.sh
. "$SPECRELAY_ROOT/lib/specrelay/verification.sh"
# shellcheck source=../lib/specrelay/verification_policy.sh
. "$SPECRELAY_ROOT/lib/specrelay/verification_policy.sh"
# shellcheck source=../lib/specrelay/verification_runner.sh
. "$SPECRELAY_ROOT/lib/specrelay/verification_runner.sh"
# shellcheck source=../lib/specrelay/coordinator.sh
. "$SPECRELAY_ROOT/lib/specrelay/coordinator.sh"

FIXTURE="$SPECRELAY_ROOT/test/fixtures/verification-fixture.sh"

specrelay_test::write_config() {
  local proj="$1" body="$2"
  mkdir -p "$proj/.specrelay"
  printf '%s\n' "$body" > "$proj/.specrelay/config.yml"
}

# =============================================================================
# 43.27: RUN_TARGETED_VERIFICATION maps only to configured check identities,
# resolved entirely by the deterministic engine (never AI-supplied text)
# =============================================================================
coord_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$coord_proj" "
version: 1
verification:
  placement:
    reviewer: targeted
  services:
    - name: backend
      checks:
        - name: unit
          command: \"$FIXTURE --exit 0\"
          required: true
          levels: [changed, full]
"
coord_task_dir="$coord_proj/.specrelay-runs/tasks/demo-task"
mkdir -p "$coord_task_dir"
coord_out="$(specrelay::coordinator::dispatch "$coord_proj" demo-task RUN_TARGETED_VERIFICATION "risk-based targeted check" 2>&1)"
specrelay_test::assert_contains "RUN_TARGETED_VERIFICATION is enacted (not merely deferred) for an engine-configured project" \
  "$coord_out" "enacted"
[ -f "$coord_task_dir/27-verification-summary.json" ]
specrelay_test::assert_true "the coordinator dispatch actually produced verification evidence" "$?"
summary_blob="$(cat "$coord_task_dir/27-verification-summary.json")"
specrelay_test::assert_contains "the executed checks came from configuration, not coordinator-supplied text" \
  "$summary_blob" "backend.unit"

# An absent-mode project defers exactly as before (spec 0025, section 8) —
# this dispatch case must never fabricate a run where no engine is configured.
absent_proj="$(specrelay_test::mktemp_project)"
absent_task_dir="$absent_proj/.specrelay-runs/tasks/demo-task"
mkdir -p "$absent_task_dir"
absent_out="$(specrelay::coordinator::dispatch "$absent_proj" demo-task RUN_TARGETED_VERIFICATION "no config" 2>&1)"
specrelay_test::assert_contains "RUN_TARGETED_VERIFICATION defers cleanly when no verification-policy engine is configured" \
  "$absent_out" "deferred"
[ ! -f "$absent_task_dir/27-verification-summary.json" ]
specrelay_test::assert_true "no evidence is fabricated when the engine is not configured" "$?"

# =============================================================================
# 43.29 / 43.30: task show/report include verification summaries; a
# historical (never-run) task reports "not recorded", never fabricated
# =============================================================================
historical_task_dir="$coord_proj/.specrelay-runs/tasks/historical-task"
mkdir -p "$historical_task_dir"
historical_out="$(specrelay::verification_policy::report "$historical_task_dir")"
specrelay_test::assert_eq "a historical task with no recorded evidence reports 'not recorded'" \
  "Verification policy: not recorded" "$historical_out"

report_out="$(specrelay::verification_policy::report "$coord_task_dir")"
specrelay_test::assert_contains "a task with recorded evidence reports its overall status" "$report_out" "Verification --"

report_json="$(specrelay::verification_policy::report_json "$coord_task_dir")"
specrelay_test::assert_contains "the JSON report includes the check identities" "$report_json" "backend.unit"

# =============================================================================
# Effective-configuration capture/drift (spec section 51): resume must not
# silently switch to a changed project verification policy for the SAME task.
# =============================================================================
drift_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$drift_proj" "
version: 1
verification:
  services:
    - name: backend
      checks:
        - name: unit
          command: \"$FIXTURE --exit 0\"
          required: true
          levels: [full]
"
drift_task="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-verify-drift.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$drift_task")
specrelay::verification_runner::run "$drift_proj" "$drift_task" drift-task 1 executor full '[]' '[]' >/dev/null 2>&1
first_rc=$?
specrelay_test::assert_eq "the first planning pass for a task succeeds and captures the effective config" "0" "$first_rc"
[ -f "$drift_task/verification/effective-config.json" ]
specrelay_test::assert_true "the effective-configuration snapshot is captured on first planning" "$?"

# Same config again: no drift, still succeeds.
specrelay::verification_runner::run "$drift_proj" "$drift_task" drift-task 1 executor full '[]' '[]' >/dev/null 2>&1
specrelay_test::assert_eq "re-planning with an UNCHANGED configuration does not refuse" "0" "$?"

# Now change the project's configuration and try again for the SAME task dir.
specrelay_test::write_config "$drift_proj" "
version: 1
verification:
  services:
    - name: backend
      checks:
        - name: unit
          command: \"$FIXTURE --exit 0\"
          required: true
          levels: [full]
        - name: lint
          command: \"$FIXTURE --exit 0\"
          required: true
          levels: [full]
"
drift_err="$(specrelay::verification_runner::run "$drift_proj" "$drift_task" drift-task 1 executor full '[]' '[]' 2>&1 >/dev/null)"
drift_rc=$?
specrelay_test::assert_eq "planning refuses when the captured task policy no longer matches the live project config" "1" "$drift_rc"
specrelay_test::assert_contains "the refusal names the configuration-drift reason (spec section 51)" "$drift_err" "changed since this task first captured it"

# =============================================================================
# Duplicate execution detection (spec section 39): the same check re-run for
# the same task/iteration/phase/config/tree is REPORTED, never silently
# claimed as fresh evidence.
# =============================================================================
dup_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$dup_proj" "
version: 1
verification:
  services:
    - name: backend
      checks:
        - name: unit
          command: \"$FIXTURE --exit 0\"
          required: true
          levels: [full]
"
dup_task="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-verify-duponly.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$dup_task")
specrelay::verification_runner::run "$dup_proj" "$dup_task" dup-task 1 executor full '[]' '[]' >/dev/null 2>&1
first_dup_summary="$(cat "$dup_task/27-verification-summary.json")"
specrelay_test::assert_contains "the first run is not marked as a duplicate" "$first_dup_summary" '"duplicate_of": null'

specrelay::verification_runner::run "$dup_proj" "$dup_task" dup-task 1 executor full '[]' '[]' >/dev/null 2>&1
second_dup_summary="$(cat "$dup_task/27-verification-summary.json")"
specrelay_test::assert_not_contains "an identical re-run for the same task/iteration/phase is detected as a duplicate" \
  "$second_dup_summary" '"duplicate_of": null'

specrelay_test::summary
exit $?
