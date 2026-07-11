#!/usr/bin/env bash
# legacy_freeze_test.sh — SDD 0085B, section 1 + test 8.8: the legacy engine is
# FROZEN. Assert the freeze is DECLARED (not merely intended) and that the
# legacy engine gained NO new behavior (its cross-engine ownership guard is
# intact; no legacy recovery path was added).
#   tools/specrelay/test/legacy_freeze_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

HOST_ROOT="$SPECRELAY_ROOT"
while [ -n "$HOST_ROOT" ] && [ ! -d "$HOST_ROOT/.git" ]; do
  parent="$(dirname "$HOST_ROOT")"
  [ "$parent" = "$HOST_ROOT" ] && HOST_ROOT="" && break
  HOST_ROOT="$parent"
done
specrelay_test::assert_true "host repository root was discovered" "$([ -n "$HOST_ROOT" ] && echo 0 || echo 1)"

LEGACY_DIR="$HOST_ROOT/.ai/scripts/legacy"
INTERNAL_DIR="$HOST_ROOT/.ai/scripts/internal"

# --- 8.8: the freeze is DECLARED, prominently, in the legacy README ---------
readme="$(cat "$LEGACY_DIR/README.md")"
specrelay_test::assert_contains "8.8: legacy README declares FROZEN as of SDD 0085B" "$readme" "FROZEN as of SDD 0085B"
specrelay_test::assert_contains "8.8: freeze forbids new features" "$readme" "no new features"
specrelay_test::assert_contains "8.8: freeze forbids new recovery paths" "$readme" "no new recovery paths"
specrelay_test::assert_contains "8.8: freeze forbids new dogfood/test infra" "$readme" "no new dogfood or test infrastructure"
specrelay_test::assert_contains "8.8: freeze forbids new dependencies" "$readme" "no new dependencies"
specrelay_test::assert_contains "8.8: freeze says recovery is SpecRelay-native only" "$readme" "specrelay task recover"

# --- 8.8: the freeze is discoverable from CLAUDE.md and architecture.md -----
claude_md="$(cat "$HOST_ROOT/CLAUDE.md")"
specrelay_test::assert_contains "8.8: CLAUDE.md states the legacy engine is FROZEN" "$claude_md" "FROZEN"
specrelay_test::assert_contains "8.8: CLAUDE.md freezes legacy from new features" "$claude_md" "no new features"
arch="$(cat "$HOST_ROOT/tools/specrelay/docs/architecture.md")"
specrelay_test::assert_contains "8.8: architecture.md has a Legacy engine freeze anchor" "$arch" "Legacy engine freeze"

# --- 8.8: legacy gained NO new behavior — the ownership guard is intact ------
# Every mutating legacy internal script must still refuse a specrelay-owned task.
for f in claim-task.sh requeue-task.sh accept-review.sh request-changes.sh block-task.sh submit-review.sh finish-task.sh; do
  src="$(cat "$INTERNAL_DIR/$f" 2>/dev/null || true)"
  specrelay_test::assert_contains "8.8: legacy $f still guards engine==specrelay" "$src" 'engine == "specrelay"'
done

# --- 8.8: NO new legacy recovery COMMAND was added --------------------------
# Recovery is SpecRelay-native only: there must be no legacy command FILE whose
# name is *recover* / *reset-running* under the legacy or internal script trees.
# (Pre-existing legacy scripts may still mention the word "recover" in prose
# comments — that is not a new recovery command and is not asserted against.)
legacy_recover_cmd="$(ls "$LEGACY_DIR"/*recover* "$LEGACY_DIR"/*reset-running* 2>/dev/null || true)"
specrelay_test::assert_eq "8.8: no legacy recovery command file exists" "" "$legacy_recover_cmd"
new_recover_cmd="$(ls "$INTERNAL_DIR"/*recover* "$INTERNAL_DIR"/*reset-running* 2>/dev/null || true)"
specrelay_test::assert_eq "8.8: no legacy internal recovery command file exists" "" "$new_recover_cmd"

specrelay_test::summary
exit $?
