#!/usr/bin/env bash
# task_timeline_cli_test.sh — `specrelay task timeline` inspection command and
# `task show` timeline summary integration (spec 0019, "CLI Inspection" /
# "Task Show Integration"). Read-only: never mutates task files.
#   tools/specrelay/test/task_timeline_cli_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

proj="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj/docs/sdd/0001-cli-timeline"
echo "# spec" > "$proj/docs/sdd/0001-cli-timeline/spec.md"
(cd "$proj" && git add -A && git commit -q -m "spec")
(cd "$proj" && "$SPECRELAY_BIN" run docs/sdd/0001-cli-timeline/spec.md >/dev/null 2>&1)

# =============================================================================
# task timeline displays the timeline (human-readable).
# =============================================================================
out="$(cd "$proj" && "$SPECRELAY_BIN" task timeline 0001-cli-timeline 2>&1)"
specrelay_test::assert_contains "task timeline prints the Execution Timeline heading" \
  "$out" "Execution Timeline"
specrelay_test::assert_contains "task timeline shows total wall time" \
  "$out" "Total wall time"
specrelay_test::assert_contains "task timeline shows the verification ledger" \
  "$out" "Verification Ledger"
specrelay_test::assert_contains "task timeline shows a final report for a completed task" \
  "$out" "FINAL"

# =============================================================================
# task timeline --json displays valid JSON.
# =============================================================================
out_json="$(cd "$proj" && "$SPECRELAY_BIN" task timeline 0001-cli-timeline --json 2>&1)"
specrelay_test::assert_eq "task timeline --json produces valid, parseable JSON" \
  "valid" "$(printf '%s' "$out_json" | python3 -c 'import json,sys
try:
    json.load(sys.stdin)
    print("valid")
except Exception:
    print("invalid")')"

# =============================================================================
# Unknown task fails clearly.
# =============================================================================
out_unknown="$(cd "$proj" && "$SPECRELAY_BIN" task timeline does-not-exist 2>&1)"
rc_unknown=$?
specrelay_test::assert_true "task timeline for an unknown task exits non-zero" \
  "$([ "$rc_unknown" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "task timeline for an unknown task reports no match" \
  "$out_unknown" "no task matches"

# =============================================================================
# A legacy task without timeline data remains inspectable.
# =============================================================================
legacy_dir="$proj/.ai-runs/tasks/0002-legacy-notimeline"
mkdir -p "$legacy_dir"
cat > "$legacy_dir/state.json" <<'JSON'
{"task_id": "0002-legacy-notimeline", "state": "READY_FOR_HUMAN_REVIEW", "engine": "specrelay", "schema_version": 1}
JSON
out_legacy="$(cd "$proj" && "$SPECRELAY_BIN" task timeline 0002-legacy-notimeline 2>&1)"
rc_legacy=$?
specrelay_test::assert_eq "a legacy task without timeline data is still inspectable (exit 0)" "0" "$rc_legacy"
specrelay_test::assert_contains "a legacy task reports 'not recorded' honestly" \
  "$out_legacy" "not recorded"

show_legacy="$(cd "$proj" && "$SPECRELAY_BIN" task show 0002-legacy-notimeline 2>&1)"
specrelay_test::assert_contains "task show for a legacy task reports 'Execution timeline: not recorded'" \
  "$show_legacy" "Execution timeline: not recorded"

# =============================================================================
# task show reports the timeline summary for a task that HAS timeline data.
# =============================================================================
show_out="$(cd "$proj" && "$SPECRELAY_BIN" task show 0001-cli-timeline 2>&1)"
specrelay_test::assert_contains "task show reports Total wall time" "$show_out" "Total wall time:"
specrelay_test::assert_contains "task show reports Invocation count" "$show_out" "Invocation count:"
specrelay_test::assert_contains "task show reports Resume count" "$show_out" "Resume count:"
specrelay_test::assert_contains "task show reports Full-suite runs" "$show_out" "Full-suite runs:"
specrelay_test::assert_contains "task show reports Reviewer marker recovery" "$show_out" "Reviewer marker recovery:"
specrelay_test::assert_contains "task show reports Budget warnings" "$show_out" "Budget warnings:"
specrelay_test::assert_contains "task show points at the timeline JSON path" "$show_out" "20-execution-timeline.json"

# =============================================================================
# Read-only commands never mutate task files: task timeline / task show must
# not change the derived timeline JSON's mtime or the state.json's content.
# =============================================================================
timeline_path="$proj/.ai-runs/tasks/0001-cli-timeline/20-execution-timeline.json"
state_path="$proj/.ai-runs/tasks/0001-cli-timeline/state.json"
before_mtime="$(stat -f %m "$timeline_path" 2>/dev/null || stat -c %Y "$timeline_path")"
before_state="$(cat "$state_path")"
(cd "$proj" && "$SPECRELAY_BIN" task timeline 0001-cli-timeline >/dev/null 2>&1)
(cd "$proj" && "$SPECRELAY_BIN" task show 0001-cli-timeline >/dev/null 2>&1)
after_mtime="$(stat -f %m "$timeline_path" 2>/dev/null || stat -c %Y "$timeline_path")"
after_state="$(cat "$state_path")"
specrelay_test::assert_eq "task timeline never mutates 20-execution-timeline.json" \
  "$before_mtime" "$after_mtime"
specrelay_test::assert_eq "task show / task timeline never mutate state.json" \
  "$before_state" "$after_state"

specrelay_test::summary
exit $?
