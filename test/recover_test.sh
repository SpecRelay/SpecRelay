#!/usr/bin/env bash
# recover_test.sh — SDD 0085B, section 3 + tests 8.3–8.5: the SpecRelay-native
# interrupted-task recovery command (`specrelay task recover`).
#
# Covers:
#   8.3  refuses a task with a LIVE owning process (simulated live lock owner).
#   8.4  safely recovers a stale EXECUTOR_RUNNING task to READY_FOR_EXECUTOR,
#        writes the recovery metadata, preserves evidence files, and never
#        reaches READY_FOR_HUMAN_REVIEW.
#   8.5  stale locks are reclaimed safely; a dead pid on a FOREIGN host is NOT
#        blindly reclaimed (the same-host dead-pid reclaim is already covered
#        by lock_test.sh — this adds the missing foreign-host guard case).
#   plus: refuses a task owned by another engine (respects _require_owned),
#         and refuses an unsupported source state (never fabricates success).

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
# shellcheck source=../lib/specrelay/state.sh
. "$SPECRELAY_ROOT/lib/specrelay/state.sh"
# shellcheck source=../lib/specrelay/lock.sh
. "$SPECRELAY_ROOT/lib/specrelay/lock.sh"

BIN="$SPECRELAY_ROOT/bin/specrelay"
THIS_HOST="$(hostname 2>/dev/null || echo unknown-host)"

# _forge_owner <owner-file> <pid> <host>
# Writes a lease-shaped owner file (spec 0029, section 21) for forging a
# lock without going through a real specrelay::lock::acquire call.
_forge_owner() {
  local owner_file="$1" pid="$2" host="$3"
  python3 -c '
import json
print(json.dumps({
    "schema_version": 1,
    "pid": int("'"$pid"'"),
    "host": "'"$host"'",
    "acquired_at": "2026-01-01T00:00:00Z",
    "pid_start_time": None,
    "invocation_id": None,
    "owner_token": "test-token",
    "provider_pgid": None,
    "heartbeat_at": "2026-01-01T00:00:00Z",
    "heartbeat_interval_seconds": 15,
}))
' > "$owner_file"
}

# _make_running_task <proj> <task-id>
# Creates a SpecRelay-owned task stuck in EXECUTOR_RUNNING, with real (non-empty)
# evidence files that recovery must preserve.
_make_running_task() {
  local proj="$1" id="$2" dir
  dir="$proj/.specrelay-runs/tasks/$id"
  mkdir -p "$dir"
  specrelay::state::init "$(specrelay::state::path "$dir")" \
    "{\"task_id\": \"$id\", \"state\": \"EXECUTOR_RUNNING\", \"engine\": \"specrelay\", \"iteration\": 1, \"claimed_at\": \"2026-01-01T00:00:00Z\", \"claimed_by\": \"specrelay-runner\"}" >/dev/null
  printf 'executor log content\n' > "$dir/03-executor-log.md"
  printf 'test output content\n' > "$dir/07-tests.txt"
  printf 'summary content\n' > "$dir/08-executor-summary.md"
  printf '%s\n' "$dir"
}

# ---- 8.3: refuse a task with a LIVE owning process -------------------------
proj1="$(specrelay_test::mktemp_specrelay_project)"
dir1="$(_make_running_task "$proj1" "0500-live-owner")"

# Start a genuinely-alive background process and forge a lock owned by it on
# THIS host.
sleep 300 &
live_pid=$!
lock_dir1="$(specrelay::lock::_dir "$proj1" "0500-live-owner")"
mkdir -p "$lock_dir1"
_forge_owner "$lock_dir1/owner" "$live_pid" "$THIS_HOST"

out1="$( (cd "$proj1" && "$BIN" task recover 0500-live-owner --reason "test" ) 2>&1 )"
rc1=$?
specrelay_test::assert_true "8.3: recover REFUSES a task with a live owning process" "$([ "$rc1" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "8.3: refusal names the live-owner reason" "$out1" "a live process still owns it"
state1="$(specrelay::state::canonical "$(specrelay::state::path "$dir1")")"
specrelay_test::assert_eq "8.3: state is unchanged after refusal" "EXECUTOR_RUNNING" "$state1"
# The live lock must NOT have been force-removed.
specrelay_test::assert_true "8.3: the live lock was not force-removed" "$([ -d "$lock_dir1" ] && echo 0 || echo 1)"

kill "$live_pid" 2>/dev/null
wait "$live_pid" 2>/dev/null

# ---- 8.4: safely recover a stale EXECUTOR_RUNNING task ---------------------
proj2="$(specrelay_test::mktemp_specrelay_project)"
dir2="$(_make_running_task "$proj2" "0501-stale-exec")"
# Forge a STALE lock (dead pid on this host).
lock_dir2="$(specrelay::lock::_dir "$proj2" "0501-stale-exec")"
mkdir -p "$lock_dir2"
_forge_owner "$lock_dir2/owner" "999999" "$THIS_HOST"

out2="$( (cd "$proj2" && "$BIN" task recover 0501-stale-exec --reason "provider process was orphaned" ) 2>&1 )"
rc2=$?
sf2="$(specrelay::state::path "$dir2")"
specrelay_test::assert_eq "8.4: recover succeeds on a stale EXECUTOR_RUNNING task" "0" "$rc2"
specrelay_test::assert_eq "8.4: recovered to READY_FOR_EXECUTOR" "READY_FOR_EXECUTOR" "$(specrelay::state::canonical "$sf2")"
specrelay_test::assert_eq "8.4: records recovered_from_state" "EXECUTOR_RUNNING" "$(specrelay::state::get "$sf2" recovered_from_state)"
specrelay_test::assert_eq "8.4: records recovery_reason" "provider process was orphaned" "$(specrelay::state::get "$sf2" recovery_reason)"
specrelay_test::assert_eq "8.4: records recovered_by" "specrelay-recover" "$(specrelay::state::get "$sf2" recovered_by)"
recovered_at2="$(specrelay::state::get "$sf2" recovered_at)"
specrelay_test::assert_true "8.4: records a recovered_at timestamp" "$([ -n "$recovered_at2" ] && echo 0 || echo 1)"
# Never reaches READY_FOR_HUMAN_REVIEW.
specrelay_test::assert_true "8.4: never reaches READY_FOR_HUMAN_REVIEW" "$([ "$(specrelay::state::canonical "$sf2")" != "READY_FOR_HUMAN_REVIEW" ] && echo 0 || echo 1)"
# Stale claim stamp cleared so the next executor iteration re-claims cleanly.
specrelay_test::assert_eq "8.4: clears the stale claimed_at stamp" "" "$(specrelay::state::get "$sf2" claimed_at)"
# Evidence preserved untouched.
specrelay_test::assert_eq "8.4: preserves 03-executor-log.md" "executor log content" "$(cat "$dir2/03-executor-log.md")"
specrelay_test::assert_eq "8.4: preserves 07-tests.txt" "test output content" "$(cat "$dir2/07-tests.txt")"
specrelay_test::assert_eq "8.4: preserves 08-executor-summary.md" "summary content" "$(cat "$dir2/08-executor-summary.md")"
# The command printed what it changed (never silent).
specrelay_test::assert_contains "8.4: prints what it changed" "$out2" "Recovered task"
# The stale lock was reclaimed and then released.
specrelay_test::assert_true "8.4: the reclaimed lock was released after recovery" "$([ ! -d "$lock_dir2" ] && echo 0 || echo 1)"

# ---- 8.4b: recovery on a task with NO lock at all --------------------------
proj3="$(specrelay_test::mktemp_specrelay_project)"
dir3="$(_make_running_task "$proj3" "0502-no-lock")"
out3="$( (cd "$proj3" && "$BIN" task recover 0502-no-lock --reason "no lock present" ) 2>&1 )"
rc3=$?
specrelay_test::assert_eq "8.4b: recover succeeds even with no pre-existing lock" "0" "$rc3"
specrelay_test::assert_eq "8.4b: recovered to READY_FOR_EXECUTOR" "READY_FOR_EXECUTOR" "$(specrelay::state::canonical "$(specrelay::state::path "$dir3")")"

# ---- 8.5: a dead pid on a FOREIGN host is NOT blindly reclaimed ------------
proj4="$(specrelay_test::mktemp_specrelay_project)"
dir4="$(_make_running_task "$proj4" "0503-foreign-host")"
lock_dir4="$(specrelay::lock::_dir "$proj4" "0503-foreign-host")"
mkdir -p "$lock_dir4"
_forge_owner "$lock_dir4/owner" "999999" "some-other-host-that-is-not-us"
out4="$( (cd "$proj4" && "$BIN" task recover 0503-foreign-host --reason "test" ) 2>&1 )"
rc4=$?
specrelay_test::assert_true "8.5: recover REFUSES a lock owned on a foreign host" "$([ "$rc4" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_eq "8.5: foreign-host task state unchanged" "EXECUTOR_RUNNING" "$(specrelay::state::canonical "$(specrelay::state::path "$dir4")")"
specrelay_test::assert_true "8.5: the foreign-host lock was not force-removed" "$([ -d "$lock_dir4" ] && echo 0 || echo 1)"

# ---- guard: refuse a task owned by another engine (respects _require_owned)
proj5="$(specrelay_test::mktemp_specrelay_project)"
dir5="$proj5/.specrelay-runs/tasks/0504-legacy-owned"
mkdir -p "$dir5"
# No engine field == not owned by SpecRelay.
specrelay::state::init "$(specrelay::state::path "$dir5")" \
  '{"task_id": "0504-legacy-owned", "state": "EXECUTOR_RUNNING", "iteration": 1}'
out5="$( (cd "$proj5" && "$BIN" task recover 0504-legacy-owned --reason "test" ) 2>&1 )"
rc5=$?
specrelay_test::assert_true "guard: recover REFUSES a task not owned by SpecRelay" "$([ "$rc5" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "guard: refusal names the ownership reason" "$out5" "not owned by the SpecRelay engine"

# ---- guard: refuse an unsupported source state (never fabricate success) ---
proj6="$(specrelay_test::mktemp_specrelay_project)"
dir6="$proj6/.specrelay-runs/tasks/0505-not-running"
mkdir -p "$dir6"
specrelay::state::init "$(specrelay::state::path "$dir6")" \
  '{"task_id": "0505-not-running", "state": "READY_FOR_HUMAN_REVIEW", "engine": "specrelay", "iteration": 1}'
out6="$( (cd "$proj6" && "$BIN" task recover 0505-not-running --reason "test" ) 2>&1 )"
rc6=$?
specrelay_test::assert_true "guard: recover REFUSES a non-running source state" "$([ "$rc6" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_eq "guard: unsupported-source task state unchanged" "READY_FOR_HUMAN_REVIEW" "$(specrelay::state::canonical "$(specrelay::state::path "$dir6")")"

# ---- guard: a missing --reason is refused (recovery is always audited) -----
proj7="$(specrelay_test::mktemp_specrelay_project)"
_make_running_task "$proj7" "0506-no-reason" >/dev/null
out7="$( (cd "$proj7" && "$BIN" task recover 0506-no-reason ) 2>&1 )"
rc7=$?
specrelay_test::assert_true "guard: recover REFUSES when no --reason is supplied" "$([ "$rc7" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "guard: refusal explains --reason is required" "$out7" "reason is required"

specrelay_test::summary
exit $?
