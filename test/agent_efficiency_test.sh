#!/usr/bin/env bash
# agent_efficiency_test.sh — agent execution-efficiency reporting engine
# (spec 0021, "Agent Execution Efficiency and Completion Gate"). Deterministic;
# NO real Claude. Proves:
#
#   A. unresolved-waiting detection (py/agent_efficiency_lib.py): every spec
#      example matches, historical narration and unrelated "wait"-containing
#      words never falsely match, and detection is conservative.
#   B. observable-work classification: exploration/implementation/
#      verification/waiting/artifact_writing/inspection/other examples
#      classify correctly, and an unknown shape classifies honestly as other.
#   C. aggregation + artifact: a hand-authored fixture (command-timing events
#      + execution events with completion_gate results) produces a valid,
#      schema-versioned, task-scoped JSON artifact; atomic write preserves
#      previous valid data on failure; secrets are never copied in.
#   D. rendering: the FINAL table and the PARTIAL gate-failure block.
#   E. timeline integration: 20-execution-timeline.json references the
#      efficiency artifact; a legacy task renders without it.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/config.sh
. "$SPECRELAY_ROOT/lib/specrelay/config.sh"
# shellcheck source=../lib/specrelay/timeline.sh
. "$SPECRELAY_ROOT/lib/specrelay/timeline.sh"
# shellcheck source=../lib/specrelay/command_timing.sh
. "$SPECRELAY_ROOT/lib/specrelay/command_timing.sh"
# shellcheck source=../lib/specrelay/verification.sh
. "$SPECRELAY_ROOT/lib/specrelay/verification.sh"
# shellcheck source=../lib/specrelay/agent_efficiency.sh
. "$SPECRELAY_ROOT/lib/specrelay/agent_efficiency.sh"

AGENT_EFFICIENCY_LIB="$SPECRELAY_ROOT/lib/specrelay/py/agent_efficiency_lib.py"

# =============================================================================
# A. Unresolved-waiting detection
# =============================================================================
wdir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ee-wait.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$wdir")

specrelay_test::_wait_check() {
  local desc="$1" text="$2" expect="$3" f
  f="$wdir/final.txt"
  printf '%s\n' "$text" > "$f"
  specrelay_test::assert_eq "$desc" "$expect" "$(specrelay::agent_efficiency::detect_unresolved_wait "$f")"
}

specrelay_test::_wait_check "final 'I will wait for the background task' fails when enabled" \
  "I will wait for the background task." "detected"
specrelay_test::_wait_check "final 'I'll continue when the monitor finishes' fails" \
  "I'll continue when the monitor finishes." "detected"
specrelay_test::_wait_check "final 'still running; stopping here' fails" \
  "The test is still running; I am stopping here." "detected"
specrelay_test::_wait_check "final 'waiting for completion notification' fails" \
  "Waiting for completion notification." "detected"
specrelay_test::_wait_check "final 'I'll pick this back up once it completes' fails" \
  "I'll pick this back up once it completes." "detected"
specrelay_test::_wait_check "historical 'I waited... and it completed successfully' passes" \
  "I waited for the test, and it completed successfully." "none"
specrelay_test::_wait_check "unrelated word 'await' does not match" \
  "The code uses async/await patterns throughout and all tests pass." "none"
specrelay_test::_wait_check "unrelated word 'waiver' does not match" \
  "The legal waiver was signed and everything is done." "none"
specrelay_test::_wait_check "ordinary completed narrative with the word 'waiting' does not match" \
  "There was some waiting around during setup, but the build finished and all tests are green." "none"
specrelay_test::_wait_check "empty final output is not a failure" "" "none"

missing_final="$wdir/does-not-exist.txt"
specrelay_test::assert_eq "missing final-output file is honestly 'none'" \
  "none" "$(specrelay::agent_efficiency::detect_unresolved_wait "$missing_final")"

# Disabled policy never blocks: exercised at the workflow-gate level in
# completion_gate_test.sh; here we confirm the detector itself is a pure
# classifier the caller decides whether to honor.
wait_fixture="$wdir/wait-fixture.txt"
printf 'I will wait for the background task.\n' > "$wait_fixture"
specrelay_test::assert_eq "detector never fabricates a duration/side effect (pure text classification)" \
  "detected" "$(python3 "$AGENT_EFFICIENCY_LIB" detect-unresolved-wait "$wait_fixture")"

# =============================================================================
# B. Observable-work classification
# =============================================================================
specrelay_test::_classify() {
  TOOL="$1" CMD="$2" python3 -c '
import sys, os
sys.path.insert(0, os.environ["LIBDIR"])
import agent_efficiency_lib as a
print(a.classify_operation(os.environ["TOOL"], os.environ["CMD"]))
'
}
export LIBDIR="$SPECRELAY_ROOT/lib/specrelay/py"

specrelay_test::assert_eq "B: find classifies as exploration" \
  "exploration" "$(specrelay_test::_classify Bash "find . -name '*.rb'")"
specrelay_test::assert_eq "B: grep classifies as exploration" \
  "exploration" "$(specrelay_test::_classify Bash "grep -rn foo lib")"
specrelay_test::assert_eq "B: git log classifies as exploration" \
  "exploration" "$(specrelay_test::_classify Bash "git log --oneline -20")"
specrelay_test::assert_eq "B: Grep tool classifies as exploration" \
  "exploration" "$(specrelay_test::_classify Grep "Grep: TODO")"
specrelay_test::assert_eq "B: broad Read classifies as exploration" \
  "exploration" "$(specrelay_test::_classify Read "Read: lib/specrelay/workflow.sh")"
specrelay_test::assert_eq "B: Edit classifies as implementation" \
  "implementation" "$(specrelay_test::_classify Edit "Edit: lib/specrelay/workflow.sh")"
specrelay_test::assert_eq "B: Write to a source file classifies as implementation" \
  "implementation" "$(specrelay_test::_classify Write "Write: lib/specrelay/new_feature.sh")"
specrelay_test::assert_eq "B: scripts/test classifies as verification" \
  "verification" "$(specrelay_test::_classify Bash "scripts/test test/foo_test.sh")"
specrelay_test::assert_eq "B: scripts/smoke classifies as verification" \
  "verification" "$(specrelay_test::_classify Bash "scripts/smoke --skip-tests")"
specrelay_test::assert_eq "B: doctor classifies as verification" \
  "verification" "$(specrelay_test::_classify Bash "bin/specrelay doctor")"
specrelay_test::assert_eq "B: version classifies as verification" \
  "verification" "$(specrelay_test::_classify Bash "bin/specrelay version")"
specrelay_test::assert_eq "B: bare sleep classifies as waiting" \
  "waiting" "$(specrelay_test::_classify Bash "sleep 30")"
specrelay_test::assert_eq "B: poll loop classifies as waiting" \
  "waiting" "$(specrelay_test::_classify Bash "until curl -sf http://x/health; do sleep 5; done")"
specrelay_test::assert_eq "B: jobs; wait classifies as waiting" \
  "waiting" "$(specrelay_test::_classify Bash "jobs; wait")"
specrelay_test::assert_eq "B: Write 03-executor-log.md classifies as artifact_writing" \
  "artifact_writing" "$(specrelay_test::_classify Write "Write: task/03-executor-log.md")"
specrelay_test::assert_eq "B: Write 07-tests.txt classifies as artifact_writing" \
  "artifact_writing" "$(specrelay_test::_classify Write "Write: task/07-tests.txt")"
specrelay_test::assert_eq "B: Write 09-consultant-review.md classifies as artifact_writing" \
  "artifact_writing" "$(specrelay_test::_classify Write "Write: task/09-consultant-review.md")"
specrelay_test::assert_eq "B: unknown tool classifies as other" \
  "other" "$(specrelay_test::_classify SomeFutureTool "SomeFutureTool")"
specrelay_test::assert_eq "B: git status classifies as inspection" \
  "inspection" "$(specrelay_test::_classify Bash "git status --short")"

# =============================================================================
# C. Aggregation + artifact (fixture mirrors command_timing_test.sh's style)
# =============================================================================
cdir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ee-agg.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$cdir")
mkdir -p "$cdir/task"
task_c="$cdir/task"

cat > "$task_c/21-command-timing-events.jsonl" <<'EOF'
{"invocation_id":"1","role":"executor","provider":"claude","tool":"Bash","command":"find . -name '*.rb'","started_at":"2026-07-14T09:00:00Z","finished_at":"2026-07-14T09:00:01Z","duration_seconds":1.0,"status":"passed","exit_code":0,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"1","role":"executor","provider":"claude","tool":"Edit","command":"Edit: lib/specrelay/workflow.sh","started_at":"2026-07-14T09:00:02Z","finished_at":"2026-07-14T09:00:03Z","duration_seconds":1.0,"status":"passed","exit_code":null,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"1","role":"executor","provider":"claude","tool":"Bash","command":"scripts/test test/foo_test.sh","started_at":"2026-07-14T09:00:04Z","finished_at":"2026-07-14T09:00:05Z","duration_seconds":1.0,"status":"passed","exit_code":0,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"1","role":"executor","provider":"claude","tool":"Bash","command":"sleep 5","started_at":"2026-07-14T09:00:06Z","finished_at":"2026-07-14T09:00:11Z","duration_seconds":5.0,"status":"passed","exit_code":0,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"1","role":"executor","provider":"claude","tool":"Write","command":"Write: task/03-executor-log.md","started_at":"2026-07-14T09:00:12Z","finished_at":"2026-07-14T09:00:12Z","duration_seconds":0.1,"status":"passed","exit_code":null,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"1","role":"executor","provider":"claude","tool":"Bash","command":"MY_API_KEY=sekretVALUE123 scripts/test","started_at":"2026-07-14T09:00:13Z","finished_at":"2026-07-14T09:00:14Z","duration_seconds":1.0,"status":"passed","exit_code":0,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"1","role":"reviewer","provider":"claude","tool":"Bash","command":"git status --short","started_at":"2026-07-14T09:01:00Z","finished_at":"2026-07-14T09:01:01Z","duration_seconds":1.0,"status":"passed","exit_code":0,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"1","role":"reviewer","provider":"claude","tool":"Write","command":"Write: task/09-consultant-review.md","started_at":"2026-07-14T09:01:02Z","finished_at":"2026-07-14T09:01:02Z","duration_seconds":0.1,"status":"passed","exit_code":null,"timing_source":"local_renderer_monotonic_clock","redacted":false}
EOF

specrelay::timeline::start "$task_c" executor_provider_execution executor
specrelay::timeline::finish "$task_c" executor_provider_execution passed
specrelay::verification::record "$task_c" executor "scripts/test test/foo_test.sh" "1" "0" "" "test"
specrelay::agent_efficiency::record_completion_gate "$task_c" executor passed

json_c="$(specrelay::agent_efficiency::render "$task_c" agg-fixture final --json)"

specrelay_test::assert_eq "C: rendered JSON is valid" \
  "valid" "$(printf '%s' "$json_c" | python3 -c 'import json,sys
try:
    json.load(sys.stdin)
    print("valid")
except Exception:
    print("invalid")')"
specrelay_test::assert_contains "C: schema version is recorded" "$json_c" '"schema_version": 1'
specrelay_test::assert_contains "C: task ID is correct" "$json_c" '"task_id": "agg-fixture"'
specrelay_test::assert_eq "C: executor exploration_operations is 1 (find)" \
  "1" "$(printf '%s' "$json_c" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["executor"]["exploration_operations"])')"
specrelay_test::assert_eq "C: executor implementation_operations is 1 (Edit)" \
  "1" "$(printf '%s' "$json_c" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["executor"]["implementation_operations"])')"
specrelay_test::assert_eq "C: executor verification_operations is 2 (scripts/test x2)" \
  "2" "$(printf '%s' "$json_c" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["executor"]["verification_operations"])')"
specrelay_test::assert_eq "C: executor waiting_operations is 1 (sleep)" \
  "1" "$(printf '%s' "$json_c" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["executor"]["waiting_operations"])')"
specrelay_test::assert_eq "C: executor artifact_writing_operations is 1" \
  "1" "$(printf '%s' "$json_c" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["executor"]["artifact_writing_operations"])')"
specrelay_test::assert_eq "C: reviewer inspection_operations is 1 (git status)" \
  "1" "$(printf '%s' "$json_c" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["reviewer"]["inspection_operations"])')"
specrelay_test::assert_eq "C: executor completion_gate is passed" \
  "passed" "$(printf '%s' "$json_c" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["executor"]["completion_gate"])')"
specrelay_test::assert_eq "C: reviewer completion_gate is not_recorded (never recorded)" \
  "not_recorded" "$(printf '%s' "$json_c" | python3 -c 'import json,sys; print(json.load(sys.stdin)["roles"]["reviewer"]["completion_gate"])')"
specrelay_test::assert_not_contains "C: secret value is never copied into the artifact" \
  "$json_c" "sekretVALUE123"
specrelay_test::assert_true "C: post_verification_seconds is non-negative when present" \
  "$(printf '%s' "$json_c" | python3 -c 'import json,sys
d = json.load(sys.stdin)
v = d["roles"]["executor"]["post_verification_seconds"]
print(1 if (v is not None and v < 0) else 0)')"
specrelay_test::assert_true "C: artifact is written under the existing task directory (no new top-level dir)" \
  "$([ -f "$task_c/22-agent-efficiency.json" ] && echo 0 || echo 1)"

# Atomic write preserves previous valid data on failure.
before_json="$(cat "$task_c/22-agent-efficiency.json")"
SPECRELAY_AGENT_EFFICIENCY_LIB_PY_BACKUP="$SPECRELAY_AGENT_EFFICIENCY_LIB_PY"
SPECRELAY_AGENT_EFFICIENCY_LIB_PY="/nonexistent/agent_efficiency_lib.py"
specrelay::agent_efficiency::render "$task_c" agg-fixture final >/dev/null
SPECRELAY_AGENT_EFFICIENCY_LIB_PY="$SPECRELAY_AGENT_EFFICIENCY_LIB_PY_BACKUP"
after_json="$(cat "$task_c/22-agent-efficiency.json")"
specrelay_test::assert_eq "C: a failed render never corrupts the previous valid artifact" \
  "$before_json" "$after_json"

# Legacy task (no command-timing events, no completion-gate events) is
# honestly reported as not recorded.
legacy_task="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ee-legacytask.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$legacy_task")
legacy_show="$(specrelay::agent_efficiency::show_json "$legacy_task")"
specrelay_test::assert_contains "C: legacy task (never rendered) shows recorded: false" \
  "$legacy_show" '"recorded": false'

# =============================================================================
# D. Rendering: FINAL table and PARTIAL gate-failure block
# =============================================================================
final_render="$(specrelay::agent_efficiency::report "$task_c" agg-fixture final)"
specrelay_test::assert_contains "D: final output prints the efficiency table" \
  "$final_render" "Agent Efficiency -- FINAL"
specrelay_test::assert_contains "D: final output lists completion gates" \
  "$final_render" "Completion gates:"
specrelay_test::assert_not_contains "D: non-TTY output has no ANSI escapes" \
  "$final_render" $'\x1b'
specrelay_test::assert_not_contains "D: output contains no cursor movement" \
  "$final_render" $'\r'

fdir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ee-partial.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$fdir")
mkdir -p "$fdir/task"
task_f="$fdir/task"
specrelay::agent_efficiency::record_completion_gate "$task_f" executor failed \
  "required Executor artifact '08-executor-summary.md' is missing or empty"
partial_render="$(specrelay::agent_efficiency::report "$task_f" partial-fixture final)"
specrelay_test::assert_contains "D: partial output names the completion failure" \
  "$partial_render" "Agent Efficiency -- PARTIAL"
specrelay_test::assert_contains "D: partial output names the failing role" \
  "$partial_render" "Executor: failed"
specrelay_test::assert_contains "D: partial output includes the recorded reason" \
  "$partial_render" "08-executor-summary.md"

# =============================================================================
# E. Timeline integration
# =============================================================================
timeline_json="$(specrelay::timeline::render "$cdir" "$task_c" agg-fixture final --json)"
specrelay_test::assert_contains "E: timeline references the efficiency artifact" \
  "$timeline_json" '"agent_efficiency_summary"'
specrelay_test::assert_contains "E: timeline efficiency summary names the artifact file" \
  "$timeline_json" "22-agent-efficiency.json"

legacy_root="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ee-legacytl-root.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$legacy_root")
legacy_tdir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ee-legacytl.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$legacy_tdir")
specrelay::timeline::start "$legacy_tdir" task_initialization
specrelay::timeline::finish "$legacy_tdir" task_initialization passed
legacy_timeline_json="$(specrelay::timeline::render "$legacy_root" "$legacy_tdir" legacy-task final --json)"
specrelay_test::assert_not_contains "E: a task with no efficiency evidence gets no efficiency block" \
  "$legacy_timeline_json" "agent_efficiency_summary"

echo
specrelay_test::summary
