#!/usr/bin/env bash
# cli_test.sh — tests for basic SpecRelay CLI behavior (version/help/unknown
# command/project root/unimplemented commands). Run directly:

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# --- 1. `version` returns the VERSION file value ----------------------------
expected_version="specrelay $(tr -d '[:space:]' < "$SPECRELAY_ROOT/VERSION")"
actual_version="$("$SPECRELAY_BIN" version)"
specrelay_test::assert_eq "version prints the VERSION file's contents" \
  "$expected_version" "$actual_version"

# --- 2. help, --help, -h exit 0 ----------------------------------------------
for flag in help --help -h; do
  "$SPECRELAY_BIN" "$flag" >/dev/null 2>&1
  specrelay_test::assert_true "'$flag' exits 0" "$?"
done

# --- 3. unknown command exits non-zero ---------------------------------------
"$SPECRELAY_BIN" totally-bogus-command >/dev/null 2>&1
rc=$?
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$rc" -ne 0 ]; then
  echo "ok - unknown command exits non-zero"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "NOT OK - unknown command exits non-zero (got 0)"
fi

# --- 4. project root works from the project root -----------------------------
proj="$(specrelay_test::mktemp_project)"
root_from_root="$(cd "$proj" && "$SPECRELAY_BIN" project root)"
specrelay_test::assert_eq "project root works from the project root" \
  "$proj" "$root_from_root"

# --- 5. project root works from a nested directory ---------------------------
mkdir -p "$proj/a/b/c"
root_from_nested="$(cd "$proj/a/b/c" && "$SPECRELAY_BIN" project root)"
specrelay_test::assert_eq "project root works from a nested directory" \
  "$proj" "$root_from_nested"

# --- 10. `run` with no spec argument is a usage error, not a crash ---------
run_output="$("$SPECRELAY_BIN" run 2>&1)"
rc=$?
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$rc" -ne 0 ]; then
  echo "ok - 'run' with no spec argument exits non-zero"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "NOT OK - 'run' with no spec argument exits non-zero (got 0)"
fi
specrelay_test::assert_contains "'run' with no spec argument reports a clear usage error" \
  "$run_output" "input-path"

# --- 11. `run` with a missing spec file fails clearly (not a crash) ---------
proj_run="$(specrelay_test::mktemp_specrelay_project)"
missing_out="$(cd "$proj_run" && "$SPECRELAY_BIN" run docs/sdd/does-not-exist/spec.md 2>&1)"
rc=$?
specrelay_test::assert_true "'run' with a missing spec file exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "'run' with a missing spec file names the missing file" \
  "$missing_out" "not found"

# --- 12. `review` remains an explicitly unimplemented command ---------------
out="$("$SPECRELAY_BIN" review 2>&1)"
rc=$?
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$rc" -ne 0 ]; then
  echo "ok - 'review' exits non-zero"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "NOT OK - 'review' exits non-zero (got 0)"
fi
specrelay_test::assert_contains "'review' explicitly says it is not implemented" \
  "$out" "not implemented"

# --- 13. `task` with no subcommand is a clear usage error -------------------
task_out="$("$SPECRELAY_BIN" task 2>&1)"
rc=$?
specrelay_test::assert_true "'task' with no subcommand exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "'task' with no subcommand reports usage" "$task_out" "usage"

# --- 14. `show`/`status`/`resume` on an unknown task fail clearly -----------
for cmd in "show 9999-nope" "status 9999-nope" "resume 9999-nope"; do
  out="$(cd "$proj_run" && "$SPECRELAY_BIN" $cmd 2>&1)"
  rc=$?
  specrelay_test::assert_true "'$cmd' on an unknown task exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
done

# --- 15. `list`/`status` with no tasks report cleanly, not an error ---------
empty_proj="$(specrelay_test::mktemp_project)"
list_out="$(cd "$empty_proj" && "$SPECRELAY_BIN" list 2>&1)"
rc=$?
specrelay_test::assert_eq "'list' with no tasks exits 0" "0" "$rc"
specrelay_test::assert_contains "'list' with no tasks says so" "$list_out" "No tasks found"

specrelay_test::summary
exit $?
