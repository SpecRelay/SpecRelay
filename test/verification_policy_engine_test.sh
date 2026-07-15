#!/usr/bin/env bash
# verification_policy_engine_test.sh — configuration parsing/validation,
# changed-path selection, flexible/risk-rule resolution, legacy translation,
# and doctor/CLI integration for the verification-policy ENGINE (spec 0026,
# "Configurable Verification Policy and Multi-Service Execution").
#
# NOT to be confused with verification_policy_test.sh (spec 0019's bounded
# run-count policy) — a different, older spec that happens to share the
# `verification:` config key at a disjoint set of sub-keys (see config.sh).
# Execution (bounded parallel, dependencies, evidence, timeouts) is covered
# separately in verification_multi_service_test.sh.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/config.sh
. "$SPECRELAY_ROOT/lib/specrelay/config.sh"
# shellcheck source=../lib/specrelay/verification_policy.sh
. "$SPECRELAY_ROOT/lib/specrelay/verification_policy.sh"
# shellcheck source=../lib/specrelay/verification_runner.sh
. "$SPECRELAY_ROOT/lib/specrelay/verification_runner.sh"

specrelay_test::write_config() {
  local proj="$1" body="$2"
  mkdir -p "$proj/.specrelay"
  printf '%s\n' "$body" > "$proj/.specrelay/config.yml"
}

specrelay_test::vpe_mode() {
  specrelay::verification_policy::mode "$1" 2>/dev/null | head -n1
}

# =============================================================================
# 43.5 (absent): no config file at all -> mode "absent"
# =============================================================================
noconf="$(specrelay_test::mktemp_project)"
specrelay_test::assert_eq "no config at all resolves to mode 'absent'" "absent" "$(specrelay_test::vpe_mode "$noconf")"

# =============================================================================
# 43.1: legacy single-command configuration continues to work
# =============================================================================
legacy_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$legacy_proj" '
version: 1
validation:
  full_test_command: "echo legacy-ok"
'
specrelay_test::assert_eq "legacy validation.full_test_command resolves to mode legacy" "legacy" "$(specrelay_test::vpe_mode "$legacy_proj")"

legacy_plan="$(specrelay::verification_policy::plan "$legacy_proj" executor full '[]' "" --json 2>/dev/null)"
specrelay_test::assert_contains "legacy translation exposes identity project.full-test" "$legacy_plan" '"project.full-test"'

# =============================================================================
# 43.2: a valid multi-service configuration is accepted
# =============================================================================
valid_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$valid_proj" '
version: 1
verification:
  defaults:
    concurrency: 3
  services:
    - name: backend
      root: services/backend
      affected_paths:
        - "services/backend/**"
      checks:
        - name: unit
          kind: unit
          command: "echo backend-unit"
          required: true
          levels: [changed, full]
    - name: frontend
      root: services/frontend
      affected_paths:
        - "services/frontend/**"
      checks:
        - name: unit
          kind: unit
          command: "echo frontend-unit"
          required: true
          levels: [changed, full]
'
specrelay_test::assert_eq "valid multi-service configuration resolves to mode new" "new" "$(specrelay_test::vpe_mode "$valid_proj")"

# =============================================================================
# 43.3: unknown fields fail validation
# =============================================================================
unknown_top_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$unknown_top_proj" '
version: 1
verification:
  bogus_top_field: true
  services: []
'
specrelay_test::assert_contains "unknown top-level verification.* field is rejected" \
  "$(specrelay_test::vpe_mode "$unknown_top_proj")" "invalid:"

unknown_check_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$unknown_check_proj" '
version: 1
verification:
  services:
    - name: backend
      checks:
        - name: unit
          command: "echo ok"
          bogus_check_field: 1
'
specrelay_test::assert_contains "unknown check field is rejected" \
  "$(specrelay_test::vpe_mode "$unknown_check_proj")" "unknown key"

# =============================================================================
# 43.4: duplicate service names fail validation
# =============================================================================
dup_service_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$dup_service_proj" '
version: 1
verification:
  services:
    - name: backend
      checks:
        - name: unit
          command: "echo a"
    - name: backend
      checks:
        - name: unit
          command: "echo b"
'
specrelay_test::assert_contains "duplicate service name is rejected" \
  "$(specrelay_test::vpe_mode "$dup_service_proj")" "duplicate service name"

# =============================================================================
# 43.5: duplicate check identities fail validation
# =============================================================================
dup_check_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$dup_check_proj" '
version: 1
verification:
  services:
    - name: backend
      checks:
        - name: unit
          command: "echo a"
        - name: unit
          command: "echo b"
'
specrelay_test::assert_contains "duplicate check name inside one service is rejected" \
  "$(specrelay_test::vpe_mode "$dup_check_proj")" "duplicate check name"

# =============================================================================
# Ambiguity: simultaneous legacy AND new configuration must fail (spec 22/36)
# =============================================================================
ambiguous_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$ambiguous_proj" '
version: 1
validation:
  full_test_command: "echo legacy"
verification:
  services:
    - name: backend
      checks:
        - name: unit
          command: "echo ok"
'
ambiguous_mode="$(specrelay_test::vpe_mode "$ambiguous_proj")"
specrelay_test::assert_contains "simultaneous legacy+new configuration is an ambiguity error" "$ambiguous_mode" "invalid:"
specrelay_test::assert_contains "ambiguity error names both configurations" "$ambiguous_mode" "ambiguity"

# =============================================================================
# 43.23: unsafe (absolute/traversing) cwd is rejected
# =============================================================================
unsafe_cwd_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$unsafe_cwd_proj" '
version: 1
verification:
  services:
    - name: backend
      checks:
        - name: unit
          command: "echo ok"
          cwd: "../escape"
'
specrelay_test::assert_contains "traversing cwd is rejected" "$(specrelay_test::vpe_mode "$unsafe_cwd_proj")" "invalid cwd"

unsafe_root_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$unsafe_root_proj" '
version: 1
verification:
  services:
    - name: backend
      root: "/etc"
      checks:
        - name: unit
          command: "echo ok"
'
specrelay_test::assert_contains "absolute service root is rejected" "$(specrelay_test::vpe_mode "$unsafe_root_proj")" "invalid root"

# =============================================================================
# 43.24: unknown dependency identity fails validation
# =============================================================================
unknown_dep_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$unknown_dep_proj" '
version: 1
verification:
  services:
    - name: backend
      checks:
        - name: unit
          command: "echo ok"
          depends_on: ["backend.nonexistent"]
'
specrelay_test::assert_contains "unknown dependency is rejected" "$(specrelay_test::vpe_mode "$unknown_dep_proj")" "unknown check"

# =============================================================================
# 43.6/43.7/43.8: changed selection, shared path, unmatched-path fallback
# =============================================================================
multi_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$multi_proj" '
version: 1
verification:
  defaults:
    changed_fallback: full
  services:
    - name: backend
      root: services/backend
      affected_paths:
        - "services/backend/**"
        - "shared/contracts/**"
      checks:
        - name: unit
          command: "echo backend-unit"
          required: true
          levels: [changed, full]
    - name: frontend
      root: services/frontend
      affected_paths:
        - "services/frontend/**"
        - "shared/contracts/**"
      checks:
        - name: unit
          command: "echo frontend-unit"
          required: true
          levels: [changed, full]
'

changed_backend_only="$(specrelay::verification_policy::plan "$multi_proj" executor changed '["services/backend/app.rb"]' "" --json 2>/dev/null)"
specrelay_test::assert_contains "changed selection picks only the affected service" "$changed_backend_only" '"backend"'
specrelay_test::assert_not_contains "changed selection excludes the unaffected service" "$changed_backend_only" '"frontend"'
specrelay_test::assert_contains "changed effective level stays 'changed' when every path matches" "$changed_backend_only" '"effective_level": "changed"'
specrelay_test::assert_contains "the engine explains WHICH file matched WHICH service (spec section 11.1)" \
  "$changed_backend_only" '"services/backend/app.rb"'

shared_both="$(specrelay::verification_policy::plan "$multi_proj" executor changed '["shared/contracts/api.proto"]' "" --json 2>/dev/null)"
specrelay_test::assert_contains "a shared path selects backend" "$shared_both" '"backend"'
specrelay_test::assert_contains "a shared path selects frontend too" "$shared_both" '"frontend"'

unmatched_plan="$(specrelay::verification_policy::plan "$multi_proj" executor changed '["random/unrelated.txt"]' "" --json 2>/dev/null)"
specrelay_test::assert_contains "an unmatched changed path triggers the configured fallback" "$unmatched_plan" '"effective_level": "full"'
specrelay_test::assert_contains "fallback reason is recorded" "$unmatched_plan" "changed_fallback"

# =============================================================================
# 43.9: full level selects every configured full-level required check
# =============================================================================
full_plan="$(specrelay::verification_policy::plan "$multi_proj" executor full '[]' "" --json 2>/dev/null)"
specrelay_test::assert_contains "full level selects backend.unit" "$full_plan" "backend.unit"
specrelay_test::assert_contains "full level selects frontend.unit" "$full_plan" "frontend.unit"

# =============================================================================
# 43.11: a risk rule elevates changed to full
# =============================================================================
risk_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$risk_proj" '
version: 1
verification:
  services:
    - name: backend
      root: services/backend
      affected_paths: ["services/backend/**"]
      checks:
        - name: unit
          command: "echo ok"
          required: true
          levels: [changed, full]
  risk_rules:
    - name: shared-contract-change
      paths: ["shared/contracts/**"]
      force_level: full
      rationale: Shared contracts may affect every service.
'
risk_plan="$(specrelay::verification_policy::plan "$risk_proj" executor changed '["services/backend/app.rb", "shared/contracts/x.proto"]' "" --json 2>/dev/null)"
specrelay_test::assert_contains "matched risk rule escalates changed to full" "$risk_plan" '"effective_level": "full"'
specrelay_test::assert_contains "matched risk rule is recorded by name" "$risk_plan" "shared-contract-change"

# =============================================================================
# 43.10: flexible resolves deterministically and records why
# =============================================================================
flex_multi_service="$(specrelay::verification_policy::plan "$multi_proj" executor flexible '["services/backend/a.rb", "services/frontend/b.js"]' "" --json 2>/dev/null)"
specrelay_test::assert_contains "flexible escalates to full when multiple services are touched" "$flex_multi_service" '"effective_level": "full"'
specrelay_test::assert_contains "flexible records why it escalated" "$flex_multi_service" "distinct services"

flex_single_service="$(specrelay::verification_policy::plan "$multi_proj" executor flexible '["services/backend/a.rb"]' "" --json 2>/dev/null)"
specrelay_test::assert_contains "flexible with a single affected service stays at 'changed'" "$flex_single_service" '"effective_level": "changed"'

# =============================================================================
# 43.25: placement policy resolves correctly (targeted narrows to required)
# =============================================================================
placement_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$placement_proj" '
version: 1
verification:
  placement:
    executor: changed
    reviewer: targeted
    final_gate: full
  services:
    - name: backend
      root: services/backend
      affected_paths: ["services/backend/**"]
      checks:
        - name: unit
          command: "echo ok"
          required: true
          levels: [changed, full]
        - name: lint
          command: "echo ok"
          required: false
          levels: [changed, full]
'
targeted_plan="$(specrelay::verification_policy::plan "$placement_proj" reviewer "" '["services/backend/a.rb"]' "" --json 2>/dev/null)"
specrelay_test::assert_contains "'targeted' placement selects the required check" "$targeted_plan" "backend.unit"
specrelay_test::assert_contains "'targeted' placement narrows away the optional check (recorded as skipped, not selected)" \
  "$targeted_plan" "optional check excluded by 'targeted' placement narrowing"

# legacy mode has no "none" placement configured (only new-engine configs do);
# exercise 'none' directly against a configured placement instead:
none_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$none_proj" '
version: 1
verification:
  placement:
    executor: none
  services:
    - name: backend
      checks:
        - name: unit
          command: "echo ok"
'
none_plan="$(specrelay::verification_policy::plan "$none_proj" executor "" '[]' "" --json 2>/dev/null)"
specrelay_test::assert_contains "'none' placement selects nothing" "$none_plan" '"selected_checks": []'

# =============================================================================
# 43.26: wasteful full-suite-everywhere configuration produces a warning
# =============================================================================
wasteful_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$wasteful_proj" '
version: 1
verification:
  placement:
    executor: full
    reviewer: full
    final_gate: full
  services:
    - name: backend
      checks:
        - name: unit
          command: "echo ok"
'
wasteful_mode_full="$(specrelay::verification_policy::mode "$wasteful_proj" 2>/dev/null)"
specrelay_test::assert_contains "identical full-suite placement everywhere produces a warning" "$wasteful_mode_full" "warning:"
specrelay_test::assert_eq "the wasteful-configuration warning is still mode 'new' (advisory, not fatal)" "new" "$(printf '%s\n' "$wasteful_mode_full" | head -n1)"

# =============================================================================
# 43.28: arbitrary AI-provided command text is rejected, never executed
# =============================================================================
reject_proj="$valid_proj"
reject_out="$(specrelay::verification_runner::check_request "$reject_proj" executor full '[]' '["rm -rf /", "backend.unit"]' 2>/dev/null)"
specrelay_test::assert_contains "an arbitrary shell-text 'check' identity is rejected" "$reject_out" '"valid": false'
specrelay_test::assert_contains "rejection names the unconfigured identity" "$reject_out" "not configured"

exclude_required_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$exclude_required_proj" '
version: 1
verification:
  services:
    - name: backend
      checks:
        - name: unit
          command: "echo ok"
          required: true
          levels: [changed, full]
        - name: lint
          command: "echo ok"
          required: false
          levels: [changed, full]
'
disable_required_out="$(specrelay::verification_runner::check_request "$exclude_required_proj" executor full '[]' '["backend.lint"]' 2>/dev/null)"
specrelay_test::assert_contains "a request cannot disable/exclude a required check" "$disable_required_out" '"valid": false'
specrelay_test::assert_contains "disabling-a-required-check rejection explains why" "$disable_required_out" "required check"

narrow_out="$(specrelay::verification_runner::check_request "$exclude_required_proj" executor full '[]' '["backend.unit"]' 2>/dev/null)"
specrelay_test::assert_contains "a genuinely narrower, policy-permitted request (drops only the optional check) is accepted" "$narrow_out" '"valid": true'

# =============================================================================
# 43.31: doctor reports new/legacy/invalid/absent states accurately
# =============================================================================
doctor_new="$(cd "$valid_proj" && SPECRELAY_PROVIDER_OPTIONAL=1 "$SPECRELAY_BIN" doctor 2>&1)"
specrelay_test::assert_contains "doctor reports mode=new for a new-engine configuration" "$doctor_new" "mode=new"

doctor_legacy="$(cd "$legacy_proj" && SPECRELAY_PROVIDER_OPTIONAL=1 "$SPECRELAY_BIN" doctor 2>&1)"
specrelay_test::assert_contains "doctor reports the legacy engine mode honestly" "$doctor_legacy" "mode=legacy"

doctor_invalid="$(cd "$dup_service_proj" && SPECRELAY_PROVIDER_OPTIONAL=1 "$SPECRELAY_BIN" doctor 2>&1)"
specrelay_test::assert_contains "doctor fails clearly on an invalid verification-engine configuration" "$doctor_invalid" "Verification-policy engine: INVALID"

doctor_absent="$(cd "$noconf" && SPECRELAY_PROVIDER_OPTIONAL=1 "$SPECRELAY_BIN" doctor 2>&1)"
specrelay_test::assert_contains "doctor reports absent when nothing is configured" "$doctor_absent" "Verification-policy engine (spec 0026): absent"

# =============================================================================
# CLI: 'specrelay verification plan' is read-only and never runs a command
# =============================================================================
cli_plan_out="$(cd "$valid_proj" && "$SPECRELAY_BIN" verification plan --level full --phase executor 2>&1)"
specrelay_test::assert_contains "'verification plan' CLI reports the effective level" "$cli_plan_out" "effective_level: full"
[ ! -d "$valid_proj/verification" ]
specrelay_test::assert_true "'verification plan' never creates evidence files (no execution)" "$?"

specrelay_test::summary
exit $?
