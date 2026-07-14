#!/usr/bin/env bash
# phase_budgets_test.sh — phase-budget configuration and warnings (spec 0019,
# "E. Phase Budgets"). Warnings are advisory only and never alter task state.
#   tools/specrelay/test/phase_budgets_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/config.sh
. "$SPECRELAY_ROOT/lib/specrelay/config.sh"
# shellcheck source=../lib/specrelay/timeline.sh
. "$SPECRELAY_ROOT/lib/specrelay/timeline.sh"

# =============================================================================
# Default budgets load.
# =============================================================================
noconf="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-budget-noconf.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$noconf")
defaults="$(specrelay::config::phase_budgets "$noconf")"
specrelay_test::assert_eq "default budgets load (exit 0)" "0" "$?"
specrelay_test::assert_contains "default reviewer_provider_seconds is 900" \
  "$defaults" "reviewer_provider_seconds=900"
specrelay_test::assert_contains "default finalization_seconds is 30" \
  "$defaults" "finalization_seconds=30"

# =============================================================================
# Configured budgets override defaults.
# =============================================================================
proj="$(specrelay_test::mktemp_project)"
mkdir -p "$proj/.specrelay"
cat > "$proj/.specrelay/config.yml" <<'YAML'
version: 1
performance:
  phase_budgets:
    reviewer_provider_seconds: 60
YAML
overridden="$(specrelay::config::phase_budgets "$proj")"
specrelay_test::assert_contains "configured reviewer_provider_seconds overrides the default" \
  "$overridden" "reviewer_provider_seconds=60"
specrelay_test::assert_contains "unconfigured budgets keep their default" \
  "$overridden" "finalization_seconds=30"

# =============================================================================
# Invalid budget values are rejected.
# =============================================================================
bad_proj="$(specrelay_test::mktemp_project)"
mkdir -p "$bad_proj/.specrelay"
cat > "$bad_proj/.specrelay/config.yml" <<'YAML'
version: 1
performance:
  phase_budgets:
    reviewer_provider_seconds: -5
YAML
bad_out="$(specrelay::config::phase_budgets "$bad_proj")"
specrelay_test::assert_eq "a negative budget is rejected (exit 1)" "1" "$?"
specrelay_test::assert_contains "negative-budget error names the field" "$bad_out" "reviewer_provider_seconds"

nonint_proj="$(specrelay_test::mktemp_project)"
mkdir -p "$nonint_proj/.specrelay"
cat > "$nonint_proj/.specrelay/config.yml" <<'YAML'
version: 1
performance:
  phase_budgets:
    finalization_seconds: "soon"
YAML
nonint_out="$(specrelay::config::phase_budgets "$nonint_proj")"
specrelay_test::assert_eq "a non-integer budget is rejected (exit 1)" "1" "$?"
specrelay_test::assert_contains "non-integer budget error names the field" "$nonint_out" "finalization_seconds"

unknown_proj="$(specrelay_test::mktemp_project)"
mkdir -p "$unknown_proj/.specrelay"
cat > "$unknown_proj/.specrelay/config.yml" <<'YAML'
version: 1
performance:
  phase_budgets:
    bogus_phase_seconds: 5
YAML
unknown_out="$(specrelay::config::phase_budgets "$unknown_proj")"
specrelay_test::assert_eq "an unknown budget key is rejected (exit 1)" "1" "$?"
specrelay_test::assert_contains "unknown budget key error names it" "$unknown_out" "bogus_phase_seconds"

# =============================================================================
# Budget status evaluation: within_budget / exceeded / not_configured /
# not_measurable, and the warning format (expected + actual duration).
# =============================================================================
tdir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-budget-eval.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$tdir")
root="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-budget-root.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$root")
mkdir -p "$root/.specrelay"
cat > "$root/.specrelay/config.yml" <<'YAML'
version: 1
performance:
  phase_budgets:
    reviewer_provider_seconds: 5
YAML

specrelay::timeline::start "$tdir" reviewer_provider_execution reviewer
sleep 0.2
specrelay::timeline::finish "$tdir" reviewer_provider_execution passed
specrelay::timeline::start "$tdir" executor_context_preflight executor
sleep 0.1
specrelay::timeline::finish "$tdir" executor_context_preflight passed

json="$(specrelay::timeline::render "$root" "$tdir" budget-task final --json)"
specrelay_test::assert_eq "a phase well under its budget is within_budget" \
  "within_budget" "$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next(b for b in d["budgets"] if b["phase"]=="reviewer_provider_execution")
print(row["status"])
')"
specrelay_test::assert_eq "an unconfigured budget (evidence-capture, not overridden) uses the default and is within_budget" \
  "within_budget" "$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next(b for b in d["budgets"] if b["phase"]=="executor_context_preflight")
print(row["status"])
')"
specrelay_test::assert_eq "a phase never recorded is not_measurable" \
  "not_measurable" "$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next(b for b in d["budgets"] if b["phase"]=="reviewer_marker_recovery")
print(row["status"])
')"

# --- exceeded status + warning fields ---------------------------------------
tdir2="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-budget-eval2.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$tdir2")
root2="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-budget-root2.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$root2")
mkdir -p "$root2/.specrelay"
cat > "$root2/.specrelay/config.yml" <<'YAML'
version: 1
performance:
  phase_budgets:
    finalization_seconds: 0
YAML
specrelay::timeline::start "$tdir2" finalization
sleep 0.2
specrelay::timeline::finish "$tdir2" finalization passed
json2="$(specrelay::timeline::render "$root2" "$tdir2" budget-task2 final --json)"
specrelay_test::assert_eq "a phase over its (near-zero) budget is exceeded" \
  "exceeded" "$(printf '%s' "$json2" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next(b for b in d["budgets"] if b["phase"]=="finalization")
print(row["status"])
')"
specrelay_test::assert_contains "budget warnings list the exceeded phase" \
  "$json2" '"phase": "finalization"'

human2="$(specrelay::timeline::render "$root2" "$tdir2" budget-task2 final)"
specrelay_test::assert_contains "warning report includes the expected duration" \
  "$human2" "expected <="
specrelay_test::assert_contains "warning report includes the actual duration" \
  "$human2" "actual"

# =============================================================================
# Budget warnings never change task state by default — verified via the real
# lifecycle: a reviewer round that (deterministically) exceeds a near-zero
# marker-recovery budget still completes normally, no state is blocked.
# =============================================================================
proj_state="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_state/docs/sdd/0001-budget-warn"
echo "# spec" > "$proj_state/docs/sdd/0001-budget-warn/spec.md"
(cd "$proj_state" && git add -A && git commit -q -m "spec")
cat >> "$proj_state/.specrelay/config.yml" <<'YAML'
performance:
  phase_budgets:
    reviewer_provider_seconds: 0
YAML
(cd "$proj_state" && git add -A && git commit -q -m "budget config")
out_state="$(cd "$proj_state" && "$SPECRELAY_BIN" run docs/sdd/0001-budget-warn/spec.md 2>&1)"
specrelay_test::assert_contains "an exceeded budget still reaches READY_FOR_HUMAN_REVIEW (no state change)" \
  "$out_state" "READY_FOR_HUMAN_REVIEW"
state_json="$(cat "$proj_state/.ai-runs/tasks/0001-budget-warn/state.json")"
specrelay_test::assert_contains "state.json reflects normal completion despite the budget warning" \
  "$state_json" '"state": "READY_FOR_HUMAN_REVIEW"'

specrelay_test::summary
exit $?
