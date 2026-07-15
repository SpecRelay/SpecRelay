#!/usr/bin/env bash
# reviewer_policy_template_test.sh — Reviewer Policy v2 template + plain
# reviewer prompt contract (spec 0019, "B. Reviewer Policy v2" / "Reviewer
# Prompt Contract"). Deterministic; needs no real Claude.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

TEMPLATE="$SPECRELAY_ROOT/templates/claude/agents/ai-reviewer.md"
template_content="$(cat "$TEMPLATE")"

# =============================================================================
# Claude agent template: every required element is present
# =============================================================================
specrelay_test::assert_contains "template requires risk classification" \
  "$template_content" "Risk classification"
specrelay_test::assert_contains "template lists all four risk levels" \
  "$template_content" "Critical"
specrelay_test::assert_contains "template requires evidence inspection" \
  "$template_content" "Evidence intake"
specrelay_test::assert_contains "template displays a verification budget" \
  "$template_content" "Verification budget"
specrelay_test::assert_contains "template shows the default focused-run limit" \
  "$template_content" "Focused test runs: 3"
specrelay_test::assert_contains "template shows the default full-suite limit" \
  "$template_content" "Full-suite runs:   0 by default"
specrelay_test::assert_contains "template requires a reason for additional verification" \
  "$template_content" "ADDITIONAL_VERIFICATION_REASON"
specrelay_test::assert_contains "template requires a reason for an extra full-suite run" \
  "$template_content" "FULL_SUITE_REASON"
specrelay_test::assert_contains "template defines the severity contract" \
  "$template_content" "Severity contract"
specrelay_test::assert_contains "template lists BLOCKER severity" "$template_content" "BLOCKER"
specrelay_test::assert_contains "template lists NOTE severity" "$template_content" "NOTE"
specrelay_test::assert_contains "template defines a stop condition" \
  "$template_content" "Stop condition"
specrelay_test::assert_contains "template requires the final decision marker" \
  "$template_content" "DECISION: ACCEPT"
specrelay_test::assert_contains "template requires the REQUEST_CHANGES marker" \
  "$template_content" "DECISION: REQUEST_CHANGES"
specrelay_test::assert_contains "template includes the completion checklist" \
  "$template_content" "Before finishing, verify"
specrelay_test::assert_contains "template's checklist checks the final marker is present exactly once" \
  "$template_content" "final decision marker is present exactly once"
specrelay_test::assert_contains "template states independence is not blind repetition" \
  "$template_content" "Independence is not blind repetition"
specrelay_test::assert_contains "template forbids running the full suite merely because it is available" \
  "$template_content" "merely because it is available"
specrelay_test::assert_contains "template warns against silently relabeling targeted as full verification" \
  "$template_content" "Never silently redefine targeted verification as full verification"

# =============================================================================
# Plain (non-Claude-subagent) reviewer prompt carries the same critical policy
# (spec 0019, "Reviewer Prompt Contract" — never depends exclusively on the
# Claude sub-agent template being installed).
# =============================================================================
proj="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj/docs/sdd/0001-plain-prompt"
echo "# spec" > "$proj/docs/sdd/0001-plain-prompt/spec.md"
(cd "$proj" && git add -A && git commit -q -m "spec")
(cd "$proj" && "$SPECRELAY_BIN" task create "docs/sdd/0001-plain-prompt/spec.md" >/dev/null)
(cd "$proj" && "$SPECRELAY_BIN" task approve 0001-plain-prompt >/dev/null)

# Drive only the executor round so the task reaches READY_FOR_REVIEW, then
# reconstruct the reviewer prompt exactly as workflow.sh would build it for
# an automated reviewer round.
plan="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")"
printf 'decision=accept\n' > "$plan/reviewer-plan.txt"
root="$proj"
task_id="0001-plain-prompt"
(cd "$proj" && "$SPECRELAY_BIN" resume "$task_id" >/dev/null 2>&1)

# Rebuild the prompt directly via the library function (never through a real
# Claude call) to inspect its content — source the full engine chain exactly
# like bin/specrelay does, so build_reviewer_prompt's dependencies all exist.
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
. "$SPECRELAY_ROOT/lib/specrelay/project.sh"
. "$SPECRELAY_ROOT/lib/specrelay/config.sh"
. "$SPECRELAY_ROOT/lib/specrelay/discovery.sh"
. "$SPECRELAY_ROOT/lib/specrelay/state.sh"
. "$SPECRELAY_ROOT/lib/specrelay/task.sh"
. "$SPECRELAY_ROOT/lib/specrelay/lock.sh"
. "$SPECRELAY_ROOT/lib/specrelay/auth.sh"
. "$SPECRELAY_ROOT/lib/specrelay/git_guard.sh"
. "$SPECRELAY_ROOT/lib/specrelay/evidence.sh"
. "$SPECRELAY_ROOT/lib/specrelay/marker.sh"
. "$SPECRELAY_ROOT/lib/specrelay/timeline.sh"
. "$SPECRELAY_ROOT/lib/specrelay/verification.sh"
. "$SPECRELAY_ROOT/lib/specrelay/transitions.sh"
. "$SPECRELAY_ROOT/lib/specrelay/providers/provider.sh"
. "$SPECRELAY_ROOT/lib/specrelay/providers/fake.sh"
. "$SPECRELAY_ROOT/lib/specrelay/providers/claude.sh"
. "$SPECRELAY_ROOT/lib/specrelay/providers/capability.sh"
. "$SPECRELAY_ROOT/lib/specrelay/context/capability.sh"
. "$SPECRELAY_ROOT/lib/specrelay/context/none.sh"
. "$SPECRELAY_ROOT/lib/specrelay/context/fake.sh"
. "$SPECRELAY_ROOT/lib/specrelay/context/contextplus.sh"
. "$SPECRELAY_ROOT/lib/specrelay/contexts.sh"
. "$SPECRELAY_ROOT/lib/specrelay/marker_recovery.sh"
. "$SPECRELAY_ROOT/lib/specrelay/workflow.sh"

prompt_file="$(specrelay::workflow::build_reviewer_prompt "$proj" "$task_id" 2>/dev/null)"
prompt_content="$(cat "$prompt_file" 2>/dev/null)"

specrelay_test::assert_contains "plain prompt requires risk classification" \
  "$prompt_content" "Classify this change's risk level"
specrelay_test::assert_contains "plain prompt displays a verification budget" \
  "$prompt_content" "verification budget for this review"
specrelay_test::assert_contains "plain prompt requires evidence inspection of the real tree" \
  "$prompt_content" "Inspect the real working tree and current diff"
specrelay_test::assert_contains "plain prompt requires structured artifacts" \
  "$prompt_content" "risk level, acceptance-criteria table"
specrelay_test::assert_contains "plain prompt requires the mandatory marker as the final line" \
  "$prompt_content" "FINAL non-empty"
specrelay_test::assert_contains "plain prompt states a stop condition" \
  "$prompt_content" "STOP once every acceptance criterion is assessed"
specrelay_test::assert_contains "plain prompt states the reviewer is not a second executor" \
  "$prompt_content" "NOT a second executor"
rm -f "$prompt_file"

specrelay_test::summary
exit $?
