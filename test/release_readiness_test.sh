#!/usr/bin/env bash
# release_readiness_test.sh — spec 0007: the standalone repository is
# release-ready. Verifies (without any network access or real GitHub Actions
# execution):
#   1. a CI workflow exists and runs the baseline verification commands, on PRs
#      and pushes to main, without requiring real Claude;
#   2. release/version docs document VERSION and a Git-tag policy;
#   3. the license state is coherent (pending a human decision, recorded
#      honestly — no arbitrary license added);
#   4. the fresh-clone/install smoke script exists, is executable, and is
#      syntactically valid;
#   5. `specrelay doctor` is deterministic in a no-Claude environment: a hard
#      failure by default, an advisory (still exit 0) under
#      SPECRELAY_PROVIDER_OPTIONAL=1, with core checks mandatory either way;
#   6. minimum requirements + environment variables are documented.
#
# This test deliberately does NOT invoke scripts/smoke or scripts/test (both run
# the whole suite, which would recurse); it checks their existence/shape and
# exercises the doctor behavior change directly. Run: test/release_readiness_test.sh
#
# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

CI_FILE="$SPECRELAY_ROOT/.github/workflows/ci.yml"
VERSIONING_DOC="$SPECRELAY_ROOT/docs/versioning.md"
INSTALL_DOC="$SPECRELAY_ROOT/docs/installation.md"
SMOKE="$SPECRELAY_ROOT/scripts/smoke"

# --- 1. CI workflow exists and contains the baseline commands ----------------
specrelay_test::assert_true "CI workflow .github/workflows/ci.yml exists" \
  "$( [ -f "$CI_FILE" ]; echo $? )"
ci="$(cat "$CI_FILE" 2>/dev/null)"
specrelay_test::assert_contains "CI runs scripts/test" "$ci" "scripts/test"
specrelay_test::assert_contains "CI runs bin/specrelay doctor" "$ci" "bin/specrelay doctor"
specrelay_test::assert_contains "CI runs bin/specrelay version" "$ci" "bin/specrelay version"
specrelay_test::assert_contains "CI triggers on pull_request" "$ci" "pull_request"
specrelay_test::assert_contains "CI triggers on push to main" "$ci" "main"
specrelay_test::assert_contains "CI does not require real Claude (provider-optional)" \
  "$ci" "SPECRELAY_PROVIDER_OPTIONAL"

# --- 2. Version / tag policy documented --------------------------------------
ver="$(cat "$VERSIONING_DOC" 2>/dev/null)"
specrelay_test::assert_contains "versioning doc references the VERSION file" "$ver" "VERSION"
specrelay_test::assert_contains "versioning doc documents a Git-tag policy" "$ver" "tag"

# --- 3. License state is coherent (pending human decision) -------------------
specrelay_test::assert_true "LICENSE.TODO placeholder exists (license decision recorded)" \
  "$( [ -f "$SPECRELAY_ROOT/LICENSE.TODO" ]; echo $? )"
readme="$(cat "$SPECRELAY_ROOT/README.md" 2>/dev/null)"
specrelay_test::assert_contains "README makes license status discoverable" "$readme" "LICENSE.TODO"

# --- 4. Fresh-clone / install smoke script -----------------------------------
specrelay_test::assert_true "scripts/smoke exists" "$( [ -f "$SMOKE" ]; echo $? )"
specrelay_test::assert_true "scripts/smoke is executable" "$( [ -x "$SMOKE" ]; echo $? )"
bash -n "$SMOKE" 2>/dev/null
specrelay_test::assert_true "scripts/smoke is syntactically valid (bash -n)" "$?"
smoke="$(cat "$SMOKE" 2>/dev/null)"
specrelay_test::assert_contains "smoke runs the test suite" "$smoke" "scripts/test"
specrelay_test::assert_contains "smoke checks doctor" "$smoke" "doctor"
specrelay_test::assert_contains "smoke checks version" "$smoke" "version"

# --- 5. Doctor is deterministic in a no-Claude environment -------------------
# A project that CONFIGURES the claude executor, run with SPECRELAY_CLAUDE_BIN
# pointed at a name that does not exist on PATH, deterministically simulates an
# absent Claude CLI regardless of what is installed on this machine.
proj="$(specrelay_test::mktemp_project)"
mkdir -p "$proj/.specrelay" "$proj/docs/sdd"
cat > "$proj/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: Claude Fixture
specs:
  root: docs/sdd
tasks:
  runs_root: .specrelay-runs/tasks
  max_iterations: 3
roles:
  executor:
    provider: claude
  reviewer:
    provider: manual
context:
  adapter: none
  required: false
validation:
  full_test_command: "echo ok"
policy:
  human_final_review_required: true
YAML
NO_CLAUDE="specrelay-nonexistent-claude-xyz"

# Default (strict): absent configured provider is a MANDATORY failure. Unset
# SPECRELAY_PROVIDER_OPTIONAL explicitly so this case is genuinely strict even
# if the caller's environment happens to have it set (e.g. under CI).
strict_out="$(cd "$proj" && env -u SPECRELAY_PROVIDER_OPTIONAL SPECRELAY_CLAUDE_BIN="$NO_CLAUDE" "$SPECRELAY_BIN" doctor 2>&1)"
strict_rc=$?
specrelay_test::assert_true "doctor exits non-zero when a configured provider CLI is absent (strict default)" \
  "$( [ "$strict_rc" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "doctor names the missing claude executor (strict)" \
  "$strict_out" "Executor provider: claude"
specrelay_test::assert_contains "doctor reports the provider CLI not found (strict)" \
  "$strict_out" "not found on PATH"

# Provider-optional: same absence becomes an advisory warning, doctor exits 0,
# and the core checks still pass.
opt_out="$(cd "$proj" && SPECRELAY_PROVIDER_OPTIONAL=1 SPECRELAY_CLAUDE_BIN="$NO_CLAUDE" "$SPECRELAY_BIN" doctor 2>&1)"
opt_rc=$?
specrelay_test::assert_eq "doctor exits 0 with an absent provider under SPECRELAY_PROVIDER_OPTIONAL=1" \
  "0" "$opt_rc"
specrelay_test::assert_contains "doctor marks the absent provider as advisory (provider-optional)" \
  "$opt_out" "advisory"
specrelay_test::assert_contains "doctor still reports overall success (provider-optional)" \
  "$opt_out" "all checks passed"

# A genuine CORE failure is NOT hidden by provider-optional mode: a project with
# NO config still fails even under SPECRELAY_PROVIDER_OPTIONAL=1.
proj_nocfg="$(specrelay_test::mktemp_project)"
core_out="$(cd "$proj_nocfg" && SPECRELAY_PROVIDER_OPTIONAL=1 "$SPECRELAY_BIN" doctor 2>&1)"
core_rc=$?
specrelay_test::assert_true "provider-optional does not hide a core failure (missing config still fails)" \
  "$( [ "$core_rc" -ne 0 ]; echo $? )"

# --- 6. Requirements + environment variables documented ----------------------
inst="$(cat "$INSTALL_DOC" 2>/dev/null)"
specrelay_test::assert_contains "requirements doc documents Bash" "$inst" "Bash"
specrelay_test::assert_contains "requirements doc documents python3" "$inst" "python3"
specrelay_test::assert_contains "requirements doc documents ruby" "$inst" "ruby"
specrelay_test::assert_contains "requirements doc documents Claude optionality" "$inst" "optional"
specrelay_test::assert_contains "requirements doc documents SPECRELAY_HOME" "$inst" "SPECRELAY_HOME"
specrelay_test::assert_contains "requirements doc documents SPECRELAY_PROVIDER_OPTIONAL" \
  "$inst" "SPECRELAY_PROVIDER_OPTIONAL"

specrelay_test::summary
exit $?
