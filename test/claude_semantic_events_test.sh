#!/usr/bin/env bash
# claude_semantic_events_test.sh — semantic Claude live event rendering (spec
# 0006). Proves the restored behavior deterministically, with NO real Claude:
#
#   0. the standalone renderer turns stream-json fixture events into useful
#      human-readable live lines, extracts the final assistant text, and
#      persists the raw events — private reasoning is never rendered;
#   1. the claude EXECUTOR adapter, driven by a fake `claude` that emits
#      stream-json, renders live lines to fd 2, extracts the final text into
#      12-executor-stdout.txt (NOT raw JSON), and persists raw events to
#      19-executor-events.jsonl;
#   2. the claude REVIEWER adapter does the same into 15/20, still invokes the
#      `--agent ai-reviewer` subagent + stream-json flags, and its DECISION
#      marker is parsed correctly from the EXTRACTED final text (the decision
#      channel is never polluted by the live rendering);
#   3. fallback: with SPECRELAY_SEMANTIC_EVENTS=0 the adapter uses the generic
#      spec-0003 streaming path (raw stdout captured, no events file, no
#      stream-json flags), and still streams live;
#   4. fallback: when the CLI does not advertise stream-json, the generic path
#      is used honestly (semantic events are never faked);
#   5. the provider's REAL exit code is preserved through the semantic pipeline.
#
# Everything runs against isolated temp fixtures and a fake `claude` binary.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/providers/provider.sh
. "$SPECRELAY_ROOT/lib/specrelay/providers/provider.sh"
# shellcheck source=../lib/specrelay/providers/claude.sh
. "$SPECRELAY_ROOT/lib/specrelay/providers/claude.sh"

FIXTURES="$SPECRELAY_ROOT/test/fixtures/agent-events"
RENDERER="$SPECRELAY_ROOT/lib/specrelay/py/render_agent_events.py"

# --- fake `claude` binary ----------------------------------------------------
# One script, parameterized by environment variables so a single fixture drives
# every scenario. It records its real (non-help) argv so tests can assert which
# flags the adapter actually passed.
FAKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-fakeclaude.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$FAKE_DIR")
FAKE_CLAUDE="$FAKE_DIR/claude"
cat > "$FAKE_CLAUDE" <<'FAKE'
#!/usr/bin/env bash
# Fake Claude CLI for deterministic tests. Env knobs:
#   FAKE_CLAUDE_ADVERTISE_STREAM  1 => --help advertises stream-json (default 1)
#   FAKE_CLAUDE_ADVERTISE_AGENT   1 => --help advertises --agent      (default 1)
#   FAKE_CLAUDE_FIXTURE           JSONL file emitted in stream-json mode
#   FAKE_CLAUDE_EXIT              exit code for a real run (default 0)
#   FAKE_CLAUDE_ARGV_LOG          file to append real-run argv to (optional)
set -u

for a in "$@"; do
  if [ "$a" = "--help" ]; then
    echo "Usage: claude [options] <prompt>"
    echo "  --print"
    echo "  --dangerously-skip-permissions"
    if [ "${FAKE_CLAUDE_ADVERTISE_STREAM:-1}" = "1" ]; then
      echo "  --verbose"
      echo "  --output-format <fmt>   one of: text, json, stream-json"
    fi
    if [ "${FAKE_CLAUDE_ADVERTISE_AGENT:-1}" = "1" ]; then
      echo "  --agent <name>          run a named subagent"
    fi
    exit 0
  fi
done

[ -n "${FAKE_CLAUDE_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_CLAUDE_ARGV_LOG"

# stderr is emitted in every mode so stderr capture can be asserted.
echo "fake-claude stderr line" >&2

stream=0
for a in "$@"; do
  [ "$a" = "stream-json" ] && stream=1
done

if [ "$stream" = "1" ] && [ -n "${FAKE_CLAUDE_FIXTURE:-}" ]; then
  cat "$FAKE_CLAUDE_FIXTURE"
else
  echo "plain claude stdout line 1"
  echo "plain claude stdout line 2"
fi

exit "${FAKE_CLAUDE_EXIT:-0}"
FAKE
chmod +x "$FAKE_CLAUDE"
export SPECRELAY_CLAUDE_BIN="$FAKE_CLAUDE"

# Per-test scratch project + task dir + prompt file.
new_task() {
  local proj task
  proj="$(specrelay_test::mktemp_project)"
  task="$proj/task"
  mkdir -p "$task"
  printf 'Implement the spec.\n' > "$task/02-prompt.md"
  printf '%s\t%s\n' "$proj" "$task"
}

# =============================================================================
# Scenario 0 — renderer unit: stream-json fixture -> live lines + extracted text
# =============================================================================
work0="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-r0.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$work0")
rendered0="$(python3 "$RENDERER" --role executor:claude --provider claude \
  --raw-events "$work0/events.jsonl" --final-stdout "$work0/final.txt" \
  < "$FIXTURES/claude-executor.jsonl" 2>/dev/null)"

specrelay_test::assert_contains "0: renders init as a 'started' line" \
  "$rendered0" "[executor:claude] started"
specrelay_test::assert_contains "0: renders a Read tool as 'reading:'" \
  "$rendered0" "[executor:claude] reading: docs/providers.md"
specrelay_test::assert_contains "0: renders a Bash tool as 'command:'" \
  "$rendered0" "[executor:claude] command: git status --short"
specrelay_test::assert_contains "0: renders the final result status" \
  "$rendered0" "[executor:claude] result: success"
specrelay_test::assert_not_contains "0: private thinking is NEVER rendered" \
  "$rendered0" "private reasoning"
specrelay_test::assert_contains "0: final assistant text extracted to --final-stdout" \
  "$(cat "$work0/final.txt")" "Executor final summary: implemented the spec"
specrelay_test::assert_contains "0: raw events persisted verbatim" \
  "$(cat "$work0/events.jsonl")" "\"type\":\"result\""
specrelay_test::assert_not_contains "0: extracted final text is NOT raw JSON" \
  "$(cat "$work0/final.txt")" "\"type\":\"result\""

# =============================================================================
# Scenario 1 — claude EXECUTOR adapter in semantic mode
# =============================================================================
IFS=$'\t' read -r proj1 task1 < <(new_task)
live1="$work0/exec-live.txt"
FAKE_CLAUDE_FIXTURE="$FIXTURES/claude-executor.jsonl" \
FAKE_CLAUDE_ARGV_LOG="$task1/argv.log" \
  specrelay::provider::claude::executor_run "$proj1" "$task1" 1 "$task1/02-prompt.md" "executor:claude" 2>"$live1"
rc1=$?

specrelay_test::assert_eq "1: executor semantic run exits 0" "0" "$rc1"
specrelay_test::assert_contains "1: live terminal shows rendered activity lines" \
  "$(cat "$live1")" "[executor:claude] reading: docs/providers.md"
specrelay_test::assert_contains "1: live terminal shows the final result line" \
  "$(cat "$live1")" "[executor:claude] result: success"
specrelay_test::assert_contains "1: stderr streamed live (prefixed)" \
  "$(cat "$live1")" "[executor:claude] fake-claude stderr line"
specrelay_test::assert_contains "1: 12-executor-stdout.txt holds the EXTRACTED final text" \
  "$(cat "$task1/12-executor-stdout.txt")" "Executor final summary"
specrelay_test::assert_not_contains "1: 12-executor-stdout.txt is NOT raw JSON" \
  "$(cat "$task1/12-executor-stdout.txt")" "\"type\":\"result\""
specrelay_test::assert_contains "1: 19-executor-events.jsonl holds the raw JSON stream" \
  "$(cat "$task1/19-executor-events.jsonl")" "\"type\":\"result\""
specrelay_test::assert_contains "1: 13-executor-stderr.txt captured raw stderr" \
  "$(cat "$task1/13-executor-stderr.txt")" "fake-claude stderr line"
specrelay_test::assert_contains "1: executor invoked claude with stream-json flags" \
  "$(cat "$task1/argv.log")" "--output-format stream-json"

# =============================================================================
# Scenario 2 — claude REVIEWER adapter in semantic mode (subagent + decision)
# =============================================================================
IFS=$'\t' read -r proj2 task2 < <(new_task)
mkdir -p "$proj2/.claude/agents"
printf '# ai-reviewer\n' > "$proj2/.claude/agents/ai-reviewer.md"
live2="$work0/rev-live.txt"
decision2="$(FAKE_CLAUDE_FIXTURE="$FIXTURES/claude-reviewer-accept.jsonl" \
  FAKE_CLAUDE_ARGV_LOG="$task2/argv.log" \
  specrelay::provider::claude::reviewer_run "$proj2" "$task2" 1 "$task2/02-prompt.md" "reviewer:claude" 2>"$live2")"
rc2=$?

specrelay_test::assert_eq "2: reviewer semantic run exits 0" "0" "$rc2"
specrelay_test::assert_eq "2: reviewer decision parsed from extracted final text" "ACCEPT" "$decision2"
specrelay_test::assert_contains "2: reviewer live output rendered (scoped)" \
  "$(cat "$live2")" "[reviewer:claude] command: git diff --stat"
specrelay_test::assert_contains "2: 15-reviewer-stdout.txt holds the extracted decision text" \
  "$(cat "$task2/15-reviewer-stdout.txt")" "DECISION: ACCEPT"
specrelay_test::assert_not_contains "2: 15-reviewer-stdout.txt is NOT raw JSON" \
  "$(cat "$task2/15-reviewer-stdout.txt")" "\"type\":\"result\""
specrelay_test::assert_contains "2: 20-reviewer-events.jsonl holds the raw JSON stream" \
  "$(cat "$task2/20-reviewer-events.jsonl")" "\"type\":\"result\""
specrelay_test::assert_contains "2: reviewer invoked the ai-reviewer subagent" \
  "$(cat "$task2/argv.log")" "--agent ai-reviewer"
specrelay_test::assert_contains "2: reviewer used stream-json flags" \
  "$(cat "$task2/argv.log")" "--output-format stream-json"
# The decision channel (fd 1) must carry ONLY the decision, never rendered lines.
specrelay_test::assert_not_contains "2: decision channel not polluted by live rendering" \
  "$decision2" "command: git diff"

# =============================================================================
# Scenario 3 — fallback: SPECRELAY_SEMANTIC_EVENTS=0 forces generic streaming
# =============================================================================
IFS=$'\t' read -r proj3 task3 < <(new_task)
live3="$work0/exec-live3.txt"
SPECRELAY_SEMANTIC_EVENTS=0 \
FAKE_CLAUDE_FIXTURE="$FIXTURES/claude-executor.jsonl" \
FAKE_CLAUDE_ARGV_LOG="$task3/argv.log" \
  specrelay::provider::claude::executor_run "$proj3" "$task3" 1 "$task3/02-prompt.md" "executor:claude" 2>"$live3"
rc3=$?

specrelay_test::assert_eq "3: disabled-semantic run exits 0" "0" "$rc3"
specrelay_test::assert_contains "3: generic path captures RAW plain stdout to 12" \
  "$(cat "$task3/12-executor-stdout.txt")" "plain claude stdout line 1"
specrelay_test::assert_true "3: generic path creates NO events file" \
  "$([ ! -e "$task3/19-executor-events.jsonl" ] && echo 0 || echo 1)"
specrelay_test::assert_not_contains "3: generic path did NOT pass stream-json flags" \
  "$(cat "$task3/argv.log")" "stream-json"
specrelay_test::assert_contains "3: generic path still streams live (prefixed)" \
  "$(cat "$live3")" "[executor:claude] plain claude stdout line 1"

# =============================================================================
# Scenario 4 — fallback: CLI does not advertise stream-json -> generic (honest)
# =============================================================================
IFS=$'\t' read -r proj4 task4 < <(new_task)
live4="$work0/exec-live4.txt"
FAKE_CLAUDE_ADVERTISE_STREAM=0 \
FAKE_CLAUDE_FIXTURE="$FIXTURES/claude-executor.jsonl" \
FAKE_CLAUDE_ARGV_LOG="$task4/argv.log" \
  specrelay::provider::claude::executor_run "$proj4" "$task4" 1 "$task4/02-prompt.md" "executor:claude" 2>"$live4"
rc4=$?

specrelay_test::assert_eq "4: unadvertised-stream run exits 0" "0" "$rc4"
specrelay_test::assert_contains "4: generic path captures RAW plain stdout to 12" \
  "$(cat "$task4/12-executor-stdout.txt")" "plain claude stdout line 2"
specrelay_test::assert_not_contains "4: generic path did NOT pass stream-json flags" \
  "$(cat "$task4/argv.log")" "stream-json"

# =============================================================================
# Scenario 5 — a FAILED semantic run preserves the real exit code AND is NOT
#   automatically retried as a generic run (pre-launch-only fallback contract).
# =============================================================================
IFS=$'\t' read -r proj5 task5 < <(new_task)
FAKE_CLAUDE_FIXTURE="$FIXTURES/claude-executor.jsonl" \
FAKE_CLAUDE_EXIT=7 \
FAKE_CLAUDE_ARGV_LOG="$task5/argv.log" \
  specrelay::provider::claude::executor_run "$proj5" "$task5" 1 "$task5/02-prompt.md" "executor:claude" 2>/dev/null
rc5=$?
specrelay_test::assert_eq "5: semantic pipeline preserves the provider exit code (7)" "7" "$rc5"
# The provider was launched exactly ONCE, in semantic mode — no generic retry.
specrelay_test::assert_eq "5: failed semantic run is not retried (single launch)" \
  "1" "$(grep -c . "$task5/argv.log")"
specrelay_test::assert_contains "5: the single launch was the semantic invocation" \
  "$(cat "$task5/argv.log")" "--output-format stream-json"
specrelay_test::assert_not_contains "5: no generic retry ran after the semantic failure" \
  "$(cat "$task5/12-executor-stdout.txt")" "plain claude stdout line"

specrelay_test::summary
exit $?
