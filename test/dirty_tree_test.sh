#!/usr/bin/env bash
# dirty_tree_test.sh — dirty-working-tree / rework-loop semantics (spec
# section 62). Each case uses an isolated temporary git repo, driven through
# the real CLI with the deterministic 'fake' provider. This is the
# acceptance test for the fix to the legacy workflow's known limitation
# (docs/current-workflow-contract.md, section 9).
#   tools/specrelay/test/dirty_tree_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# =============================================================================
# Case 1 — clean baseline -> executor creates task changes -> review requests
# changes -> iteration 2 continues successfully. THIS MUST PASS.
# =============================================================================
proj1="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj1/docs/sdd/0001-case1"
echo "# Case 1 spec" > "$proj1/docs/sdd/0001-case1/spec.md"
(cd "$proj1" && git add -A && git commit -q -m "commit spec before running")

plan1="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")"
printf 'decision=request_changes\ndecision=accept\n' > "$plan1/reviewer-plan.txt"

out1="$(cd "$proj1" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan1/reviewer-plan.txt" "$SPECRELAY_BIN" run docs/sdd/0001-case1/spec.md 2>&1)"
rc1=$?
specrelay_test::assert_eq "case 1: clean baseline -> rework -> iteration 2 succeeds" "0" "$rc1"
specrelay_test::assert_contains "case 1: reaches READY_FOR_HUMAN_REVIEW" "$out1" "READY_FOR_HUMAN_REVIEW"

# =============================================================================
# Case 2 — pre-existing UNRELATED dirty change before task start. Explicit
# policy: refuse by default (Case 2 detection), succeed with
# --allow-dirty-baseline (an explicit, evidence-recorded opt-in).
# =============================================================================
proj2="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj2/docs/sdd/0002-case2"
echo "# Case 2 spec" > "$proj2/docs/sdd/0002-case2/spec.md"
(cd "$proj2" && git add -A && git commit -q -m "commit spec")
# An unrelated file, dirty BEFORE the task is created, that has nothing to do
# with this task or its spec.
echo "unrelated draft notes" > "$proj2/unrelated-scratch-file.txt"

out2_default="$(cd "$proj2" && "$SPECRELAY_BIN" run docs/sdd/0002-case2/spec.md 2>&1)"
rc2_default=$?
specrelay_test::assert_true "case 2: refuses by default with pre-existing unrelated dirt" \
  "$([ "$rc2_default" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "case 2: names the unrelated pre-existing file" \
  "$out2_default" "unrelated-scratch-file.txt"

out2_allowed="$(cd "$proj2" && "$SPECRELAY_BIN" run docs/sdd/0002-case2/spec.md --allow-dirty-baseline 2>&1)"
rc2_allowed=$?
specrelay_test::assert_eq "case 2: succeeds with an explicit --allow-dirty-baseline opt-in" "0" "$rc2_allowed"
specrelay_test::assert_contains "case 2 (allowed): reaches READY_FOR_HUMAN_REVIEW" "$out2_allowed" "READY_FOR_HUMAN_REVIEW"

# =============================================================================
# Case 3 — an unexpected EXTERNAL change appears between controlled workflow
# phases (after round 1 submission, before round 2's claim). Must be
# detected/blocked.
# =============================================================================
proj3="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj3/docs/sdd/0003-case3"
echo "# Case 3 spec" > "$proj3/docs/sdd/0003-case3/spec.md"
(cd "$proj3" && git add -A && git commit -q -m "commit spec")

# Manually drive round 1 to CHANGES_REQUESTED via a single --once step so we
# can inject an external change before continuing.
plan3="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")"
printf 'decision=request_changes\n' > "$plan3/reviewer-plan.txt"

(cd "$proj3" && "$SPECRELAY_BIN" task create docs/sdd/0003-case3/spec.md >/dev/null)
(cd "$proj3" && "$SPECRELAY_BIN" task approve 0003-case3 >/dev/null)
(cd "$proj3" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan3/reviewer-plan.txt" "$SPECRELAY_BIN" resume 0003-case3 >/dev/null 2>&1)
(cd "$proj3" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan3/reviewer-plan.txt" "$SPECRELAY_BIN" resume 0003-case3 >/dev/null 2>&1)
state3="$(cd "$proj3" && "$SPECRELAY_BIN" task status 0003-case3 2>&1)"
specrelay_test::assert_contains "case 3 setup: task is CHANGES_REQUESTED before the external change" "$state3" "CHANGES_REQUESTED"

# An external, unrelated file appears — NOT produced by this task's executor.
echo "surprise external edit" > "$proj3/surprise-external-file.txt"

out3="$(cd "$proj3" && "$SPECRELAY_BIN" resume 0003-case3 2>&1)"
rc3=$?
specrelay_test::assert_true "case 3: an unexpected external change blocks the next claim" \
  "$([ "$rc3" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "case 3: names the unexpected external file" "$out3" "surprise-external-file.txt"

# =============================================================================
# Case 4 — task-owned changes remain present BETWEEN iterations and must NOT
# be misclassified as unrelated dirtiness (this is the core rework-loop fix).
# =============================================================================
proj4="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj4/docs/sdd/0004-case4"
echo "# Case 4 spec" > "$proj4/docs/sdd/0004-case4/spec.md"
(cd "$proj4" && git add -A && git commit -q -m "commit spec")

plan4="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")"
printf 'decision=request_changes\ndecision=accept\n' > "$plan4/reviewer-plan.txt"

out4="$(cd "$proj4" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan4/reviewer-plan.txt" "$SPECRELAY_BIN" run docs/sdd/0004-case4/spec.md 2>&1)"
rc4=$?
specrelay_test::assert_eq "case 4: round 1's accumulated diff is never misclassified as unrelated" "0" "$rc4"
specrelay_test::assert_not_contains "case 4: no 'unexpected working-tree changes' refusal occurred" \
  "$out4" "unexpected working-tree changes"
fake_impl4="$proj4/specrelay-fake-impl.txt"
specrelay_test::assert_eq "case 4: the fake executor's file has both rounds' lines" \
  "2" "$(wc -l < "$fake_impl4" | tr -d ' ')"

specrelay_test::summary
exit $?
