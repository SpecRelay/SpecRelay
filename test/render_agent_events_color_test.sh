#!/usr/bin/env bash
# render_agent_events_color_test.sh — optional ANSI color for the semantic live
# renderer (render_agent_events.py). Deterministic; NO real Claude. Proves:
#
#   1. default (auto) output to a non-TTY (a captured pipe) stays PLAIN text;
#   2. SPECRELAY_COLOR=always emits ANSI escape codes even to a non-TTY;
#   3. SPECRELAY_COLOR=never emits no ANSI escape codes;
#   4. NO_COLOR disables color in auto mode, but SPECRELAY_COLOR=always overrides
#      NO_COLOR;
#   5. the raw events file and the final-stdout evidence file are NEVER colorized,
#      even when SPECRELAY_COLOR=always.
#
# Color is applied only to the live lines this process writes to stdout; the
# shell wraps that to the operator terminal. Evidence files stay plain.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

FIXTURES="$SPECRELAY_ROOT/test/fixtures/agent-events"
RENDERER="$SPECRELAY_ROOT/lib/specrelay/py/render_agent_events.py"
EXECUTOR_FIXTURE="$FIXTURES/claude-executor.jsonl"

# A literal ESC byte — the leading character of every ANSI escape sequence.
ESC=$'\033'

work="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-color.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$work")

# render <extra-env...> — run the renderer against the executor fixture with
# stdout captured (a non-TTY pipe) and stderr discarded, echoing rendered stdout.
render() {
  env "$@" python3 "$RENDERER" --role executor --provider claude \
    < "$EXECUTOR_FIXTURE" 2>/dev/null
}

# =============================================================================
# 1 — default mode (auto) to a captured pipe (non-TTY): PLAIN text
# =============================================================================
out_default="$(render)"
specrelay_test::assert_not_contains "1: default auto/non-TTY output has NO ANSI escapes" \
  "$out_default" "$ESC["
specrelay_test::assert_contains "1: default output still shows the plain rendered lines" \
  "$out_default" "[executor] command: git status --short"

# =============================================================================
# 2 — SPECRELAY_COLOR=always emits ANSI escapes even to a non-TTY
# =============================================================================
out_always="$(render SPECRELAY_COLOR=always)"
specrelay_test::assert_contains "2: always mode emits ANSI escapes" \
  "$out_always" "$ESC["
specrelay_test::assert_contains "2: always mode dims the role prefix" \
  "$out_always" "${ESC}[2m[executor]${ESC}[0m"
specrelay_test::assert_contains "2: always mode colors a command line yellow" \
  "$out_always" "${ESC}[33mcommand: git status --short${ESC}[0m"
specrelay_test::assert_contains "2: always mode colors the success result green" \
  "$out_always" "${ESC}[32mresult: success"

# =============================================================================
# 3 — SPECRELAY_COLOR=never emits no ANSI escapes
# =============================================================================
out_never="$(render SPECRELAY_COLOR=never)"
specrelay_test::assert_not_contains "3: never mode emits NO ANSI escapes" \
  "$out_never" "$ESC["
specrelay_test::assert_contains "3: never mode still shows the plain rendered lines" \
  "$out_never" "[executor] result: success"

# =============================================================================
# 4 — NO_COLOR disables color in auto, but SPECRELAY_COLOR=always overrides it
# =============================================================================
out_nocolor_auto="$(render NO_COLOR=1)"
specrelay_test::assert_not_contains "4a: NO_COLOR disables color in auto mode" \
  "$out_nocolor_auto" "$ESC["
out_nocolor_always="$(render NO_COLOR=1 SPECRELAY_COLOR=always)"
specrelay_test::assert_contains "4b: SPECRELAY_COLOR=always overrides NO_COLOR" \
  "$out_nocolor_always" "$ESC["

# =============================================================================
# 5 — evidence files are NEVER colorized, even with SPECRELAY_COLOR=always
# =============================================================================
events5="$work/events.jsonl"
final5="$work/final.txt"
env SPECRELAY_COLOR=always python3 "$RENDERER" --role executor --provider claude \
  --raw-events "$events5" --final-stdout "$final5" \
  < "$EXECUTOR_FIXTURE" >/dev/null 2>&1

specrelay_test::assert_not_contains "5: raw events file has NO ANSI escapes" \
  "$(cat "$events5")" "$ESC["
specrelay_test::assert_contains "5: raw events file still holds verbatim JSON" \
  "$(cat "$events5")" "\"type\":\"result\""
specrelay_test::assert_not_contains "5: final-stdout evidence file has NO ANSI escapes" \
  "$(cat "$final5")" "$ESC["
specrelay_test::assert_contains "5: final-stdout evidence file holds the extracted text" \
  "$(cat "$final5")" "Executor final summary"

# =============================================================================
# 6 — an invalid SPECRELAY_COLOR value falls back to auto (plain to non-TTY)
# =============================================================================
out_bogus="$(render SPECRELAY_COLOR=technicolor)"
specrelay_test::assert_not_contains "6: invalid SPECRELAY_COLOR falls back to auto (plain non-TTY)" \
  "$out_bogus" "$ESC["
warn_bogus="$(env SPECRELAY_COLOR=technicolor python3 "$RENDERER" \
  --role executor --provider claude < "$EXECUTOR_FIXTURE" 2>&1 >/dev/null)"
specrelay_test::assert_contains "6: invalid SPECRELAY_COLOR warns on stderr" \
  "$warn_bogus" "unrecognized SPECRELAY_COLOR"

specrelay_test::summary
exit $?
