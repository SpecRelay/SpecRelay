#!/usr/bin/env bash
# execution_timeline_test.sh — execution-timeline instrumentation, JSON
# durability, and multi-resume history (spec 0019, "D. Execution Timeline").

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/config.sh
. "$SPECRELAY_ROOT/lib/specrelay/config.sh"
# shellcheck source=../lib/specrelay/timeline.sh
. "$SPECRELAY_ROOT/lib/specrelay/timeline.sh"
# shellcheck source=../lib/specrelay/verification.sh
. "$SPECRELAY_ROOT/lib/specrelay/verification.sh"

# =============================================================================
# Low-level instrumentation API: start/finish, invocation lifecycle, and
# JSON validity/atomicity, exercised directly (no real task lifecycle).
# =============================================================================
tdir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-timeline-unit.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$tdir")
proj_root="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-timeline-root.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$proj_root")

specrelay::timeline::invocation_start "$tdir" 1 READY_FOR_EXECUTOR
specrelay::timeline::start "$tdir" task_initialization
specrelay::timeline::finish "$tdir" task_initialization passed
specrelay::timeline::start "$tdir" executor_provider_execution executor
specrelay::timeline::finish "$tdir" executor_provider_execution passed
specrelay::timeline::invocation_finish "$tdir" 1 READY_FOR_HUMAN_REVIEW 0

specrelay_test::assert_true "invocation start is recorded (events file exists)" \
  "$([ -s "$tdir/20-execution-events.jsonl" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "invocation start event is present" \
  "$(cat "$tdir/20-execution-events.jsonl")" "invocation_start"
specrelay_test::assert_contains "invocation finish event is present" \
  "$(cat "$tdir/20-execution-events.jsonl")" "invocation_finish"
specrelay_test::assert_contains "executor preflight/provider phases are timed" \
  "$(cat "$tdir/20-execution-events.jsonl")" "executor_provider_execution"

json1="$(specrelay::timeline::render "$proj_root" "$tdir" "unit-task" final --json)"
specrelay_test::assert_eq "rendered JSON is valid" \
  "valid" "$(printf '%s' "$json1" | python3 -c 'import json,sys
try:
    json.load(sys.stdin)
    print("valid")
except Exception:
    print("invalid")' 2>/dev/null)"
specrelay_test::assert_contains "schema version is recorded" "$json1" '"schema_version": 1'
specrelay_test::assert_contains "task ID is correct" "$json1" '"task_id": "unit-task"'
specrelay_test::assert_true "the file is written atomically (exists + non-empty)" \
  "$([ -s "$tdir/20-execution-timeline.json" ] && echo 0 || echo 1)"
specrelay_test::assert_true "durations are non-negative" \
  "$(printf '%s' "$json1" | python3 -c 'import json,sys
d = json.load(sys.stdin)
bad = any((p.get("duration_seconds") or 0) < 0 for p in d["phases"])
print(1 if bad else 0)')"
specrelay_test::assert_true "UTC timestamps are valid ISO-8601 Z" \
  "$(printf '%s' "$json1" | python3 -c 'import json,sys,re
d = json.load(sys.stdin)
ok = bool(re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", d["started_at"] or ""))
print(0 if ok else 1)')"

# --- no secret values are recorded ------------------------------------------
specrelay::verification::record "$tdir" executor "MY_API_KEY=sekret123 scripts/test" "" "" "" "test"
ledger_secret_check="$(cat "$tdir/20-execution-events.jsonl")"
specrelay_test::assert_not_contains "no secret values are recorded in the event log" \
  "$ledger_secret_check" "sekret123"
specrelay_test::assert_contains "the command is redacted, not silently dropped" \
  "$ledger_secret_check" "redacted"

# --- interrupted write does not destroy previous valid timeline -------------
before_json="$(cat "$tdir/20-execution-timeline.json")"
# Simulate a render that would fail (no python3 available) — the file must
# remain exactly as it was.
SPECRELAY_TIMELINE_LIB_PY_BACKUP="$SPECRELAY_TIMELINE_LIB_PY"
SPECRELAY_TIMELINE_LIB_PY="/nonexistent/timeline_lib.py"
specrelay::timeline::render "$proj_root" "$tdir" "unit-task" final >/dev/null
SPECRELAY_TIMELINE_LIB_PY="$SPECRELAY_TIMELINE_LIB_PY_BACKUP"
after_json="$(cat "$tdir/20-execution-timeline.json")"
specrelay_test::assert_eq "an unavailable renderer never corrupts the previous valid timeline JSON" \
  "$before_json" "$after_json"

# --- no new top-level runtime directory is created --------------------------
specrelay_test::assert_true "no new top-level runtime directory exists next to .specrelay-runs" \
  "$([ ! -e "$SPECRELAY_ROOT/.specrelay-timeline" ] && [ ! -e "$SPECRELAY_ROOT/.specrelay-events" ] && echo 0 || echo 1)"

# =============================================================================
# Multi-resume: invocation count, resume count, and previous invocations stay
# intact, exercised through the REAL task lifecycle (fake provider).
# =============================================================================
proj="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj/docs/sdd/0001-multi-resume"
echo "# spec" > "$proj/docs/sdd/0001-multi-resume/spec.md"
(cd "$proj" && git add -A && git commit -q -m "spec")
(cd "$proj" && "$SPECRELAY_BIN" run docs/sdd/0001-multi-resume/spec.md >/dev/null 2>&1)

timeline_json="$(cd "$proj" && "$SPECRELAY_BIN" task timeline 0001-multi-resume --json)"
specrelay_test::assert_eq "after the first run: invocation_count is 1" \
  "1" "$(printf '%s' "$timeline_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["invocation_count"])')"
specrelay_test::assert_eq "after the first run: resume_count is 0" \
  "0" "$(printf '%s' "$timeline_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["resume_count"])')"
first_invocation_started="$(printf '%s' "$timeline_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["invocations"][0]["started_at"])')"

(cd "$proj" && "$SPECRELAY_BIN" resume 0001-multi-resume >/dev/null 2>&1)
(cd "$proj" && "$SPECRELAY_BIN" resume 0001-multi-resume >/dev/null 2>&1)
timeline_json2="$(cd "$proj" && "$SPECRELAY_BIN" task timeline 0001-multi-resume --json)"
specrelay_test::assert_eq "after two resumes: invocation_count is 3" \
  "3" "$(printf '%s' "$timeline_json2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["invocation_count"])')"
specrelay_test::assert_eq "resume adds a new invocation each time: resume_count is 2" \
  "2" "$(printf '%s' "$timeline_json2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["resume_count"])')"
specrelay_test::assert_eq "the previous (first) invocation remains intact" \
  "$first_invocation_started" \
  "$(printf '%s' "$timeline_json2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["invocations"][0]["started_at"])')"
specrelay_test::assert_eq "total wall time spans all invocations (matches first start .. last finish)" \
  "1" "$(printf '%s' "$timeline_json2" | python3 -c '
import json, sys
from datetime import datetime
d = json.load(sys.stdin)
invs = d["invocations"]
fmt = "%Y-%m-%dT%H:%M:%SZ"
start = datetime.strptime(invs[0]["started_at"], fmt)
finish = datetime.strptime(invs[-1]["finished_at"], fmt)
expected = (finish - start).total_seconds()
print(1 if abs(expected - d["wall_seconds"]) < 2 else 0)
')"

# =============================================================================
# Partial invocation is retained after a provider failure (interrupted phase
# stays visible rather than being erased).
# =============================================================================
proj_fail="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_fail/docs/sdd/0002-partial"
echo "# spec" > "$proj_fail/docs/sdd/0002-partial/spec.md"
(cd "$proj_fail" && git add -A && git commit -q -m "spec")
plan_fail="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")"
printf 'exit=1\n' > "$plan_fail/executor-plan.txt"
(cd "$proj_fail" && SPECRELAY_FAKE_EXECUTOR_PLAN="$plan_fail/executor-plan.txt" \
  "$SPECRELAY_BIN" run docs/sdd/0002-partial/spec.md >/dev/null 2>&1)
partial_timeline="$(cd "$proj_fail" && "$SPECRELAY_BIN" task timeline 0002-partial 2>&1)"
specrelay_test::assert_contains "a provider failure yields a PARTIAL report" \
  "$partial_timeline" "PARTIAL"
specrelay_test::assert_contains "the partial report still shows the attempted phase" \
  "$partial_timeline" "executor_provider_execution"

# =============================================================================
# Final Timeline Rendering: stream-friendly properties (spec 0019, "Stream-
# Friendly Output Remains Mandatory" / "Final Timeline Rendering").
# =============================================================================
human_report="$(specrelay::timeline::render "$proj_root" "$tdir" "unit-task" final)"
esc="$(printf '\033')"
specrelay_test::assert_not_contains "no ANSI escape codes in the (non-TTY) rendered report" \
  "$human_report" "$esc"
specrelay_test::assert_contains "a final report is labeled FINAL" "$human_report" "FINAL"

partial_report="$(specrelay::timeline::render "$proj_root" "$tdir" "unit-task" partial)"
specrelay_test::assert_contains "a partial report is labeled PARTIAL" "$partial_report" "PARTIAL"

# Redirected output (a real file, not a pipe/tty) contains the complete
# report end-to-end.
redirect_file="$(mktemp "${TMPDIR:-/tmp}/specrelay-timeline-redirect.XXXXXX")"
specrelay::timeline::render "$proj_root" "$tdir" "unit-task" final > "$redirect_file"
specrelay_test::assert_contains "redirected output contains the total wall time line" \
  "$(cat "$redirect_file")" "Total wall time"
specrelay_test::assert_contains "redirected output contains the verification ledger" \
  "$(cat "$redirect_file")" "Verification Ledger"
specrelay_test::assert_contains "redirected output contains the performance summary" \
  "$(cat "$redirect_file")" "Performance Summary"
rm -f "$redirect_file"

# Slowest phases are printed sorted (descending by duration).
tdir_sort="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-timeline-sort.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$tdir_sort")
specrelay::timeline::invocation_start "$tdir_sort" 1 READY_FOR_EXECUTOR
specrelay::timeline::start "$tdir_sort" executor_evidence_capture executor; sleep 0.05
specrelay::timeline::finish "$tdir_sort" executor_evidence_capture passed
specrelay::timeline::start "$tdir_sort" executor_provider_execution executor; sleep 0.2
specrelay::timeline::finish "$tdir_sort" executor_provider_execution passed
specrelay::timeline::invocation_finish "$tdir_sort" 1 READY_FOR_HUMAN_REVIEW 0
sort_report="$(specrelay::timeline::render "$proj_root" "$tdir_sort" "sort-task" final)"
first_slow_line="$(printf '%s\n' "$sort_report" | grep -A1 "^Slowest phases:" | tail -n1)"
specrelay_test::assert_contains "slowest phases: the largest measured duration is listed first" \
  "$first_slow_line" "executor_provider_execution"

specrelay_test::summary
exit $?
