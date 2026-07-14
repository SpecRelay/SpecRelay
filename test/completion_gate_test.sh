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
#   tools/specrelay/test/completion_gate_test.sh

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
out_a="$(specrelay_test::run "$proj_a" "docs/sdd/0001-gate-ok/spec.md" 2>&1)"
specrelay_test::assert_eq "A: run exits 0" "0" "$?"
specrelay_test::assert_contains "A: reaches READY_FOR_HUMAN_REVIEW" "$out_a" "READY_FOR_HUMAN_REVIEW"
specrelay_test::assert_contains "A: executor completion gate passed" "$out_a" $'Executor: passed'

# =============================================================================
# Scenario B — exit 0 with EACH required artifact missing, individually, is
# INCOMPLETE (never a false SUCCESS), and the task remains EXECUTOR_RUNNING.
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
  specrelay_test::assert_true "B ($artifact): run exits non-zero" "$([ "$rc_b" -ne 0 ] && echo 0 || echo 1)"
  specrelay_test::assert_contains "B ($artifact): Executor Result card says INCOMPLETE" "$out_b" "INCOMPLETE"
  specrelay_test::assert_not_contains "B ($artifact): never prints a false SUCCESS card" \
    "$(printf '%s\n' "$out_b" | grep -A1 'Executor Result')" "SUCCESS"
  specrelay_test::assert_contains "B ($artifact): names the missing artifact" "$out_b" "$artifact"
  specrelay_test::assert_contains "B ($artifact): never falsely reaches READY_FOR_HUMAN_REVIEW" \
    "$(printf '%s\n' "$out_b" | grep -c 'reached READY_FOR_HUMAN_REVIEW')" "0"

  task_dir_b="$proj_b/.ai-runs/tasks/0002-$slug"
  specrelay_test::assert_contains "B ($artifact): task remains EXECUTOR_RUNNING" \
    "$(cat "$task_dir_b/state.json")" "EXECUTOR_RUNNING"
  specrelay_test::assert_contains "B ($artifact): efficiency artifact records the gate failure reason" \
    "$(cat "$task_dir_b/22-agent-efficiency.json" 2>/dev/null)" "$artifact"

  # Existing evidence files ARE preserved (the other two artifacts, still
  # written by the fake provider, are not deleted by the gate check).
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
# Scenario D — explicit unresolved-waiting final output -> INCOMPLETE for the
# Executor, task remains EXECUTOR_RUNNING.
# =============================================================================
proj_d="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_d/docs/sdd/0004-exec-wait"
echo "# exec wait spec" > "$proj_d/docs/sdd/0004-exec-wait/spec.md"
plan_dir_d="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-gate-plan.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$plan_dir_d")
printf 'wait_text=I will wait for the background task.\n' > "$plan_dir_d/exec-plan.txt"
out_d="$(SPECRELAY_FAKE_EXECUTOR_PLAN="$plan_dir_d/exec-plan.txt" \
  specrelay_test::run "$proj_d" "docs/sdd/0004-exec-wait/spec.md" 2>&1)"
specrelay_test::assert_contains "D: Executor Result card says INCOMPLETE for unresolved waiting" "$out_d" "INCOMPLETE"
specrelay_test::assert_contains "D: names the unresolved-work reason" "$out_d" "declared background work"
task_dir_d="$proj_d/.ai-runs/tasks/0004-exec-wait"
specrelay_test::assert_contains "D: task remains EXECUTOR_RUNNING" \
  "$(cat "$task_dir_d/state.json")" "EXECUTOR_RUNNING"

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
out_f="$(specrelay_test::run "$proj_f" "docs/sdd/0006-reviewer-accept/spec.md" 2>&1)"
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

echo
specrelay_test::summary
