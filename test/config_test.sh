#!/usr/bin/env bash
# config_test.sh — tests for .specrelay/config.yml discovery, loading, and
# error handling (missing / malformed config). Uses only temporary fixture
# directories — never the real repository's .specrelay/config.yml.
#   tools/specrelay/test/config_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# --- 6. project inspect reads .specrelay/config.yml -------------------------
proj="$(specrelay_test::mktemp_project)"
mkdir -p "$proj/.specrelay"
cat > "$proj/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: Fixture Project
specs:
  root: docs/sdd
tasks:
  runs_root: .ai-runs/tasks
validation:
  full_test_command: bin/test
YAML

out="$(cd "$proj" && "$SPECRELAY_BIN" project inspect)"
rc=$?
specrelay_test::assert_eq "project inspect exits 0 with a valid config" "0" "$rc"
specrelay_test::assert_contains "project inspect reports the config as present" \
  "$out" "Config file (.specrelay/config.yml): present"
specrelay_test::assert_contains "project inspect reads project.name" \
  "$out" "Project name: Fixture Project"
specrelay_test::assert_contains "project inspect reads specs.root" \
  "$out" "Configured spec root: docs/sdd"
specrelay_test::assert_contains "project inspect reads tasks.runs_root" \
  "$out" "Configured task-run root: .ai-runs/tasks"
specrelay_test::assert_contains "project inspect reads validation.full_test_command" \
  "$out" "Configured validation command: bin/test"

# --- 7. missing config: library-level error, and a graceful CLI report ------
# lib/specrelay/config.sh's validate() is the codepath a future
# config-requiring command would call; it must fail clearly when the file is
# absent (rather than silently proceeding with empty/default data).
# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/config.sh
. "$SPECRELAY_ROOT/lib/specrelay/config.sh"

proj_noconfig="$(specrelay_test::mktemp_project)"
validate_err="$(specrelay::config::validate "$proj_noconfig" 2>&1)"
rc=$?
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$rc" -ne 0 ]; then
  echo "ok - config validate fails clearly when the config file is missing"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "NOT OK - config validate fails clearly when the config file is missing (got rc=0)"
fi
specrelay_test::assert_contains "missing-config error message names the missing file" \
  "$validate_err" "config not found"

# The CLI itself treats an absent config as a normal (not required) state for
# project/workflow inspect and reports it, rather than crashing.
out_noconfig="$(cd "$proj_noconfig" && "$SPECRELAY_BIN" project inspect)"
rc=$?
specrelay_test::assert_eq "project inspect exits 0 when config is simply absent" "0" "$rc"
specrelay_test::assert_contains "project inspect reports the config as NOT present" \
  "$out_noconfig" "Config file (.specrelay/config.yml): NOT present"

# --- 8. malformed config produces a clear error -----------------------------
proj_bad="$(specrelay_test::mktemp_project)"
mkdir -p "$proj_bad/.specrelay"
printf 'not: [valid: yaml: broken\n' > "$proj_bad/.specrelay/config.yml"

bad_out="$(cd "$proj_bad" && "$SPECRELAY_BIN" project inspect 2>&1)"
rc=$?
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$rc" -ne 0 ]; then
  echo "ok - project inspect fails clearly on a malformed config"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "NOT OK - project inspect fails clearly on a malformed config (got rc=0)"
fi
specrelay_test::assert_contains "malformed-config error message says 'malformed config'" \
  "$bad_out" "malformed config"

# A top-level non-mapping (e.g. a bare list) is also malformed.
proj_bad2="$(specrelay_test::mktemp_project)"
mkdir -p "$proj_bad2/.specrelay"
printf -- '- 1\n- 2\n' > "$proj_bad2/.specrelay/config.yml"
bad2_err="$(specrelay::config::validate "$proj_bad2" 2>&1)"
rc=$?
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$rc" -ne 0 ]; then
  echo "ok - config validate rejects a non-mapping top level"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "NOT OK - config validate rejects a non-mapping top level (got rc=0)"
fi
specrelay_test::assert_contains "non-mapping top-level error message is clear" \
  "$bad2_err" "must be a mapping"

specrelay_test::summary
exit $?
