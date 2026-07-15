#!/usr/bin/env bash
# reviewer_continuation_test.sh — the automated-reviewer continuation contract
# (spec 0010). Proves that `specrelay resume <task>` drives the SAME
# executor<->reviewer automation loop as `specrelay run`, so an automated
# reviewer continues from READY_FOR_REVIEW into reviewer execution IN THE SAME
# invocation and reaches READY_FOR_HUMAN_REVIEW — no second manual `resume`
# required. READY_FOR_REVIEW is an internal handoff state; the loop only rests
# there for an explicit `manual` reviewer or a reviewer failure, and never
# silently. Uses only the deterministic 'fake'/'manual' providers.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# specrelay_test::_write_config <project-root> <reviewer-provider>
# Writes a fixture config with the deterministic 'fake' executor and the given
# reviewer provider, then commits it so the working tree is clean.
specrelay_test::_write_config() {
  local dir="$1" reviewer="$2"
  cat > "$dir/.specrelay/config.yml" <<YAML
version: 1
project:
  name: Fixture Project
specs:
  root: docs/sdd
tasks:
  runs_root: .specrelay-runs/tasks
  max_iterations: 3
roles:
  executor:
    provider: fake
  reviewer:
    provider: $reviewer
context:
  adapter: none
  required: false
validation:
  full_test_command: "echo ok"
policy:
  human_final_review_required: true
YAML
  # Tolerate a no-op commit (e.g. reconfiguring fake -> fake leaves the tree
  # unchanged); the point is only to keep the working tree clean.
  (cd "$dir" && git add -A && git commit -q -m "config: reviewer=$reviewer" >/dev/null 2>&1) || true
}

# specrelay_test::_new_task <project-root> <task-id> <reviewer-provider>
# Creates and approves a task so it rests at READY_FOR_EXECUTOR, ready to be
# driven by `specrelay resume`.
specrelay_test::_new_task() {
  local proj="$1" task_id="$2" reviewer="$3"
  specrelay_test::_write_config "$proj" "$reviewer"
  mkdir -p "$proj/docs/sdd/$task_id"
  echo "# $task_id spec" > "$proj/docs/sdd/$task_id/spec.md"
  (cd "$proj" && git add -A && git commit -q -m "spec $task_id")
  (cd "$proj" && "$SPECRELAY_BIN" task create "docs/sdd/$task_id/spec.md" >/dev/null)
  (cd "$proj" && "$SPECRELAY_BIN" task approve "$task_id" >/dev/null)
}

# =============================================================================
# Test 1 (spec required tests #2 + #4) — `specrelay resume` starting from
# READY_FOR_EXECUTOR with an AUTOMATED reviewer reaches READY_FOR_HUMAN_REVIEW
# in ONE invocation. No second manual resume is required.
# =============================================================================
proj1="$(specrelay_test::mktemp_specrelay_project)"
specrelay_test::_new_task "$proj1" "0001-resume-auto" "fake"

out1="$(cd "$proj1" && "$SPECRELAY_BIN" resume 0001-resume-auto 2>&1)"
rc1=$?
specrelay_test::assert_eq "resume from READY_FOR_EXECUTOR (automated reviewer) exits 0" "0" "$rc1"
specrelay_test::assert_contains "resume runs the reviewer in the same invocation" "$out1" "reviewer:fake"
specrelay_test::assert_contains "resume reaches READY_FOR_HUMAN_REVIEW in one invocation" \
  "$out1" "READY_FOR_HUMAN_REVIEW"
state1="$proj1/.specrelay-runs/tasks/0001-resume-auto/state.json"
specrelay_test::assert_contains "final state.json is READY_FOR_HUMAN_REVIEW" \
  "$(cat "$state1")" "READY_FOR_HUMAN_REVIEW"
# #4: the single resume already reached the terminal state — it must NOT have
# rested at READY_FOR_REVIEW waiting for a second manual resume.
specrelay_test::assert_not_contains "resume never rests at READY_FOR_REVIEW for an automated reviewer" \
  "$out1" "stopping at READY_FOR_REVIEW"

# A second resume is a clean no-op on the already-terminal task (confirms no
# second resume was needed and none is harmful).
out1b="$(cd "$proj1" && "$SPECRELAY_BIN" resume 0001-resume-auto 2>&1)"
rc1b=$?
specrelay_test::assert_eq "a redundant second resume is a clean no-op (exit 0)" "0" "$rc1b"
specrelay_test::assert_contains "second resume reports the terminal state, runs no new round" \
  "$out1b" "READY_FOR_HUMAN_REVIEW"

# =============================================================================
# Test 2 (spec required test #3) — `specrelay resume` starting from
# READY_FOR_REVIEW with an automated reviewer runs the reviewer and reaches
# READY_FOR_HUMAN_REVIEW. Models the "manual bootstrap -> switch to automated"
# story: a task parked at READY_FOR_REVIEW (manual reviewer) is later resumed
# once the reviewer provider is automated.
# =============================================================================
proj2="$(specrelay_test::mktemp_specrelay_project)"
specrelay_test::_new_task "$proj2" "0002-resume-from-review" "manual"

# Manual reviewer: run drives the executor and parks the task at
# READY_FOR_REVIEW (exit 2, an explicit human handoff).
(cd "$proj2" && "$SPECRELAY_BIN" resume 0002-resume-from-review >/dev/null 2>&1)
parked_state2="$(cd "$proj2" && "$SPECRELAY_BIN" task status 0002-resume-from-review 2>&1)"
specrelay_test::assert_contains "manual reviewer parks the task at READY_FOR_REVIEW" \
  "$parked_state2" "READY_FOR_REVIEW"

# Switch to an automated reviewer and resume: it must run the reviewer FROM
# READY_FOR_REVIEW and reach READY_FOR_HUMAN_REVIEW.
specrelay_test::_write_config "$proj2" "fake"
out2="$(cd "$proj2" && "$SPECRELAY_BIN" resume 0002-resume-from-review 2>&1)"
rc2=$?
specrelay_test::assert_eq "resume from READY_FOR_REVIEW (automated reviewer) exits 0" "0" "$rc2"
specrelay_test::assert_contains "resume from READY_FOR_REVIEW runs the reviewer" "$out2" "reviewer:fake"
specrelay_test::assert_contains "resume from READY_FOR_REVIEW reaches READY_FOR_HUMAN_REVIEW" \
  "$out2" "READY_FOR_HUMAN_REVIEW"

# =============================================================================
# Test 3 (spec required test #5) — MANUAL reviewer via resume stops at
# READY_FOR_REVIEW with a clear, non-silent human handoff message and exit 2.
# =============================================================================
proj3="$(specrelay_test::mktemp_specrelay_project)"
specrelay_test::_new_task "$proj3" "0003-resume-manual" "manual"

out3="$(cd "$proj3" && "$SPECRELAY_BIN" resume 0003-resume-manual 2>&1)"
rc3=$?
specrelay_test::assert_eq "manual reviewer via resume stops the loop (exit 2)" "2" "$rc3"
specrelay_test::assert_contains "manual stop states that the reviewer provider is 'manual'" \
  "$out3" "reviewer provider is 'manual'"
specrelay_test::assert_contains "manual stop tells the operator what to do next (accept)" \
  "$out3" "specrelay task accept"
specrelay_test::assert_contains "manual stop tells the operator what to do next (request-changes)" \
  "$out3" "specrelay task request-changes"
state3="$proj3/.specrelay-runs/tasks/0003-resume-manual/state.json"
specrelay_test::assert_contains "manual reviewer leaves the task at READY_FOR_REVIEW" \
  "$(cat "$state3")" "READY_FOR_REVIEW"

# =============================================================================
# Test 4 (spec required test #6) — an AUTOMATED reviewer that FAILS leaves the
# task in REVIEWER_RUNNING with a clear recovery reason and exit 4 (never a
# silent stop, never a false acceptance). Under spec 0011 the runner enters
# REVIEWER_RUNNING before executing the reviewer, so an interrupted review
# remains in REVIEWER_RUNNING (no rollback) for a later resume to continue.
# =============================================================================
proj4="$(specrelay_test::mktemp_specrelay_project)"
specrelay_test::_new_task "$proj4" "0004-resume-revfail" "fake"
plan4="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")"
printf 'exit=1\n' > "$plan4/reviewer-plan.txt"

out4="$(cd "$proj4" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan4/reviewer-plan.txt" "$SPECRELAY_BIN" resume 0004-resume-revfail 2>&1)"
rc4=$?
specrelay_test::assert_eq "automated reviewer failure via resume exits 4" "4" "$rc4"
specrelay_test::assert_contains "reviewer failure is reported clearly with a recovery reason" \
  "$out4" "automated reviewer failed"
specrelay_test::assert_not_contains "reviewer failure never falsely accepts" \
  "$out4" "READY_FOR_HUMAN_REVIEW"
state4="$proj4/.specrelay-runs/tasks/0004-resume-revfail/state.json"
specrelay_test::assert_contains "interrupted review remains in REVIEWER_RUNNING for recovery (spec 0011)" \
  "$(cat "$state4")" "REVIEWER_RUNNING"

# =============================================================================
# Test 5 (spec required test #7) — the request-changes flow via resume still
# requeues the executor and continues the automated loop until acceptance, all
# in one resume invocation.
# =============================================================================
proj5="$(specrelay_test::mktemp_specrelay_project)"
specrelay_test::_new_task "$proj5" "0005-resume-rework" "fake"
plan5="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")"
printf 'decision=request_changes\ndecision=accept\n' > "$plan5/reviewer-plan.txt"

out5="$(cd "$proj5" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan5/reviewer-plan.txt" "$SPECRELAY_BIN" resume 0005-resume-rework 2>&1)"
rc5=$?
specrelay_test::assert_eq "resume rework loop reaches acceptance (exit 0)" "0" "$rc5"
specrelay_test::assert_contains "resume rework requests changes in round 1" "$out5" "CHANGES_REQUESTED"
specrelay_test::assert_contains "resume rework runs a second executor round" "$out5" "round 2"
specrelay_test::assert_contains "resume rework reaches READY_FOR_HUMAN_REVIEW" "$out5" "READY_FOR_HUMAN_REVIEW"
task_dir5="$proj5/.specrelay-runs/tasks/0005-resume-rework"
specrelay_test::assert_eq "resume rework: final iteration is 2" \
  "2" "$(grep -o '"iteration": [0-9]*' "$task_dir5/state.json" | grep -o '[0-9]*')"

# =============================================================================
# Test 6 (spec 0011) — an interrupted automated review parked in REVIEWER_RUNNING
# is continued by a later `specrelay resume` directly from REVIEWER_RUNNING and
# reaches READY_FOR_HUMAN_REVIEW. Proves the acceptance criteria "interrupted
# reviews remain in REVIEWER_RUNNING" and "resume continues correctly from
# REVIEWER_RUNNING" — no rollback to READY_FOR_REVIEW is required or performed.
# =============================================================================
proj6="$(specrelay_test::mktemp_specrelay_project)"
specrelay_test::_new_task "$proj6" "0006-resume-revrunning" "fake"
plan6="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")"
printf 'exit=1\n' > "$plan6/reviewer-plan.txt"

# First resume: executor submits, reviewer enters REVIEWER_RUNNING then crashes
# (exit=1). The task must be left in REVIEWER_RUNNING (exit 4), not rolled back.
out6a="$(cd "$proj6" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan6/reviewer-plan.txt" "$SPECRELAY_BIN" resume 0006-resume-revrunning 2>&1)"
rc6a=$?
specrelay_test::assert_eq "first resume (reviewer crash) exits 4" "4" "$rc6a"
state6="$proj6/.specrelay-runs/tasks/0006-resume-revrunning/state.json"
specrelay_test::assert_contains "crashed automated review is left in REVIEWER_RUNNING" \
  "$(cat "$state6")" "REVIEWER_RUNNING"

# Second resume: no failing plan (reviewer defaults to accept). The loop must
# continue FROM REVIEWER_RUNNING, run the reviewer, and reach the terminal state.
out6b="$(cd "$proj6" && "$SPECRELAY_BIN" resume 0006-resume-revrunning 2>&1)"
rc6b=$?
specrelay_test::assert_eq "resume from REVIEWER_RUNNING exits 0" "0" "$rc6b"
specrelay_test::assert_contains "resume from REVIEWER_RUNNING continues the interrupted review" \
  "$out6b" "resuming an interrupted review from REVIEWER_RUNNING"
specrelay_test::assert_contains "resume from REVIEWER_RUNNING runs the reviewer" "$out6b" "reviewer:fake"
specrelay_test::assert_contains "resume from REVIEWER_RUNNING reaches READY_FOR_HUMAN_REVIEW" \
  "$out6b" "READY_FOR_HUMAN_REVIEW"
specrelay_test::assert_contains "final state.json is READY_FOR_HUMAN_REVIEW" \
  "$(cat "$state6")" "READY_FOR_HUMAN_REVIEW"

specrelay_test::summary
exit $?
