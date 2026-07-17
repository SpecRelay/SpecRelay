#!/usr/bin/env bash
# executor_recovery_test.sh — spec 0029, section 23 ("Safe interrupted-round
# recovery") + section 32.1 tests M/N/O: `specrelay resume` alone (no
# `specrelay task recover`, no hand-edited guard files) safely continues an
# EXECUTOR_RUNNING task whose owning process is gone, adopting ONLY proven
# task-owned paths from the round-change ledger.
#
#   M  a proven diff recovers automatically, without any manual guard-file
#      editing.
#   N  an unrelated external dirty path blocks, naming it explicitly.

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
# shellcheck source=../lib/specrelay/git_guard.sh
. "$SPECRELAY_ROOT/lib/specrelay/git_guard.sh"
# shellcheck source=../lib/specrelay/evidence.sh
. "$SPECRELAY_ROOT/lib/specrelay/evidence.sh"

BIN="$SPECRELAY_ROOT/bin/specrelay"

# _make_interrupted_round <proj> <task-id>
# Simulates a round that crashed AFTER executor_evidence_capture ran (so 04/
# 05/06 + the round-change ledger already exist) but BEFORE the round
# reached submission: state left at EXECUTOR_RUNNING, NO lock held (the
# owning process is simply gone — "absent" lease classification), and a real
# uncommitted change in the working tree that IS this round's own diff.
_make_interrupted_round() {
  local proj="$1" id="$2" dir spec_rel
  spec_rel="docs/sdd/$id/spec.md"
  mkdir -p "$proj/docs/sdd/$id"
  echo "# $id spec" > "$proj/$spec_rel"
  (cd "$proj" && git add -A && git commit -q -m "add spec for $id")

  dir="$proj/.specrelay-runs/tasks/$id"
  mkdir -p "$dir"
  specrelay::state::init "$(specrelay::state::path "$dir")" \
    "{\"task_id\": \"$id\", \"state\": \"EXECUTOR_RUNNING\", \"engine\": \"specrelay\", \"iteration\": 1, \"spec_source\": \"$spec_rel\", \"claimed_at\": \"2026-01-01T00:00:00Z\", \"claimed_by\": \"specrelay-runner\"}" >/dev/null
  specrelay::git_guard::write_baseline "$dir" ""
  printf 'executor prompt\n' > "$dir/02-executor-prompt.md"
  printf 'executor log content\n' > "$dir/03-executor-log.md"
  printf 'test output content\n' > "$dir/07-tests.txt"
  printf 'summary content\n## Input Coverage\ncoverage\n' > "$dir/08-executor-summary.md"

  # This round's OWN change: a real, uncommitted repository edit.
  echo "round 1 change" >> "$proj/round-1-output.txt"
  (cd "$proj" && git add -A)
  (cd "$proj" && git reset -- round-1-output.txt >/dev/null)

  specrelay::evidence::capture "$proj" "$dir"
  specrelay::git_guard::record_round_change "$proj" "$dir" "1"
  specrelay::git_guard::derive_owned_from_ledger "$proj" "$dir"
  printf '%s\n' "$dir"
}

# ---- M: recovery after an incomplete round with proven diff ownership ------
proj_m="$(specrelay_test::mktemp_specrelay_project)"
dir_m="$(_make_interrupted_round "$proj_m" "0600-recover-m")"

out_m="$( (cd "$proj_m" && "$BIN" resume 0600-recover-m --verbose) 2>&1)"
rc_m=$?
specrelay_test::assert_eq "M: resume alone recovers and drives to completion" "0" "$rc_m"
specrelay_test::assert_contains "M: auto-recovery message is printed" "$out_m" "auto-recovering the interrupted round"
specrelay_test::assert_contains "M: reaches READY_FOR_HUMAN_REVIEW" "$out_m" "READY_FOR_HUMAN_REVIEW"
specrelay_test::assert_not_contains "M: no manual guard-file editing was needed or suggested" \
  "$out_m" "manually"
specrelay_test::assert_true "M: round-1's own file is present in the final tree" \
  "$([ -f "$proj_m/round-1-output.txt" ] && echo 0 || echo 1)"

# ---- N: an unrelated external dirty path blocks, naming it explicitly -----
proj_n="$(specrelay_test::mktemp_specrelay_project)"
dir_n="$(_make_interrupted_round "$proj_n" "0601-recover-n")"
# A genuinely UNRELATED change: never captured by evidence/ledger for this
# round, and not part of the baseline.
echo "unrelated external edit" > "$proj_n/unrelated-external-file.txt"

out_n="$( (cd "$proj_n" && "$BIN" resume 0601-recover-n) 2>&1)"
rc_n=$?
specrelay_test::assert_true "N: resume refuses (unrelated dirty path)" "$([ "$rc_n" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "N: names the unrelated path" "$out_n" "unrelated-external-file.txt"
specrelay_test::assert_contains "N: task remains EXECUTOR_RUNNING" \
  "$(cat "$dir_n/state.json")" "EXECUTOR_RUNNING"

echo
specrelay_test::summary
