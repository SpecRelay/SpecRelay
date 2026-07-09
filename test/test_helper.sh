#!/usr/bin/env bash
# test_helper.sh — minimal shared test harness for SpecRelay's own tests.
#
# Deliberately tiny (no external test framework): each test file sources this,
# runs its own checks via the assert_* helpers below, then calls
# specrelay_test::summary at the end and exits with its result.
#
# Tests run in isolated temporary directories (never the real repository) so
# they never depend on, or mutate, this developer's real .ai/ or .ai-runs/
# state, and never depend on the local absolute filesystem path.

set -uo pipefail

SPECRELAY_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECRELAY_ROOT="$(cd "$SPECRELAY_TEST_DIR/.." && pwd)"
SPECRELAY_BIN="$SPECRELAY_ROOT/bin/specrelay"

TESTS_RUN=0
TESTS_FAILED=0

# specrelay_test::mktemp_project
# Creates an isolated temp directory that is also a fresh git repo (so
# project-root discovery behaves like a real project), and prints its
# absolute path. Every created directory is tracked for cleanup at process
# exit via a single trap installed the first time this is called.
SPECRELAY_TEST_TMP_DIRS=()
specrelay_test::_cleanup() {
  local d
  for d in "${SPECRELAY_TEST_TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap specrelay_test::_cleanup EXIT

specrelay_test::mktemp_project() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-test.XXXXXX")"
  # Resolve to the canonical physical path (macOS mktemp defaults to a path
  # under a symlink, e.g. /tmp -> /private/tmp) so callers can directly
  # compare against `specrelay project root`, which resolves the same way.
  dir="$(cd "$dir" && pwd -P)"
  SPECRELAY_TEST_TMP_DIRS+=("$dir")
  (cd "$dir" && git init -q)
  printf '%s\n' "$dir"
}

specrelay_test::mktemp_project_with_spec() {
  local dir spec_dir
  dir="$(specrelay_test::mktemp_project)"
  spec_dir="$dir/docs/sdd/$1"
  mkdir -p "$spec_dir"
  printf '%s\n' "${2:-# Fixture spec}" > "$spec_dir/spec.md"
  printf '%s\n' "$dir"
}

# specrelay_test::mktemp_specrelay_project
# A fresh git project (see mktemp_project) pre-configured with a
# .specrelay/config.yml using the deterministic 'fake' executor/reviewer
# providers and no context-capability requirement, plus a .gitignore for the
# task-runs root (so the guard tests below reflect this repository's real
# .ai-runs/ policy rather than a bare-git-repo artifact). Individual tests
# still commit their own fixture files as needed.
specrelay_test::mktemp_specrelay_project() {
  local dir
  dir="$(specrelay_test::mktemp_project)"
  mkdir -p "$dir/.specrelay"
  cat > "$dir/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: Fixture Project
specs:
  root: docs/sdd
tasks:
  runs_root: .ai-runs/tasks
  max_iterations: 3
roles:
  executor:
    provider: fake
  reviewer:
    provider: fake
context:
  adapter: none
  required: false
validation:
  full_test_command: "echo ok"
policy:
  human_final_review_required: true
YAML
  printf '.ai-runs/\n' > "$dir/.gitignore"
  (cd "$dir" && git add -A && git commit -q -m "fixture init")
  printf '%s\n' "$dir"
}

specrelay_test::assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" = "$actual" ]; then
    echo "ok - $desc"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "NOT OK - $desc"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

specrelay_test::assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    echo "ok - $desc"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "NOT OK - $desc"
    echo "    expected to contain: $needle"
    echo "    actual: $haystack"
  fi
}

specrelay_test::assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "NOT OK - $desc"
    echo "    expected NOT to contain: $needle"
    echo "    actual: $haystack"
  else
    echo "ok - $desc"
  fi
}

specrelay_test::assert_true() {
  local desc="$1" condition="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$condition" -eq 0 ] 2>/dev/null; then
    echo "ok - $desc"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "NOT OK - $desc (exit code: $condition)"
  fi
}

specrelay_test::summary() {
  echo
  echo "$TESTS_RUN test(s), $TESTS_FAILED failed"
  [ "$TESTS_FAILED" -eq 0 ]
}
