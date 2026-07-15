#!/usr/bin/env bash
# verification_multi_service_test.sh — bounded parallel execution,
# dependency-graph enforcement, timeouts, required/optional semantics,
# per-check evidence isolation, and environment redaction for the
# verification-policy ENGINE (spec 0026). Configuration parsing/selection is
# covered separately in verification_policy_engine_test.sh.
#
# Uses test/fixtures/verification-fixture.sh (spec section 44, "Fake
# verification support") as every configured `command:` — never a real
# language toolchain, so this suite stays deterministic and hermetic.

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

FIXTURE="$SPECRELAY_ROOT/test/fixtures/verification-fixture.sh"

specrelay_test::write_config() {
  local proj="$1" body="$2"
  mkdir -p "$proj/.specrelay"
  printf '%s\n' "$body" > "$proj/.specrelay/config.yml"
}

specrelay_test::run_engine() {
  # run_engine <root> <task_dir> <phase> <level>
  specrelay::verification_runner::run "$1" "$2" testtask 1 "$3" "$4" '[]' '[]' --json 2>/dev/null
}

# =============================================================================
# 43.12 / 43.13: dependency order + dependency failure -> BLOCKED_BY_DEPENDENCY
# =============================================================================
dep_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$dep_proj" "
version: 1
verification:
  services:
    - name: backend
      checks:
        - name: unit
          command: \"$FIXTURE --exit 0\"
          required: true
          levels: [full]
        - name: integration
          command: \"$FIXTURE --exit 0\"
          required: true
          levels: [full]
          depends_on: [backend.unit]
"
dep_task="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-verify-dep.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$dep_task")
dep_summary="$(specrelay_test::run_engine "$dep_proj" "$dep_task" executor full)"
specrelay_test::assert_contains "dependency order: overall PASSED when the dependency passes" "$dep_summary" '"overall_status": "PASSED"'
integ_started="$(python3 -c "import json;d=json.load(open('$dep_task/27-verification-summary.json'));print([c for c in d['checks'] if c['identity']=='backend.integration'][0]['status'])")"
specrelay_test::assert_eq "the dependent check actually ran after its dependency passed" "PASSED" "$integ_started"

fail_dep_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$fail_dep_proj" "
version: 1
verification:
  services:
    - name: backend
      checks:
        - name: unit
          command: \"$FIXTURE --exit 7\"
          required: true
          levels: [full]
        - name: integration
          command: \"$FIXTURE --exit 0\"
          required: true
          levels: [full]
          depends_on: [backend.unit]
"
fail_dep_task="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-verify-faildep.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$fail_dep_task")
specrelay_test::run_engine "$fail_dep_proj" "$fail_dep_task" executor full >/dev/null
dep_status="$(python3 -c "import json;d=json.load(open('$fail_dep_task/27-verification-summary.json'));print([c['status'] for c in d['checks'] if c['identity']=='backend.integration'][0])")"
specrelay_test::assert_eq "a dependent check becomes BLOCKED_BY_DEPENDENCY when its dependency fails" "BLOCKED_BY_DEPENDENCY" "$dep_status"
specrelay_test::assert_contains "overall status reflects the blocked required check" \
  "$(cat "$fail_dep_task/27-verification-summary.json")" '"overall_status": "BLOCKED"'

# =============================================================================
# 43.15 / 43.16: parallel execution within the bound + deterministic ordering
# =============================================================================
par_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$par_proj" "
version: 1
verification:
  defaults:
    concurrency: 4
  services:
    - name: backend
      checks:
        - name: a
          command: \"$FIXTURE --exit 0 --sleep 1\"
          required: true
          levels: [full]
        - name: b
          command: \"$FIXTURE --exit 0 --sleep 1\"
          required: true
          levels: [full]
        - name: c
          command: \"$FIXTURE --exit 0 --sleep 1\"
          required: true
          levels: [full]
"
par_task="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-verify-par.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$par_task")
par_start="$(date +%s)"
specrelay_test::run_engine "$par_proj" "$par_task" executor full >/dev/null
par_elapsed=$(( $(date +%s) - par_start ))
# Three independent 1s checks run concurrently (concurrency: 4) should take
# well under the ~3s serial sum. Generous bound for slow/loaded CI hosts.
[ "$par_elapsed" -lt 3 ]
specrelay_test::assert_true "independent checks execute concurrently within the configured limit" "$?"

order_out="$(python3 -c "import json;d=json.load(open('$par_task/27-verification-summary.json'));print(','.join(c['identity'] for c in d['checks']))")"
specrelay_test::assert_eq "final report ordering is declaration order regardless of completion order" \
  "backend.a,backend.b,backend.c" "$order_out"

# =============================================================================
# 43.14: dependency cycle fails before any execution
# =============================================================================
cycle_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$cycle_proj" "
version: 1
verification:
  services:
    - name: backend
      checks:
        - name: a
          command: \"$FIXTURE --exit 0\"
          depends_on: [backend.b]
        - name: b
          command: \"$FIXTURE --exit 0\"
          depends_on: [backend.a]
"
cycle_task="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-verify-cycle.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$cycle_task")
cycle_out="$(specrelay_test::run_engine "$cycle_proj" "$cycle_task" executor full)"
specrelay_test::assert_eq "a dependency cycle refuses to run (nonzero exit)" "1" "$?"
[ ! -f "$cycle_task/27-verification-summary.json" ]
specrelay_test::assert_true "a rejected cyclic config never produces execution evidence" "$?"

# =============================================================================
# 43.17 / 43.18: timeout (required fails the gate; optional does not)
# =============================================================================
timeout_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$timeout_proj" "
version: 1
verification:
  services:
    - name: backend
      checks:
        - name: slow_required
          command: \"$FIXTURE --sleep 5\"
          required: true
          timeout_seconds: 1
          levels: [full]
        - name: slow_optional
          command: \"$FIXTURE --sleep 5\"
          required: false
          timeout_seconds: 1
          levels: [full]
"
timeout_task="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-verify-timeout.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$timeout_task")
timeout_start="$(date +%s)"
specrelay_test::run_engine "$timeout_proj" "$timeout_task" executor full >/dev/null
timeout_elapsed=$(( $(date +%s) - timeout_start ))
[ "$timeout_elapsed" -lt 4 ]
specrelay_test::assert_true "a timed-out process is actually terminated (does not run to completion)" "$?"
timeout_summary="$(cat "$timeout_task/27-verification-summary.json")"
specrelay_test::assert_contains "a required timed-out check fails the gate" "$timeout_summary" '"overall_status": "FAILED"'
req_status="$(python3 -c "import json;d=json.load(open('$timeout_task/27-verification-summary.json'));print([c['status'] for c in d['checks'] if c['identity']=='backend.slow_required'][0])")"
opt_status="$(python3 -c "import json;d=json.load(open('$timeout_task/27-verification-summary.json'));print([c['status'] for c in d['checks'] if c['identity']=='backend.slow_optional'][0])")"
specrelay_test::assert_eq "the required check is recorded TIMED_OUT" "TIMED_OUT" "$req_status"
specrelay_test::assert_eq "the optional check is recorded TIMED_OUT_OPTIONAL (visible, not gate-failing)" "TIMED_OUT_OPTIONAL" "$opt_status"

# =============================================================================
# 43.19 / 43.20: required failure fails the gate; optional failure does not
# =============================================================================
fail_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$fail_proj" "
version: 1
verification:
  services:
    - name: backend
      checks:
        - name: req
          command: \"$FIXTURE --exit 1\"
          required: true
          levels: [full]
        - name: opt
          command: \"$FIXTURE --exit 1\"
          required: false
          levels: [full]
"
fail_task="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-verify-fail.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$fail_task")
specrelay_test::run_engine "$fail_proj" "$fail_task" executor full >/dev/null
fail_rc=$?
specrelay_test::assert_eq "a required non-zero exit fails the gate (nonzero engine exit)" "1" "$fail_rc"
fail_summary="$(cat "$fail_task/27-verification-summary.json")"
specrelay_test::assert_contains "overall status is FAILED" "$fail_summary" '"overall_status": "FAILED"'
specrelay_test::assert_contains "the optional failure is still visible in the summary" "$fail_summary" '"optional_failed": 1'

# =============================================================================
# 43.21 / 43.22: per-check evidence isolation, no output mixing
# =============================================================================
mix_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$mix_proj" "
version: 1
verification:
  defaults:
    concurrency: 4
  services:
    - name: backend
      checks:
        - name: alpha
          command: \"$FIXTURE --exit 0 --stdout ALPHA_MARKER --stderr ALPHA_ERR\"
          required: true
          levels: [full]
        - name: beta
          command: \"$FIXTURE --exit 0 --stdout BETA_MARKER --stderr BETA_ERR\"
          required: true
          levels: [full]
"
mix_task="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-verify-mix.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$mix_task")
specrelay_test::run_engine "$mix_proj" "$mix_task" executor full >/dev/null

alpha_out="$(cat "$mix_task/verification/services/backend/alpha/stdout.txt")"
beta_out="$(cat "$mix_task/verification/services/backend/beta/stdout.txt")"
specrelay_test::assert_contains "alpha's own stdout file has its own marker" "$alpha_out" "ALPHA_MARKER"
specrelay_test::assert_not_contains "alpha's stdout is never contaminated by beta's output" "$alpha_out" "BETA_MARKER"
specrelay_test::assert_contains "beta's own stdout file has its own marker" "$beta_out" "BETA_MARKER"
specrelay_test::assert_not_contains "beta's stdout is never contaminated by alpha's output" "$beta_out" "ALPHA_MARKER"

for f in command.json stdout.txt stderr.txt result.json; do
  [ -f "$mix_task/verification/services/backend/alpha/$f" ]
  specrelay_test::assert_true "alpha has its own $f evidence file" "$?"
  [ -f "$mix_task/verification/services/backend/beta/$f" ]
  specrelay_test::assert_true "beta has its own $f evidence file" "$?"
done

# =============================================================================
# 43.32: no silent skip — a missing required command/cwd never becomes pass
# =============================================================================
missing_cwd_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$missing_cwd_proj" '
version: 1
verification:
  services:
    - name: backend
      root: services/does-not-exist
      checks:
        - name: unit
          command: "echo should-not-run"
          required: true
          levels: [full]
'
missing_cwd_task="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-verify-missingcwd.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$missing_cwd_task")
specrelay_test::run_engine "$missing_cwd_proj" "$missing_cwd_task" executor full >/dev/null
missing_status="$(python3 -c "import json;d=json.load(open('$missing_cwd_task/27-verification-summary.json'));print(d['checks'][0]['status'])")"
specrelay_test::assert_eq "a missing configured cwd is CONFIGURATION_ERROR, never a silent pass" "CONFIGURATION_ERROR" "$missing_status"
specrelay_test::assert_contains "a required CONFIGURATION_ERROR blocks the overall gate" \
  "$(cat "$missing_cwd_task/27-verification-summary.json")" '"overall_status": "BLOCKED"'

# =============================================================================
# 43.33: deleted/renamed paths participate in changed-path matching
# =============================================================================
rename_root="$(specrelay_test::mktemp_project)"
mkdir -p "$rename_root/services/backend"
specrelay_test::write_config "$rename_root" '
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
'
echo "content" > "$rename_root/services/backend/old_name.rb"
(cd "$rename_root" && git add -A && git commit -q -m "add file")
(cd "$rename_root" && git mv services/backend/old_name.rb services/backend/new_name.rb)
changed_json="$(specrelay::verification_policy::changed_paths "$rename_root")"
specrelay_test::assert_contains "changed-path discovery includes the renamed file's OLD path" "$changed_json" "old_name.rb"
specrelay_test::assert_contains "changed-path discovery includes the renamed file's NEW path" "$changed_json" "new_name.rb"
rename_plan="$(specrelay::verification_policy::plan "$rename_root" executor changed "$changed_json" "" --json 2>/dev/null)"
specrelay_test::assert_contains "a rename within an affected service still selects that service" "$rename_plan" '"backend"'

# =============================================================================
# 43.34: secret-shaped environment variable NAMES are redacted from evidence
# =============================================================================
env_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$env_proj" "
version: 1
verification:
  services:
    - name: backend
      checks:
        - name: unit
          command: \"$FIXTURE --exit 0\"
          required: true
          levels: [full]
          environment: [RAILS_ENV, DATABASE_URL, API_KEY_FOO]
"
env_task="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-verify-env.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$env_task")
DATABASE_URL="postgres://user:supersecret@localhost/db" API_KEY_FOO="topsecretvalue" \
  specrelay_test::run_engine "$env_proj" "$env_task" executor full >/dev/null
command_json="$(cat "$env_task/verification/services/backend/unit/command.json")"
specrelay_test::assert_contains "command.json records the non-secret environment name" "$command_json" "RAILS_ENV"
specrelay_test::assert_contains "command.json marks DATABASE_URL as redacted" "$command_json" '"DATABASE_URL"'
specrelay_test::assert_not_contains "no secret VALUE ever appears in durable evidence" "$command_json" "supersecret"
specrelay_test::assert_not_contains "no secret VALUE ever appears in durable evidence (API key)" "$command_json" "topsecretvalue"

# The check itself still received the real value (spec: "environment" is a
# passthrough of names, not a value store) — proven via the fixture's own
# --assert-env, which fails the check (nonzero exit) if the real value was
# NOT actually present in the child process environment.
env_assert_proj="$(specrelay_test::mktemp_project)"
specrelay_test::write_config "$env_assert_proj" "
version: 1
verification:
  services:
    - name: backend
      checks:
        - name: unit
          command: \"$FIXTURE --exit 0 --assert-env MY_VAR=expected-value\"
          required: true
          levels: [full]
          environment: [MY_VAR]
"
env_assert_task="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-verify-envassert.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$env_assert_task")
MY_VAR="expected-value" specrelay_test::run_engine "$env_assert_proj" "$env_assert_task" executor full >/dev/null
env_assert_rc=$?
specrelay_test::assert_eq "the configured environment variable is genuinely passed through to the check process" "0" "$env_assert_rc"

# =============================================================================
# cwd is genuinely applied (fixture --assert-cwd fails if the runner used the
# wrong working directory)
# =============================================================================
cwd_proj_root="$(specrelay_test::mktemp_project)"
mkdir -p "$cwd_proj_root/services/backend"
specrelay_test::write_config "$cwd_proj_root" "
version: 1
verification:
  services:
    - name: backend
      root: services/backend
      checks:
        - name: unit
          command: \"$FIXTURE --exit 0 --assert-cwd $cwd_proj_root/services/backend\"
          required: true
          levels: [full]
"
cwd_task="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-verify-cwd.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$cwd_task")
specrelay_test::run_engine "$cwd_proj_root" "$cwd_task" executor full >/dev/null
specrelay_test::assert_eq "the configured cwd is genuinely applied when launching the check" "0" "$?"

specrelay_test::summary
exit $?
