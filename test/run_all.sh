#!/usr/bin/env bash
# run_all.sh — runs every SpecRelay test file in this directory and reports
# an overall pass/fail summary. Each test file is self-contained (isolated
# temp git fixtures only; never this repository's own .ai/ or .ai-runs/).
#   tools/specrelay/test/run_all.sh

set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- mandatory host repository mutation safety (spec 0085, section 66) -----
# Discover the HOST repository root (the real Sprint Reports checkout this
# test suite lives in, NOT any test's isolated temp fixture) and capture its
# safety invariants BEFORE running anything. Every individual test operates
# in its own isolated temp git fixture (test_helper.sh), so these invariants
# should never change; this is the suite-level backstop that catches it
# LOUDLY (never a soft warning) if one ever does — this is exactly the
# incident this section exists to prevent.
HOST_ROOT="$TEST_DIR"
while [ -n "$HOST_ROOT" ] && [ ! -d "$HOST_ROOT/.git" ]; do
  parent="$(dirname "$HOST_ROOT")"
  [ "$parent" = "$HOST_ROOT" ] && HOST_ROOT="" && break
  HOST_ROOT="$parent"
done
if [ -z "$HOST_ROOT" ]; then
  echo "FATAL: could not discover the host repository root; refusing to run (host-safety precondition unmet)." >&2
  exit 1
fi

# Path set only (the leading two-character X/Y status code is stripped), so
# an unrelated process re-staging already-modified files (index-only, no
# content change — observed in practice from editor/IDE auto-stage behavior
# unrelated to this suite) is never a false positive. This still catches
# every mutation spec section 66 actually cares about: a new/removed/renamed
# path, since those change the path SET regardless of staged-ness.
specrelay_run_all::host_status() {
  (cd "$HOST_ROOT" && git status --porcelain --untracked-files=all) | sed -E 's/^.{2} //' | sort
}
HOST_HEAD_BEFORE="$(cd "$HOST_ROOT" && git rev-parse HEAD)"
HOST_BRANCH_BEFORE="$(cd "$HOST_ROOT" && git rev-parse --abbrev-ref HEAD)"
HOST_STATUS_BEFORE="$(specrelay_run_all::host_status)"

FILES_RUN=0
FILES_FAILED=0
FAILED_NAMES=()

for f in "$TEST_DIR"/*_test.sh; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  echo "=== $name ==="
  if "$f"; then
    echo
  else
    FILES_FAILED=$((FILES_FAILED + 1))
    FAILED_NAMES+=("$name")
    echo
  fi
  FILES_RUN=$((FILES_RUN + 1))
done

echo "========================================"
echo "$FILES_RUN test file(s) run, $FILES_FAILED failed"
if [ "$FILES_FAILED" -gt 0 ]; then
  printf 'Failed: %s\n' "${FAILED_NAMES[@]}"
fi

# --- verify host repository safety invariants AFTER the full suite ---------
# This check is NEVER skipped, even if individual test files already failed
# above: a host mutation is a more severe failure than any single assertion.
HOST_HEAD_AFTER="$(cd "$HOST_ROOT" && git rev-parse HEAD)"
HOST_BRANCH_AFTER="$(cd "$HOST_ROOT" && git rev-parse --abbrev-ref HEAD)"
HOST_STATUS_AFTER="$(specrelay_run_all::host_status)"

HOST_SAFETY_VIOLATED=0
if [ "$HOST_HEAD_BEFORE" != "$HOST_HEAD_AFTER" ]; then
  echo "FATAL: host repository HEAD changed during the test suite ($HOST_HEAD_BEFORE -> $HOST_HEAD_AFTER)." >&2
  HOST_SAFETY_VIOLATED=1
fi
if [ "$HOST_BRANCH_BEFORE" != "$HOST_BRANCH_AFTER" ]; then
  echo "FATAL: host repository branch changed during the test suite ($HOST_BRANCH_BEFORE -> $HOST_BRANCH_AFTER)." >&2
  HOST_SAFETY_VIOLATED=1
fi
if [ "$HOST_STATUS_BEFORE" != "$HOST_STATUS_AFTER" ]; then
  echo "FATAL: host repository working-tree status changed during the test suite." >&2
  echo "--- before ---" >&2
  printf '%s\n' "$HOST_STATUS_BEFORE" >&2
  echo "--- after ---" >&2
  printf '%s\n' "$HOST_STATUS_AFTER" >&2
  HOST_SAFETY_VIOLATED=1
fi

if [ "$HOST_SAFETY_VIOLATED" -ne 0 ]; then
  echo "FATAL: host repository mutation safety check failed (spec 0085, section 66). This is not a soft warning." >&2
  exit 1
fi
echo "Host repository safety: HEAD, branch, and working-tree status are unchanged."

if [ "$FILES_FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
