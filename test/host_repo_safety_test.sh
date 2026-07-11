#!/usr/bin/env bash
# host_repo_safety_test.sh — regression test for spec 0085 section 66
# ("Mandatory host repository mutation safety"), added after a prior
# execution attempt of this task mutated the HOST repository: a
# compatibility/fixture test renamed real product documentation because it
# lost track of its own isolated temp-dir root and fell back to acting on
# the current directory. That run was discarded; this test proves the
# regression cannot recur silently.
#   tools/specrelay/test/host_repo_safety_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

HOST_ROOT="$SPECRELAY_ROOT"
while [ -n "$HOST_ROOT" ] && [ ! -d "$HOST_ROOT/.git" ]; do
  parent="$(dirname "$HOST_ROOT")"
  [ "$parent" = "$HOST_ROOT" ] && HOST_ROOT="" && break
  HOST_ROOT="$parent"
done
specrelay_test::assert_true "host repository root was discovered for this test run" "$([ -n "$HOST_ROOT" ] && echo 0 || echo 1)"

# A destructive action a real fixture helper might run — implemented here as
# a harmless marker-file write, gated behind the safety check, so this test
# can prove whether the guard ran BEFORE any mutating action without
# actually risking a real mutating git command.
run_guarded_mutation() {
  local candidate="$1" marker="$2"
  if ! specrelay_test::safe_fixture_root_or_abort "$candidate" "$HOST_ROOT"; then
    return 1
  fi
  : > "$marker"
  return 0
}

# Path set only (leading X/Y status code stripped) so an unrelated process
# re-staging already-modified files (index-only, no content change) is never
# a false positive, while a real new/removed/renamed path (what section 66's
# incident actually did) still changes this set and is still caught.
host_status() {
  (cd "$HOST_ROOT" && git status --porcelain --untracked-files=all) | sed -E 's/^.{2} //' | sort
}

# --- capture host safety invariants BEFORE anything below ------------------
before_head="$(cd "$HOST_ROOT" && git rev-parse HEAD)"
before_branch="$(cd "$HOST_ROOT" && git rev-parse --abbrev-ref HEAD)"
before_status="$(host_status)"

marker_dir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-host-safety-marker.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$marker_dir")

# --- Case 1: empty candidate path is rejected, never treated as cwd --------
marker1="$marker_dir/case1.marker"
rc=1
( run_guarded_mutation "" "$marker1" ) ; rc=$?
specrelay_test::assert_true "empty fixture root is rejected before any mutating action" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_true "empty fixture root: no marker file was written" "$([ ! -e "$marker1" ] && echo 0 || echo 1)"

# --- Case 2: nonexistent candidate path is rejected -------------------------
marker2="$marker_dir/case2.marker"
rc=1
( run_guarded_mutation "/nonexistent/path/does-not-exist-$$" "$marker2" ) ; rc=$?
specrelay_test::assert_true "nonexistent fixture root is rejected" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_true "nonexistent fixture root: no marker file was written" "$([ ! -e "$marker2" ] && echo 0 || echo 1)"

# --- Case 3: a path that is not a git repository is rejected ---------------
non_git_dir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-non-git.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$non_git_dir")
marker3="$marker_dir/case3.marker"
rc=1
( run_guarded_mutation "$non_git_dir" "$marker3" ) ; rc=$?
specrelay_test::assert_true "a non-Git-repository fixture root is rejected" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_true "non-Git fixture root: no marker file was written" "$([ ! -e "$marker3" ] && echo 0 || echo 1)"

# --- Case 4: the HOST repository root itself is rejected (this IS the
# exact incident this check exists to prevent) ------------------------------
marker4="$marker_dir/case4.marker"
rc=1
( run_guarded_mutation "$HOST_ROOT" "$marker4" ) ; rc=$?
specrelay_test::assert_true "the HOST repository root is rejected as a fixture root" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_true "HOST repository root: no marker file was written" "$([ ! -e "$marker4" ] && echo 0 || echo 1)"

# --- Case 5: a command-substitution helper that loses its mktemp result in a
# discarded subshell must never silently resolve to something usable --------
lost_subshell_root() {
  ( local d; d="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-lost.XXXXXX")"; SPECRELAY_TEST_TMP_DIRS+=("$d") )
  # $d is NOT visible here: it was set inside a discarded subshell.
  printf '%s' "${d:-}"
}
marker5="$marker_dir/case5.marker"
rc=1
( run_guarded_mutation "$(lost_subshell_root)" "$marker5" ) ; rc=$?
specrelay_test::assert_true "a fixture root lost in a discarded subshell resolves empty and is rejected" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_true "lost-subshell fixture root: no marker file was written" "$([ ! -e "$marker5" ] && echo 0 || echo 1)"

# --- Case 6 (positive control): a genuinely valid, isolated temp fixture is
# accepted, so this guard is not simply refusing everything ----------------
valid_dir="$(specrelay_test::mktemp_project)"
marker6="$marker_dir/case6.marker"
rc=1
( run_guarded_mutation "$valid_dir" "$marker6" ) ; rc=$?
specrelay_test::assert_true "a valid isolated temp fixture root is accepted" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
specrelay_test::assert_true "valid fixture root: marker file WAS written (mutation proceeded only after the guard passed)" "$([ -e "$marker6" ] && echo 0 || echo 1)"

# --- verify host repository safety invariants AFTER the whole test file ----
after_head="$(cd "$HOST_ROOT" && git rev-parse HEAD)"
after_branch="$(cd "$HOST_ROOT" && git rev-parse --abbrev-ref HEAD)"
after_status="$(host_status)"

specrelay_test::assert_eq "host HEAD is unchanged after this test file ran" "$before_head" "$after_head"
specrelay_test::assert_eq "host branch is unchanged after this test file ran" "$before_branch" "$after_branch"
specrelay_test::assert_eq "host working-tree status is unchanged after this test file ran" "$before_status" "$after_status"

specrelay_test::summary
exit $?
