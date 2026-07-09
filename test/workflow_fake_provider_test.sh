#!/usr/bin/env bash
# workflow_fake_provider_test.sh — end-to-end `specrelay run` scenarios using
# the deterministic 'fake' executor/reviewer providers (spec section 60).
# Drives the real CLI (bin/specrelay) against isolated temp git fixtures —
# never the real Claude/Codex CLI, never this repository's own tasks.
#   tools/specrelay/test/workflow_fake_provider_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

specrelay_test::run() {
  local proj="$1" spec="$2"
  shift 2
  (cd "$proj" && "$SPECRELAY_BIN" run "$spec" "$@")
}

# =============================================================================
# Scenario A — accepted first round: executor success, reviewer ACCEPT
#   -> READY_FOR_HUMAN_REVIEW
# =============================================================================
proj_a="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_a/docs/sdd/0001-scenario-a"
echo "# Scenario A spec" > "$proj_a/docs/sdd/0001-scenario-a/spec.md"

out_a="$(specrelay_test::run "$proj_a" "docs/sdd/0001-scenario-a/spec.md" 2>&1)"
rc_a=$?
specrelay_test::assert_eq "scenario A: run exits 0" "0" "$rc_a"
specrelay_test::assert_contains "scenario A: reaches READY_FOR_HUMAN_REVIEW" "$out_a" "READY_FOR_HUMAN_REVIEW"

state_a="$proj_a/.ai-runs/tasks/0001-scenario-a/state.json"
specrelay_test::assert_contains "scenario A: state.json records READY_FOR_HUMAN_REVIEW" \
  "$(cat "$state_a")" "READY_FOR_HUMAN_REVIEW"

# =============================================================================
# Scenario B — changes then accept: executor round 1, reviewer
#   REQUEST_CHANGES, executor round 2, reviewer ACCEPT -> READY_FOR_HUMAN_REVIEW
# =============================================================================
proj_b="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_b/docs/sdd/0002-scenario-b"
echo "# Scenario B spec" > "$proj_b/docs/sdd/0002-scenario-b/spec.md"
plan_dir_b="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")"
cat > "$plan_dir_b/reviewer-plan.txt" <<'EOF'
decision=request_changes
decision=accept
EOF

out_b="$(SPECRELAY_FAKE_REVIEWER_PLAN="$plan_dir_b/reviewer-plan.txt" specrelay_test::run "$proj_b" "docs/sdd/0002-scenario-b/spec.md" 2>&1)"
rc_b=$?
specrelay_test::assert_eq "scenario B: run exits 0" "0" "$rc_b"
specrelay_test::assert_contains "scenario B: requests changes in round 1" "$out_b" "CHANGES_REQUESTED"
specrelay_test::assert_contains "scenario B: runs a second executor round" "$out_b" "round 2"
specrelay_test::assert_contains "scenario B: reaches READY_FOR_HUMAN_REVIEW" "$out_b" "READY_FOR_HUMAN_REVIEW"

task_dir_b="$proj_b/.ai-runs/tasks/0002-scenario-b"
specrelay_test::assert_eq "scenario B: final iteration is 2" "2" "$(cat "$task_dir_b/state.json" | grep -o '"iteration": [0-9]*' | grep -o '[0-9]*')"
specrelay_test::assert_contains "scenario B: round 1 evidence survives (archived, not overwritten)" \
  "$(cat "$task_dir_b/iterations/round-1/08-executor-summary.md" 2>/dev/null)" "round 1"
specrelay_test::assert_contains "scenario B: round 2 is the live 08-executor-summary.md" \
  "$(cat "$task_dir_b/08-executor-summary.md" 2>/dev/null)" "round 2"

# =============================================================================
# Scenario C — executor failure: non-zero exit -> no false review submission
# =============================================================================
proj_c="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_c/docs/sdd/0003-scenario-c"
echo "# Scenario C spec" > "$proj_c/docs/sdd/0003-scenario-c/spec.md"
plan_dir_c="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")"
printf 'exit=1\n' > "$plan_dir_c/exec-plan.txt"

out_c="$(SPECRELAY_FAKE_EXECUTOR_PLAN="$plan_dir_c/exec-plan.txt" specrelay_test::run "$proj_c" "docs/sdd/0003-scenario-c/spec.md" 2>&1)"
rc_c=$?
specrelay_test::assert_true "scenario C: run exits non-zero on executor failure" "$([ "$rc_c" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_not_contains "scenario C: never falsely reaches READY_FOR_HUMAN_REVIEW" "$out_c" "reached READY_FOR_HUMAN_REVIEW"
task_dir_c="$proj_c/.ai-runs/tasks/0003-scenario-c"
specrelay_test::assert_contains "scenario C: task remains EXECUTOR_RUNNING (not submitted)" \
  "$(cat "$task_dir_c/state.json")" "EXECUTOR_RUNNING"
specrelay_test::assert_eq "scenario C: no READY_FOR_REVIEW submission was recorded" \
  "" "$(cat "$task_dir_c/state.json" | grep -o 'submitted_for_review_at')"

# =============================================================================
# Scenario D — reviewer failure: non-zero exit -> no false acceptance
# =============================================================================
proj_d="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_d/docs/sdd/0004-scenario-d"
echo "# Scenario D spec" > "$proj_d/docs/sdd/0004-scenario-d/spec.md"
plan_dir_d="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")"
printf 'exit=1\n' > "$plan_dir_d/reviewer-plan.txt"

out_d="$(SPECRELAY_FAKE_REVIEWER_PLAN="$plan_dir_d/reviewer-plan.txt" specrelay_test::run "$proj_d" "docs/sdd/0004-scenario-d/spec.md" 2>&1)"
rc_d=$?
specrelay_test::assert_true "scenario D: run exits non-zero on reviewer failure" "$([ "$rc_d" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_not_contains "scenario D: never falsely accepts" "$out_d" "accepted -> READY_FOR_HUMAN_REVIEW"
task_dir_d="$proj_d/.ai-runs/tasks/0004-scenario-d"
specrelay_test::assert_contains "scenario D: task remains READY_FOR_REVIEW (no false accept)" \
  "$(cat "$task_dir_d/state.json")" "READY_FOR_REVIEW"

# =============================================================================
# Scenario E — max rounds: repeated REQUEST_CHANGES -> clear max-round outcome
# =============================================================================
proj_e="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_e/docs/sdd/0005-scenario-e"
echo "# Scenario E spec" > "$proj_e/docs/sdd/0005-scenario-e/spec.md"
plan_dir_e="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")"
printf 'decision=request_changes\ndecision=request_changes\ndecision=request_changes\ndecision=request_changes\n' > "$plan_dir_e/reviewer-plan.txt"

out_e="$(SPECRELAY_FAKE_REVIEWER_PLAN="$plan_dir_e/reviewer-plan.txt" specrelay_test::run "$proj_e" "docs/sdd/0005-scenario-e/spec.md" 2>&1)"
rc_e=$?
specrelay_test::assert_true "scenario E: run exits non-zero at the max-round limit" "$([ "$rc_e" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "scenario E: reports the maximum-iterations outcome explicitly" \
  "$out_e" "maximum of 3 iteration(s)"
specrelay_test::assert_not_contains "scenario E: never pretends acceptance" "$out_e" "READY_FOR_HUMAN_REVIEW"
task_dir_e="$proj_e/.ai-runs/tasks/0005-scenario-e"
specrelay_test::assert_not_contains "scenario E: final state.json is not READY_FOR_HUMAN_REVIEW" \
  "$(cat "$task_dir_e/state.json")" "READY_FOR_HUMAN_REVIEW"
specrelay_test::assert_contains "scenario E: all 3 rounds' evidence is archived" \
  "$(ls "$task_dir_e/iterations" 2>/dev/null)" "round-3"

specrelay_test::summary
exit $?
