#!/usr/bin/env bash
# provider_streaming_test.sh — live provider terminal output (spec 0003).
#
# Proves, through the deterministic 'fake' provider and the real CLI
# (bin/specrelay run), that:
#   1. executor provider output is streamed LIVE to the terminal, scoped by a
#      role/provider prefix ([executor:fake]);
#   2. reviewer provider output is streamed LIVE too, scoped by its own prefix
#      ([reviewer:fake]);
#   3. the durable evidence files still contain the COMPLETE provider output,
#      raw and UNprefixed (live prefixing is an operator UX layer only);
#   4. a failing provider is STILL detected when its output is streamed — the
#      streaming path never masks a non-zero exit as success.
#
# Everything runs against isolated temp git fixtures; never a real CLI, never
# this repository's own tasks.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

specrelay_test::run() {
  local proj="$1" spec="$2"
  shift 2
  (cd "$proj" && "$SPECRELAY_BIN" run "$spec" "$@")
}

# =============================================================================
# Scenario 1 — happy path: executor + reviewer output is visible live, scoped
#   by role/provider, and the evidence files still hold the raw output.
# =============================================================================
proj1="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj1/docs/sdd/0001-streaming"
echo "# Streaming spec" > "$proj1/docs/sdd/0001-streaming/spec.md"

# Capture stdout+stderr together, exactly as an operator's terminal shows both.
out1="$(specrelay_test::run "$proj1" "docs/sdd/0001-streaming/spec.md" 2>&1)"
rc1=$?
specrelay_test::assert_eq "scenario 1: run exits 0" "0" "$rc1"

specrelay_test::assert_contains "scenario 1: executor output is streamed live, scoped [executor:fake]" \
  "$out1" "[executor:fake]"
specrelay_test::assert_contains "scenario 1: reviewer output is streamed live, scoped [reviewer:fake]" \
  "$out1" "[reviewer:fake]"
# The scoped prefix must wrap the actual provider line (not be ambiguous).
specrelay_test::assert_contains "scenario 1: executor stream carries the provider's real line" \
  "$out1" "[executor:fake] [fake-executor] round 1"
specrelay_test::assert_contains "scenario 1: reviewer stream carries the provider's real line" \
  "$out1" "[reviewer:fake] [fake-reviewer] round 1"

# Durable evidence: raw, complete, and NOT prefixed with the live scope.
task1="$proj1/.ai-runs/tasks/0001-streaming"
exec_cap="$(cat "$task1/12-executor-stdout.txt" 2>/dev/null)"
rev_cap="$(cat "$task1/15-reviewer-stdout.txt" 2>/dev/null)"
specrelay_test::assert_contains "scenario 1: executor evidence still holds the complete output" \
  "$exec_cap" "[fake-executor] round 1"
specrelay_test::assert_not_contains "scenario 1: executor evidence is raw (no live [executor:fake] prefix)" \
  "$exec_cap" "[executor:fake]"
specrelay_test::assert_contains "scenario 1: reviewer evidence still holds the complete output" \
  "$rev_cap" "[fake-reviewer] round 1"
specrelay_test::assert_not_contains "scenario 1: reviewer evidence is raw (no live [reviewer:fake] prefix)" \
  "$rev_cap" "[reviewer:fake]"

# Streaming did not corrupt the reviewer's machine-readable decision channel.
specrelay_test::assert_contains "scenario 1: reviewer decision still drives the transition" \
  "$out1" "READY_FOR_HUMAN_REVIEW"

# =============================================================================
# Scenario 2 — failing executor: output is streamed live AND the failure is
#   still detected (exit non-zero, task not submitted for review). Proves the
#   streaming path does not let a failing provider look successful.
# =============================================================================
proj2="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj2/docs/sdd/0002-streaming-fail"
echo "# Streaming failure spec" > "$proj2/docs/sdd/0002-streaming-fail/spec.md"
plan_dir2="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")"
printf 'exit=1\n' > "$plan_dir2/exec-plan.txt"

out2="$(SPECRELAY_FAKE_EXECUTOR_PLAN="$plan_dir2/exec-plan.txt" specrelay_test::run "$proj2" "docs/sdd/0002-streaming-fail/spec.md" 2>&1)"
rc2=$?
specrelay_test::assert_true "scenario 2: run exits non-zero on a failing (but streamed) executor" \
  "$([ "$rc2" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "scenario 2: the failing executor's output was still streamed live" \
  "$out2" "[executor:fake] [fake-executor] round 1"
specrelay_test::assert_not_contains "scenario 2: streaming did not fake success" \
  "$out2" "reached READY_FOR_HUMAN_REVIEW"
task2="$proj2/.ai-runs/tasks/0002-streaming-fail"
specrelay_test::assert_contains "scenario 2: task remained EXECUTOR_RUNNING (not submitted)" \
  "$(cat "$task2/state.json")" "EXECUTOR_RUNNING"

# =============================================================================
# Scenario 3 — unit check: run_streamed returns the wrapped command's REAL
#   exit code (never a tee/pipe status), while still capturing + streaming.
# =============================================================================
# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/providers/provider.sh
. "$SPECRELAY_ROOT/lib/specrelay/providers/provider.sh"

stream_dir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-stream-unit.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$stream_dir")

stream_out="$(specrelay::provider::run_streamed "unit:test" \
  "$stream_dir/out.txt" "$stream_dir/err.txt" "$stream_dir" -- \
  bash -c 'echo captured-stdout; echo captured-stderr >&2; exit 7' 2>"$stream_dir/live.txt")"
stream_rc=$?
specrelay_test::assert_eq "scenario 3: run_streamed preserves the real exit code (7)" "7" "$stream_rc"
specrelay_test::assert_eq "scenario 3: nothing leaks onto run_streamed's own stdout" "" "$stream_out"
specrelay_test::assert_contains "scenario 3: stdout captured raw to file" \
  "$(cat "$stream_dir/out.txt")" "captured-stdout"
specrelay_test::assert_contains "scenario 3: stderr captured raw to file" \
  "$(cat "$stream_dir/err.txt")" "captured-stderr"
specrelay_test::assert_contains "scenario 3: stdout streamed live with scope prefix" \
  "$(cat "$stream_dir/live.txt")" "[unit:test] captured-stdout"
specrelay_test::assert_contains "scenario 3: stderr streamed live with scope prefix" \
  "$(cat "$stream_dir/live.txt")" "[unit:test] captured-stderr"

specrelay_test::summary
exit $?
