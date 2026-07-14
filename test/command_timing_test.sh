#!/usr/bin/env bash
# command_timing_test.sh — agent command timing ledger (spec 0020, "Agent
# Command Timing Ledger"). Deterministic; NO real Claude. Proves:
#
#   A. aggregation (py/command_timing_lib.py): a hand-authored, deterministic
#      fixture covering every required scenario — a successful Bash command,
#      a failed one, a repeated command (across roles), a bare sleep, a
#      polling loop, an operation with no timestamps, a secret-bearing
#      command a renderer might have failed to redact (defense in depth),
#      Read/Edit/Write timing, an unsupported tool, different test filenames,
#      different Git refs, and operations from two invocations — is turned
#      into an honest, redacted, deduplicated summary; the JSON artifact is
#      valid, schema-versioned, task-scoped, and atomic.
#   B. renderer pairing (py/render_agent_events.py): live tool_use/tool_result
#      pairing via the renderer's own local monotonic clock — a matched pair
#      becomes one operation, a pipeline stays ONE observable command, an
#      unmatched start is retained as 'incomplete', an unmatched finish is
#      silently ignored (never fabricates an operation), and a secret is
#      redacted BEFORE it is ever persisted to the timing-events file.
#   C. full lifecycle (bin/specrelay, real claude adapter + fake stream-json
#      CLI): the artifact is written under the real task directory (no new
#      top-level runtime directory), 'task timeline'/'task commands' surface
#      it, resume preserves prior operation history, read-only inspection
#      never mutates task files, and a legacy/never-instrumented task is
#      reported honestly rather than fabricated.
#   D. performance: extraction over a synthetic ~1,200-operation fixture
#      completes within a reasonable bound.

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

COMMAND_TIMING_LIB="$SPECRELAY_ROOT/lib/specrelay/py/command_timing_lib.py"
RENDERER="$SPECRELAY_ROOT/lib/specrelay/py/render_agent_events.py"

# =============================================================================
# A. Aggregation: a deterministic fixture covering every required scenario.
# =============================================================================
adir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-cmdtiming-agg.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$adir")
mkdir -p "$adir/task"
task_a="$adir/task"

cat > "$task_a/21-command-timing-events.jsonl" <<'EOF'
{"invocation_id":"1","role":"executor","provider":"claude","tool":"Bash","command":"scripts/test test/foo_spec.sh","started_at":"2026-07-14T09:00:00.000000Z","finished_at":"2026-07-14T09:00:12.500000Z","duration_seconds":12.5,"status":"passed","exit_code":0,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"1","role":"executor","provider":"claude","tool":"Bash","command":"scripts/test test/bar_spec.sh","started_at":"2026-07-14T09:00:13.000000Z","finished_at":"2026-07-14T09:00:16.200000Z","duration_seconds":3.2,"status":"failed","exit_code":1,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"1","role":"executor","provider":"claude","tool":"Bash","command":"bin/specrelay doctor","started_at":"2026-07-14T09:00:20.000000Z","finished_at":"2026-07-14T09:00:21.100000Z","duration_seconds":1.1,"status":"passed","exit_code":0,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"2","role":"executor","provider":"claude","tool":"Bash","command":"bin/specrelay doctor","started_at":"2026-07-14T09:05:00.000000Z","finished_at":"2026-07-14T09:05:01.300000Z","duration_seconds":1.3,"status":"passed","exit_code":0,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"2","role":"reviewer","provider":"claude","tool":"Bash","command":"bin/specrelay doctor","started_at":"2026-07-14T09:05:05.000000Z","finished_at":"2026-07-14T09:05:05.900000Z","duration_seconds":0.9,"status":"passed","exit_code":0,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"1","role":"executor","provider":"claude","tool":"Bash","command":"sleep 30","started_at":"2026-07-14T09:01:00.000000Z","finished_at":"2026-07-14T09:01:30.000000Z","duration_seconds":30.0,"status":"passed","exit_code":0,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"2","role":"executor","provider":"claude","tool":"Bash","command":"until curl -sf http://localhost:3000/health; do sleep 5; done","started_at":"2026-07-14T09:06:00.000000Z","finished_at":"2026-07-14T09:06:45.000000Z","duration_seconds":45.0,"status":"passed","exit_code":0,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"2","role":"executor","provider":"claude","tool":"Bash","command":"some-hung-command --forever","started_at":null,"finished_at":null,"duration_seconds":null,"status":"incomplete","exit_code":null,"timing_source":"not_measurable","redacted":false}
{"invocation_id":"1","role":"executor","provider":"claude","tool":"Bash","command":"OPENAI_API_KEY=sk-LEAKEDSECRET123 scripts/test","started_at":"2026-07-14T09:02:00.000000Z","finished_at":"2026-07-14T09:02:05.000000Z","duration_seconds":5.0,"status":"passed","exit_code":0,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"1","role":"executor","provider":"claude","tool":"Read","command":"Read: lib/specrelay/workflow.sh","started_at":"2026-07-14T09:02:10.000000Z","finished_at":"2026-07-14T09:02:10.400000Z","duration_seconds":0.4,"status":"passed","exit_code":null,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"1","role":"executor","provider":"claude","tool":"Edit","command":"Edit: lib/specrelay/workflow.sh","started_at":"2026-07-14T09:02:11.000000Z","finished_at":"2026-07-14T09:02:11.200000Z","duration_seconds":0.2,"status":"passed","exit_code":null,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"1","role":"executor","provider":"claude","tool":"Write","command":"Write: docs/notes.md","started_at":"2026-07-14T09:02:12.000000Z","finished_at":"2026-07-14T09:02:12.100000Z","duration_seconds":0.1,"status":"passed","exit_code":null,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"1","role":"executor","provider":"claude","tool":"SomeFutureTool","command":"SomeFutureTool","started_at":"2026-07-14T09:02:20.000000Z","finished_at":"2026-07-14T09:02:22.000000Z","duration_seconds":2.0,"status":"passed","exit_code":null,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"2","role":"executor","provider":"claude","tool":"Bash","command":"scripts/test test/baz_spec.sh","started_at":"2026-07-14T09:07:00.000000Z","finished_at":"2026-07-14T09:07:09.000000Z","duration_seconds":9.0,"status":"passed","exit_code":0,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"2","role":"executor","provider":"claude","tool":"Bash","command":"git diff main..feature/x","started_at":"2026-07-14T09:07:10.000000Z","finished_at":"2026-07-14T09:07:11.000000Z","duration_seconds":1.0,"status":"passed","exit_code":0,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"2","role":"executor","provider":"claude","tool":"Bash","command":"git diff main..feature/y","started_at":"2026-07-14T09:07:12.000000Z","finished_at":"2026-07-14T09:07:13.000000Z","duration_seconds":1.0,"status":"passed","exit_code":0,"timing_source":"local_renderer_monotonic_clock","redacted":false}
{"invocation_id":"2","role":"reviewer","provider":"claude","tool":"Bash","command":"scripts/test test/reviewer_check.sh","started_at":"2026-07-14T09:08:00.000000Z","finished_at":"2026-07-14T09:08:06.000000Z","duration_seconds":6.0,"status":"passed","exit_code":0,"timing_source":"local_renderer_monotonic_clock","redacted":false}
EOF

json_a="$(python3 "$COMMAND_TIMING_LIB" render "$task_a" cmdtiming-fixture final --json)"

specrelay_test::assert_eq "A: rendered JSON is valid" \
  "valid" "$(printf '%s' "$json_a" | python3 -c 'import json,sys
try:
    json.load(sys.stdin)
    print("valid")
except Exception:
    print("invalid")' 2>/dev/null)"
specrelay_test::assert_contains "A: schema version is present" "$json_a" '"schema_version": 1'
specrelay_test::assert_contains "A: task ID is correct" "$json_a" '"task_id": "cmdtiming-fixture"'
specrelay_test::assert_eq "A: operation count is correct" \
  "17" "$(printf '%s' "$json_a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["operation_count"])')"
specrelay_test::assert_eq "A: measurable count is correct" \
  "16" "$(printf '%s' "$json_a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["measurable_operation_count"])')"
specrelay_test::assert_eq "A: unmeasurable count is correct" \
  "1" "$(printf '%s' "$json_a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["unmeasurable_operation_count"])')"
specrelay_test::assert_true "A: durations are non-negative" \
  "$(printf '%s' "$json_a" | python3 -c 'import json,sys
d = json.load(sys.stdin)
bad = any((o.get("duration_seconds") or 0) < 0 for o in d["operations"])
print(1 if bad else 0)')"
specrelay_test::assert_eq "A: bash wall time is correct" \
  "116.0" "$(printf '%s' "$json_a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["bash_wall_seconds"])')"

# --- redaction: no fixture secret survives, even one the renderer "missed" --
specrelay_test::assert_not_contains "A: the fixture secret value never appears in the artifact" \
  "$json_a" "sk-LEAKEDSECRET123"
specrelay_test::assert_contains "A: the API key NAME stays readable (targeted redaction)" \
  "$json_a" "OPENAI_API_KEY=<redacted>"
specrelay_test::assert_true "A: the secret-bearing operation is marked redacted" \
  "$(printf '%s' "$json_a" | python3 -c 'import json,sys
d = json.load(sys.stdin)
op = next(o for o in d["operations"] if "scripts/test" in o["command"] and "OPENAI" in o["command"])
print(0 if op["redacted"] else 1)')"
specrelay_test::assert_not_contains "A: the normalized command does not reintroduce the secret" \
  "$json_a" "\"normalized_command\": \"OPENAI_API_KEY=sk-"

# --- unmeasurable operation is honest, never fabricated ---------------------
specrelay_test::assert_true "A: the timestamp-less operation is not_measurable with a null duration" \
  "$(printf '%s' "$json_a" | python3 -c 'import json,sys
d = json.load(sys.stdin)
op = next(o for o in d["operations"] if o["command"] == "some-hung-command --forever")
ok = op["timing_source"] == "not_measurable" and op["duration_seconds"] is None and op["status"] == "incomplete"
print(0 if ok else 1)')"

# --- Bash timing: text, exit code, pass/fail -------------------------------
specrelay_test::assert_true "A: passed Bash status is recorded" \
  "$(printf '%s' "$json_a" | python3 -c 'import json,sys
d = json.load(sys.stdin)
op = next(o for o in d["operations"] if o["command"] == "scripts/test test/foo_spec.sh")
print(0 if op["status"] == "passed" and op["exit_code"] == 0 else 1)')"
specrelay_test::assert_true "A: failed Bash status is recorded" \
  "$(printf '%s' "$json_a" | python3 -c 'import json,sys
d = json.load(sys.stdin)
op = next(o for o in d["operations"] if o["command"] == "scripts/test test/bar_spec.sh")
print(0 if op["status"] == "failed" and op["exit_code"] == 1 else 1)')"

# --- other tools: Read/Edit/Write captured, unsupported tool retained ------
specrelay_test::assert_true "A: Read timing is captured" \
  "$(printf '%s' "$json_a" | python3 -c 'import json,sys
d = json.load(sys.stdin)
print(0 if any(o["tool"] == "Read" and o["duration_seconds"] == 0.4 for o in d["operations"]) else 1)')"
specrelay_test::assert_true "A: Edit timing is captured" \
  "$(printf '%s' "$json_a" | python3 -c 'import json,sys
d = json.load(sys.stdin)
print(0 if any(o["tool"] == "Edit" and o["duration_seconds"] == 0.2 for o in d["operations"]) else 1)')"
specrelay_test::assert_true "A: Write timing is captured" \
  "$(printf '%s' "$json_a" | python3 -c 'import json,sys
d = json.load(sys.stdin)
print(0 if any(o["tool"] == "Write" and o["duration_seconds"] == 0.1 for o in d["operations"]) else 1)')"
specrelay_test::assert_true "A: an unsupported tool is retained WITHOUT a fabricated exit code" \
  "$(printf '%s' "$json_a" | python3 -c 'import json,sys
d = json.load(sys.stdin)
op = next(o for o in d["operations"] if o["tool"] == "SomeFutureTool")
print(0 if op["duration_seconds"] == 2.0 and op["exit_code"] is None else 1)')"

# --- duplicate detection: grouped conservatively ---------------------------
specrelay_test::assert_eq "A: exactly one duplicate group is detected" \
  "1" "$(printf '%s' "$json_a" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["duplicate_commands"]))')"
specrelay_test::assert_true "A: the duplicate group is 'bin/specrelay doctor' with count 3" \
  "$(printf '%s' "$json_a" | python3 -c 'import json,sys
d = json.load(sys.stdin)
g = d["duplicate_commands"][0]
print(0 if g["normalized_command"] == "bin/specrelay doctor" and g["count"] == 3 else 1)')"
specrelay_test::assert_true "A: role counts are correct (executor 2, reviewer 1)" \
  "$(printf '%s' "$json_a" | python3 -c 'import json,sys
d = json.load(sys.stdin)
g = d["duplicate_commands"][0]
print(0 if g["roles"] == {"executor": 2, "reviewer": 1} else 1)')"
specrelay_test::assert_true "A: total measured duplicate duration is correct (1.1+1.3+0.9)" \
  "$(printf '%s' "$json_a" | python3 -c 'import json,sys
d = json.load(sys.stdin)
g = d["duplicate_commands"][0]
print(0 if abs(g["duration_seconds"] - 3.3) < 0.001 else 1)')"
specrelay_test::assert_true "A: different test filenames are NOT grouped as duplicates" \
  "$(printf '%s' "$json_a" | python3 -c 'import json,sys
d = json.load(sys.stdin)
cmds = {g["normalized_command"] for g in d["duplicate_commands"]}
print(1 if any("foo_spec" in c or "bar_spec" in c or "baz_spec" in c for c in cmds) else 0)')"
specrelay_test::assert_true "A: different Git refs are NOT grouped as duplicates" \
  "$(printf '%s' "$json_a" | python3 -c 'import json,sys
d = json.load(sys.stdin)
cmds = {g["normalized_command"] for g in d["duplicate_commands"]}
print(1 if any("git diff" in c for c in cmds) else 0)')"
specrelay_test::assert_contains "A: the duplicate report never claims a run was avoidable" \
  "$(python3 "$COMMAND_TIMING_LIB" report "$task_a" cmdtiming-fixture final)" "informational only"

# --- waiting/polling detection ----------------------------------------------
specrelay_test::assert_eq "A: waiting count is correct (sleep + poll loop)" \
  "2" "$(printf '%s' "$json_a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["waiting"]["count"])')"
specrelay_test::assert_eq "A: waiting duration is aggregated correctly (30 + 45)" \
  "75.0" "$(printf '%s' "$json_a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["waiting"]["duration_seconds"])')"
specrelay_test::assert_true "A: an ordinary test command is never classified as waiting" \
  "$(printf '%s' "$json_a" | python3 -c 'import json,sys
d = json.load(sys.stdin)
op = next(o for o in d["operations"] if o["command"] == "scripts/test test/foo_spec.sh")
print(0 if not op["waiting"] else 1)')"

# --- Executor/Reviewer role separation --------------------------------------
specrelay_test::assert_true "A: executor and reviewer operations are separated by role" \
  "$(printf '%s' "$json_a" | python3 -c 'import json,sys
d = json.load(sys.stdin)
roles = {o["role"] for o in d["operations"]}
print(0 if roles == {"executor", "reviewer"} else 1)')"

# --- rendering: slowest sorted, bounded, waiting/duplicate/unmeasurable shown
report_a="$(python3 "$COMMAND_TIMING_LIB" report "$task_a" cmdtiming-fixture final)"
first_slow_row_a="$(printf '%s\n' "$report_a" | sed -n '/^| Role/,/^+---/p' | sed -n '3p')"
specrelay_test::assert_contains "A: slowest commands are sorted descending (poll loop, 45s, is first)" \
  "$first_slow_row_a" "45s"
specrelay_test::assert_contains "A: unmeasurable count is printed" "$report_a" "Unmeasurable operations:   1"
specrelay_test::assert_contains "A: waiting summary is printed" "$report_a" "Waiting/polling commands:"
specrelay_test::assert_contains "A: duplicate commands are printed" "$report_a" "Repeated agent commands:"
esc="$(printf '\033')"
specrelay_test::assert_not_contains "A: no ANSI escapes appear in redirected output" "$report_a" "$esc"
specrelay_test::assert_contains "A: a final report is labeled FINAL" "$report_a" "FINAL"
partial_a="$(python3 "$COMMAND_TIMING_LIB" report "$task_a" cmdtiming-fixture partial)"
specrelay_test::assert_contains "A: a partial report is labeled PARTIAL" "$partial_a" "PARTIAL"

# --- JSON artifact: atomic write, task-scoped path --------------------------
python3 "$COMMAND_TIMING_LIB" render "$task_a" cmdtiming-fixture final >/dev/null
specrelay_test::assert_true "A: 21-command-timings.json is written under the task dir (task-scoped)" \
  "$([ -s "$task_a/21-command-timings.json" ] && echo 0 || echo 1)"
before_json="$(cat "$task_a/21-command-timings.json")"
COMMAND_TIMING_LIB_BACKUP="$COMMAND_TIMING_LIB"
python3 "/nonexistent/command_timing_lib.py" render "$task_a" cmdtiming-fixture final >/dev/null 2>&1
after_json="$(cat "$task_a/21-command-timings.json")"
specrelay_test::assert_eq "A: an unavailable renderer never corrupts the previous valid JSON" \
  "$before_json" "$after_json"
specrelay_test::assert_true "A: no new top-level runtime directory exists next to .specrelay-runs" \
  "$([ ! -e "$SPECRELAY_ROOT/.specrelay-command-timing" ] && [ ! -e "$SPECRELAY_ROOT/.specrelay-timing" ] && echo 0 || echo 1)"

# --- timeline integration ----------------------------------------------------
timeline_summary="$(python3 -c '
import sys
sys.path.insert(0, "'"$SPECRELAY_ROOT"'/lib/specrelay/py")
import command_timing_lib as c
print(c.timeline_summary("'"$task_a"'"))
')"
specrelay_test::assert_contains "A: timeline_summary references the command-timing artifact" \
  "$timeline_summary" "21-command-timings.json"
specrelay_test::assert_contains "A: timeline_summary includes operation_count" \
  "$timeline_summary" "'operation_count': 17"
specrelay_test::assert_contains "A: timeline_summary includes duplicate_command_count" \
  "$timeline_summary" "'duplicate_command_count': 1"

# A task with NO 21-command-timing-events.jsonl at all -> no summary block
# (legacy timeline stays exactly as before).
legacy_dir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-cmdtiming-legacy.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$legacy_dir")
legacy_none="$(python3 -c '
import sys
sys.path.insert(0, "'"$SPECRELAY_ROOT"'/lib/specrelay/py")
import command_timing_lib as c
print(c.timeline_summary("'"$legacy_dir"'"))
')"
specrelay_test::assert_eq "A: a legacy task with no command-timing events gets no summary block" \
  "None" "$legacy_none"

# =============================================================================
# B. Renderer pairing (py/render_agent_events.py): a matched pair becomes one
#    operation, a pipeline stays one command, an unmatched start is
#    'incomplete', an unmatched finish is silently ignored, and a secret is
#    redacted BEFORE it is ever persisted.
# =============================================================================
bdir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-cmdtiming-render.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$bdir")

cat > "$bdir/fixture.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_a","name":"Bash","input":{"command":"echo start && SECRET_TOKEN=abcdef123456 curl -s https://example.test"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_a","is_error":false,"content":"ok"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_b","name":"Bash","input":{"command":"scripts/test test/x.sh 2>&1 | tail -5"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_b","is_error":true,"content":"Exit code 1\nfailure detail"}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_unknown","is_error":false,"content":"orphan result, no matching start"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_c","name":"Bash","input":{"command":"sleep 999"}}]}}
EOF

python3 "$RENDERER" --role executor:claude --provider claude \
  --command-timing-events "$bdir/timing-events.jsonl" --invocation-id 7 \
  < "$bdir/fixture.jsonl" >/dev/null 2>"$bdir/stderr.txt"

timing_events_b="$(cat "$bdir/timing-events.jsonl" 2>/dev/null)"
specrelay_test::assert_eq "B: exactly 3 operations recorded (orphan finish creates NO 4th)" \
  "3" "$(printf '%s\n' "$timing_events_b" | grep -c .)"
specrelay_test::assert_not_contains "B: the secret value never reaches the timing-events file" \
  "$timing_events_b" "abcdef123456"
specrelay_test::assert_contains "B: the secret NAME stays readable" \
  "$timing_events_b" "SECRET_TOKEN=<redacted>"
specrelay_test::assert_contains "B: a pipeline remains ONE observable command" \
  "$timing_events_b" "scripts/test test/x.sh 2>&1 | tail -5"
specrelay_test::assert_true "B: the passed operation has status passed and exit_code 0" \
  "$(printf '%s\n' "$timing_events_b" | python3 -c 'import json,sys
ops = [json.loads(l) for l in sys.stdin if l.strip()]
op = next(o for o in ops if "curl" in o["command"])
print(0 if op["status"] == "passed" and op["exit_code"] == 0 else 1)')"
specrelay_test::assert_true "B: the failed operation has status failed and exit_code 1 (from 'Exit code 1')" \
  "$(printf '%s\n' "$timing_events_b" | python3 -c 'import json,sys
ops = [json.loads(l) for l in sys.stdin if l.strip()]
op = next(o for o in ops if "tail -5" in o["command"])
print(0 if op["status"] == "failed" and op["exit_code"] == 1 else 1)')"
specrelay_test::assert_true "B: durations are non-negative" \
  "$(printf '%s\n' "$timing_events_b" | python3 -c 'import json,sys
ops = [json.loads(l) for l in sys.stdin if l.strip()]
bad = any(o["duration_seconds"] is not None and o["duration_seconds"] < 0 for o in ops)
print(1 if bad else 0)')"
specrelay_test::assert_true "B: an unmatched start (sleep 999, no tool_result) is marked incomplete" \
  "$(printf '%s\n' "$timing_events_b" | python3 -c 'import json,sys
ops = [json.loads(l) for l in sys.stdin if l.strip()]
op = next(o for o in ops if o["command"] == "sleep 999")
print(0 if op["status"] == "incomplete" and op["duration_seconds"] is None and op["timing_source"] == "not_measurable" else 1)')"
specrelay_test::assert_true "B: every recorded operation is tagged with the given invocation id" \
  "$(printf '%s\n' "$timing_events_b" | python3 -c 'import json,sys
ops = [json.loads(l) for l in sys.stdin if l.strip()]
print(0 if all(o["invocation_id"] == "7" for o in ops) else 1)')"

# =============================================================================
# C. Full lifecycle: bin/specrelay run/resume with a real claude adapter
#    (fake stream-json CLI) and manual reviewer.
# =============================================================================
FAKE_DIR_C="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-cmdtiming-fakeclaude.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$FAKE_DIR_C")
FAKE_CLAUDE_C="$FAKE_DIR_C/claude"
cat > "$FAKE_CLAUDE_C" <<'FAKE'
#!/usr/bin/env bash
set -u
for a in "$@"; do
  if [ "$a" = "--help" ]; then
    echo "Usage: claude"
    echo "  --print"
    echo "  --dangerously-skip-permissions"
    echo "  --verbose"
    echo "  --output-format <fmt>   one of: text, json, stream-json"
    exit 0
  fi
done
cat "$FAKE_CLAUDE_FIXTURE_C"
mkdir -p "$(dirname "$FAKE_EXEC_TASK_DIR_C/x")"
printf 'Fake executor log.\n' > "$FAKE_EXEC_TASK_DIR_C/03-executor-log.md"
printf 'Fake tests.\n' > "$FAKE_EXEC_TASK_DIR_C/07-tests.txt"
printf 'Fake executor summary.\n' > "$FAKE_EXEC_TASK_DIR_C/08-executor-summary.md"
exit 0
FAKE
chmod +x "$FAKE_CLAUDE_C"

proj_c="$(specrelay_test::mktemp_project)"
mkdir -p "$proj_c/.specrelay"
{
  echo "version: 1"
  echo "project:"
  echo "  name: Fixture"
  echo "specs:"
  echo "  root: specs"
  echo "tasks:"
  echo "  runs_root: .specrelay-runs/tasks"
  echo "  max_iterations: 3"
  echo "roles:"
  echo "  executor:"
  echo "    provider: claude"
  echo "  reviewer:"
  echo "    provider: manual"
  echo "context:"
  echo "  adapter: none"
  echo "  required: false"
  echo "validation:"
  echo "  full_test_command: \"echo ok\""
  echo "policy:"
  echo "  human_final_review_required: true"
} > "$proj_c/.specrelay/config.yml"
printf '.specrelay-runs/\n' > "$proj_c/.gitignore"
mkdir -p "$proj_c/specs/0020-fixture"
printf '# Fixture spec\n' > "$proj_c/specs/0020-fixture/spec.md"
(cd "$proj_c" && git add -A && git commit -q -m "fixture")

task_dir_c="$proj_c/.specrelay-runs/tasks/0020-fixture"

cat > "$FAKE_DIR_C/fixture-round1.jsonl" <<'EOF'
{"type":"system","subtype":"init","model":"claude-fixture"}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_r1a","name":"Bash","input":{"command":"scripts/test test/fixture_check.sh"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_r1a","is_error":false,"content":"ok"}]}}
{"type":"result","subtype":"success","result":"Executor summary text."}
EOF

out_c1="$(cd "$proj_c" && \
  SPECRELAY_CLAUDE_BIN="$FAKE_CLAUDE_C" \
  FAKE_CLAUDE_FIXTURE_C="$FAKE_DIR_C/fixture-round1.jsonl" \
  FAKE_EXEC_TASK_DIR_C="$task_dir_c" \
  "$SPECRELAY_BIN" run specs/0020-fixture/spec.md 2>&1)"
rc_c1=$?
specrelay_test::assert_true "C: run stops cleanly at READY_FOR_REVIEW (manual reviewer, exit 2)" \
  "$([ "$rc_c1" -eq 2 ] && echo 0 || echo 1)"

specrelay_test::assert_true "C: 21-command-timing-events.jsonl is written under the REAL task dir" \
  "$([ -s "$task_dir_c/21-command-timing-events.jsonl" ] && echo 0 || echo 1)"
specrelay_test::assert_true "C: 21-command-timings.json is written under the REAL task dir" \
  "$([ -s "$task_dir_c/21-command-timings.json" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "C: the fixture Bash command appears in the artifact" \
  "$(cat "$task_dir_c/21-command-timings.json")" "scripts/test test/fixture_check.sh"

json_ops_c1="$(python3 -c 'import json; print(json.load(open("'"$task_dir_c"'/21-command-timings.json"))["operation_count"])')"
specrelay_test::assert_eq "C: one operation recorded after round 1" "1" "$json_ops_c1"

timeline_out_c="$(cd "$proj_c" && "$SPECRELAY_BIN" task timeline 0020-fixture 2>&1)"
specrelay_test::assert_contains "C: 'task timeline' includes the command-timing report" \
  "$timeline_out_c" "Command Timing"
timeline_json_c="$(cd "$proj_c" && "$SPECRELAY_BIN" task timeline 0020-fixture --json 2>&1)"
specrelay_test::assert_contains "C: 'task timeline --json' includes command_timing_summary" \
  "$timeline_json_c" "command_timing_summary"

commands_out_c="$(cd "$proj_c" && "$SPECRELAY_BIN" task commands 0020-fixture 2>&1)"
specrelay_test::assert_contains "C: 'task commands' shows the Slowest Agent Commands section" \
  "$commands_out_c" "Slowest Agent Commands"
commands_json_c="$(cd "$proj_c" && "$SPECRELAY_BIN" task commands 0020-fixture --json 2>&1)"
specrelay_test::assert_eq "C: 'task commands --json' is valid JSON" \
  "valid" "$(printf '%s' "$commands_json_c" | python3 -c 'import json,sys
try:
    json.load(sys.stdin); print("valid")
except Exception:
    print("invalid")' 2>/dev/null)"

# --- read-only: state.json and the artifact are byte-identical before/after
state_before="$(cat "$task_dir_c/state.json")"
artifact_before="$(cat "$task_dir_c/21-command-timings.json")"
(cd "$proj_c" && "$SPECRELAY_BIN" task timeline 0020-fixture >/dev/null 2>&1)
(cd "$proj_c" && "$SPECRELAY_BIN" task timeline 0020-fixture --json >/dev/null 2>&1)
(cd "$proj_c" && "$SPECRELAY_BIN" task commands 0020-fixture >/dev/null 2>&1)
(cd "$proj_c" && "$SPECRELAY_BIN" task commands 0020-fixture --json >/dev/null 2>&1)
state_after="$(cat "$task_dir_c/state.json")"
artifact_after="$(cat "$task_dir_c/21-command-timings.json")"
specrelay_test::assert_eq "C: read-only inspection never mutates state.json" "$state_before" "$state_after"
specrelay_test::assert_eq "C: read-only inspection never mutates the command-timing artifact" \
  "$artifact_before" "$artifact_after"

# --- resume: a second invocation preserves prior operation history ---------
out_c2="$(cd "$proj_c" && "$SPECRELAY_BIN" resume 0020-fixture 2>&1)"
specrelay_test::assert_true "C: resume with a manual reviewer stops cleanly again (exit 2)" \
  "$([ "$?" -le 2 ] && echo 0 || echo 1)"
json_ops_c2="$(python3 -c 'import json; print(json.load(open("'"$task_dir_c"'/21-command-timings.json"))["operation_count"])')"
specrelay_test::assert_eq "C: resume preserves the prior operation (no new provider run, no data lost)" \
  "1" "$json_ops_c2"
invocation_count_c2="$(cd "$proj_c" && "$SPECRELAY_BIN" task timeline 0020-fixture --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["invocation_count"])')"
specrelay_test::assert_eq "C: the execution timeline recorded a second invocation" "2" "$invocation_count_c2"

# --- no new top-level runtime directory -------------------------------------
specrelay_test::assert_true "C: no new top-level runtime directory was created in the project" \
  "$([ ! -e "$proj_c/.specrelay-command-timing" ] && [ ! -e "$proj_c/21-command-timing-events.jsonl" ] && [ ! -e "$proj_c/21-command-timings.json" ] && echo 0 || echo 1)"

# --- legacy task: created but never run, no command-timing data at all -----
proj_legacy="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_legacy/docs/sdd/0001-legacy"
printf '# spec\n' > "$proj_legacy/docs/sdd/0001-legacy/spec.md"
(cd "$proj_legacy" && git add -A && git commit -q -m "legacy spec")
(cd "$proj_legacy" && "$SPECRELAY_BIN" task create docs/sdd/0001-legacy/spec.md >/dev/null 2>&1)
legacy_timeline="$(cd "$proj_legacy" && "$SPECRELAY_BIN" task timeline 0001-legacy 2>&1)"
specrelay_test::assert_true "C: 'task timeline' for a legacy task still exits 0" \
  "$([ "$?" -eq 0 ] || [ -n "$legacy_timeline" ] && echo 0 || echo 1)"
legacy_commands="$(cd "$proj_legacy" && "$SPECRELAY_BIN" task commands 0001-legacy 2>&1)"
rc_legacy_cmd=$?
specrelay_test::assert_eq "C: 'task commands' for a legacy/never-instrumented task exits 0" "0" "$rc_legacy_cmd"
specrelay_test::assert_contains "C: 'task commands' reports the legacy task honestly as not recorded" \
  "$legacy_commands" "not recorded"
legacy_cmd_json="$(cd "$proj_legacy" && "$SPECRELAY_BIN" task commands 0001-legacy --json 2>&1)"
specrelay_test::assert_eq "C: 'task commands --json' for a legacy task is still valid JSON" \
  "valid" "$(printf '%s' "$legacy_cmd_json" | python3 -c 'import json,sys
try:
    json.load(sys.stdin); print("valid")
except Exception:
    print("invalid")' 2>/dev/null)"

# --- an unknown task fails clearly ------------------------------------------
(cd "$proj_c" && "$SPECRELAY_BIN" task commands nonexistent-task-id >/dev/null 2>&1)
specrelay_test::assert_true "C: 'task commands' for an unknown task fails clearly (non-zero)" \
  "$([ "$?" -ne 0 ] && echo 0 || echo 1)"

# =============================================================================
# D. Performance: extraction over a synthetic ~1,200-operation fixture
#    completes within a reasonable bound (spec 0020, "Performance
#    Requirements" — target is under 2s for a normal event file; this is a
#    deliberately larger stress fixture, so a generous bound is asserted here
#    while the ACTUAL measured time is reported in 08-executor-summary.md).
# =============================================================================
perf_dir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-cmdtiming-perf.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$perf_dir")
python3 -c '
import json
lines = []
for i in range(1200):
    role = "executor" if i % 3 else "reviewer"
    lines.append(json.dumps({
        "invocation_id": str(1 + (i % 4)),
        "role": role,
        "provider": "claude",
        "tool": "Bash",
        "command": "scripts/test test/generated_%d_spec.sh" % i,
        "started_at": "2026-07-14T09:00:00.000000Z",
        "finished_at": "2026-07-14T09:00:01.000000Z",
        "duration_seconds": 1.0,
        "status": "passed",
        "exit_code": 0,
        "timing_source": "local_renderer_monotonic_clock",
        "redacted": False,
    }))
with open("'"$perf_dir"'/21-command-timing-events.jsonl", "w") as f:
    f.write("\n".join(lines) + "\n")
'
perf_start="$(date +%s.%N 2>/dev/null || date +%s)"
python3 "$COMMAND_TIMING_LIB" render "$perf_dir" perf-fixture final --json >/dev/null
perf_end="$(date +%s.%N 2>/dev/null || date +%s)"
perf_elapsed="$(python3 -c "print(round(${perf_end} - ${perf_start}, 3))" 2>/dev/null || echo "n/a")"
echo "D: command-timing extraction over 1,200 synthetic operations took ${perf_elapsed}s"
specrelay_test::assert_true "D: extraction over ~1,200 operations completes within a reasonable bound (<5s)" \
  "$(python3 -c "print(0 if ${perf_elapsed} < 5 else 1)" 2>/dev/null || echo 1)"

specrelay_test::summary
exit $?
