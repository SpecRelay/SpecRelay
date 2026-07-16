#!/usr/bin/env bash
# archive_test.sh — `specrelay task archive`: move completed (terminal-state)
# tasks out of the active runs root into the archive root, preserving every
# artifact, while never hiding in-flight or foreign work.
#
# Covers:
#   1  archives a READY_FOR_HUMAN_REVIEW task: moved under the archive root,
#      disappears from `task list`, provenance stamped, artifacts preserved.
#   2  refuses a non-terminal task (EXECUTOR_RUNNING) and leaves it in place.
#   3  refuses a task a LIVE process still owns; state and lock untouched.
#   4  BLOCKED is refused by default, archived with --include-blocked.
#   5  --dry-run mutates nothing.
#   6  --all archives only completed tasks and leaves active ones in place.
#   7  refuses to overwrite an existing archived copy.
#   8  refuses a task not owned by the SpecRelay engine.

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

# _make_task <proj> <task-id> <state>
# Creates a SpecRelay-owned task in <state> with a real (non-empty) artifact so
# tests can assert the artifact is preserved through the move.
_make_task() {
  local proj="$1" id="$2" state="$3" dir
  dir="$proj/.specrelay-runs/tasks/$id"
  mkdir -p "$dir"
  specrelay::state::init "$(specrelay::state::path "$dir")" \
    "{\"task_id\": \"$id\", \"state\": \"$state\", \"engine\": \"specrelay\", \"iteration\": 1}" >/dev/null
  printf 'artifact for %s\n' "$id" > "$dir/08-executor-summary.md"
  printf '%s\n' "$dir"
}

# ---- 1: archive a completed (READY_FOR_HUMAN_REVIEW) task ------------------
proj1="$(specrelay_test::mktemp_specrelay_project)"
dir1="$(_make_task "$proj1" "0600-done" "READY_FOR_HUMAN_REVIEW")"
out1="$( (cd "$proj1" && "$BIN" task archive 0600-done) 2>&1 )"
rc1=$?
specrelay_test::assert_eq "1: archive succeeds on a completed task" "0" "$rc1"
specrelay_test::assert_true "1: task dir removed from the runs root" "$([ ! -e "$dir1" ] && echo 0 || echo 1)"
arc1="$proj1/.specrelay-runs/archive/0600-done"
specrelay_test::assert_true "1: task dir now exists under the archive root" "$([ -d "$arc1" ] && echo 0 || echo 1)"
specrelay_test::assert_eq "1: artifact preserved through the move" "artifact for 0600-done" "$(cat "$arc1/08-executor-summary.md")"
specrelay_test::assert_eq "1: archived_from_state recorded" "READY_FOR_HUMAN_REVIEW" "$(specrelay::state::get "$(specrelay::state::path "$arc1")" archived_from_state)"
specrelay_test::assert_true "1: archived_at timestamp recorded" "$([ -n "$(specrelay::state::get "$(specrelay::state::path "$arc1")" archived_at)" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "1: prints what it did" "$out1" "archived 0600-done"
# No longer listed among active tasks.
list1="$( (cd "$proj1" && "$BIN" task list) 2>&1 )"
specrelay_test::assert_not_contains "1: archived task no longer appears in 'task list'" "$list1" "0600-done"

# ---- 2: refuse a non-terminal (in-flight) task ----------------------------
proj2="$(specrelay_test::mktemp_specrelay_project)"
dir2="$(_make_task "$proj2" "0601-running" "EXECUTOR_RUNNING")"
out2="$( (cd "$proj2" && "$BIN" task archive 0601-running) 2>&1 )"
rc2=$?
specrelay_test::assert_true "2: archive REFUSES a non-terminal task" "$([ "$rc2" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_true "2: the in-flight task dir is left in place" "$([ -d "$dir2" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "2: refusal names the current state" "$out2" "EXECUTOR_RUNNING"

# ---- 3: refuse a task a LIVE process still owns ----------------------------
proj3="$(specrelay_test::mktemp_specrelay_project)"
dir3="$(_make_task "$proj3" "0602-live" "READY_FOR_HUMAN_REVIEW")"
sleep 300 &
live_pid=$!
lock_dir3="$(specrelay::lock::_dir "$proj3" "0602-live")"
mkdir -p "$lock_dir3"
{
  echo "pid=$live_pid"
  echo "host=$THIS_HOST"
  echo "acquired_at=2026-01-01T00:00:00Z"
} > "$lock_dir3/owner"
out3="$( (cd "$proj3" && "$BIN" task archive 0602-live) 2>&1 )"
rc3=$?
specrelay_test::assert_true "3: archive REFUSES a live-owned task" "$([ "$rc3" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_true "3: live-owned task left in place" "$([ -d "$dir3" ] && echo 0 || echo 1)"
specrelay_test::assert_true "3: live lock not force-removed" "$([ -d "$lock_dir3" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "3: refusal names the live-owner reason" "$out3" "a live process still owns it"
kill "$live_pid" 2>/dev/null
wait "$live_pid" 2>/dev/null

# ---- 4: BLOCKED refused by default, archived with --include-blocked --------
proj4="$(specrelay_test::mktemp_specrelay_project)"
dir4="$(_make_task "$proj4" "0603-blocked" "BLOCKED")"
out4a="$( (cd "$proj4" && "$BIN" task archive 0603-blocked) 2>&1 )"
rc4a=$?
specrelay_test::assert_true "4: BLOCKED refused without --include-blocked" "$([ "$rc4a" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_true "4: BLOCKED task still in place after refusal" "$([ -d "$dir4" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "4: refusal mentions --include-blocked" "$out4a" "--include-blocked"
out4b="$( (cd "$proj4" && "$BIN" task archive 0603-blocked --include-blocked) 2>&1 )"
rc4b=$?
specrelay_test::assert_eq "4: BLOCKED archived with --include-blocked" "0" "$rc4b"
specrelay_test::assert_true "4: BLOCKED task moved to the archive root" "$([ -d "$proj4/.specrelay-runs/archive/0603-blocked" ] && echo 0 || echo 1)"

# ---- 5: --dry-run mutates nothing ------------------------------------------
proj5="$(specrelay_test::mktemp_specrelay_project)"
dir5="$(_make_task "$proj5" "0604-dry" "READY_FOR_HUMAN_REVIEW")"
out5="$( (cd "$proj5" && "$BIN" task archive 0604-dry --dry-run) 2>&1 )"
rc5=$?
specrelay_test::assert_eq "5: --dry-run succeeds" "0" "$rc5"
specrelay_test::assert_true "5: --dry-run leaves the task in place" "$([ -d "$dir5" ] && echo 0 || echo 1)"
specrelay_test::assert_true "5: --dry-run creates nothing under the archive root" "$([ ! -e "$proj5/.specrelay-runs/archive/0604-dry" ] && echo 0 || echo 1)"
specrelay_test::assert_eq "5: --dry-run does not stamp archived_at" "" "$(specrelay::state::get "$(specrelay::state::path "$dir5")" archived_at)"
specrelay_test::assert_contains "5: --dry-run reports what it would do" "$out5" "would archive 0604-dry"

# ---- 6: --all archives only completed tasks --------------------------------
proj6="$(specrelay_test::mktemp_specrelay_project)"
done6="$(_make_task "$proj6" "0605-done" "READY_FOR_HUMAN_REVIEW")"
run6="$(_make_task "$proj6" "0606-running" "EXECUTOR_RUNNING")"
draft6="$(_make_task "$proj6" "0607-draft" "DRAFT")"
out6="$( (cd "$proj6" && "$BIN" task archive --all) 2>&1 )"
rc6=$?
specrelay_test::assert_eq "6: --all succeeds" "0" "$rc6"
specrelay_test::assert_true "6: completed task archived" "$([ -d "$proj6/.specrelay-runs/archive/0605-done" ] && echo 0 || echo 1)"
specrelay_test::assert_true "6: EXECUTOR_RUNNING task left in place" "$([ -d "$run6" ] && echo 0 || echo 1)"
specrelay_test::assert_true "6: DRAFT task left in place" "$([ -d "$draft6" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "6: summary reports one archived, two left" "$out6" "Archived 1 task(s); 2 active task(s) left in place."

# ---- 7: refuse to overwrite an existing archived copy ----------------------
proj7="$(specrelay_test::mktemp_specrelay_project)"
dir7="$(_make_task "$proj7" "0608-dup" "READY_FOR_HUMAN_REVIEW")"
# Pre-create a collision under the archive root.
mkdir -p "$proj7/.specrelay-runs/archive/0608-dup"
out7="$( (cd "$proj7" && "$BIN" task archive 0608-dup) 2>&1 )"
rc7=$?
specrelay_test::assert_true "7: archive REFUSES an existing archived copy" "$([ "$rc7" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_true "7: source task left in place on collision" "$([ -d "$dir7" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "7: refusal names the collision" "$out7" "already exists"

# ---- 8: refuse a task not owned by the SpecRelay engine --------------------
proj8="$(specrelay_test::mktemp_specrelay_project)"
dir8="$proj8/.specrelay-runs/tasks/0609-foreign"
mkdir -p "$dir8"
# No engine field == not owned by SpecRelay.
specrelay::state::init "$(specrelay::state::path "$dir8")" \
  '{"task_id": "0609-foreign", "state": "READY_FOR_HUMAN_REVIEW", "iteration": 1}'
out8="$( (cd "$proj8" && "$BIN" task archive 0609-foreign) 2>&1 )"
rc8=$?
specrelay_test::assert_true "8: archive REFUSES a task not owned by SpecRelay" "$([ "$rc8" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_true "8: foreign task left in place" "$([ -d "$dir8" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "8: refusal names the ownership reason" "$out8" "not owned by the SpecRelay engine"

specrelay_test::summary
exit $?
