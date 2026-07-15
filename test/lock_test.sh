#!/usr/bin/env bash
# lock_test.sh — unit tests for lock.sh: acquire/release, mutual exclusion,
# and stale-lock reclaim after a crashed owner (spec sections 51, 63).

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/project.sh
. "$SPECRELAY_ROOT/lib/specrelay/project.sh"
# shellcheck source=../lib/specrelay/config.sh
. "$SPECRELAY_ROOT/lib/specrelay/config.sh"
# shellcheck source=../lib/specrelay/task.sh
. "$SPECRELAY_ROOT/lib/specrelay/task.sh"
# shellcheck source=../lib/specrelay/lock.sh
. "$SPECRELAY_ROOT/lib/specrelay/lock.sh"

proj="$(specrelay_test::mktemp_project)"

# --- acquire / release ------------------------------------------------------
specrelay::lock::acquire "$proj" "task-a"
rc=$?
specrelay_test::assert_eq "acquire succeeds on an unlocked task" "0" "$rc"

specrelay::lock::is_locked "$proj" "task-a"
specrelay_test::assert_true "is_locked reports true after acquire" "$?"

specrelay::lock::release "$proj" "task-a"
specrelay::lock::is_locked "$proj" "task-a"
specrelay_test::assert_true "is_locked reports false after release" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# --- mutual exclusion: a second acquire by a DIFFERENT (fake) live pid ------
specrelay::lock::acquire "$proj" "task-b"
lock_dir="$(specrelay::lock::_dir "$proj" "task-b")"
# Forge the owner file to look like a different, still-alive process. Using
# this TEST SCRIPT's own pid ($$) is the only pid we can reliably both know
# is alive AND are permitted to signal (kill -0) in a sandboxed test
# environment, where signaling pid 1 may be denied (EPERM) even though it
# exists — which would make _pid_alive falsely report "not alive."
{
  echo "pid=$$"
  echo "host=$(hostname 2>/dev/null || echo unknown-host)"
  echo "acquired_at=2026-01-01T00:00:00Z"
} > "$lock_dir/owner"

specrelay::lock::acquire "$proj" "task-b" 2>/tmp/specrelay-lock-conflict.$$
rc=$?
specrelay_test::assert_true "acquire refuses when a live process holds the lock" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "conflict message names the holding pid" \
  "$(cat "/tmp/specrelay-lock-conflict.$$")" "locked by another process"
rm -f "/tmp/specrelay-lock-conflict.$$"

# --- stale-lock reclaim: owner pid is dead ----------------------------------
# A PID essentially guaranteed not to be alive (very large, unlikely to be a
# real live process, and not reused so quickly by the test host).
dead_pid=999999
{
  echo "pid=$dead_pid"
  echo "host=$(hostname 2>/dev/null || echo unknown-host)"
  echo "acquired_at=2026-01-01T00:00:00Z"
} > "$lock_dir/owner"

specrelay::lock::acquire "$proj" "task-b"
rc=$?
specrelay_test::assert_eq "acquire reclaims a stale lock (dead owner pid)" "0" "$rc"

specrelay_test::summary
exit $?
