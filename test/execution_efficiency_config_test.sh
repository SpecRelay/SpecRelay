#!/usr/bin/env bash
# execution_efficiency_config_test.sh — execution-efficiency policy
# configuration parsing, validation, and durable capture (spec 0021,
# "Configuration" / "Durable Effective Policy").
#   tools/specrelay/test/execution_efficiency_config_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/config.sh
. "$SPECRELAY_ROOT/lib/specrelay/config.sh"

# =============================================================================
# Defaults resolve correctly with no .specrelay/config.yml at all
# =============================================================================
noconf="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ee-noconf.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$noconf")
defaults="$(specrelay::config::execution_efficiency_policy "$noconf")"
rc_defaults=$?
specrelay_test::assert_eq "defaults load successfully (exit 0)" "0" "$rc_defaults"
specrelay_test::assert_contains "default enabled is true" "$defaults" "enabled=true"
specrelay_test::assert_contains "default executor exploration_warning_calls is 30" \
  "$defaults" "executor_exploration_warning_calls=30"
specrelay_test::assert_contains "default reviewer exploration_warning_calls is 20" \
  "$defaults" "reviewer_exploration_warning_calls=20"
specrelay_test::assert_contains "default executor repeated_verification_limit is 1" \
  "$defaults" "executor_repeated_verification_limit=1"
specrelay_test::assert_contains "default executor unresolved_wait_is_failure is true" \
  "$defaults" "executor_unresolved_wait_is_failure=true"
specrelay_test::assert_contains "default reviewer require_artifacts_before_success is true" \
  "$defaults" "reviewer_require_artifacts_before_success=true"

# =============================================================================
# Missing execution_efficiency: section (config present) is backward
# compatible — resolves to defaults.
# =============================================================================
legacy_proj="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ee-legacy.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$legacy_proj")
mkdir -p "$legacy_proj/.specrelay"
cat > "$legacy_proj/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: legacy
YAML
legacy_out="$(specrelay::config::execution_efficiency_policy "$legacy_proj")"
specrelay_test::assert_eq "legacy project (no execution_efficiency: section) still resolves (exit 0)" "0" "$?"
specrelay_test::assert_contains "legacy project gets default executor limits" \
  "$legacy_out" "executor_exploration_warning_calls=30"

# =============================================================================
# Executor and Reviewer values remain isolated (an override for one role
# never leaks into the other's fields).
# =============================================================================
iso_proj="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ee-iso.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$iso_proj")
mkdir -p "$iso_proj/.specrelay"
cat > "$iso_proj/.specrelay/config.yml" <<'YAML'
version: 1
execution_efficiency:
  executor:
    exploration_warning_calls: 25
    repeated_verification_limit: 2
  reviewer:
    exploration_warning_calls: 15
YAML
iso_out="$(specrelay::config::execution_efficiency_policy "$iso_proj")"
specrelay_test::assert_contains "configured executor exploration_warning_calls applies" \
  "$iso_out" "executor_exploration_warning_calls=25"
specrelay_test::assert_contains "configured executor repeated_verification_limit applies" \
  "$iso_out" "executor_repeated_verification_limit=2"
specrelay_test::assert_contains "configured reviewer exploration_warning_calls applies" \
  "$iso_out" "reviewer_exploration_warning_calls=15"
specrelay_test::assert_contains "reviewer repeated_verification_limit is untouched by executor override" \
  "$iso_out" "reviewer_repeated_verification_limit=1"
specrelay_test::assert_contains "executor exploration_warning_calls override does not leak to reviewer" \
  "$iso_out" "reviewer_exploration_warning_calls=15"
specrelay_test::assert_not_contains "reviewer exploration_warning_calls is not 25 (isolation)" \
  "$(printf '%s\n' "$iso_out" | grep '^reviewer_exploration_warning_calls=')" "25"

# =============================================================================
# Invalid booleans fail
# =============================================================================
bad_bool_proj="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ee-badbool.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$bad_bool_proj")
mkdir -p "$bad_bool_proj/.specrelay"
cat > "$bad_bool_proj/.specrelay/config.yml" <<'YAML'
version: 1
execution_efficiency:
  executor:
    unresolved_wait_is_failure: "yes"
YAML
bad_bool_out="$(specrelay::config::execution_efficiency_policy "$bad_bool_proj")"
specrelay_test::assert_eq "invalid boolean fails (exit 1)" "1" "$?"
specrelay_test::assert_contains "invalid boolean error is clear" "$bad_bool_out" "must be a boolean"

# top-level enabled must also be boolean
bad_enabled_proj="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ee-badenabled.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$bad_enabled_proj")
mkdir -p "$bad_enabled_proj/.specrelay"
cat > "$bad_enabled_proj/.specrelay/config.yml" <<'YAML'
version: 1
execution_efficiency:
  enabled: "yes"
YAML
specrelay::config::execution_efficiency_policy "$bad_enabled_proj" >/dev/null
specrelay_test::assert_eq "invalid top-level enabled fails (exit 1)" "1" "$?"

# =============================================================================
# Invalid negative limits fail
# =============================================================================
bad_neg_proj="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ee-badneg.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$bad_neg_proj")
mkdir -p "$bad_neg_proj/.specrelay"
cat > "$bad_neg_proj/.specrelay/config.yml" <<'YAML'
version: 1
execution_efficiency:
  reviewer:
    exploration_warning_calls: -5
YAML
bad_neg_out="$(specrelay::config::execution_efficiency_policy "$bad_neg_proj")"
specrelay_test::assert_eq "negative limit fails (exit 1)" "1" "$?"
specrelay_test::assert_contains "negative limit error is clear" "$bad_neg_out" "non-negative integer"

# =============================================================================
# Unknown keys fail (top-level and nested)
# =============================================================================
bad_unknown_proj="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ee-badunknown.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$bad_unknown_proj")
mkdir -p "$bad_unknown_proj/.specrelay"
cat > "$bad_unknown_proj/.specrelay/config.yml" <<'YAML'
version: 1
execution_efficiency:
  bogus_top_key: true
YAML
bad_unknown_out="$(specrelay::config::execution_efficiency_policy "$bad_unknown_proj")"
specrelay_test::assert_eq "unknown top-level key fails (exit 1)" "1" "$?"
specrelay_test::assert_contains "unknown key error names the key" "$bad_unknown_out" "bogus_top_key"

bad_unknown_nested_proj="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ee-badunknown2.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$bad_unknown_nested_proj")
mkdir -p "$bad_unknown_nested_proj/.specrelay"
cat > "$bad_unknown_nested_proj/.specrelay/config.yml" <<'YAML'
version: 1
execution_efficiency:
  executor:
    bogus_nested_key: 5
YAML
specrelay::config::execution_efficiency_policy "$bad_unknown_nested_proj" >/dev/null
specrelay_test::assert_eq "unknown nested key fails (exit 1)" "1" "$?"

echo
specrelay_test::summary
