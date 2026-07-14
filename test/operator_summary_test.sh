#!/usr/bin/env bash
# operator_summary_test.sh — spec 0022, section 7: summary-first terminal
# output. Exercises the REAL 'specrelay run' lifecycle with the deterministic
# fake providers.
#
#   test/operator_summary_test.sh
#
# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

specrelay_test::run() {
  local proj="$1" spec="$2"
  shift 2
  (cd "$proj" && "$SPECRELAY_BIN" run "$spec" "$@")
}

# --- 1. default output: concise summary card, no automatic full dump -------
proj_a="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_a/docs/sdd/0001-summary"
echo "# summary spec" > "$proj_a/docs/sdd/0001-summary/spec.md"
out_a="$(specrelay_test::run "$proj_a" "docs/sdd/0001-summary/spec.md" 2>&1)"
specrelay_test::assert_eq "default run exits 0" "0" "$?"

specrelay_test::assert_contains "default output has the SpecRelay Result summary card" "$out_a" "SpecRelay Result"
specrelay_test::assert_contains "summary shows the terminal state" "$out_a" "READY FOR HUMAN REVIEW"
specrelay_test::assert_contains "summary shows the Task field" "$out_a" "Task"
specrelay_test::assert_contains "summary shows an Executor status+duration field" "$out_a" "Executor"
specrelay_test::assert_contains "summary shows a Reviewer status+duration field" "$out_a" "Reviewer"
specrelay_test::assert_contains "summary shows a Tests field" "$out_a" "Tests"
specrelay_test::assert_contains "summary shows a Context field" "$out_a" "Context"
specrelay_test::assert_contains "summary shows an Active time field" "$out_a" "Active time"
specrelay_test::assert_contains "summary shows a Warnings field" "$out_a" "Warnings"
specrelay_test::assert_contains "summary points at the full 'task report' command" "$out_a" "specrelay task report"

specrelay_test::assert_not_contains "default output does NOT dump the full Execution Timeline table" "$out_a" "Execution Timeline --"
specrelay_test::assert_not_contains "default output does NOT dump the Command Timing detail" "$out_a" "Command Timing"
specrelay_test::assert_not_contains "default output does NOT dump the Agent Efficiency detail" "$out_a" "Agent Efficiency"

# Roughly 15-20 lines (spec 7.1) for the FINAL SUMMARY BLOCK specifically —
# not the whole run transcript, which legitimately includes provider
# streaming/log lines from earlier in execution (spec 7.1 explicitly excludes
# those). Isolate from the "SpecRelay Result" card onward.
summary_block="$(printf '%s\n' "$out_a" | awk '/SpecRelay Result/{found=1} found')"
summary_lines="$(printf '%s\n' "$summary_block" | grep -c '[^[:space:]]')"
specrelay_test::assert_true "the final summary block is concise (~15-20 lines, not a full detail dump)" \
  "$( [ "$summary_lines" -le 20 ]; echo $? )"

# --- 2. task report gives the full combined detail on request --------------
report_out="$(cd "$proj_a" && "$SPECRELAY_BIN" task report 0001-summary 2>&1)"
specrelay_test::assert_contains "'task report' includes the Execution Timeline" "$report_out" "Execution Timeline"

report_json="$(cd "$proj_a" && "$SPECRELAY_BIN" task report 0001-summary --json 2>&1)"
valid_json="$(printf '%s' "$report_json" | python3 -c 'import json,sys; json.load(sys.stdin); print("ok")' 2>/dev/null)"
specrelay_test::assert_eq "'task report --json' is valid JSON" "ok" "$valid_json"
has_keys="$(printf '%s' "$report_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(all(k in d for k in ("timeline","command_timing","agent_efficiency","task_id")))' 2>/dev/null)"
specrelay_test::assert_eq "'task report --json' has timeline/command_timing/agent_efficiency/task_id keys" "True" "$has_keys"

# --- 3. --verbose restores the full detail inline, in addition to the summary
proj_b="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_b/docs/sdd/0002-verbose"
echo "# verbose spec" > "$proj_b/docs/sdd/0002-verbose/spec.md"
out_b="$(specrelay_test::run "$proj_b" "docs/sdd/0002-verbose/spec.md" --verbose 2>&1)"
specrelay_test::assert_contains "--verbose still shows the concise summary card" "$out_b" "SpecRelay Result"
specrelay_test::assert_contains "--verbose ALSO shows the full Execution Timeline" "$out_b" "Execution Timeline --"

# --- 4. redirected / non-TTY output is plain text, still contains the summary
plain_out="$( (cd "$proj_a" && "$SPECRELAY_BIN" task report 0001-summary) | cat )"
specrelay_test::assert_contains "redirected 'task report' output is readable plain text" "$plain_out" "Execution Timeline"

# --- 5. resume also supports --verbose (resuming an already-terminal task is
# idempotent: it immediately re-confirms READY_FOR_HUMAN_REVIEW, exit 0) -----
resume_out="$(cd "$proj_a" && "$SPECRELAY_BIN" resume 0001-summary --verbose 2>&1)"
specrelay_test::assert_eq "'resume --verbose' is accepted (no 'unknown option' usage error)" "0" "$?"
specrelay_test::assert_contains "'resume --verbose' also shows the full Execution Timeline" "$resume_out" "Execution Timeline --"

specrelay_test::summary
exit $?
