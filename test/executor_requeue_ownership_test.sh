#!/usr/bin/env bash
# executor_requeue_ownership_test.sh — spec 0029, section 23.2/23.5 regression.
#
# Reproduces the exact dogfooding failure that stranded task 0029's own
# iteration-2 executor claim: a reviewed round that returned CHANGES_REQUESTED
# must requeue to READY_FOR_EXECUTOR and let the NEXT executor claim proceed
# WITHOUT any manual guard-file editing — even when the round's ownership was
# never recorded in 32-round-change-ledger.jsonl during executor_evidence_capture
# (a round finalized out-of-band via a runner authorization, or produced by an
# engine predating the ledger). An unrelated external change must still block,
# named explicitly (section 23.3).
#
#   R1 requeue adopts the round's PROVEN owned paths from durable evidence
#      (05-changed-files.txt) so the next claim's working-tree guard passes.
#   R2 an unrelated external path, absent from the round's evidence, still blocks.
#   R3 end-to-end: `specrelay resume` claims and runs the next round, the claim
#      path self-healing from evidence with no manual guard-file editing.

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

# _reviewed_round_without_ledger <proj> <id> <state>
# Builds a task whose iteration-1 round genuinely changed multiple TRACKED and
# UNTRACKED files and produced full 04/05/06 evidence, but whose ownership was
# NEVER written to 32-round-change-ledger.jsonl — the exact condition that
# stranded task 0029 (round finalized out-of-band / pre-ledger engine).
_reviewed_round_without_ledger() {
  local proj="$1" id="$2" state="$3" dir spec_rel
  spec_rel="docs/sdd/$id/spec.md"
  mkdir -p "$proj/docs/sdd/$id" "$proj/src"
  echo "# $id spec" > "$proj/$spec_rel"
  echo "original tracked line" > "$proj/src/app.txt"
  (cd "$proj" && git add -A && git commit -q -m "seed $id")

  dir="$proj/.specrelay-runs/tasks/$id"
  mkdir -p "$dir"
  specrelay::state::init "$(specrelay::state::path "$dir")" \
    "{\"task_id\": \"$id\", \"state\": \"$state\", \"engine\": \"specrelay\", \"iteration\": 1, \"spec_source\": \"$spec_rel\", \"claimed_at\": \"2026-01-01T00:00:00Z\", \"claimed_by\": \"specrelay-runner\"}" >/dev/null
  specrelay::git_guard::write_baseline "$dir" ""

  printf 'executor prompt r1\n' > "$dir/02-executor-prompt.md"
  printf 'engine-observed executor log\n' > "$dir/03-executor-log.md"
  printf 'test evidence\n' > "$dir/07-tests.txt"
  printf 'summary\n## Input Coverage\ncoverage\n' > "$dir/08-executor-summary.md"
  printf 'reviewer notes\nDecision: REQUEST_CHANGES\n' > "$dir/09-consultant-review.md"
  printf 'rework prompt: close the reviewer gaps\n' > "$dir/11-next-executor-prompt.md"

  # The round's OWN diff: modify a tracked file AND add untracked files (nested).
  echo "round-1 tracked edit" >> "$proj/src/app.txt"
  echo "round-1 new untracked" > "$proj/new-module.txt"
  mkdir -p "$proj/pkg" && echo "round-1 nested untracked" > "$proj/pkg/nested.txt"

  # Evidence capture writes 04/05/06 (05 = name-status proof). We DELIBERATELY
  # do NOT call record_round_change — the ownership is left unrecorded, exactly
  # as it was for task 0029's manually-submitted round.
  specrelay::evidence::capture "$proj" "$dir"

  printf '%s\n' "$dir"
}

# ---- R1: requeue adopts proven owned paths so the next claim's guard passes --
proj1="$(specrelay_test::mktemp_specrelay_project)"
dir1="$(_reviewed_round_without_ledger "$proj1" "0700-requeue-adopt" CHANGES_REQUESTED)"

specrelay_test::assert_true "R1: precondition — no round-change ledger was recorded" \
  "$([ ! -f "$dir1/32-round-change-ledger.jsonl" ] && echo 0 || echo 1)"
# Precondition: with no owned snapshot, the guard would reject the round's diff.
specrelay::git_guard::check "$proj1" "$dir1" >/dev/null 2>&1; pre_rc1=$?
specrelay_test::assert_true "R1: precondition — guard rejects before requeue (bug reproduces)" \
  "$([ "$pre_rc1" -ne 0 ] && echo 0 || echo 1)"

out1="$( (cd "$proj1" && "$BIN" task requeue 0700-requeue-adopt) 2>&1)"
rc1=$?
specrelay_test::assert_eq "R1: requeue succeeds" "0" "$rc1"
specrelay_test::assert_contains "R1: task is READY_FOR_EXECUTOR after requeue" \
  "$(cat "$dir1/state.json")" "READY_FOR_EXECUTOR"
specrelay_test::assert_true "R1: requeue recorded the ownership ledger" \
  "$([ -f "$dir1/32-round-change-ledger.jsonl" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "R1: ledger entry is sourced from evidence" \
  "$(cat "$dir1/32-round-change-ledger.jsonl")" "adopted-from-evidence"

# The next executor claim's guard now passes with NO manual guard-file editing.
specrelay::git_guard::check "$proj1" "$dir1" >/dev/null 2>&1; gc1=$?
specrelay_test::assert_true "R1: working-tree guard now accepts the round's owned diff" "$gc1"
owned1="$(cat "$dir1/.git-owned-snapshot.txt" 2>/dev/null)"
specrelay_test::assert_contains "R1: tracked path is owned" "$owned1" "src/app.txt"
specrelay_test::assert_contains "R1: untracked path is owned" "$owned1" "new-module.txt"
specrelay_test::assert_contains "R1: nested untracked path is owned" "$owned1" "pkg/nested.txt"

# ---- R2: an unrelated external path still blocks, named explicitly -----------
proj2="$(specrelay_test::mktemp_specrelay_project)"
dir2="$(_reviewed_round_without_ledger "$proj2" "0701-requeue-unrelated" CHANGES_REQUESTED)"
(cd "$proj2" && "$BIN" task requeue 0701-requeue-unrelated >/dev/null 2>&1)

# An unrelated external change appears — never part of the round's proof.
echo "unrelated external edit" > "$proj2/unrelated-external.txt"
guard_out2="$(specrelay::git_guard::check "$proj2" "$dir2" 2>&1)"; rc2=$?
specrelay_test::assert_true "R2: unrelated external path still blocks the claim" \
  "$([ "$rc2" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "R2: the unrelated path is named explicitly" \
  "$guard_out2" "unrelated-external.txt"
specrelay_test::assert_not_contains "R2: the round's own owned path is NOT flagged as unrelated" \
  "$guard_out2" "new-module.txt"

# ---- R3: end-to-end — `resume` claims and runs, self-healing at claim time ---
# READY_FOR_EXECUTOR with evidence but NO ledger/owned snapshot: exactly the
# state a pre-ledger requeue would leave. The claim path must self-heal from
# evidence and proceed — no manual guard-file editing.
proj3="$(specrelay_test::mktemp_specrelay_project)"
dir3="$(_reviewed_round_without_ledger "$proj3" "0702-claim-selfheal" READY_FOR_EXECUTOR)"
specrelay_test::assert_true "R3: precondition — no ledger present at claim time" \
  "$([ ! -f "$dir3/32-round-change-ledger.jsonl" ] && echo 0 || echo 1)"

out3="$( (cd "$proj3" && "$BIN" resume 0702-claim-selfheal) 2>&1)"
rc3=$?
specrelay_test::assert_eq "R3: resume drives the requeued round to completion" "0" "$rc3"
specrelay_test::assert_contains "R3: the claim self-healed ownership from durable evidence" \
  "$out3" "adopted the prior round's proven owned paths from durable evidence"
specrelay_test::assert_not_contains "R3: the working-tree guard did NOT refuse the claim" \
  "$out3" "unexpected working-tree changes outside this task"
specrelay_test::assert_not_contains "R3: no manual guard-file editing was suggested" \
  "$out3" "manually"

echo
specrelay_test::summary
