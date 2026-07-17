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
python3 -c '
import json
print(json.dumps({
    "schema_version": 1,
    "pid": '"$$"',
    "host": "'"$(hostname 2>/dev/null || echo unknown-host)"'",
    "acquired_at": "2026-01-01T00:00:00Z",
    "pid_start_time": None,
    "invocation_id": None,
    "owner_token": "test-token",
    "provider_pgid": None,
    "heartbeat_at": "2026-01-01T00:00:00Z",
    "heartbeat_interval_seconds": 15,
}))
' > "$lock_dir/owner"

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
python3 -c '
import json
print(json.dumps({
    "schema_version": 1,
    "pid": '"$dead_pid"',
    "host": "'"$(hostname 2>/dev/null || echo unknown-host)"'",
    "acquired_at": "2026-01-01T00:00:00Z",
    "pid_start_time": None,
    "invocation_id": None,
    "owner_token": "test-token",
    "provider_pgid": None,
    "heartbeat_at": "2026-01-01T00:00:00Z",
    "heartbeat_interval_seconds": 15,
}))
' > "$lock_dir/owner"

specrelay::lock::acquire "$proj" "task-b"
rc=$?
specrelay_test::assert_eq "acquire reclaims a stale lock (dead owner pid)" "0" "$rc"

# --- lease classification (spec 0029, section 21.2) -------------------------

this_host="$(hostname 2>/dev/null || echo unknown-host)"

# AB: a reused PID (same pid number, mismatched pid_start_time) classifies
# stale-dead-pid (recoverable), never "live" — AC-11.
specrelay::lock::acquire "$proj" "task-ab"
lock_dir_ab="$(specrelay::lock::_dir "$proj" "task-ab")"
python3 -c '
import json
print(json.dumps({
    "schema_version": 1, "pid": '"$$"', "host": "'"$this_host"'",
    "acquired_at": "2026-01-01T00:00:00Z",
    "pid_start_time": "definitely-not-the-real-start-time",
    "invocation_id": None, "owner_token": "test-token", "provider_pgid": None,
    "heartbeat_at": "2026-01-01T00:00:00Z", "heartbeat_interval_seconds": 15,
}))
' > "$lock_dir_ab/owner"
specrelay_test::assert_eq "AB: reused-pid lease classifies stale-dead-pid" \
  "stale-dead-pid" "$(specrelay::lock::lease_classify "$proj" "task-ab")"
specrelay::lock::acquire "$proj" "task-ab"
specrelay_test::assert_eq "AB: acquire reclaims a stale-dead-pid (PID reuse) lease" "0" "$?"

# AC / AJ: a LIVE pid with the correct start time but a STALE/failed
# heartbeat classifies suspect-hung, never live and never treated as
# equivalent to a dead owner — auto-recovery must refuse it (AC-23).
specrelay::lock::acquire "$proj" "task-ac"
lock_dir_ac="$(specrelay::lock::_dir "$proj" "task-ac")"
real_start="$(specrelay::lock::_pid_start_time "$$")"
python3 -c '
import json, sys
print(json.dumps({
    "schema_version": 1, "pid": '"$$"', "host": "'"$this_host"'",
    "acquired_at": "2026-01-01T00:00:00Z",
    "pid_start_time": sys.argv[1],
    "invocation_id": None, "owner_token": "test-token", "provider_pgid": None,
    "heartbeat_at": "2020-01-01T00:00:00Z", "heartbeat_interval_seconds": 15,
}))
' "$real_start" > "$lock_dir_ac/owner"
specrelay_test::assert_eq "AC/AJ: live pid + stale heartbeat classifies suspect-hung" \
  "suspect-hung" "$(specrelay::lock::lease_classify "$proj" "task-ac")"
out_ac="$(specrelay::lock::acquire "$proj" "task-ac" 2>&1)"
rc_ac=$?
specrelay_test::assert_true "AC/AJ: acquire REFUSES a suspect-hung lease (no auto-recovery)" \
  "$([ "$rc_ac" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "AC/AJ: refusal names the suspect-hung classification" "$out_ac" "suspect-hung"
specrelay_test::assert_contains "AC/AJ: refusal states an explicit human decision is required" "$out_ac" "explicit human decision"

# AD: a lock owned by a different hostname classifies foreign-host and is
# conservatively refused (cannot be liveness-checked from here).
specrelay::lock::acquire "$proj" "task-ad"
lock_dir_ad="$(specrelay::lock::_dir "$proj" "task-ad")"
python3 -c '
import json
print(json.dumps({
    "schema_version": 1, "pid": 424242, "host": "some-other-host.example",
    "acquired_at": "2026-01-01T00:00:00Z", "pid_start_time": None,
    "invocation_id": None, "owner_token": "test-token", "provider_pgid": None,
    "heartbeat_at": "2026-01-01T00:00:00Z", "heartbeat_interval_seconds": 15,
}))
' > "$lock_dir_ad/owner"
specrelay_test::assert_eq "AD: a different-host lease classifies foreign-host" \
  "foreign-host" "$(specrelay::lock::lease_classify "$proj" "task-ad")"
out_ad="$(specrelay::lock::acquire "$proj" "task-ad" 2>&1)"
rc_ad=$?
specrelay_test::assert_true "AD: acquire REFUSES a foreign-host lease" \
  "$([ "$rc_ad" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "AD: refusal names the foreign-host classification" "$out_ad" "foreign-host"

specrelay_test::summary
exit $?
