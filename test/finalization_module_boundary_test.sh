#!/usr/bin/env bash
# finalization_module_boundary_test.sh — spec 0029, section 10.5 / AC-24: a
# deterministic, static check that `workflow.sh` stays a lifecycle
# COORDINATOR and never absorbs finalization-record rendering, lease
# internals, process-group termination, or round-change-ledger
# reconstruction — those stay owned by finalization.sh / lock.sh /
# git_guard.sh / proc_supervisor.py respectively.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

WORKFLOW="$SPECRELAY_ROOT/lib/specrelay/workflow.sh"

# workflow.sh must never construct the finalization record's JSON directly
# (that is finalization_lib.py's job) or write to its numbered path itself.
specrelay_test::assert_true "workflow.sh never opens 30-executor-finalization.json directly" \
  "$(grep -q '30-executor-finalization\.json' "$WORKFLOW" && echo 1 || echo 0)"

# workflow.sh must never touch the lock lease's owner file or lease fields
# directly (pid_start_time/owner_token/heartbeat_at are lock.sh's alone).
specrelay_test::assert_true "workflow.sh never reads/writes lease fields directly" \
  "$(grep -qE 'owner_token|pid_start_time|heartbeat_at' "$WORKFLOW" && echo 1 || echo 0)"

# workflow.sh must never send process-group signals itself (SIGKILL/SIGTERM/
# os.killpg) — that is proc_supervisor.py's/provider.sh's job.
specrelay_test::assert_true "workflow.sh never sends process-group signals directly" \
  "$(grep -qE 'killpg|SIGKILL|SIGTERM' "$WORKFLOW" && echo 1 || echo 0)"

# workflow.sh must never reconstruct or hand-derive the round-change ledger
# / owned-snapshot itself — it only CALLS git_guard.sh's public API.
specrelay_test::assert_true "workflow.sh never opens the round-change ledger file directly" \
  "$(grep -q '32-round-change-ledger\.jsonl' "$WORKFLOW" && echo 1 || echo 0)"

# Positive control: confirm those responsibilities really DO live in their
# owning modules (a passing check above for the wrong reason — e.g. the
# feature not existing at all — would be a false sense of safety).
FINALIZATION="$SPECRELAY_ROOT/lib/specrelay/finalization.sh"
LOCK="$SPECRELAY_ROOT/lib/specrelay/lock.sh"
GIT_GUARD="$SPECRELAY_ROOT/lib/specrelay/git_guard.sh"
PROC_SUPERVISOR="$SPECRELAY_ROOT/lib/specrelay/py/proc_supervisor.py"

specrelay_test::assert_true "finalization.sh owns the finalization record path" \
  "$(grep -q '30-executor-finalization\.json' "$FINALIZATION" && echo 0 || echo 1)"
specrelay_test::assert_true "lock.sh owns lease fields" \
  "$(grep -q 'owner_token' "$LOCK" && echo 0 || echo 1)"
specrelay_test::assert_true "git_guard.sh owns the round-change ledger" \
  "$(grep -q '32-round-change-ledger\.jsonl' "$GIT_GUARD" && echo 0 || echo 1)"
specrelay_test::assert_true "proc_supervisor.py owns process-group termination" \
  "$(grep -q 'killpg' "$PROC_SUPERVISOR" && echo 0 || echo 1)"

specrelay_test::summary
