#!/usr/bin/env bash
# orchestrator_color_test.sh — optional ANSI color for the engine/orchestrator
# logs (lib/specrelay/output.sh) and the state_lib.py human-facing status lines.
# Deterministic; no real provider. Proves:
#
#   a) non-TTY output stays PLAIN by default (auto mode, captured pipe);
#   b) SPECRELAY_COLOR=always colors orchestrator logs (out::log / out::err);
#   c) NO_COLOR disables color unless SPECRELAY_COLOR=always overrides it;
#   d) evidence (state.json) stays uncolored, and machine-parsed state_lib output
#      (get) is NEVER colored — even with SPECRELAY_COLOR=always — so parsing and
#      the reviewer decision channel are never polluted.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"

STATE_LIB="$SPECRELAY_ROOT/lib/specrelay/py/state_lib.py"
ESC=$'\033'  # literal ESC byte — start of every ANSI escape sequence

LINE="[executor] task '0001': checking working-tree guard"

# =============================================================================
# a — auto mode to a captured pipe (non-TTY): PLAIN
# =============================================================================
out_auto="$(specrelay::out::log "$LINE")"
specrelay_test::assert_not_contains "a: auto/non-TTY orchestrator log has NO ANSI escapes" \
  "$out_auto" "$ESC["
specrelay_test::assert_eq "a: auto/non-TTY orchestrator log is byte-identical plain text" \
  "$LINE" "$out_auto"

# =============================================================================
# b — SPECRELAY_COLOR=always colors orchestrator logs even to a non-TTY
# =============================================================================
out_always="$(export SPECRELAY_COLOR=always; specrelay::out::log "$LINE")"
specrelay_test::assert_contains "b: always mode emits ANSI escapes on stdout logs" \
  "$out_always" "$ESC["
specrelay_test::assert_contains "b: always mode dims the [tag] prefix" \
  "$out_always" "${ESC}[2m[executor]${ESC}[0m"
specrelay_test::assert_contains "b: always mode preserves the log text" \
  "$out_always" "task '0001': checking working-tree guard"

out_success="$(export SPECRELAY_COLOR=always; specrelay::out::log "[specrelay] task '0001' reached READY_FOR_HUMAN_REVIEW.")"
specrelay_test::assert_contains "b: a completion log is accented green" \
  "$out_success" "${ESC}[32m"

err_always="$(export SPECRELAY_COLOR=always; specrelay::out::err "boom" 2>&1 1>/dev/null)"
specrelay_test::assert_contains "b: always mode colors error lines red on stderr" \
  "$err_always" "${ESC}[31mspecrelay: boom${ESC}[0m"

# =============================================================================
# c — NO_COLOR disables color in auto, but SPECRELAY_COLOR=always overrides it
# =============================================================================
out_nocolor="$(export NO_COLOR=1; specrelay::out::log "$LINE")"
specrelay_test::assert_not_contains "c: NO_COLOR disables orchestrator color in auto mode" \
  "$out_nocolor" "$ESC["
out_nocolor_always="$(export NO_COLOR=1 SPECRELAY_COLOR=always; specrelay::out::log "$LINE")"
specrelay_test::assert_contains "c: SPECRELAY_COLOR=always overrides NO_COLOR for orchestrator logs" \
  "$out_nocolor_always" "$ESC["

# never mode is always plain
out_never="$(export SPECRELAY_COLOR=never; specrelay::out::log "$LINE")"
specrelay_test::assert_not_contains "c: never mode emits no orchestrator color" \
  "$out_never" "$ESC["

# =============================================================================
# d — evidence (state.json) uncolored; machine-parsed get output never colored
# =============================================================================
work="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ocolor.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$work")
state="$work/state.json"

python3 "$STATE_LIB" init "$state" '{"state": "READY_FOR_EXECUTOR", "task_id": "0001", "engine": "specrelay"}' >/dev/null

# The human-facing transition line IS colored in always mode ...
trans_out="$(export SPECRELAY_COLOR=always; python3 "$STATE_LIB" transition "$state" "READY_FOR_EXECUTOR" "EXECUTOR_RUNNING" '{}' 2>/dev/null)"
specrelay_test::assert_contains "d: state_lib 'Transitioned' line is colored in always mode" \
  "$trans_out" "$ESC["
specrelay_test::assert_contains "d: state_lib 'Transitioned' text is preserved" \
  "$trans_out" "Transitioned: READY_FOR_EXECUTOR -> EXECUTOR_RUNNING"

# ... but the persisted state.json evidence has NO ANSI escapes.
specrelay_test::assert_not_contains "d: persisted state.json has NO ANSI escapes (even in always mode)" \
  "$(cat "$state")" "$ESC["

# ... and machine-parsed output stays raw so callers can parse it / the decision
# channel is never polluted, even with SPECRELAY_COLOR=always.
get_out="$(export SPECRELAY_COLOR=always; python3 "$STATE_LIB" get "$state" state 2>/dev/null)"
specrelay_test::assert_eq "d: machine-parsed 'get' output is raw (never colored) even in always mode" \
  "EXECUTOR_RUNNING" "$get_out"

specrelay_test::summary
exit $?
