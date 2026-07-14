#!/usr/bin/env bash
# update_command_test.sh — spec 0022, section 4: explicit update commands
# (--check, --dry-run, --from, --yes, --ignore, --reset-notifications),
# atomic staging/verification/rollback, and concurrent-update locking. Uses a
# REAL local Git repository as the "official" update source (no network) with
# two tagged releases, and a REAL temp-prefix install as the installed
# SpecRelay under test.
#
#   test/update_command_test.sh
#
# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

INSTALL_SH="$SPECRELAY_ROOT/install/install.sh"
SOURCE_VERSION="$(tr -d '[:space:]' < "$SPECRELAY_ROOT/VERSION")"

# --- fixture: a local "official" upstream repo with two tagged releases ----
WORK="$(specrelay_test::mktemp_project)"
UPSTREAM="$WORK/upstream"
mkdir -p "$UPSTREAM"
cp -R "$SPECRELAY_ROOT"/. "$UPSTREAM"/
rm -rf "$UPSTREAM/.git" "$UPSTREAM/.specrelay-runs" "$UPSTREAM/.specrelay-cache" "$UPSTREAM/.specrelay-locks"
(
  cd "$UPSTREAM" \
    && git init -q \
    && git config core.hooksPath /dev/null \
    && git config user.name "SpecRelay Test" \
    && git config user.email "specrelay-test@example.invalid" \
    && git add -A \
    && git commit -q -m "v9.9.9" \
    && git tag v9.9.9
)
echo "9.9.10" > "$UPSTREAM/VERSION"
(cd "$UPSTREAM" && git add -A && git commit -q -m "v9.9.10" && git tag v9.9.10)

PREFIX="$WORK/prefix"
"$INSTALL_SH" --prefix "$PREFIX" >/dev/null 2>&1
INSTALLED="$PREFIX/bin/specrelay"
SHARE="$PREFIX/share/specrelay"
META="$SHARE/install-metadata.json"

specrelay_test::_point_update_source() {
  python3 -c '
import json, sys
meta, repo = sys.argv[1], sys.argv[2]
d = json.load(open(meta))
d["update_source"] = {"type": "official-git", "repository": repo, "ref": "main"}
json.dump(d, open(meta, "w"))
' "$META" "$1"
}
specrelay_test::_point_update_source "$UPSTREAM"

specrelay::run_installed() {
  env -u SPECRELAY_HOME "$@"
}

# --- 1. source-local refusal: bin/specrelay update never mutates -----------
src_update_out="$("$SPECRELAY_BIN" update --check 2>&1)"
src_rc=$?
specrelay_test::assert_true "'bin/specrelay update' refuses (non-zero) in source-local mode" "$( [ "$src_rc" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "source-local update explains it is not applicable" "$src_update_out" "not applicable"

# --- 2. --check: read-only discovery, bypasses cache, never mutates --------
check_out="$(specrelay::run_installed "$INSTALLED" update --check 2>&1)"
check_rc=$?
specrelay_test::assert_eq "'update --check' with a newer release exits 0" "0" "$check_rc"
specrelay_test::assert_contains "'update --check' reports the installed version" "$check_out" "Installed version: $SOURCE_VERSION"
specrelay_test::assert_contains "'update --check' reports the available version" "$check_out" "Available version: 9.9.10"
specrelay_test::assert_contains "'update --check' reports an update is available" "$check_out" "An update is available"
specrelay_test::assert_eq "'update --check' never changes the installed VERSION" "$SOURCE_VERSION" "$(tr -d '[:space:]' < "$SHARE/VERSION")"

# --- 3. --dry-run: shows a plan, mutates nothing ----------------------------
dry_out="$(specrelay::run_installed "$INSTALLED" update --dry-run 2>&1)"
specrelay_test::assert_contains "'update --dry-run' shows the current installation" "$dry_out" "Current installation:"
specrelay_test::assert_contains "'update --dry-run' shows the proposed version" "$dry_out" "Proposed version:     9.9.10"
specrelay_test::assert_contains "'update --dry-run' names its verification steps" "$dry_out" "Verification steps:"
specrelay_test::assert_eq "'update --dry-run' never changes the installed VERSION" "$SOURCE_VERSION" "$(tr -d '[:space:]' < "$SHARE/VERSION")"

# --- 4. --from: structural validation + dirty-checkout refusal -------------
not_a_source="$WORK/not-a-source"
mkdir -p "$not_a_source"
from_bad_out="$(specrelay::run_installed "$INSTALLED" update --from "$not_a_source" --yes 2>&1)"
from_bad_rc=$?
specrelay_test::assert_true "'update --from' refuses a non-SpecRelay directory" "$( [ "$from_bad_rc" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "'update --from' names the structural problem" "$from_bad_out" "valid SpecRelay source checkout"

echo "dirty change" >> "$UPSTREAM/README.md"
dirty_out="$(specrelay::run_installed "$INSTALLED" update --from "$UPSTREAM" --yes 2>&1)"
dirty_rc=$?
specrelay_test::assert_true "'update --from' refuses a dirty source checkout" "$( [ "$dirty_rc" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "'update --from' explains the dirty-checkout refusal" "$dirty_out" "uncommitted changes"
# git diff --quiet exits 1 when a diff exists — i.e. the dirty change must
# STILL be present (never reset/overwritten by the refused update attempt).
(cd "$UPSTREAM" && git diff --quiet README.md)
specrelay_test::assert_true "the dirty source tree itself is never reset/overwritten" \
  "$( [ "$?" -ne 0 ]; echo $? )"
(cd "$UPSTREAM" && git checkout -q -- README.md)

# --- 5. successful --yes update: stage, verify, activate, proof ------------
yes_out="$(specrelay::run_installed "$INSTALLED" update --yes 2>&1)"
yes_rc=$?
specrelay_test::assert_eq "'update --yes' exits 0 on a genuine newer release" "0" "$yes_rc"
specrelay_test::assert_contains "'update --yes' prints the installed version as proof" "$yes_out" "Installed version: specrelay 9.9.10"
specrelay_test::assert_contains "'update --yes' prints the installed commit as proof" "$yes_out" "Installed commit:"
new_version="$(specrelay::run_installed "$INSTALLED" version 2>&1)"
specrelay_test::assert_eq "the installed launcher now reports the new version" "specrelay 9.9.10" "$new_version"
specrelay_test::assert_true "no leftover staging/old directories remain after activation" \
  "$( ls "$PREFIX/share" | grep -Eq '\.(staging|old|failed)-' && echo 1 || echo 0 )"

# --- 6. already up to date: no mutation, exit 0 -----------------------------
already_out="$(specrelay::run_installed "$INSTALLED" update --yes 2>&1)"
specrelay_test::assert_contains "re-running update when already current reports up to date" "$already_out" "Already up to date"
specrelay_test::assert_eq "re-running update when already current exits 0" "0" "$?"

# --- 7. --ignore / --reset-notifications ------------------------------------
ignore_out="$(specrelay::run_installed "$INSTALLED" update --ignore 42.0.0 2>&1)"
specrelay_test::assert_contains "'update --ignore <version>' confirms it will not be offered again" "$ignore_out" "will not be offered again"
ignored_field="$(python3 -c 'import json; print(json.load(open("'"$SHARE/update-state.json"'"))["ignored_version"])' 2>/dev/null)"
specrelay_test::assert_eq "ignored_version is persisted in update-state.json" "42.0.0" "$ignored_field"

reset_out="$(specrelay::run_installed "$INSTALLED" update --reset-notifications 2>&1)"
specrelay_test::assert_contains "'update --reset-notifications' confirms the state was cleared" "$reset_out" "cleared"
specrelay_test::assert_true "update-state.json is removed after --reset-notifications" \
  "$( [ ! -f "$SHARE/update-state.json" ]; echo $? )"

# --- 8. staged-payload verification failure preserves the current install --
BROKEN="$WORK/broken-source"
cp -R "$UPSTREAM" "$BROKEN"
rm -rf "$BROKEN/.git"
echo "42.0.0" > "$BROKEN/VERSION"
# Corrupt cli.sh's very FIRST line: bash still finishes sourcing every OTHER
# lib file, but specrelay::cli::main itself never gets defined, so the
# staged launcher probe genuinely fails (rather than a trailing corruption,
# which — since bash defines each function as it parses past it — would
# leave every function defined before the bad line fully usable).
printf 'this is not valid bash(\n%s' "$(cat "$BROKEN/lib/specrelay/cli.sh")" > "$BROKEN/lib/specrelay/cli.sh"
before_version="$(specrelay::run_installed "$INSTALLED" version 2>&1)"
broken_out="$(specrelay::run_installed "$INSTALLED" update --from "$BROKEN" --yes 2>&1)"
broken_rc=$?
specrelay_test::assert_true "a broken staged payload fails verification (non-zero)" "$( [ "$broken_rc" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "a failed verification names the problem" "$broken_out" "verification"
after_version="$(specrelay::run_installed "$INSTALLED" version 2>&1)"
specrelay_test::assert_eq "the prior installation is completely untouched after a failed update" "$before_version" "$after_version"
specrelay_test::assert_true "no stale staging directory is left behind after a failed update" \
  "$( ls "$PREFIX/share" | grep -Eq '\.staging-' && echo 1 || echo 0 )"

# --- 8b. post-activation verification failure rolls back, not deletes ------
# Regression test for a defect where _activate removed the prior install
# (<share>.old-<tag>) immediately on a successful swap, so when the SEPARATE
# post-activation re-verification (11.2) failed, _rollback had nothing left
# to restore and the whole installation was destroyed. This fixture makes the
# PRE-activation probe (run against the staging dir) pass normally, and the
# POST-activation probe (run against the same directory, now renamed to the
# live share path by _activate) fail: the staged `version` command drops a
# canary marker file into $SPECRELAY_HOME on its first invocation, and that
# marker travels with the directory across the `mv` from staging to share, so
# the SECOND invocation (post-activation, against the same underlying files)
# detects the marker and reports a corrupted version instead.
POSTACT="$WORK/postact-source"
cp -R "$UPSTREAM" "$POSTACT"
rm -rf "$POSTACT/.git"
echo "9.9.11" > "$POSTACT/VERSION"
PATCH_PY="$WORK/patch_postact_version.py"
cat > "$PATCH_PY" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = r'''specrelay::cli::version() {
  local home="$1"
  local version_file="$home/VERSION"
  if [ ! -f "$version_file" ]; then
    specrelay::out::err "VERSION file not found: $version_file"
    return 1
  fi
  printf 'specrelay %s\n' "$(tr -d '[:space:]' < "$version_file")"
}'''
new = r'''specrelay::cli::version() {
  local home="$1"
  local version_file="$home/VERSION"
  local canary="$home/.postact-canary"
  if [ ! -f "$version_file" ]; then
    specrelay::out::err "VERSION file not found: $version_file"
    return 1
  fi
  if [ -f "$canary" ]; then
    printf 'specrelay CORRUPTED-POST-ACTIVATION\n'
    return 0
  fi
  : > "$canary"
  printf 'specrelay %s\n' "$(tr -d '[:space:]' < "$version_file")"
}'''
assert old in src, "version() body drifted from expected fixture text"
open(path, "w").write(src.replace(old, new, 1))
PYEOF
python3 "$PATCH_PY" "$POSTACT/lib/specrelay/cli.sh"

before_postact_version="$(specrelay::run_installed "$INSTALLED" version 2>&1)"
before_snapshot="$(find "$SHARE" -type f | sort | xargs shasum 2>/dev/null)"

postact_out="$(specrelay::run_installed "$INSTALLED" update --from "$POSTACT" --yes 2>&1)"
postact_rc=$?
specrelay_test::assert_true "a post-activation verification failure exits non-zero" \
  "$( [ "$postact_rc" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "the failure names the post-activation step" "$postact_out" "post-activation"
specrelay_test::assert_contains "the failure explains a rollback occurred" "$postact_out" "rolling back"
specrelay_test::assert_not_contains "a failed update never prints the success proof line (the original command is not treated as having succeeded)" \
  "$postact_out" "Installed version: specrelay"

after_postact_version="$(specrelay::run_installed "$INSTALLED" version 2>&1)"
specrelay_test::assert_eq "the prior installed version is restored after a post-activation rollback" \
  "$before_postact_version" "$after_postact_version"

after_snapshot="$(find "$SHARE" -type f | sort | xargs shasum 2>/dev/null)"
specrelay_test::assert_eq "the prior installation is restored byte-for-byte after a post-activation rollback" \
  "$before_snapshot" "$after_snapshot"

specrelay_test::assert_true "no leftover .old-/.staging-/.failed- directories remain after a post-activation rollback" \
  "$( ls "$PREFIX/share" | grep -Eq '\.(staging|old|failed)-' && echo 1 || echo 0 )"

# --- 9. concurrent update locking (stale-lock reclaim) ----------------------
# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/update.sh
. "$SPECRELAY_ROOT/lib/specrelay/update.sh"
specrelay::update::_lock_acquire "$SHARE"
specrelay_test::assert_true "first update-lock acquire succeeds" "$?"
( specrelay::update::_lock_acquire "$SHARE" )
specrelay_test::assert_true "a second concurrent acquire is refused while the first is held" "$([ $? -ne 0 ] && echo 0 || echo 1)"
specrelay::update::_lock_release "$SHARE"
specrelay::update::_lock_acquire "$SHARE"
specrelay_test::assert_true "acquire succeeds again after release" "$?"
specrelay::update::_lock_release "$SHARE"

specrelay_test::summary
exit $?
