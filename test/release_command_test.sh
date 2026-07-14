#!/usr/bin/env bash
# release_command_test.sh — spec 0022, sections 8-9 and 10: release-impact
# metadata validation, release plan/prepare/verify/tag, and the 0.5.0
# baseline. Exercises the REAL bin/specrelay against isolated temp copies of
# this source tree (never the developer's real checkout, never a real push).
#
#   test/release_command_test.sh
#
# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# --- 1. VERSION is 0.5.0, version command reports it, honest changelog -----
specrelay_test::assert_eq "VERSION is 0.5.0" "0.5.0" "$(tr -d '[:space:]' < "$SPECRELAY_ROOT/VERSION")"
version_out="$("$SPECRELAY_BIN" version 2>&1)"
specrelay_test::assert_eq "'specrelay version' reports 0.5.0" "specrelay 0.5.0" "$version_out"
changelog="$(cat "$SPECRELAY_ROOT/CHANGELOG.md")"
specrelay_test::assert_contains "CHANGELOG.md has a 0.5.0 entry" "$changelog" "## 0.5.0"
specrelay_test::assert_contains "CHANGELOG.md's 0.5.0 entry references spec 0022" "$changelog" "spec 0022"

# --- 2. release plan is read-only and reports the current version -----------
plan_out="$("$SPECRELAY_BIN" release plan 2>&1)"
specrelay_test::assert_eq "'release plan' exits 0" "0" "$?"
specrelay_test::assert_contains "'release plan' reports the current version" "$plan_out" "Current version: 0.5.0"
version_after_plan="$(tr -d '[:space:]' < "$SPECRELAY_ROOT/VERSION")"
specrelay_test::assert_eq "'release plan' never mutates VERSION" "0.5.0" "$version_after_plan"

# --- 3. release-impact metadata validation (isolated fixture copy) ---------
WORK="$(specrelay_test::mktemp_project)"
FIXTURE="$WORK/specrelay-src"
mkdir -p "$FIXTURE"
cp -R "$SPECRELAY_ROOT"/. "$FIXTURE"/
rm -rf "$FIXTURE/.git" "$FIXTURE/.specrelay-runs" "$FIXTURE/.specrelay-cache" "$FIXTURE/.specrelay-locks"
(cd "$FIXTURE" && git init -q && git config core.hooksPath /dev/null \
  && git config user.name "SpecRelay Test" && git config user.email "specrelay-test@example.invalid" \
  && git add -A && git commit -q -m "baseline 0.5.0")

# 3a. no pending specs after 0022 yet -> nothing to prepare.
plan_none="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release plan 2>&1)"
specrelay_test::assert_contains "with no specs after 0022, pending impact is none" "$plan_none" "Pending impact: none"

# 3b. a valid 'minor' spec after 0022 is discovered and proposes a minor bump.
mkdir -p "$FIXTURE/docs/specs/0023-example-feature"
cat > "$FIXTURE/docs/specs/0023-example-feature/spec.md" <<'SPEC'
# Spec 0023 — Example feature

## Status

Proposed

release:
  impact: minor
  rationale: Adds a new public CLI command.

## Summary

An example.
SPEC
plan_minor="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release plan 2>&1)"
specrelay_test::assert_contains "a pending minor spec is listed in the plan" "$plan_minor" "0023-example-feature"
specrelay_test::assert_contains "pre-1.0 minor bump proposes 0.6.0" "$plan_minor" "Proposed version: 0.6.0"

# 3c. an INVALID impact value is reported as an error, not silently accepted.
mkdir -p "$FIXTURE/docs/specs/0024-bad-impact"
cat > "$FIXTURE/docs/specs/0024-bad-impact/spec.md" <<'SPEC'
# Spec 0024 — Bad impact

release:
  impact: huge
  rationale: not a real impact level

## Summary
SPEC
plan_bad="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release plan 2>&1)"
specrelay_test::assert_contains "an invalid impact value is reported as an error" "$plan_bad" "0024-bad-impact"
specrelay_test::assert_contains "the error names the impact/rationale problem" "$plan_bad" "impact"
rm -rf "$FIXTURE/docs/specs/0024-bad-impact"

# 3d. a 'patch' impact proposes a patch bump only.
rm -rf "$FIXTURE/docs/specs/0023-example-feature"
mkdir -p "$FIXTURE/docs/specs/0023-patch-fix"
cat > "$FIXTURE/docs/specs/0023-patch-fix/spec.md" <<'SPEC'
# Spec 0023 — Patch fix

release:
  impact: patch
  rationale: Fixes a backward-compatible defect.

## Summary
SPEC
plan_patch="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release plan 2>&1)"
specrelay_test::assert_contains "a pending patch spec proposes 0.5.1" "$plan_patch" "Proposed version: 0.5.1"

# --- 4. release prepare updates VERSION/CHANGELOG, shows a diff, never commits
prepare_out="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release prepare 2>&1)"
specrelay_test::assert_eq "'release prepare' exits 0" "0" "$?"
specrelay_test::assert_contains "'release prepare' reports the VERSION bump" "$prepare_out" "0.5.0 -> 0.5.1"
specrelay_test::assert_contains "'release prepare' shows a diff" "$prepare_out" "Diff:"
specrelay_test::assert_contains "'release prepare' confirms nothing was committed/tagged/pushed" "$prepare_out" "Nothing was committed, tagged, or pushed."
specrelay_test::assert_eq "'release prepare' actually wrote the new VERSION" "0.5.1" "$(tr -d '[:space:]' < "$FIXTURE/VERSION")"
dirty_status="$(cd "$FIXTURE" && git status --porcelain)"
specrelay_test::assert_true "'release prepare' leaves the change UNCOMMITTED" "$( [ -n "$dirty_status" ]; echo $? )"

# --- 5. release verify checks syntax/monotonicity/changelog/version proof --
verify_out="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release verify 2>&1)"
specrelay_test::assert_eq "'release verify' passes for a properly prepared release" "0" "$?"
specrelay_test::assert_contains "'release verify' confirms valid semver syntax" "$verify_out" "valid semantic version syntax"
specrelay_test::assert_contains "'release verify' confirms a CHANGELOG.md entry" "$verify_out" "CHANGELOG.md mentions 0.5.1"
specrelay_test::assert_contains "'release verify' confirms source-local version proof" "$verify_out" "reports 0.5.1"

# A version that regressed relative to CHANGELOG must FAIL verify.
echo "0.1.0" > "$FIXTURE/VERSION"
verify_bad="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release verify 2>&1)"
verify_bad_rc=$?
specrelay_test::assert_true "'release verify' fails when CHANGELOG has no entry for VERSION" "$( [ "$verify_bad_rc" -ne 0 ]; echo $? )"
echo "0.5.1" > "$FIXTURE/VERSION"

# --- 6. release tag: clean tree required, creates vX.Y.Z, never pushes -----
tag_dirty_out="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release tag 2>&1)"
tag_dirty_rc=$?
specrelay_test::assert_true "'release tag' refuses a dirty working tree" "$( [ "$tag_dirty_rc" -ne 0 ]; echo $? )"

(cd "$FIXTURE" && git add -A && git commit -q -m "Release 0.5.1")
tag_out="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release tag 2>&1)"
specrelay_test::assert_eq "'release tag' succeeds on a clean tree" "0" "$?"
specrelay_test::assert_contains "'release tag' creates the vX.Y.Z tag" "$tag_out" "v0.5.1"
specrelay_test::assert_contains "'release tag' confirms nothing was pushed" "$tag_out" "Nothing was pushed."
tag_exists="$(cd "$FIXTURE" && git rev-parse -q --verify refs/tags/v0.5.1 >/dev/null 2>&1; echo $?)"
specrelay_test::assert_eq "the v0.5.1 tag actually exists" "0" "$tag_exists"

# A second attempt at the same tag must refuse the conflict.
tag_conflict_out="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release tag 2>&1)"
tag_conflict_rc=$?
specrelay_test::assert_true "'release tag' refuses an existing tag conflict" "$( [ "$tag_conflict_rc" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "'release tag' names the conflicting tag" "$tag_conflict_out" "already exists"

# --- 7. release commands are refused in installed mode ----------------------
PREFIX="$WORK/prefix"
"$SPECRELAY_ROOT/install/install.sh" --prefix "$PREFIX" >/dev/null 2>&1
installed_release_out="$(env -u SPECRELAY_HOME "$PREFIX/bin/specrelay" release plan 2>&1)"
installed_release_rc=$?
specrelay_test::assert_true "'release plan' refuses in installed mode" "$( [ "$installed_release_rc" -ne 0 ]; echo $? )"

specrelay_test::summary
exit $?
