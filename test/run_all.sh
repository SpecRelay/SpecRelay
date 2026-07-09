#!/usr/bin/env bash
# run_all.sh — runs every SpecRelay test file in this directory and reports
# an overall pass/fail summary. Each test file is self-contained (isolated
# temp git fixtures only; never this repository's own .ai/ or .ai-runs/).
#   tools/specrelay/test/run_all.sh

set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  exit 1
fi
exit 0
