#!/usr/bin/env bash
# completion_gate_test.sh — Executor/Reviewer completion gate (spec 0021,
# "Agent Execution Efficiency and Completion Gate"). End-to-end via the
# deterministic 'fake' provider (never a real Claude/Codex call), mirroring
# workflow_fake_provider_test.sh's style. Proves:
#
#   * exit 0 + all required artifacts -> SUCCESS, submitted for review;
#   * exit 0 + a missing required Executor artifact (each of the three,
#     individually) -> INCOMPLETE, task remains EXECUTOR_RUNNING, no false
#     SUCCESS card;
#   * a real provider failure (non-zero exit) remains a provider failure,
#     distinct from a completion-gate failure;
#   * existing evidence files are preserved on a completion-gate failure;
#   * an explicit final "I will wait ..." statement -> INCOMPLETE for both
#     Executor and Reviewer when the policy is enabled;
#   * disabling unresolved_wait_is_failure never blocks completion;
#   * Reviewer ACCEPT/REQUEST_CHANGES with required artifacts still pass
#     through the gate unchanged (spec 0019 rules remain authoritative).

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

specrelay_test::run() {
  local proj="$1" spec="$2"
  shift 2
  (cd "$proj" && "$SPECRELAY_BIN" run "$spec" "$@")
}

# =============================================================================
# Scenario A — exit 0 + all artifacts present -> SUCCESS (regression: the
# completion gate must never block a genuinely complete round).
# =============================================================================
proj_a="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_a/docs/sdd/0001-gate-ok"
echo "# gate ok spec" > "$proj_a/docs/sdd/0001-gate-ok/spec.md"
# --verbose (spec 0022, "Summary-first terminal output"): the default run
# output is now a concise operator summary; the full agent-efficiency
# completion-gate detail this scenario checks is still fully captured, just
# only PRINTED with --verbose (see 'task efficiency'/'task report' for the
# always-available read-only equivalent).
out_a="$(specrelay_test::run "$proj_a" "docs/sdd/0001-gate-ok/spec.md" --verbose 2>&1)"
specrelay_test::assert_eq "A: run exits 0" "0" "$?"
specrelay_test::assert_contains "A: reaches READY_FOR_HUMAN_REVIEW" "$out_a" "READY_FOR_HUMAN_REVIEW"
specrelay_test::assert_contains "A: executor completion gate passed" "$out_a" $'Executor: passed'

# =============================================================================
# Scenario B — exit 0 with EACH required artifact missing, individually, is
# now REPAIRED by the engine-owned finalization pipeline (spec 0029, section
# 12/16/17, AC-03/AC-08) rather than left INCOMPLETE: this is the concrete
# fix for the exact "provider exited successfully but the round was never
# finished" failure class spec 0029 exists to close (spec 0029 section 32.1,
# tests A/B/H). The round now reaches READY_FOR_HUMAN_REVIEW with an
# engine-generated/finalizer-adopted artifact in place of the missing one.
# =============================================================================
for artifact in 03-executor-log.md 07-tests.txt 08-executor-summary.md; do
  proj_b="$(specrelay_test::mktemp_specrelay_project)"
  slug="gate-missing-${artifact%%.*}"
  mkdir -p "$proj_b/docs/sdd/0002-$slug"
  echo "# missing $artifact spec" > "$proj_b/docs/sdd/0002-$slug/spec.md"
  plan_dir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-gate-plan.XXXXXX")"
  SPECRELAY_TEST_TMP_DIRS+=("$plan_dir")
  printf 'missing_artifact=%s\n' "$artifact" > "$plan_dir/exec-plan.txt"

  out_b="$(SPECRELAY_FAKE_EXECUTOR_PLAN="$plan_dir/exec-plan.txt" \
    specrelay_test::run "$proj_b" "docs/sdd/0002-$slug/spec.md" 2>&1)"
  rc_b=$?
  specrelay_test::assert_eq "B ($artifact): run exits 0 (the engine repairs the missing artifact)" "0" "$rc_b"
  specrelay_test::assert_contains "B ($artifact): reaches READY_FOR_HUMAN_REVIEW" "$out_b" "READY_FOR_HUMAN_REVIEW"

  task_dir_b="$proj_b/.specrelay-runs/tasks/0002-$slug"
  specrelay_test::assert_true "B ($artifact): the repaired artifact is non-empty" \
    "$([ -s "$task_dir_b/$artifact" ] && echo 0 || echo 1)"

  # The OTHER two artifacts (still written by the fake provider) are preserved.
  for other in 03-executor-log.md 07-tests.txt 08-executor-summary.md; do
    [ "$other" = "$artifact" ] && continue
    specrelay_test::assert_true "B ($artifact): $other is preserved" \
      "$([ -s "$task_dir_b/$other" ] && echo 0 || echo 1)"
  done
done

# =============================================================================
# Scenario C — a real provider failure (non-zero exit) remains a provider
# failure, distinct from a completion-gate failure (no INCOMPLETE card).
# =============================================================================
proj_c="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_c/docs/sdd/0003-provider-fail"
echo "# provider fail spec" > "$proj_c/docs/sdd/0003-provider-fail/spec.md"
plan_dir_c="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-gate-plan.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$plan_dir_c")
printf 'exit=1\n' > "$plan_dir_c/exec-plan.txt"
out_c="$(SPECRELAY_FAKE_EXECUTOR_PLAN="$plan_dir_c/exec-plan.txt" \
  specrelay_test::run "$proj_c" "docs/sdd/0003-provider-fail/spec.md" 2>&1)"
specrelay_test::assert_contains "C: FAILED card for a real provider crash" "$out_c" "FAILED (exit 1)"
specrelay_test::assert_not_contains "C: never labeled INCOMPLETE (a provider crash is not a gate failure)" \
  "$out_c" "INCOMPLETE"

# =============================================================================
# Scenario D — explicit unresolved-waiting final output, but no engine-owned
# job is actually pending and no provider-spawned child survived: text alone
# is now advisory-only and does NOT block (spec 0029, section 19.2's own
# worked "test D" example, AC-10) — this INTENTIONALLY supersedes the pre-
# spec-0029 behavior of blocking on the text heuristic alone. The warning is
# still durably recorded (background.text_wait_warning in
# 30-executor-finalization.json).
# =============================================================================
proj_d="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_d/docs/sdd/0004-exec-wait"
echo "# exec wait spec" > "$proj_d/docs/sdd/0004-exec-wait/spec.md"
plan_dir_d="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-gate-plan.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$plan_dir_d")
printf 'wait_text=I will wait for the background task.\n' > "$plan_dir_d/exec-plan.txt"
out_d="$(SPECRELAY_FAKE_EXECUTOR_PLAN="$plan_dir_d/exec-plan.txt" \
  specrelay_test::run "$proj_d" "docs/sdd/0004-exec-wait/spec.md" 2>&1)"
specrelay_test::assert_eq "D: run exits 0 (text alone never blocks — spec 0029 section 19.2)" "0" "$?"
specrelay_test::assert_contains "D: reaches READY_FOR_HUMAN_REVIEW despite the wait text" "$out_d" "READY_FOR_HUMAN_REVIEW"
task_dir_d="$proj_d/.specrelay-runs/tasks/0004-exec-wait"
specrelay_test::assert_contains "D: the text-wait warning is durably recorded" \
  "$(cat "$task_dir_d/30-executor-finalization.json" 2>/dev/null)" '"text_wait_warning": true'

# =============================================================================
# Scenario E — disabling unresolved_wait_is_failure never blocks completion,
# even with the same wait_text final output.
# =============================================================================
proj_e="$(specrelay_test::mktemp_specrelay_project)"
cat >> "$proj_e/.specrelay/config.yml" <<'YAML'
execution_efficiency:
  executor:
    unresolved_wait_is_failure: false
YAML
mkdir -p "$proj_e/docs/sdd/0005-wait-disabled"
echo "# wait disabled spec" > "$proj_e/docs/sdd/0005-wait-disabled/spec.md"
(cd "$proj_e" && git add -A && git commit -q -m "disable unresolved wait policy")
plan_dir_e="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-gate-plan.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$plan_dir_e")
printf 'wait_text=I will wait for the background task.\n' > "$plan_dir_e/exec-plan.txt"
out_e="$(SPECRELAY_FAKE_EXECUTOR_PLAN="$plan_dir_e/exec-plan.txt" \
  specrelay_test::run "$proj_e" "docs/sdd/0005-wait-disabled/spec.md" 2>&1)"
specrelay_test::assert_eq "E: run exits 0 (disabled policy never blocks)" "0" "$?"
specrelay_test::assert_contains "E: reaches READY_FOR_HUMAN_REVIEW despite wait_text" "$out_e" "READY_FOR_HUMAN_REVIEW"

# =============================================================================
# Scenario F — Reviewer ACCEPT with required artifacts still passes the
# completion gate (spec 0019 rules remain authoritative; the gate does not
# weaken them).
# =============================================================================
proj_f="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_f/docs/sdd/0006-reviewer-accept"
echo "# reviewer accept spec" > "$proj_f/docs/sdd/0006-reviewer-accept/spec.md"
# --verbose: see the note on scenario A above.
out_f="$(specrelay_test::run "$proj_f" "docs/sdd/0006-reviewer-accept/spec.md" --verbose 2>&1)"
specrelay_test::assert_eq "F: run exits 0" "0" "$?"
specrelay_test::assert_contains "F: reviewer completion gate passed" "$out_f" $'Reviewer: passed'

# =============================================================================
# Scenario G — Reviewer REQUEST_CHANGES with required artifacts also passes
# the completion gate.
# =============================================================================
proj_g="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_g/docs/sdd/0007-reviewer-changes"
echo "# reviewer changes spec" > "$proj_g/docs/sdd/0007-reviewer-changes/spec.md"
plan_dir_g="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-gate-plan.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$plan_dir_g")
cat > "$plan_dir_g/reviewer-plan.txt" <<'EOF'
decision=request_changes
decision=accept
EOF
out_g="$(SPECRELAY_FAKE_REVIEWER_PLAN="$plan_dir_g/reviewer-plan.txt" \
  specrelay_test::run "$proj_g" "docs/sdd/0007-reviewer-changes/spec.md" 2>&1)"
specrelay_test::assert_eq "G: run exits 0" "0" "$?"
specrelay_test::assert_contains "G: requests changes in round 1" "$out_g" "CHANGES_REQUESTED"
specrelay_test::assert_contains "G: reaches READY_FOR_HUMAN_REVIEW after round 2" "$out_g" "READY_FOR_HUMAN_REVIEW"

# =============================================================================
# Scenario X — a UI-impact task with UI PASS proceeds to READY_FOR_HUMAN_REVIEW
# (spec 0029, section 32.1 test X / AC-07): engine-owned executor_verification
# actually invokes the spec-0028 fake UI runner and the completion gate reads
# its REAL ui_status.
# =============================================================================
proj_x="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_x/.specrelay"
cat >> "$proj_x/.specrelay/config.yml" <<'YAML'
verification:
  ui:
    enabled: true
    provider: fake
    runtime:
      start_command: "bin/dev"
      ready_url: "http://127.0.0.1:9/health"
YAML
mkdir -p "$proj_x/docs/sdd/0008-ui-pass"
printf '# UI pass spec\n\n## Acceptance Criteria\nPage renders without error\n' > "$proj_x/docs/sdd/0008-ui-pass/spec.md"
cat > "$proj_x/.specrelay/ui-scenarios.yml" <<'YAML'
- id: "01-pass"
  title: "Renders the page"
  acceptance_criteria:
    - "Page renders without error"
  steps:
    - action: goto
      url: "/x"
  assertions:
    - type: visible
      target: "A"
  checkpoints: []
  fixture:
    case: pass
YAML
(cd "$proj_x" && git add -A && git commit -q -m "ui pass fixture")
out_x="$(specrelay_test::run "$proj_x" "docs/sdd/0008-ui-pass/spec.md" 2>&1)"
rc_x=$?
specrelay_test::assert_eq "X: run exits 0 (UI PASS proceeds)" "0" "$rc_x"
specrelay_test::assert_contains "X: reaches READY_FOR_HUMAN_REVIEW" "$out_x" "READY_FOR_HUMAN_REVIEW"
task_dir_x="$proj_x/.specrelay-runs/tasks/0008-ui-pass"
specrelay_test::assert_contains "X: UI verification overall PASS" \
  "$(cat "$task_dir_x/29-ui-verification/summary.json" 2>/dev/null)" '"overall_status": "PASS"'
specrelay_test::assert_contains "X: finalization record shows ui_status PASS" \
  "$(cat "$task_dir_x/30-executor-finalization.json" 2>/dev/null)" '"ui_status": "PASS"'

# =============================================================================
# Scenario Y — a UI-impact task with required UI FAIL / BLOCKED / pending
# refuses submission (spec 0029, section 32.1 test Y / AC-07): no submit;
# VERIFICATION_FAILED / VERIFICATION_BLOCKED; task remains EXECUTOR_RUNNING.
# =============================================================================

# Y1: a required scenario assertion FAILS -> VERIFICATION_FAILED.
proj_y1="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_y1/.specrelay"
cat >> "$proj_y1/.specrelay/config.yml" <<'YAML'
verification:
  ui:
    enabled: true
    provider: fake
    runtime:
      start_command: "bin/dev"
      ready_url: "http://127.0.0.1:9/health"
YAML
mkdir -p "$proj_y1/docs/sdd/0009-ui-fail"
printf '# UI fail spec\n\n## Acceptance Criteria\nElement B is absent\n' > "$proj_y1/docs/sdd/0009-ui-fail/spec.md"
cat > "$proj_y1/.specrelay/ui-scenarios.yml" <<'YAML'
- id: "01-fail"
  title: "Assertion fails"
  acceptance_criteria:
    - "Element B is absent"
  steps:
    - action: goto
      url: "/y"
  assertions:
    - type: absent
      target: "B"
  checkpoints: []
  fixture:
    case: failed_assertion
YAML
(cd "$proj_y1" && git add -A && git commit -q -m "ui fail fixture")
out_y1="$(specrelay_test::run "$proj_y1" "docs/sdd/0009-ui-fail/spec.md" 2>&1)"
rc_y1=$?
specrelay_test::assert_true "Y1: run exits non-zero (no submit)" "$([ "$rc_y1" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "Y1: names VERIFICATION_FAILED" "$out_y1" "VERIFICATION_FAILED"
task_dir_y1="$proj_y1/.specrelay-runs/tasks/0009-ui-fail"
specrelay_test::assert_contains "Y1: task remains EXECUTOR_RUNNING" \
  "$(cat "$task_dir_y1/state.json")" "EXECUTOR_RUNNING"
specrelay_test::assert_contains "Y1: UI verification overall FAIL" \
  "$(cat "$task_dir_y1/29-ui-verification/summary.json" 2>/dev/null)" '"overall_status": "FAIL"'

# Y2: a required scenario is BLOCKED (missing credentials fixture) ->
# VERIFICATION_BLOCKED, with the blocked prerequisite reported.
proj_y2="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_y2/.specrelay"
cat >> "$proj_y2/.specrelay/config.yml" <<'YAML'
verification:
  ui:
    enabled: true
    provider: fake
    runtime:
      start_command: "bin/dev"
      ready_url: "http://127.0.0.1:9/health"
YAML
mkdir -p "$proj_y2/docs/sdd/0010-ui-blocked"
printf '# UI blocked spec\n\n## Acceptance Criteria\nRequires authenticated session\n' > "$proj_y2/docs/sdd/0010-ui-blocked/spec.md"
cat > "$proj_y2/.specrelay/ui-scenarios.yml" <<'YAML'
- id: "01-blocked"
  title: "Needs login"
  acceptance_criteria:
    - "Requires authenticated session"
  steps:
    - action: goto
      url: "/z"
  assertions: []
  checkpoints: []
  fixture:
    case: blocked_credentials
YAML
(cd "$proj_y2" && git add -A && git commit -q -m "ui blocked fixture")
out_y2="$(specrelay_test::run "$proj_y2" "docs/sdd/0010-ui-blocked/spec.md" 2>&1)"
rc_y2=$?
specrelay_test::assert_true "Y2: run exits non-zero (no submit)" "$([ "$rc_y2" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "Y2: names VERIFICATION_BLOCKED" "$out_y2" "VERIFICATION_BLOCKED"
task_dir_y2="$proj_y2/.specrelay-runs/tasks/0010-ui-blocked"
specrelay_test::assert_contains "Y2: task remains EXECUTOR_RUNNING" \
  "$(cat "$task_dir_y2/state.json")" "EXECUTOR_RUNNING"
specrelay_test::assert_contains "Y2: UI verification overall BLOCKED" \
  "$(cat "$task_dir_y2/29-ui-verification/summary.json" 2>/dev/null)" '"overall_status": "BLOCKED"'
scenario_result_y2="$(find "$task_dir_y2/29-ui-verification/scenarios" -name "result.json" 2>/dev/null | head -n1 | xargs cat 2>/dev/null)"
specrelay_test::assert_contains "Y2: the blocked prerequisite reason is reported" \
  "$scenario_result_y2" "credentials"

# Y3: required UI verification never reaches a terminal result (an invalid
# scenario manifest -- a scenario with no steps -- makes the engine-owned UI
# run fail BEFORE any summary.json is written) -> "pending" is never silently
# treated as passing; the completion gate refuses with VERIFICATION_BLOCKED.
proj_y3="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_y3/.specrelay"
cat >> "$proj_y3/.specrelay/config.yml" <<'YAML'
verification:
  ui:
    enabled: true
    provider: fake
    runtime:
      start_command: "bin/dev"
      ready_url: "http://127.0.0.1:9/health"
YAML
mkdir -p "$proj_y3/docs/sdd/0011-ui-pending"
echo "# ui pending spec" > "$proj_y3/docs/sdd/0011-ui-pending/spec.md"
cat > "$proj_y3/.specrelay/ui-scenarios.yml" <<'YAML'
- id: "01-invalid"
  title: "Invalid scenario (no steps)"
  acceptance_criteria:
    - "Never actually run"
  steps: []
  assertions: []
  checkpoints: []
YAML
(cd "$proj_y3" && git add -A && git commit -q -m "ui pending fixture")
out_y3="$(specrelay_test::run "$proj_y3" "docs/sdd/0011-ui-pending/spec.md" 2>&1)"
rc_y3=$?
specrelay_test::assert_true "Y3: run exits non-zero (no submit)" "$([ "$rc_y3" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "Y3: names VERIFICATION_BLOCKED (pending UI result is never a silent pass)" \
  "$out_y3" "VERIFICATION_BLOCKED"
task_dir_y3="$proj_y3/.specrelay-runs/tasks/0011-ui-pending"
specrelay_test::assert_contains "Y3: task remains EXECUTOR_RUNNING" \
  "$(cat "$task_dir_y3/state.json")" "EXECUTOR_RUNNING"
specrelay_test::assert_true "Y3: no UI summary.json was ever produced (genuinely pending, not fabricated)" \
  "$([ ! -f "$task_dir_y3/29-ui-verification/summary.json" ] && echo 0 || echo 1)"

echo
specrelay_test::summary
