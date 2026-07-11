#!/usr/bin/env bash
# providers/fake.sh — deterministic executor/reviewer provider for tests
# (spec section 60). Never invokes a real CLI. Behavior per round is driven
# by an optional PLAN FILE (one line per round, 1-indexed), so a test can
# script exact multi-round scenarios (accept-first-round, changes-then-
# accept, executor failure, reviewer failure, max-rounds) without any real
# provider call.
#
# Plan line format: comma-separated key=value pairs.
#   executor plan keys:  exit=<0|N> (default 0), outputs=<0|1> (default 1),
#                        touch=<0|1> (default 1, appends a line to the
#                        configured fixture file to produce a real diff)
#   reviewer plan keys:  exit=<0|N> (default 0),
#                        decision=<accept|request_changes> (default accept)
#
# Env hooks:
#   SPECRELAY_FAKE_EXECUTOR_PLAN   path to the executor plan file (optional)
#   SPECRELAY_FAKE_REVIEWER_PLAN   path to the reviewer plan file (optional)
#   SPECRELAY_FAKE_IMPL_FILE       fixture file the executor "implements"
#                                  into (default: <project-root>/specrelay-fake-impl.txt)
#   SPECRELAY_FAKE_REVIEWER_SELF_TRANSITION
#                                  when =1, the reviewer ALSO enacts its own
#                                  decision transition (accept/request-changes)
#                                  before emitting its DECISION line — exactly
#                                  what a real reviewer agent running under
#                                  `claude --print --dangerously-skip-permissions`
#                                  can do, since accept/request-changes are NOT
#                                  runner-owned. This deterministically
#                                  reproduces the spec 0004 duplicate-transition
#                                  bug (a runner that then transitions AGAIN out
#                                  of an already-final state).
# Missing a plan file (or a line past its end) falls back to the defaults
# above, so a scenario that only cares about round 1 need not specify later
# rounds explicitly.

specrelay::provider::fake::_plan_line() {
  local file="$1" round="$2"
  [ -n "$file" ] && [ -f "$file" ] || { printf ''; return 0; }
  sed -n "${round}p" "$file"
}

specrelay::provider::fake::_field() {
  local line="$1" key="$2" default="$3" val
  val="$(printf '%s' "$line" | tr ',' '\n' | sed -n "s/^${key}=//p" | head -n1)"
  printf '%s' "${val:-$default}"
}

# Emitted THROUGH specrelay::provider::run_streamed so the fake provider
# exercises the exact same live-streaming + capture path as a real provider
# (spec 0003): its lines appear live on the terminal (prefixed) and are
# captured raw to 12-executor-stdout.txt. Deliberately small and deterministic
# so the test suite stays non-flaky and non-noisy.
specrelay::provider::fake::_executor_emit() {
  local round="$1" prompt_file="$2" exit_code="$3" outputs="$4" touch_flag="$5"
  echo "[fake-executor] round $round"
  echo "[fake-executor] prompt file: $prompt_file"
  echo "[fake-executor] plan: exit=$exit_code outputs=$outputs touch=$touch_flag"
}

specrelay::provider::fake::executor_run() {
  local root="$1" task_dir="$2" round="$3" prompt_file="$4" label="${5:-executor:fake}"
  local plan_line exit_code outputs touch_flag impl_file

  plan_line="$(specrelay::provider::fake::_plan_line "${SPECRELAY_FAKE_EXECUTOR_PLAN:-}" "$round")"
  exit_code="$(specrelay::provider::fake::_field "$plan_line" exit "0")"
  outputs="$(specrelay::provider::fake::_field "$plan_line" outputs "1")"
  touch_flag="$(specrelay::provider::fake::_field "$plan_line" touch "1")"

  # Test-only: widen the race window for concurrency tests (see
  # concurrent_test.sh) by sleeping AFTER the claim has already happened
  # (this function only runs once claim-task has already claimed the task).
  if [ -n "${SPECRELAY_FAKE_EXECUTOR_SLEEP:-}" ]; then
    sleep "$SPECRELAY_FAKE_EXECUTOR_SLEEP"
  fi

  specrelay::provider::run_streamed "$label" \
    "$task_dir/12-executor-stdout.txt" "$task_dir/13-executor-stderr.txt" "$root" -- \
    specrelay::provider::fake::_executor_emit "$round" "$prompt_file" "$exit_code" "$outputs" "$touch_flag"

  if [ "$touch_flag" = "1" ]; then
    impl_file="${SPECRELAY_FAKE_IMPL_FILE:-$root/specrelay-fake-impl.txt}"
    echo "round $round change" >> "$impl_file"
  fi

  if [ "$outputs" = "1" ]; then
    printf 'Fake executor log for round %s.\n' "$round" > "$task_dir/03-executor-log.md"
    printf 'Fake test output for round %s: 1 example, 0 failures.\n' "$round" > "$task_dir/07-tests.txt"
    printf 'Fake executor summary for round %s.\n' "$round" > "$task_dir/08-executor-summary.md"
  fi

  return "$exit_code"
}

specrelay::provider::fake::_reviewer_emit() {
  local round="$1" prompt_file="$2" exit_code="$3" decision="$4"
  echo "[fake-reviewer] round $round"
  echo "[fake-reviewer] prompt file: $prompt_file"
  echo "[fake-reviewer] plan: exit=$exit_code decision=$decision"
}

specrelay::provider::fake::reviewer_run() {
  local root="$1" task_dir="$2" round="$3" prompt_file="$4" label="${5:-reviewer:fake}"
  local plan_line exit_code decision

  plan_line="$(specrelay::provider::fake::_plan_line "${SPECRELAY_FAKE_REVIEWER_PLAN:-}" "$round")"
  exit_code="$(specrelay::provider::fake::_field "$plan_line" exit "0")"
  decision="$(specrelay::provider::fake::_field "$plan_line" decision "accept")"

  # Stream the reviewer's log lines live to fd 2 and capture them raw to
  # 15-reviewer-stdout.txt. The ACCEPT/REQUEST_CHANGES decision below is
  # printed to this function's OWN stdout (fd 1), which the lifecycle reads via
  # command substitution — kept strictly separate from the streamed copy.
  specrelay::provider::run_streamed "$label" \
    "$task_dir/15-reviewer-stdout.txt" "$task_dir/16-reviewer-stderr.txt" "$root" -- \
    specrelay::provider::fake::_reviewer_emit "$round" "$prompt_file" "$exit_code" "$decision"

  if [ "$exit_code" != "0" ]; then
    return "$exit_code"
  fi

  printf 'Fake reviewer notes for round %s.\n' "$round" > "$task_dir/09-consultant-review.md"
  if [ "$decision" = "accept" ]; then
    printf 'Fake business summary for round %s.\n' "$round" > "$task_dir/10-business-summary.md"
    # Simulate a real reviewer agent that enacts its own decision (accept is
    # NOT runner-owned, so an agent with CLI access can run it directly). Its
    # output goes to the reviewer stdout capture, never to the decision stream
    # the runner reads from this function's own stdout (spec 0004 repro).
    if [ "${SPECRELAY_FAKE_REVIEWER_SELF_TRANSITION:-}" = "1" ]; then
      specrelay::transitions::accept "$root" "$(basename "$task_dir")" fake \
        >> "$task_dir/15-reviewer-stdout.txt" 2>&1 || true
    fi
    echo "ACCEPT"
  else
    printf 'Fake next executor prompt for round %s.\n' "$round" > "$task_dir/11-next-executor-prompt.md"
    if [ "${SPECRELAY_FAKE_REVIEWER_SELF_TRANSITION:-}" = "1" ]; then
      specrelay::transitions::request_changes "$root" "$(basename "$task_dir")" \
        "fake reviewer self-enacted request-changes" fake \
        >> "$task_dir/15-reviewer-stdout.txt" 2>&1 || true
    fi
    echo "REQUEST_CHANGES"
  fi
  return 0
}
