#!/usr/bin/env bash
# render_agent_events_collapse_test.sh — terminal collapse/continuation layout
# for the semantic live renderer (render_agent_events.py). Deterministic; NO
# real Claude. It drives a fixture JSONL stream through the renderer and proves
# the purely-visual noise-reduction behavior added on top of the per-event
# lines:
#
#   1. a long Bash command wraps onto a continuation line whose role prefix is
#      BLANKED to spaces (never tabs), the body aligned under the 'Bash' label;
#   2. immediately-repeated Read events collapse — only the first keeps its role
#      prefix + action label; the repeats blank both, keeping the aligned path;
#   3. repeated Edit and Write events collapse the same way;
#   4. semantic boundaries (says / Bash / result) reset the collapse run, so the
#      next action's first line is fully labeled again;
#   5. the raw events file stays verbatim JSON — never collapsed, never
#      space-prefixed, never colorized (evidence is untouched);
#   6. the behavior holds in BOTH no-color and color modes.
#
# Collapse/continuation is applied ONLY to the live lines this process writes to
# stdout (which the shell wraps to the operator terminal). Evidence files are
# produced from separate data and are never affected.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

FIXTURES="$SPECRELAY_ROOT/test/fixtures/agent-events"
RENDERER="$SPECRELAY_ROOT/lib/specrelay/py/render_agent_events.py"
COLLAPSE_FIXTURE="$FIXTURES/claude-collapse.jsonl"

# A literal ESC byte — the leading character of every ANSI escape sequence.
ESC=$'\033'

work="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-collapse.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$work")

# Space-only continuation indents (built with printf so the widths cannot drift
# out of sync with a hand-counted string literal). For role "executor":
#   plain: "[executor] " (11) + "reading: " (9)          -> body column 20
#   color: "[executor] " (11) + "Read " (5) + " " (1)    -> body column 17
PLAIN_INDENT="$(printf '%20s' '')"
COLOR_INDENT="$(printf '%17s' '')"

# render <extra-env...> — run the renderer against the collapse fixture with
# stdout captured (a non-TTY pipe) and stderr discarded, echoing rendered stdout.
render() {
  env "$@" python3 "$RENDERER" --role executor --provider claude \
    < "$COLLAPSE_FIXTURE" 2>/dev/null
}

# =============================================================================
# no-color (plain) mode — the deterministic, ANSI-free view
# =============================================================================
out_plain="$(render SPECRELAY_COLOR=never)"

# 2 — repeated Read events collapse: first keeps the full prefix + verb, the
#     immediate repeats blank both and only the aligned path remains.
specrelay_test::assert_contains "2: first Read keeps its full role prefix + verb" \
  "$out_plain" "[executor] reading: lib/specrelay/config.sh"
specrelay_test::assert_contains "2: repeated Read collapses to an aligned, blank-prefixed path" \
  "$out_plain" "${PLAIN_INDENT}lib/specrelay/providers/provider.sh"
specrelay_test::assert_contains "2: a third repeated Read stays collapsed and aligned" \
  "$out_plain" "${PLAIN_INDENT}lib/specrelay/providers/claude.sh"
specrelay_test::assert_not_contains "2: a repeated Read does NOT repeat the role prefix + verb" \
  "$out_plain" "[executor] reading: lib/specrelay/providers/provider.sh"

# 3 — repeated Edit and Write events collapse the same way.
specrelay_test::assert_contains "3: first Edit keeps its full role prefix + verb" \
  "$out_plain" "[executor] editing: lib/specrelay/edit-one.sh"
specrelay_test::assert_contains "3: repeated Edit collapses to an aligned, blank-prefixed path" \
  "$out_plain" "${PLAIN_INDENT}lib/specrelay/edit-two.sh"
specrelay_test::assert_not_contains "3: a repeated Edit does NOT repeat the role prefix + verb" \
  "$out_plain" "[executor] editing: lib/specrelay/edit-two.sh"
specrelay_test::assert_contains "3: first Write keeps its full role prefix + verb" \
  "$out_plain" "[executor] writing: lib/specrelay/write-one.sh"
specrelay_test::assert_contains "3: repeated Write collapses to an aligned, blank-prefixed path" \
  "$out_plain" "${PLAIN_INDENT}lib/specrelay/write-two.sh"
specrelay_test::assert_not_contains "3: a repeated Write does NOT repeat the role prefix + verb" \
  "$out_plain" "[executor] writing: lib/specrelay/write-two.sh"

# 4 — semantic boundaries reset the collapse run: the Bash between the Read runs
#     is a boundary, so the Read that follows it is fully labeled again (NOT
#     collapsed onto the earlier Read run); says/result also render in full.
specrelay_test::assert_contains "4: a Bash boundary renders in full (never collapsed)" \
  "$out_plain" "[executor] command: git status --short"
specrelay_test::assert_contains "4: a Read AFTER a boundary is fully labeled again" \
  "$out_plain" "[executor] reading: lib/specrelay/output.sh"
specrelay_test::assert_contains "4: a says boundary renders in full" \
  "$out_plain" "[executor] says: Done applying the changes."
specrelay_test::assert_contains "4: a result boundary renders in full" \
  "$out_plain" "[executor] result: success"
specrelay_test::assert_not_contains "4: the post-boundary Read is NOT space-collapsed" \
  "$out_plain" "${PLAIN_INDENT}lib/specrelay/output.sh"

# 5 — the raw events file is verbatim JSON: no collapse, no space-prefix, no ANSI.
events5="$work/events.jsonl"
final5="$work/final.txt"
env SPECRELAY_COLOR=always python3 "$RENDERER" --role executor --provider claude \
  --raw-events "$events5" --final-stdout "$final5" \
  < "$COLLAPSE_FIXTURE" >/dev/null 2>&1
specrelay_test::assert_not_contains "5: raw events file has NO ANSI escapes" \
  "$(cat "$events5")" "$ESC["
specrelay_test::assert_contains "5: raw events file keeps every repeated Read verbatim" \
  "$(cat "$events5")" "\"file_path\":\"lib/specrelay/providers/provider.sh\""
specrelay_test::assert_not_contains "5: raw events file is never space-collapsed" \
  "$(cat "$events5")" "${PLAIN_INDENT}lib/specrelay/providers/provider.sh"
specrelay_test::assert_contains "5: final-stdout evidence holds the extracted text" \
  "$(cat "$final5")" "Collapse fixture final text."

# =============================================================================
# 6 — color mode: collapse holds, and the continuation lines are ANSI-free
#     spaces (the colored label appears only on each group's first line)
# =============================================================================
out_color="$(render SPECRELAY_COLOR=always)"
specrelay_test::assert_contains "6: first Read still renders a colored aligned 'Read' label" \
  "$out_color" "${ESC}[34mRead ${ESC}[0m lib/specrelay/config.sh"
specrelay_test::assert_contains "6: repeated Read collapses to a blank (space-only) aligned path" \
  "$out_color" "${COLOR_INDENT}lib/specrelay/providers/provider.sh"
specrelay_test::assert_not_contains "6: a collapsed continuation carries NO colored label" \
  "$out_color" "${ESC}[34mRead ${ESC}[0m lib/specrelay/providers/provider.sh"

specrelay_test::summary
exit $?
