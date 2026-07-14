#!/usr/bin/env bash
# verification_policy_test.sh — bounded verification policy configuration and
# command classification (spec 0019, "Bounded Verification Policy").
#   tools/specrelay/test/verification_policy_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/config.sh
. "$SPECRELAY_ROOT/lib/specrelay/config.sh"
# shellcheck source=../lib/specrelay/timeline.sh
. "$SPECRELAY_ROOT/lib/specrelay/timeline.sh"
# shellcheck source=../lib/specrelay/verification.sh
. "$SPECRELAY_ROOT/lib/specrelay/verification.sh"

# =============================================================================
# Defaults load successfully with no .specrelay/config.yml at all
# =============================================================================
noconf="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-verify-noconf.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$noconf")
defaults="$(specrelay::config::verification_policy "$noconf")"
rc_defaults=$?
specrelay_test::assert_eq "defaults load successfully (exit 0)" "0" "$rc_defaults"
specrelay_test::assert_contains "default executor full_suite_max_runs is 1" "$defaults" "executor_full_suite_max_runs=1"
specrelay_test::assert_contains "default reviewer full_suite_max_runs is 0" "$defaults" "reviewer_full_suite_max_runs=0"
specrelay_test::assert_contains "default reviewer focused_max_runs is 3" "$defaults" "reviewer_focused_max_runs=3"
specrelay_test::assert_contains "default reviewer default_mode is targeted" "$defaults" "reviewer_default_mode=targeted"

# =============================================================================
# Missing verification: section (but config file present) is backward
# compatible — resolves to defaults.
# =============================================================================
legacy_proj="$(specrelay_test::mktemp_specrelay_project)"
legacy_out="$(specrelay::config::verification_policy "$legacy_proj")"
specrelay_test::assert_eq "missing verification: section is backward compatible (exit 0)" "0" "$?"
specrelay_test::assert_contains "backward-compat project still gets default executor limits" \
  "$legacy_out" "executor_smoke_max_runs=1"

# =============================================================================
# Valid executor + reviewer limits parse
# =============================================================================
valid_proj="$(specrelay_test::mktemp_project)"
mkdir -p "$valid_proj/.specrelay"
cat > "$valid_proj/.specrelay/config.yml" <<'YAML'
version: 1
verification:
  executor:
    full_suite_max_runs: 2
    smoke_max_runs: 3
  reviewer:
    default_mode: full
    focused_max_runs: 5
    full_suite_max_runs: 1
YAML
valid_out="$(specrelay::config::verification_policy "$valid_proj")"
rc_valid=$?
specrelay_test::assert_eq "valid executor+reviewer limits parse (exit 0)" "0" "$rc_valid"
specrelay_test::assert_contains "configured executor full_suite_max_runs applied" "$valid_out" "executor_full_suite_max_runs=2"
specrelay_test::assert_contains "configured executor smoke_max_runs applied" "$valid_out" "executor_smoke_max_runs=3"
specrelay_test::assert_contains "unconfigured executor doctor_max_runs keeps default" "$valid_out" "executor_doctor_max_runs=1"
specrelay_test::assert_contains "configured reviewer default_mode applied" "$valid_out" "reviewer_default_mode=full"
specrelay_test::assert_contains "configured reviewer focused_max_runs applied" "$valid_out" "reviewer_focused_max_runs=5"
specrelay_test::assert_contains "configured reviewer full_suite_max_runs applied" "$valid_out" "reviewer_full_suite_max_runs=1"

# =============================================================================
# Negative limits are rejected
# =============================================================================
neg_proj="$(specrelay_test::mktemp_project)"
mkdir -p "$neg_proj/.specrelay"
cat > "$neg_proj/.specrelay/config.yml" <<'YAML'
version: 1
verification:
  executor:
    full_suite_max_runs: -1
YAML
neg_out="$(specrelay::config::verification_policy "$neg_proj")"
specrelay_test::assert_eq "negative executor limit is rejected (exit 1)" "1" "$?"
specrelay_test::assert_contains "negative-limit error names the offending field" "$neg_out" "full_suite_max_runs"

# =============================================================================
# Non-integer limits are rejected
# =============================================================================
noninty_proj="$(specrelay_test::mktemp_project)"
mkdir -p "$noninty_proj/.specrelay"
cat > "$noninty_proj/.specrelay/config.yml" <<'YAML'
version: 1
verification:
  reviewer:
    focused_max_runs: "three"
YAML
noninty_out="$(specrelay::config::verification_policy "$noninty_proj")"
specrelay_test::assert_eq "non-integer limit is rejected (exit 1)" "1" "$?"
specrelay_test::assert_contains "non-integer error names the offending field" "$noninty_out" "focused_max_runs"

# =============================================================================
# Unknown verification modes / keys are rejected
# =============================================================================
badmode_proj="$(specrelay_test::mktemp_project)"
mkdir -p "$badmode_proj/.specrelay"
cat > "$badmode_proj/.specrelay/config.yml" <<'YAML'
version: 1
verification:
  reviewer:
    default_mode: bogus
YAML
badmode_out="$(specrelay::config::verification_policy "$badmode_proj")"
specrelay_test::assert_eq "unknown reviewer default_mode is rejected (exit 1)" "1" "$?"
specrelay_test::assert_contains "unknown-mode error lists valid modes" "$badmode_out" "focused, targeted, full"

badkey_proj="$(specrelay_test::mktemp_project)"
mkdir -p "$badkey_proj/.specrelay"
cat > "$badkey_proj/.specrelay/config.yml" <<'YAML'
version: 1
verification:
  executor:
    bogus_key: 1
YAML
badkey_out="$(specrelay::config::verification_policy "$badkey_proj")"
specrelay_test::assert_eq "unknown executor key is rejected (exit 1)" "1" "$?"
specrelay_test::assert_contains "unknown-key error names it" "$badkey_out" "bogus_key"

top_badkey_proj="$(specrelay_test::mktemp_project)"
mkdir -p "$top_badkey_proj/.specrelay"
cat > "$top_badkey_proj/.specrelay/config.yml" <<'YAML'
version: 1
verification:
  bogus_top: 1
YAML
top_badkey_out="$(specrelay::config::verification_policy "$top_badkey_proj")"
specrelay_test::assert_eq "unknown top-level verification key is rejected (exit 1)" "1" "$?"
specrelay_test::assert_contains "unknown top-level key error names it" "$top_badkey_out" "bogus_top"

# =============================================================================
# Effective policy can be inspected (doctor)
# =============================================================================
doctor_out="$(cd "$legacy_proj" && SPECRELAY_PROVIDER_OPTIONAL=1 "$SPECRELAY_BIN" doctor 2>&1)"
specrelay_test::assert_contains "doctor reports the executor verification policy" \
  "$doctor_out" "Verification policy (executor)"
specrelay_test::assert_contains "doctor reports the reviewer verification policy" \
  "$doctor_out" "Verification policy (reviewer)"
specrelay_test::assert_contains "doctor reports phase budgets" \
  "$doctor_out" "Phase budgets"

bad_doctor_out="$(cd "$neg_proj" && SPECRELAY_PROVIDER_OPTIONAL=1 "$SPECRELAY_BIN" doctor 2>&1)"
specrelay_test::assert_contains "doctor fails clearly on an invalid verification policy" \
  "$bad_doctor_out" "Verification policy: INVALID"

# =============================================================================
# Effective policy is captured durably for each task
# =============================================================================
task_proj="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$task_proj/docs/sdd/0001-verify-capture"
echo "# spec" > "$task_proj/docs/sdd/0001-verify-capture/spec.md"
(cd "$task_proj" && git add -A && git commit -q -m "spec")
(cd "$task_proj" && "$SPECRELAY_BIN" run docs/sdd/0001-verify-capture/spec.md >/dev/null 2>&1)
state_blob="$(cat "$task_proj/.ai-runs/tasks/0001-verify-capture/state.json")"
specrelay_test::assert_contains "task state.json durably captures the effective verification policy" \
  "$state_blob" "verification_policy_effective"
specrelay_test::assert_contains "captured policy includes the executor limit" \
  "$state_blob" "executor_full_suite_max_runs"

# =============================================================================
# Command classification (spec 0019, "Verification Operation Classification")
# =============================================================================
specrelay_test::assert_eq "focused test file classifies as test_focused" \
  "test_focused" "$(specrelay::verification::classify "scripts/test test/config_test.sh")"
specrelay_test::assert_eq "--changed classifies as test_targeted" \
  "test_targeted" "$(specrelay::verification::classify "scripts/test --changed --jobs auto --timings --explain")"
specrelay_test::assert_eq "--changed-files classifies as test_targeted" \
  "test_targeted" "$(specrelay::verification::classify "scripts/test --changed-files foo.txt")"
specrelay_test::assert_eq "bare full-suite run classifies as test_full" \
  "test_full" "$(specrelay::verification::classify "scripts/test --jobs auto --timings")"
specrelay_test::assert_eq "smoke classifies as smoke" \
  "smoke" "$(specrelay::verification::classify "scripts/smoke --skip-tests")"
specrelay_test::assert_eq "doctor classifies as doctor" \
  "doctor" "$(specrelay::verification::classify "bin/specrelay doctor")"
specrelay_test::assert_eq "version classifies as version" \
  "version" "$(specrelay::verification::classify "bin/specrelay version")"
specrelay_test::assert_eq "an unrecognized command remains unclassified" \
  "agent_tool_execution_unclassified" "$(specrelay::verification::classify "ls -la /tmp")"

specrelay_test::summary
exit $?
