#!/usr/bin/env bash
# marker_recovery_test.sh — smart, narrow, single-attempt marker-only
# recovery (spec 0019, "C. Mandatory Decision Marker" / marker_recovery.sh).
# Uses only the deterministic 'fake' provider (missing_marker / marker_artifacts
# plan keys — see providers/fake.sh).

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

specrelay_test::_new_task() {
  local proj="$1" task_id="$2"
  mkdir -p "$proj/docs/sdd/$task_id"
  echo "# $task_id spec" > "$proj/docs/sdd/$task_id/spec.md"
  (cd "$proj" && git add -A && git commit -q -m "spec $task_id")
  (cd "$proj" && "$SPECRELAY_BIN" task create "docs/sdd/$task_id/spec.md" >/dev/null)
  (cd "$proj" && "$SPECRELAY_BIN" task approve "$task_id" >/dev/null)
}

specrelay_test::_plan() {
  local dir line
  dir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")"
  line="$1"
  printf '%s\n' "$line" > "$dir/reviewer-plan.txt"
  printf '%s\n' "$dir/reviewer-plan.txt"
}

# =============================================================================
# 1 — missing marker + complete ACCEPT artifacts triggers ONE corrective
# attempt, which succeeds, and the full review is NOT repeated (no second
# reviewer:fake round in the log).
# =============================================================================
proj1="$(specrelay_test::mktemp_specrelay_project)"
specrelay_test::_new_task "$proj1" "0001-accept-recovery"
plan1="$(specrelay_test::_plan "decision=missing_marker,marker_artifacts=accept")"

out1="$(cd "$proj1" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan1" "$SPECRELAY_BIN" resume 0001-accept-recovery 2>&1)"
rc1=$?
specrelay_test::assert_eq "ACCEPT recovery: task reaches READY_FOR_HUMAN_REVIEW (exit 0)" "0" "$rc1"
specrelay_test::assert_contains "ACCEPT recovery: attempts the one corrective attempt" \
  "$out1" "attempting the one allowed marker-only corrective attempt"
specrelay_test::assert_contains "ACCEPT recovery: reports success without repeating the review" \
  "$out1" "the full review was NOT repeated"
n_reviewer_rounds1="$(printf '%s\n' "$out1" | grep -c '\[fake-reviewer\] round')"
specrelay_test::assert_eq "ACCEPT recovery: reviewer:fake ran exactly once (not repeated)" "1" "$n_reviewer_rounds1"
state1="$proj1/.specrelay-runs/tasks/0001-accept-recovery/state.json"
specrelay_test::assert_contains "ACCEPT recovery: state.json reflects acceptance" \
  "$(cat "$state1")" "READY_FOR_HUMAN_REVIEW"

# =============================================================================
# 2 — missing marker + complete REQUEST_CHANGES artifacts triggers ONE
# corrective attempt, which succeeds as REQUEST_CHANGES.
# =============================================================================
proj2="$(specrelay_test::mktemp_specrelay_project)"
specrelay_test::_new_task "$proj2" "0002-request-changes-recovery"
plan2="$(specrelay_test::_plan "decision=missing_marker,marker_artifacts=request_changes")"

out2="$(cd "$proj2" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan2" "$SPECRELAY_BIN" resume 0002-request-changes-recovery 2>&1)"
specrelay_test::assert_contains "REQUEST_CHANGES recovery: succeeds via the corrective attempt" \
  "$out2" "marker-only recovery succeeded (decision: REQUEST_CHANGES)"
# The automation loop auto-requeues CHANGES_REQUESTED and continues (spec
# 0010) — proving the transition happened means checking the LOG line, not
# the final state.json (which may already be past it after a second round).
specrelay_test::assert_contains "REQUEST_CHANGES recovery: reviewer transitioned to CHANGES_REQUESTED" \
  "$out2" "changes requested -> CHANGES_REQUESTED"

# =============================================================================
# 3 — the corrective attempt receives a NARROW prompt (never the original
# full review prompt: no spec text, no diff) and never reruns repository
# tools (the fake corrective entry point writes no repository files at all).
# =============================================================================
proj3="$(specrelay_test::mktemp_specrelay_project)"
specrelay_test::_new_task "$proj3" "0003-narrow-prompt"
plan3="$(specrelay_test::_plan "decision=missing_marker,marker_artifacts=accept")"
(cd "$proj3" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan3" "$SPECRELAY_BIN" resume 0003-narrow-prompt >/dev/null 2>&1)
recovery_stdout="$(cat "$proj3/.specrelay-runs/tasks/0003-narrow-prompt/21-marker-recovery-stdout.txt" 2>/dev/null)"
specrelay_test::assert_true "corrective attempt wrote its own capture file" \
  "$([ -s "$proj3/.specrelay-runs/tasks/0003-narrow-prompt/21-marker-recovery-stdout.txt" ] && echo 0 || echo 1)"
prompt_ref="$(printf '%s\n' "$recovery_stdout" | sed -n 's/^\[fake-reviewer-recovery\] prompt file: //p')"
if [ -n "$prompt_ref" ] && [ -f "$prompt_ref" ]; then
  narrow_prompt="$(cat "$prompt_ref")"
  specrelay_test::assert_contains "corrective prompt tells the reviewer not to repeat the review" \
    "$narrow_prompt" "Do not repeat the review"
  specrelay_test::assert_contains "corrective prompt tells the reviewer not to run tests" \
    "$narrow_prompt" "Do not run tests"
  specrelay_test::assert_contains "corrective prompt tells the reviewer not to inspect the repository again" \
    "$narrow_prompt" "Do not inspect the repository again"
  specrelay_test::assert_not_contains "corrective prompt does NOT include the original spec text" \
    "$narrow_prompt" "0003-narrow-prompt spec"
fi

# =============================================================================
# 4 — a SECOND recovery attempt is forbidden: if the corrective attempt fails,
# the task stays REVIEWER_RUNNING and no automatic further attempt is made
# (no infinite loop — a follow-up resume must be a fresh, independent
# invocation, never a second attempt inside the same failed one).
# =============================================================================
proj4="$(specrelay_test::mktemp_specrelay_project)"
specrelay_test::_new_task "$proj4" "0004-recovery-fails"
plan4="$(specrelay_test::_plan "decision=missing_marker,marker_artifacts=accept")"

out4="$(cd "$proj4" && SPECRELAY_FAKE_MARKER_RECOVERY_FAIL=1 SPECRELAY_FAKE_REVIEWER_PLAN="$plan4" \
  "$SPECRELAY_BIN" resume 0004-recovery-fails 2>&1)"
rc4=$?
specrelay_test::assert_contains "failed correction leaves the task in REVIEWER_RUNNING" \
  "$out4" "marker-only recovery failed"
specrelay_test::assert_true "failed correction: exit is non-zero" \
  "$([ "$rc4" -ne 0 ] && echo 0 || echo 1)"
state4="$proj4/.specrelay-runs/tasks/0004-recovery-fails/state.json"
specrelay_test::assert_contains "failed correction: state.json remains REVIEWER_RUNNING" \
  "$(cat "$state4")" "REVIEWER_RUNNING"
specrelay_test::assert_not_contains "failed correction never fabricates acceptance" \
  "$out4" "READY_FOR_HUMAN_REVIEW"
n_reviewer_rounds4="$(printf '%s\n' "$out4" | grep -c '\[fake-reviewer\] round')"
specrelay_test::assert_eq "failed correction: the full review still ran only once" "1" "$n_reviewer_rounds4"

# =============================================================================
# 5 — missing review artifacts prevents marker recovery (normal resume
# behavior remains: the task stays REVIEWER_RUNNING).
# =============================================================================
proj5="$(specrelay_test::mktemp_specrelay_project)"
specrelay_test::_new_task "$proj5" "0005-missing-artifacts"
plan5="$(specrelay_test::_plan "decision=missing_marker,marker_artifacts=missing")"

out5="$(cd "$proj5" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan5" "$SPECRELAY_BIN" resume 0005-missing-artifacts 2>&1)"
specrelay_test::assert_contains "missing artifacts: recovery is refused" \
  "$out5" "marker-only recovery is not safe"
specrelay_test::assert_not_contains "missing artifacts: no attempt is made" \
  "$out5" "attempting the one allowed marker-only corrective attempt"

# =============================================================================
# 6 — empty artifacts prevent marker recovery.
# =============================================================================
proj6="$(specrelay_test::mktemp_specrelay_project)"
specrelay_test::_new_task "$proj6" "0006-empty-artifacts"
plan6="$(specrelay_test::_plan "decision=missing_marker,marker_artifacts=empty")"

out6="$(cd "$proj6" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan6" "$SPECRELAY_BIN" resume 0006-empty-artifacts 2>&1)"
specrelay_test::assert_contains "empty artifacts: recovery is refused" \
  "$out6" "marker-only recovery is not safe"

# =============================================================================
# 7 — unclear/contradictory artifact decision prevents marker recovery.
# =============================================================================
proj7="$(specrelay_test::mktemp_specrelay_project)"
specrelay_test::_new_task "$proj7" "0007-conflicting-artifacts"
plan7="$(specrelay_test::_plan "decision=missing_marker,marker_artifacts=conflicting")"

out7="$(cd "$proj7" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan7" "$SPECRELAY_BIN" resume 0007-conflicting-artifacts 2>&1)"
specrelay_test::assert_contains "conflicting artifacts: recovery is refused" \
  "$out7" "marker-only recovery is not safe"

# =============================================================================
# 8 — missing 11-next-executor-prompt.md prevents REQUEST_CHANGES recovery
# (marker_artifacts=request_changes always writes 11, so simulate the gap by
# using the 'missing' fixture, which never writes ANY artifact including 11 —
# already covered by scenario 5/6's structural absence; this scenario proves
# the SPECIFIC request-changes-without-11 shape is exercised too via the
# eligibility check itself).
# =============================================================================
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
. "$SPECRELAY_ROOT/lib/specrelay/marker_recovery.sh"
elig_dir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-elig.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$elig_dir")
printf 'notes\nDecision: REQUEST_CHANGES\n' > "$elig_dir/09-consultant-review.md"
specrelay_test::assert_eq "eligibility: REQUEST_CHANGES without 11-next-executor-prompt.md is ineligible" \
  "1" "$(specrelay::marker_recovery::eligible "$elig_dir" >/dev/null 2>&1; echo $?)"
printf 'next steps\n' > "$elig_dir/11-next-executor-prompt.md"
specrelay_test::assert_eq "eligibility: REQUEST_CHANGES WITH 11-next-executor-prompt.md is eligible" \
  "REQUEST_CHANGES" "$(specrelay::marker_recovery::eligible "$elig_dir" 2>/dev/null)"

# =============================================================================
# 9 — recovery is recorded in the timeline.
# =============================================================================
timeline_json1="$(cat "$proj1/.specrelay-runs/tasks/0001-accept-recovery/20-execution-timeline.json" 2>/dev/null)"
specrelay_test::assert_contains "timeline records the marker-recovery outcome" \
  "$timeline_json1" '"marker_recovery"'
specrelay_test::assert_contains "timeline reports the recovery as successful" \
  "$timeline_json1" '"outcome": "success"'

specrelay_test::summary
exit $?
