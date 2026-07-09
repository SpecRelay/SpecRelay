#!/usr/bin/env bash
# transitions_test.sh — unit tests for transitions.sh + auth.sh: the full
# create -> approve -> claim -> submit(authorized) -> accept/request-changes
# -> requeue -> block lifecycle, forbidden transitions, and the runner-owned
# submit-authorization gate (spec sections 11, 12).
#   tools/specrelay/test/transitions_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
for f in output project config discovery state task lock auth git_guard evidence transitions; do
  # shellcheck disable=SC1090
  . "$SPECRELAY_ROOT/lib/specrelay/$f.sh"
done

proj="$(specrelay_test::mktemp_project_with_spec "0001-fixture")"
spec_rel="docs/sdd/0001-fixture/spec.md"

# --- create ------------------------------------------------------------
specrelay::transitions::create "$proj" "0001-fixture" "$spec_rel" "0" >/dev/null
rc=$?
specrelay_test::assert_eq "create succeeds for a new task" "0" "$rc"

task_dir="$(specrelay::task::dir "$proj" "0001-fixture")"
state_file="$(specrelay::state::path "$task_dir")"
specrelay_test::assert_eq "create writes state DRAFT" "DRAFT" "$(specrelay::state::canonical "$state_file")"
specrelay_test::assert_eq "create records the engine as specrelay" "specrelay" "$(specrelay::state::get "$state_file" "engine")"
specrelay_test::assert_eq "create records the spec source" "$spec_rel" "$(specrelay::state::get "$state_file" "spec_source")"

specrelay::transitions::create "$proj" "0001-fixture" "$spec_rel" "0" >/tmp/specrelay-dup.$$ 2>&1
rc=$?
specrelay_test::assert_true "create refuses to overwrite an existing task" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
rm -f /tmp/specrelay-dup.$$

# --- approve -------------------------------------------------------------
specrelay::transitions::approve "$proj" "0001-fixture" >/dev/null
rc=$?
specrelay_test::assert_eq "approve succeeds from DRAFT" "0" "$rc"
specrelay_test::assert_eq "approve transitions to READY_FOR_EXECUTOR" "READY_FOR_EXECUTOR" "$(specrelay::state::canonical "$state_file")"

specrelay::transitions::approve "$proj" "0001-fixture" >/tmp/specrelay-reapprove.$$ 2>&1
rc=$?
specrelay_test::assert_true "approve refuses a second time (already approved)" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
rm -f /tmp/specrelay-reapprove.$$

# --- claim: refuses an empty executor prompt --------------------------------
: > "$task_dir/02-executor-prompt.md"
specrelay::transitions::claim "$proj" "0001-fixture" >/tmp/specrelay-emptyprompt.$$ 2>&1
rc=$?
specrelay_test::assert_true "claim refuses an empty executor prompt" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
rm -f /tmp/specrelay-emptyprompt.$$
echo "Prompt #1 — do the fixture thing" > "$task_dir/02-executor-prompt.md"

specrelay::transitions::claim "$proj" "0001-fixture" >/dev/null
rc=$?
specrelay_test::assert_eq "claim succeeds with a non-empty prompt" "0" "$rc"
specrelay_test::assert_eq "claim transitions to EXECUTOR_RUNNING" "EXECUTOR_RUNNING" "$(specrelay::state::canonical "$state_file")"

# --- submit: refused without a valid authorization token --------------------
printf 'log\n' > "$task_dir/03-executor-log.md"
printf 'tests\n' > "$task_dir/07-tests.txt"
printf 'summary\n' > "$task_dir/08-executor-summary.md"
specrelay::evidence::capture "$proj" "$task_dir"

specrelay::transitions::submit "$proj" "0001-fixture" "wrong-token" >/tmp/specrelay-badtoken.$$ 2>&1
rc=$?
specrelay_test::assert_true "submit refuses an invalid/missing authorization token" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_eq "a refused submit leaves the task EXECUTOR_RUNNING" "EXECUTOR_RUNNING" "$(specrelay::state::canonical "$state_file")"
rm -f /tmp/specrelay-badtoken.$$

token="$(specrelay::auth::mint "$proj" "0001-fixture")"
specrelay::transitions::submit "$proj" "0001-fixture" "$token" >/dev/null
rc=$?
specrelay_test::assert_eq "submit succeeds with a validly minted token" "0" "$rc"
specrelay_test::assert_eq "submit transitions to READY_FOR_REVIEW" "READY_FOR_REVIEW" "$(specrelay::state::canonical "$state_file")"

specrelay::transitions::submit "$proj" "0001-fixture" "$token" >/tmp/specrelay-reuse.$$ 2>&1
rc=$?
specrelay_test::assert_true "a consumed submit token cannot be reused" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
rm -f /tmp/specrelay-reuse.$$

# --- request-changes: requires 09 + 11 --------------------------------------
specrelay::transitions::request_changes "$proj" "0001-fixture" "needs work" "fake" >/tmp/specrelay-nofiles.$$ 2>&1
rc=$?
specrelay_test::assert_true "request-changes refuses without 09/11 written" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
rm -f /tmp/specrelay-nofiles.$$

printf 'review notes\n' > "$task_dir/09-consultant-review.md"
printf 'do it differently\n' > "$task_dir/11-next-executor-prompt.md"
specrelay::transitions::request_changes "$proj" "0001-fixture" "needs work" "fake" >/dev/null
rc=$?
specrelay_test::assert_eq "request-changes succeeds once 09/11 exist" "0" "$rc"
specrelay_test::assert_eq "request-changes transitions to CHANGES_REQUESTED" "CHANGES_REQUESTED" "$(specrelay::state::canonical "$state_file")"

# --- requeue: promotes 11 -> 02, backs up old prompt, bumps iteration -------
old_prompt="$(cat "$task_dir/02-executor-prompt.md")"
specrelay::transitions::requeue "$proj" "0001-fixture" >/dev/null
rc=$?
specrelay_test::assert_eq "requeue succeeds from CHANGES_REQUESTED" "0" "$rc"
specrelay_test::assert_eq "requeue transitions to READY_FOR_EXECUTOR" "READY_FOR_EXECUTOR" "$(specrelay::state::canonical "$state_file")"
specrelay_test::assert_contains "requeue promotes 11-next-executor-prompt.md into 02" \
  "$(cat "$task_dir/02-executor-prompt.md")" "do it differently"
specrelay_test::assert_eq "requeue increments the iteration counter" "2" "$(specrelay::state::get "$state_file" "iteration")"

backup_count="$(find "$task_dir" -maxdepth 1 -name '02-executor-prompt.before-requeue-*' | wc -l | tr -d ' ')"
specrelay_test::assert_eq "requeue leaves exactly one backup of the previous prompt" "1" "$backup_count"

archive_count="$(find "$task_dir/iterations/round-1" -type f 2>/dev/null | wc -l | tr -d ' ')"
specrelay_test::assert_true "requeue archives round 1's artifacts before overwriting them" "$([ "$archive_count" -gt 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "the round-1 archive keeps round 1's 09-consultant-review.md" \
  "$(cat "$task_dir/iterations/round-1/09-consultant-review.md" 2>/dev/null)" "review notes"

# --- block: only from EXECUTOR_RUNNING --------------------------------------
specrelay::transitions::block "$proj" "0001-fixture" "cannot proceed" >/tmp/specrelay-block-wrong-state.$$ 2>&1
rc=$?
specrelay_test::assert_true "block refuses from a non-EXECUTOR_RUNNING state" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
rm -f /tmp/specrelay-block-wrong-state.$$

: > "$task_dir/02-executor-prompt.md"
echo "Prompt #1 — retry" > "$task_dir/02-executor-prompt.md"
specrelay::transitions::claim "$proj" "0001-fixture" >/dev/null
specrelay::transitions::block "$proj" "0001-fixture" "cannot proceed" >/dev/null
rc=$?
specrelay_test::assert_eq "block succeeds from EXECUTOR_RUNNING" "0" "$rc"
specrelay_test::assert_eq "block transitions to BLOCKED" "BLOCKED" "$(specrelay::state::canonical "$state_file")"

# --- cross-engine mutation safety (spec section 50) -------------------------
legacy_task_dir="$proj/.ai-runs/tasks/9999-legacy-task"
mkdir -p "$legacy_task_dir"
legacy_state="$(specrelay::state::path "$legacy_task_dir")"
specrelay::state::init "$legacy_state" '{"task_id": "9999-legacy-task", "state": "READY_FOR_EXECUTOR"}' >/dev/null
echo "some prompt" > "$legacy_task_dir/02-executor-prompt.md"

specrelay::transitions::claim "$proj" "9999-legacy-task" >/tmp/specrelay-crossengine.$$ 2>&1
rc=$?
specrelay_test::assert_true "SpecRelay refuses to claim a task it does not own (no engine=specrelay field)" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "cross-engine refusal message is explicit" \
  "$(cat /tmp/specrelay-crossengine.$$)" "not owned by the SpecRelay engine"
rm -f /tmp/specrelay-crossengine.$$

specrelay_test::summary
exit $?
