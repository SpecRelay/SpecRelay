#!/usr/bin/env bash
# install_upgrade_test.sh — spec 0008: public installation & upgrade readiness.
#
# Deterministic, network-free coverage for the install / upgrade / uninstall /
# consumer-bootstrap story (spec section 8). It exercises the REAL installer,
# uninstaller, and the INSTALLED executable in a temporary prefix, so a fresh
# user's journey is proven — not just documented. It never touches the real
# repository install, never needs Claude, and never accesses the network.
#
# Because the shared harness pins SPECRELAY_HOME to this source tree (so the
# suite tests the in-repo code), every invocation of the freshly INSTALLED
# executable below runs under `env -u SPECRELAY_HOME` so it resolves its OWN
# home from the temp prefix (the exact thing an end user's install does).
#
#   test/install_upgrade_test.sh
#
# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

INSTALL_SH="$SPECRELAY_ROOT/install/install.sh"
UNINSTALL_SH="$SPECRELAY_ROOT/install/uninstall.sh"
UPDATE_SH="$SPECRELAY_ROOT/install/update.sh"
SOURCE_VERSION="$(tr -d '[:space:]' < "$SPECRELAY_ROOT/VERSION")"

# A temp prefix under the test temp area (reused by several cases). We create a
# throwaway git project only to get a tracked temp dir; we install UNDER it.
WORK="$(specrelay_test::mktemp_project)"
PREFIX="$WORK/prefix"
INSTALLED="$PREFIX/bin/specrelay"

# --- 1. installer installs into a temporary prefix/bin directory -------------
"$INSTALL_SH" --prefix "$PREFIX" >/dev/null 2>&1
specrelay_test::assert_true "installer exits 0 into a temp prefix" "$?"
specrelay_test::assert_true "installed executable exists at <prefix>/bin/specrelay" \
  "$( [ -x "$INSTALLED" ]; echo $? )"
specrelay_test::assert_true "installed resources exist at <prefix>/share/specrelay" \
  "$( [ -d "$PREFIX/share/specrelay/lib/specrelay" ]; echo $? )"

# --- 2. installed `specrelay version` works and matches VERSION --------------
installed_version_out="$(env -u SPECRELAY_HOME "$INSTALLED" version 2>&1)"
specrelay_test::assert_true "installed 'version' exits 0" "$?"
specrelay_test::assert_eq "installed 'version' matches the source VERSION" \
  "specrelay $SOURCE_VERSION" "$installed_version_out"

# --- 3. reinstall / upgrade over an existing install (idempotent) ------------
reinstall_out="$("$INSTALL_SH" --prefix "$PREFIX" --force 2>&1)"
specrelay_test::assert_true "reinstall over existing install exits 0 (upgrade path)" "$?"
specrelay_test::assert_eq "installed 'version' still works after reinstall" \
  "specrelay $SOURCE_VERSION" "$(env -u SPECRELAY_HOME "$INSTALLED" version 2>&1)"

# The local-source updater refreshes an existing install from a source tree and
# never touches consumer config (it delegates to install.sh --force).
update_out="$("$UPDATE_SH" --from "$SPECRELAY_ROOT" --prefix "$PREFIX" 2>&1)"
specrelay_test::assert_true "update.sh --from a local source exits 0" "$?"
specrelay_test::assert_contains "update.sh reports the installed version" \
  "$update_out" "$SOURCE_VERSION"

# --- 4. installed `doctor` in a fake-provider consumer project (no Claude) ----
# A brand-new consumer with the deterministic fake providers must pass doctor
# with NO Claude and NO provider-optional flag.
fake_proj="$(specrelay_test::mktemp_specrelay_project)"
# The fixture config's spec root is docs/sdd; create it so the (read-only)
# spec-root check has a real directory to find.
mkdir -p "$fake_proj/docs/sdd"
fake_doctor_out="$(cd "$fake_proj" && env -u SPECRELAY_HOME "$INSTALLED" doctor 2>&1)"
fake_doctor_rc=$?
specrelay_test::assert_eq "installed doctor passes in a fake-provider consumer (no Claude)" \
  "0" "$fake_doctor_rc"
specrelay_test::assert_contains "installed doctor reports the fake executor as available" \
  "$fake_doctor_out" "Executor provider: fake"
specrelay_test::assert_contains "installed doctor reports overall success (fake consumer)" \
  "$fake_doctor_out" "all checks passed"

# --- 5. installed `doctor` without Claude unless Claude is configured ---------
# A consumer that DOES configure the claude executor, with the Claude bin name
# pointed at something absent, deterministically simulates "no Claude":
#   - strict default  -> mandatory failure (never silently hidden);
#   - provider-optional -> advisory warning, exit 0, core checks still pass.
claude_proj="$(specrelay_test::mktemp_project)"
mkdir -p "$claude_proj/.specrelay" "$claude_proj/specs"
cat > "$claude_proj/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: Claude Consumer
specs:
  root: specs
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
strict_rc=0
(cd "$claude_proj" && env -u SPECRELAY_HOME -u SPECRELAY_PROVIDER_OPTIONAL \
  SPECRELAY_CLAUDE_BIN="$NO_CLAUDE" "$INSTALLED" doctor >/dev/null 2>&1) || strict_rc=$?
specrelay_test::assert_true "installed doctor fails when a CONFIGURED claude CLI is absent (strict)" \
  "$( [ "$strict_rc" -ne 0 ]; echo $? )"
opt_out="$(cd "$claude_proj" && env -u SPECRELAY_HOME SPECRELAY_PROVIDER_OPTIONAL=1 \
  SPECRELAY_CLAUDE_BIN="$NO_CLAUDE" "$INSTALLED" doctor 2>&1)"
opt_rc=$?
specrelay_test::assert_eq "installed doctor exits 0 with absent provider under provider-optional" \
  "0" "$opt_rc"
specrelay_test::assert_contains "installed doctor marks the absent provider advisory" \
  "$opt_out" "advisory"

# --- 6. temporary consumer can RUN a fake-provider task with installed CLI ----
run_proj="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$run_proj/docs/sdd/0001-install-smoke"
echo "# Install smoke spec" > "$run_proj/docs/sdd/0001-install-smoke/spec.md"
(cd "$run_proj" && git add -A && git commit -q -m "add spec")
run_out="$(cd "$run_proj" && env -u SPECRELAY_HOME "$INSTALLED" run docs/sdd/0001-install-smoke/spec.md 2>&1)"
run_rc=$?
specrelay_test::assert_eq "installed CLI runs a fake-provider task to completion (exit 0)" \
  "0" "$run_rc"
specrelay_test::assert_contains "installed fake run reaches READY_FOR_HUMAN_REVIEW" \
  "$run_out" "READY_FOR_HUMAN_REVIEW"

# --- 7. uninstall removes tool-owned files, preserves consumer .specrelay -----
# Give the fake consumer its OWN install prefix so uninstalling it cannot affect
# the shared PREFIX used by earlier cases.
uconsumer="$(specrelay_test::mktemp_specrelay_project)"
uprefix="$WORK/uprefix"
"$INSTALL_SH" --prefix "$uprefix" >/dev/null 2>&1
uninstall_out="$("$UNINSTALL_SH" --prefix "$uprefix" 2>&1)"
specrelay_test::assert_true "uninstall.sh exits 0" "$?"
specrelay_test::assert_true "uninstall removed <prefix>/bin/specrelay" \
  "$( [ ! -e "$uprefix/bin/specrelay" ]; echo $? )"
specrelay_test::assert_true "uninstall removed <prefix>/share/specrelay" \
  "$( [ ! -e "$uprefix/share/specrelay" ]; echo $? )"
specrelay_test::assert_true "uninstall left the consumer's .specrelay/config.yml untouched" \
  "$( [ -f "$uconsumer/.specrelay/config.yml" ]; echo $? )"
# Idempotent: a second uninstall is a clean no-op, not an error.
"$UNINSTALL_SH" --prefix "$uprefix" >/dev/null 2>&1
specrelay_test::assert_true "uninstall.sh is idempotent (second run exits 0)" "$?"

# Refuses to delete a share/specrelay that is NOT a SpecRelay install.
notours="$WORK/notours"
mkdir -p "$notours/share/specrelay"
echo "not specrelay" > "$notours/share/specrelay/random.txt"
"$UNINSTALL_SH" --prefix "$notours" >/dev/null 2>&1
specrelay_test::assert_true "uninstall refuses to delete a non-SpecRelay share dir (non-zero)" \
  "$( [ "$?" -ne 0 ]; echo $? )"
specrelay_test::assert_true "uninstall did NOT delete the non-SpecRelay directory" \
  "$( [ -f "$notours/share/specrelay/random.txt" ]; echo $? )"

# --- 8. docs reference commands / files that actually exist ------------------
specrelay_test::assert_true "install/uninstall.sh exists" \
  "$( [ -f "$UNINSTALL_SH" ]; echo $? )"
specrelay_test::assert_true "install/uninstall.sh is executable" \
  "$( [ -x "$UNINSTALL_SH" ]; echo $? )"
specrelay_test::assert_true "docs/upgrading.md exists" \
  "$( [ -f "$SPECRELAY_ROOT/docs/upgrading.md" ]; echo $? )"
specrelay_test::assert_true "docs/homebrew.md exists" \
  "$( [ -f "$SPECRELAY_ROOT/docs/homebrew.md" ]; echo $? )"
specrelay_test::assert_true "packaging/homebrew/specrelay.rb exists" \
  "$( [ -f "$SPECRELAY_ROOT/packaging/homebrew/specrelay.rb" ]; echo $? )"

upgrading="$(cat "$SPECRELAY_ROOT/docs/upgrading.md" 2>/dev/null)"
# Honest about the absence of self-update (must NOT claim it exists).
specrelay_test::assert_contains "upgrading doc states there is no specrelay self-update" \
  "$upgrading" "no \`specrelay self-update\`"
specrelay_test::assert_contains "upgrading doc references install/uninstall.sh (which exists)" \
  "$upgrading" "install/uninstall.sh"
specrelay_test::assert_contains "upgrading doc references install/install.sh (which exists)" \
  "$upgrading" "install/install.sh"

homebrew="$(cat "$SPECRELAY_ROOT/docs/homebrew.md" 2>/dev/null)"
specrelay_test::assert_contains "homebrew doc references the sample formula (which exists)" \
  "$homebrew" "packaging/homebrew/specrelay.rb"
specrelay_test::assert_contains "homebrew doc states no tap exists yet" \
  "$homebrew" "No official tap exists"

formula="$(cat "$SPECRELAY_ROOT/packaging/homebrew/specrelay.rb" 2>/dev/null)"
specrelay_test::assert_contains "formula is clearly marked SAMPLE / TEMPLATE" \
  "$formula" "SAMPLE / TEMPLATE"
specrelay_test::assert_contains "formula uses a placeholder (not real) sha256" \
  "$formula" "0000000000000000000000000000000000000000000000000000000000000000"

install_doc="$(cat "$SPECRELAY_ROOT/docs/installation.md" 2>/dev/null)"
specrelay_test::assert_contains "installation doc references install/uninstall.sh" \
  "$install_doc" "install/uninstall.sh"

specrelay_test::summary
exit $?
