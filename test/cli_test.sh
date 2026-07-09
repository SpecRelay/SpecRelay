#!/usr/bin/env bash
# cli_test.sh — tests for basic SpecRelay CLI behavior (version/help/unknown
# command/project root/unimplemented commands). Run directly:
#   tools/specrelay/test/cli_test.sh

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

# --- 10. unimplemented run command exits non-zero and says so explicitly ----
run_output="$("$SPECRELAY_BIN" run 2>&1)"
rc=$?
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$rc" -ne 0 ]; then
  echo "ok - 'run' exits non-zero"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "NOT OK - 'run' exits non-zero (got 0)"
fi
specrelay_test::assert_contains "'run' explicitly says execution is not available yet" \
  "$run_output" "not available in incubation version 0.1"

for cmd in task review; do
  out="$("$SPECRELAY_BIN" "$cmd" 2>&1)"
  rc=$?
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$rc" -ne 0 ]; then
    echo "ok - '$cmd' exits non-zero"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "NOT OK - '$cmd' exits non-zero (got 0)"
  fi
  specrelay_test::assert_contains "'$cmd' explicitly says execution is not available yet" \
    "$out" "not available in incubation version 0.1"
done

specrelay_test::summary
exit $?
