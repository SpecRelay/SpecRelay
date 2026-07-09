#!/usr/bin/env bash
# legacy_compat_test.sh — SpecRelay must be able to INSPECT tasks created by
# the legacy .ai/ workflow (accepted, changes-requested, multi-iteration)
# without mutating them, and must REFUSE to mutate them (spec sections 48-50,
# 64). Fixtures below mirror the real shape documented in
# tools/specrelay/docs/current-workflow-contract.md (state.json fields,
# canonical states, legacy READY_FOR_CODEX_REVIEW alias) without embedding
# any real project data — never the real repository's own .ai-runs/ tasks.
#   tools/specrelay/test/legacy_compat_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

proj="$(specrelay_test::mktemp_specrelay_project)"
tasks_dir="$proj/.ai-runs/tasks"

# --- fixture 1: an accepted legacy task (READY_FOR_HUMAN_REVIEW) ------------
accepted_dir="$tasks_dir/0040-legacy-accepted"
mkdir -p "$accepted_dir"
cat > "$accepted_dir/state.json" <<'JSON'
{
  "task_id": "0040-legacy-accepted",
  "state": "READY_FOR_HUMAN_REVIEW",
  "created_at": "2026-01-01T00:00:00Z",
  "base_commit": "deadbeef",
  "approved_at": "2026-01-01T00:05:00Z",
  "approved_by": "human",
  "claimed_at": "2026-01-01T00:06:00Z",
  "claimed_by": "local-runner",
  "submitted_for_review_at": "2026-01-01T01:00:00Z",
  "submitted_for_review_by": "local-runner",
  "reviewed_at": "2026-01-01T02:00:00Z",
  "reviewed_by": "reviewer-agent",
  "review_result": "accepted",
  "reviewer_provider": "claude-subagent"
}
JSON
for f in 00-user-request.md 01-consultant-analysis.md 02-executor-prompt.md 03-executor-log.md \
  07-tests.txt 08-executor-summary.md 09-consultant-review.md 10-business-summary.md; do
  echo "legacy fixture content for $f" > "$accepted_dir/$f"
done
: > "$accepted_dir/04-git-status.txt"
: > "$accepted_dir/05-changed-files.txt"
: > "$accepted_dir/05-git-diff-stat.txt"
: > "$accepted_dir/06-git-diff.patch"

# --- fixture 2: a changes-requested legacy task, using the legacy alias ------
changes_dir="$tasks_dir/0041-legacy-changes-requested"
mkdir -p "$changes_dir"
cat > "$changes_dir/state.json" <<'JSON'
{
  "task_id": "0041-legacy-changes-requested",
  "state": "CHANGES_REQUESTED",
  "created_at": "2026-01-02T00:00:00Z",
  "base_commit": "cafef00d",
  "approved_at": "2026-01-02T00:05:00Z",
  "submitted_for_codex_review_at": "2026-01-02T01:00:00Z",
  "changes_requested_at": "2026-01-02T02:00:00Z",
  "changes_requested_reason": "needs more tests"
}
JSON
echo "legacy prompt" > "$changes_dir/02-executor-prompt.md"

# --- fixture 3: a multi-iteration legacy task (has a requeue backup) --------
multi_dir="$tasks_dir/0042-legacy-multi-iteration"
mkdir -p "$multi_dir"
cat > "$multi_dir/state.json" <<'JSON'
{
  "task_id": "0042-legacy-multi-iteration",
  "state": "READY_FOR_EXECUTOR",
  "created_at": "2026-01-03T00:00:00Z",
  "base_commit": "0ff1ce00",
  "requeued_at": "2026-01-03T03:00:00Z",
  "requeued_by": "reviewer-agent"
}
JSON
echo "round 2 prompt" > "$multi_dir/02-executor-prompt.md"
echo "round 1 prompt (backed up)" > "$multi_dir/02-executor-prompt.before-requeue-20260103T030000Z.md"

# --- snapshot every fixture file's content + mtime before any SpecRelay call
snapshot() {
  (cd "$proj" && find .ai-runs -type f -exec sh -c '
      for f; do
        printf "%s %s %s\n" "$f" "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")" "$(cksum < "$f")"
      done
    ' sh {} + | sort)
}
before="$(snapshot)"

# --- read-only inspection must work for all three legacy fixtures ----------
for id in 0040-legacy-accepted 0041-legacy-changes-requested 0042-legacy-multi-iteration; do
  out="$(cd "$proj" && "$SPECRELAY_BIN" task show "$id" 2>&1)"
  rc=$?
  specrelay_test::assert_eq "task show succeeds for legacy fixture $id" "0" "$rc"
  specrelay_test::assert_contains "task show reports the task id for $id" "$out" "$id"
done

status_all="$(cd "$proj" && "$SPECRELAY_BIN" status 2>&1)"
specrelay_test::assert_contains "status lists the accepted legacy task" "$status_all" "0040-legacy-accepted"
specrelay_test::assert_contains "status lists the changes-requested legacy task" "$status_all" "0041-legacy-changes-requested"
specrelay_test::assert_contains "status shows the canonical state for the legacy alias task" \
  "$(cd "$proj" && "$SPECRELAY_BIN" task status 0041-legacy-changes-requested 2>&1)" "CHANGES_REQUESTED"

list_out="$(cd "$proj" && "$SPECRELAY_BIN" list 2>&1)"
specrelay_test::assert_contains "list includes the multi-iteration legacy task" "$list_out" "0042-legacy-multi-iteration"

after="$(snapshot)"
specrelay_test::assert_eq "no read-only inspection command mutated any legacy fixture file" "$before" "$after"

# --- mutating commands must refuse a task SpecRelay does not own -----------
approve_out="$(cd "$proj" && "$SPECRELAY_BIN" task approve 0042-legacy-multi-iteration 2>&1)"
rc=$?
specrelay_test::assert_true "task approve refuses a legacy (non-specrelay-owned) task" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "refusal names the ownership reason" "$approve_out" "not owned by the SpecRelay engine"

requeue_out="$(cd "$proj" && "$SPECRELAY_BIN" task requeue 0042-legacy-multi-iteration 2>&1)"
rc=$?
specrelay_test::assert_true "task requeue refuses a legacy (non-specrelay-owned) task" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

after_mutation_attempt="$(snapshot)"
specrelay_test::assert_eq "a refused mutation attempt leaves every legacy fixture file untouched" \
  "$before" "$after_mutation_attempt"

specrelay_test::summary
exit $?
