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

# Pin SpecRelay's home to THIS source tree for the whole suite. bin/specrelay
# honors an ambient SPECRELAY_HOME override before deriving home from its own
# location, so a developer (or CI) that happens to have SPECRELAY_HOME pointing
# at a separately-installed copy would otherwise have every test silently
# exercise that INSTALLED engine instead of the code under test in this
# repository — making the suite validate the wrong thing (this bit spec 0003:
# the installed copy predated the live-streaming change). Pinning it here makes
# `scripts/test` deterministically test the in-repo libs regardless of the
# ambient environment. Individual tests that must install a fresh copy override
# this per-invocation (e.g. `env -u SPECRELAY_HOME`).
export SPECRELAY_HOME="$SPECRELAY_ROOT"

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
  # Make every fixture repo HERMETIC with respect to developer-global Git hooks
  # (spec 0002). A developer-global `core.hooksPath` fires on EVERY commit in
  # EVERY repo, including the throwaway fixtures these tests commit into — so a
  # hostile or malformed global hook (e.g. one with non-ASCII shell punctuation)
  # leaks its `fatal: ... / grep: illegal byte sequence / sed: invalid command
  # code` noise into `scripts/test`. Pointing this repo's local `core.hooksPath`
  # at a nonexistent path (`/dev/null`) overrides the global setting so NO
  # developer hook runs for fixture commits. This is isolation only: it changes
  # nothing about what the tests commit, just that they do not execute arbitrary
  # developer hooks, so the suite is deterministic regardless of the developer's
  # environment.
  # Give every fixture repo a DETERMINISTIC, local Git identity. CI runners (and
  # freshly-provisioned dev machines) frequently have NO global user.name /
  # user.email, so any commit — the fixture setup below, OR one SpecRelay's own
  # engine makes inside the fixture during a task run — would otherwise fail with
  # "empty ident name / Author identity unknown", leaving the tree dirty and
  # tripping the working-tree guard. Setting it LOCALLY (not --global) keeps the
  # suite hermetic: it never reads or writes the developer's real Git identity,
  # and the value is stable regardless of the ambient environment.
  (cd "$dir" \
    && git init -q \
    && git config core.hooksPath /dev/null \
    && git config user.name "SpecRelay Test" \
    && git config user.email "specrelay-test@example.invalid")
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

# specrelay_test::safe_fixture_root_or_abort <candidate-path> <host-root>
#
# Implements the mandatory host-repository mutation safety check (spec 0085,
# section 66 — added after a prior execution attempt of this task mutated
# the HOST repository by renaming real product docs from inside a fixture
# test that had lost track of its own temp-dir root). Any test helper that is
# about to run a Git-MUTATING command (add/commit/reset/checkout/switch/
# clean, or a rename/move of repository files) against a fixture project
# MUST call this first and abort (return non-zero, print why) unless ALL of:
#   1. the candidate path is non-empty;
#   2. it exists;
#   3. it is a Git repository (has a resolvable `git rev-parse --show-toplevel`);
#   4. it is NOT equal to the host repository root;
#   5. it is inside the expected temporary test area ($TMPDIR, canonicalized),
#      where practical (skipped only if TMPDIR itself can't be resolved).
# An empty or unresolved candidate is NEVER treated as equivalent to the
# current directory — this function only ever inspects the exact string it
# was given.
specrelay_test::safe_fixture_root_or_abort() {
  local candidate="$1" host_root="$2"

  if [ -z "$candidate" ]; then
    echo "specrelay_test: refusing to proceed: fixture root is empty (never falling back to cwd)" >&2
    return 1
  fi
  if [ ! -e "$candidate" ]; then
    echo "specrelay_test: refusing to proceed: fixture root does not exist: $candidate" >&2
    return 1
  fi
  local resolved
  if ! resolved="$(cd "$candidate" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" || [ -z "$resolved" ]; then
    echo "specrelay_test: refusing to proceed: fixture root is not a Git repository: $candidate" >&2
    return 1
  fi
  if [ -n "$host_root" ] && [ "$resolved" = "$host_root" ]; then
    echo "specrelay_test: refusing to proceed: fixture root equals the HOST repository root ($host_root) — this is exactly the incident this check prevents" >&2
    return 1
  fi
  local tmp_root
  if tmp_root="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)"; then
    case "$resolved" in
      "$tmp_root"/*) : ;;
      *)
        echo "specrelay_test: refusing to proceed: fixture root is not inside the expected temp area ($tmp_root): $resolved" >&2
        return 1
        ;;
    esac
  fi
  return 0
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

# Literal substring matching WITHOUT a pipe. The previous form
# (`printf '%s' "$haystack" | grep -Fq -- "$needle"`) races under load: grep -q
# exits the instant it matches and closes the pipe, so printf — still writing a
# large haystack — takes SIGPIPE and prints "printf: write error: Broken pipe"
# to stderr (and could taint the exit status under pipefail). Bash's `==` inside
# `[[ ]]` does the same fixed-string test with no subprocess and no pipe: the
# quoted "$needle" is treated as a literal (glob metacharacters in it are NOT
# expanded), so this is exactly `grep -F`, minus the failure mode.
specrelay_test::_contains() {
  case "$2" in
    *"$1"*) return 0 ;;
    *) return 1 ;;
  esac
}

specrelay_test::assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if specrelay_test::_contains "$needle" "$haystack"; then
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
  if specrelay_test::_contains "$needle" "$haystack"; then
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
