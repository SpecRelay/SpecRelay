#!/usr/bin/env bash
# release_command_test.sh — spec 0022, sections 8-9 and 10: release-impact
# metadata validation and release plan/prepare/verify/tag. Exercises the REAL
# bin/specrelay against isolated temp copies of this source tree (never the
# developer's real checkout, never a real push).
#
# Version-agnostic by design (review finding 7): the repository VERSION advances
# over time (0.5.0 -> 0.6.0 -> ...), so this suite reads the CURRENT VERSION and
# computes the expected pre-1.0 bumps from it rather than hard-coding a value.
# It also builds a DETERMINISTIC release-impact slate in the fixture by removing
# the repository's own post-0022 specs (which now legitimately carry release:
# metadata), so the "no pending impact" and controlled-bump assertions are
# stable — and so the fixture never contains two directories sharing a spec
# number (which the architecture preflight, spec 0031, rejects).
#
#   test/release_command_test.sh
#
# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# Pre-1.0 bump helpers (mirror lib/specrelay/py/release_lib.py's policy).
bump_minor() { local M m p; IFS=. read -r M m p <<< "$1"; printf '%s.%s.0\n' "$M" "$((m + 1))"; }
bump_patch() { local M m p; IFS=. read -r M m p <<< "$1"; printf '%s.%s.%s\n' "$M" "$m" "$((p + 1))"; }

CURRENT="$(tr -d '[:space:]' < "$SPECRELAY_ROOT/VERSION")"
EXPECT_MINOR="$(bump_minor "$CURRENT")"
EXPECT_PATCH="$(bump_patch "$CURRENT")"

# --- 1. VERSION is reported honestly and has a matching CHANGELOG entry ------
version_out="$("$SPECRELAY_BIN" version 2>&1)"
specrelay_test::assert_eq "'specrelay version' reports the current VERSION" "specrelay $CURRENT" "$version_out"
changelog="$(cat "$SPECRELAY_ROOT/CHANGELOG.md")"
specrelay_test::assert_contains "CHANGELOG.md has a '## $CURRENT' entry" "$changelog" "## $CURRENT"

# --- 2. release plan is read-only and reports the current version -----------
plan_out="$("$SPECRELAY_BIN" release plan 2>&1)"
specrelay_test::assert_eq "'release plan' exits 0" "0" "$?"
specrelay_test::assert_contains "'release plan' reports the current version" "$plan_out" "Current version: $CURRENT"
version_after_plan="$(tr -d '[:space:]' < "$SPECRELAY_ROOT/VERSION")"
specrelay_test::assert_eq "'release plan' never mutates VERSION" "$CURRENT" "$version_after_plan"

# --- 3. release-impact metadata validation (isolated fixture copy) ---------
WORK="$(specrelay_test::mktemp_project)"
FIXTURE="$WORK/specrelay-src"
mkdir -p "$FIXTURE"
cp -R "$SPECRELAY_ROOT"/. "$FIXTURE"/
rm -rf "$FIXTURE/.git" "$FIXTURE/.specrelay-runs" "$FIXTURE/.specrelay-cache" "$FIXTURE/.specrelay-locks"
# Remove the repository's OWN post-0022 specs so the fixture starts with a clean,
# deterministic release-impact slate and no spec-number collisions. The adoption
# boundary stays 31 in architecture-version.yml, and no spec numbered > 31
# remains, so the architecture contract still validates.
for d in "$FIXTURE"/docs/specs/*/; do
  n="$(basename "$d" | grep -oE '^[0-9]{4}' || true)"
  [ -n "$n" ] && [ "$n" -gt 22 ] 2>/dev/null && rm -rf "$d"
done
(cd "$FIXTURE" && git init -q && git config core.hooksPath /dev/null \
  && git config user.name "SpecRelay Test" && git config user.email "specrelay-test@example.invalid" \
  && git add -A && git commit -q -m "baseline $CURRENT")

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
specrelay_test::assert_contains "pre-1.0 minor bump proposes $EXPECT_MINOR" "$plan_minor" "Proposed version: $EXPECT_MINOR"

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
specrelay_test::assert_contains "a pending patch spec proposes $EXPECT_PATCH" "$plan_patch" "Proposed version: $EXPECT_PATCH"

# --- 4. release prepare updates VERSION/CHANGELOG, shows a diff, never commits
prepare_out="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release prepare 2>&1)"
specrelay_test::assert_eq "'release prepare' exits 0" "0" "$?"
specrelay_test::assert_contains "'release prepare' reports the VERSION bump" "$prepare_out" "$CURRENT -> $EXPECT_PATCH"
specrelay_test::assert_contains "'release prepare' shows a diff" "$prepare_out" "Diff:"
specrelay_test::assert_contains "'release prepare' confirms nothing was committed/tagged/pushed" "$prepare_out" "Nothing was committed, tagged, or pushed."
specrelay_test::assert_eq "'release prepare' actually wrote the new VERSION" "$EXPECT_PATCH" "$(tr -d '[:space:]' < "$FIXTURE/VERSION")"
dirty_status="$(cd "$FIXTURE" && git status --porcelain)"
specrelay_test::assert_true "'release prepare' leaves the change UNCOMMITTED" "$( [ -n "$dirty_status" ]; echo $? )"

# --- 5. release verify checks syntax/monotonicity/changelog/version proof --
verify_out="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release verify 2>&1)"
specrelay_test::assert_eq "'release verify' passes for a properly prepared release" "0" "$?"
specrelay_test::assert_contains "'release verify' confirms valid semver syntax" "$verify_out" "valid semantic version syntax"
specrelay_test::assert_contains "'release verify' confirms a CHANGELOG.md entry" "$verify_out" "CHANGELOG.md mentions $EXPECT_PATCH"
specrelay_test::assert_contains "'release verify' confirms source-local version proof" "$verify_out" "reports $EXPECT_PATCH"

# A version that regressed relative to CHANGELOG must FAIL verify.
echo "0.0.1" > "$FIXTURE/VERSION"
verify_bad="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release verify 2>&1)"
verify_bad_rc=$?
specrelay_test::assert_true "'release verify' fails when CHANGELOG has no entry for VERSION" "$( [ "$verify_bad_rc" -ne 0 ]; echo $? )"
echo "$EXPECT_PATCH" > "$FIXTURE/VERSION"

# --- 6. release tag: clean tree required, creates vX.Y.Z, never pushes -----
tag_dirty_out="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release tag 2>&1)"
tag_dirty_rc=$?
specrelay_test::assert_true "'release tag' refuses a dirty working tree" "$( [ "$tag_dirty_rc" -ne 0 ]; echo $? )"

(cd "$FIXTURE" && git add -A && git commit -q -m "Release $EXPECT_PATCH")
tag_out="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release tag 2>&1)"
specrelay_test::assert_eq "'release tag' succeeds on a clean tree" "0" "$?"
specrelay_test::assert_contains "'release tag' creates the vX.Y.Z tag" "$tag_out" "v$EXPECT_PATCH"
specrelay_test::assert_contains "'release tag' confirms nothing was pushed" "$tag_out" "Nothing was pushed."
tag_exists="$(cd "$FIXTURE" && git rev-parse -q --verify "refs/tags/v$EXPECT_PATCH" >/dev/null 2>&1; echo $?)"
specrelay_test::assert_eq "the v$EXPECT_PATCH tag actually exists" "0" "$tag_exists"

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

# --- 8. architecture-contract preflight (spec 0031) ------------------------
# Every release command validates the architecture contract first (the fixture
# copied a ratified repo, so a valid contract lets release proceed).
arch_plan_ok="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release plan 2>&1)"
specrelay_test::assert_contains "'release plan' runs when the architecture contract is valid" "$arch_plan_ok" "Current version:"
# Breaking the contract blocks release plan before any VERSION mutation.
arch_v_before="$(tr -d '[:space:]' < "$FIXTURE/VERSION")"
cp "$FIXTURE/architecture/architecture-version.yml" "$FIXTURE/architecture/architecture-version.yml.bak"
printf 'version: 1\nstatus: bogus\n' > "$FIXTURE/architecture/architecture-version.yml"
arch_plan_bad="$(env -u SPECRELAY_HOME "$FIXTURE/bin/specrelay" release plan 2>&1)"
arch_plan_bad_rc=$?
specrelay_test::assert_true "'release plan' refuses an invalid architecture contract" "$( [ "$arch_plan_bad_rc" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "'release plan' names the architecture problem" "$arch_plan_bad" "architecture"
specrelay_test::assert_eq "'release plan' made no VERSION mutation when blocked" "$arch_v_before" "$(tr -d '[:space:]' < "$FIXTURE/VERSION")"
mv "$FIXTURE/architecture/architecture-version.yml.bak" "$FIXTURE/architecture/architecture-version.yml"

specrelay_test::summary
exit $?
