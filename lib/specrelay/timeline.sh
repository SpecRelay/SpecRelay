#!/usr/bin/env bash
# timeline.sh — execution-timeline / verification-ledger instrumentation
# (spec 0019, "Execution Timeline"). Thin bash wrapper around
# py/timeline_lib.py (SpecRelay's own timing/aggregation module — mirrors
# state.sh's relationship to py/state_lib.py).
#
# Every call is TASK-SCOPED (never a new top-level directory): events are
# appended to <task-dir>/20-execution-events.jsonl and the derived report is
# written atomically to <task-dir>/20-execution-timeline.json. Concurrent
# writers are already serialized by the existing per-task lock (lock.sh) that
# `specrelay run`/`resume` hold for their whole invocation — no separate lock
# namespace is introduced.

SPECRELAY_TIMELINE_LIB_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/timeline_lib.py"

specrelay::timeline::_available() {
  command -v python3 >/dev/null 2>&1 && [ -f "$SPECRELAY_TIMELINE_LIB_PY" ]
}

# specrelay::timeline::event <task-dir> <event-type> <json-fields>
# <json-fields> is a JSON OBJECT (already redacted by the caller) merged into
# the event; empty/"{}" is fine. Never fatal: instrumentation must never break
# the workflow it observes (a missing python3 silently disables timing, exactly
# like the semantic-events renderer degrades — spec 0019 does not require
# instrumentation to be able to break a run).
specrelay::timeline::event() {
  local task_dir="$1" event_type="$2" fields="${3:-{\}}"
  specrelay::timeline::_available || return 0
  printf '%s' "$fields" | python3 "$SPECRELAY_TIMELINE_LIB_PY" emit "$task_dir" "$event_type" 2>/dev/null || true
}

# specrelay::timeline::start <task-dir> <phase> [role]
specrelay::timeline::start() {
  local task_dir="$1" phase="$2" role="${3:-}"
  specrelay::timeline::event "$task_dir" phase_start \
    "$(ROLE="$role" PHASE="$phase" python3 -c 'import json,os; print(json.dumps({"phase": os.environ["PHASE"], "role": os.environ["ROLE"] or None}))' 2>/dev/null || printf '{"phase":"%s"}' "$phase")"
}

# specrelay::timeline::finish <task-dir> <phase> <status>
# <status> is one of passed|failed|skipped (never mutates task state; purely
# observational).
specrelay::timeline::finish() {
  local task_dir="$1" phase="$2" status="${3:-passed}"
  specrelay::timeline::event "$task_dir" phase_finish \
    "$(PHASE="$phase" STATUS="$status" python3 -c 'import json,os; print(json.dumps({"phase": os.environ["PHASE"], "status": os.environ["STATUS"]}))' 2>/dev/null || printf '{"phase":"%s","status":"%s"}' "$phase" "$status")"
}

# specrelay::timeline::phase <task-dir> <phase> <role> -- <command...>
# Convenience wrapper: times an arbitrary command as one phase, recording
# passed/failed from its real exit code, and returns that exit code.
specrelay::timeline::phase() {
  local task_dir="$1" phase="$2" role="$3"
  shift 3
  [ "${1:-}" = "--" ] && shift
  specrelay::timeline::start "$task_dir" "$phase" "$role"
  local rc
  "$@"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    specrelay::timeline::finish "$task_dir" "$phase" passed
  else
    specrelay::timeline::finish "$task_dir" "$phase" failed
  fi
  return "$rc"
}

# specrelay::timeline::invocation_start <task-dir> <invocation-id> <initial-state>
specrelay::timeline::invocation_start() {
  local task_dir="$1" invocation_id="$2" initial_state="$3"
  specrelay::timeline::event "$task_dir" invocation_start \
    "$(ID="$invocation_id" STATE="$initial_state" python3 -c 'import json,os; print(json.dumps({"invocation_id": int(os.environ["ID"]), "initial_state": os.environ["STATE"]}))' 2>/dev/null)"
}

# specrelay::timeline::invocation_finish <task-dir> <invocation-id> <final-state> <exit-code>
specrelay::timeline::invocation_finish() {
  local task_dir="$1" invocation_id="$2" final_state="$3" exit_code="$4"
  specrelay::timeline::event "$task_dir" invocation_finish \
    "$(ID="$invocation_id" STATE="$final_state" EXIT="$exit_code" python3 -c 'import json,os; print(json.dumps({"invocation_id": int(os.environ["ID"]), "final_state": os.environ["STATE"], "exit_code": int(os.environ["EXIT"])}))' 2>/dev/null)"
}

# specrelay::timeline::next_invocation_id <task-dir>
# Prints the next invocation id (1-indexed) by counting existing
# invocation_start events. Read-only.
specrelay::timeline::next_invocation_id() {
  local task_dir="$1" n
  specrelay::timeline::_available || { printf '1\n'; return 0; }
  n="$(python3 "$SPECRELAY_TIMELINE_LIB_PY" next-invocation-id "$task_dir" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  printf '%s\n' "$n"
}

# specrelay::timeline::marker_recovery_event <task-dir> <attempted:true|false> <outcome>
specrelay::timeline::marker_recovery_event() {
  local task_dir="$1" attempted="$2" outcome="$3"
  specrelay::timeline::event "$task_dir" marker_recovery \
    "$(ATT="$attempted" OUT="$outcome" python3 -c 'import json,os; print(json.dumps({"attempted": os.environ["ATT"] == "true", "outcome": os.environ["OUT"]}))' 2>/dev/null)"
}

# specrelay::timeline::render <project-root> <task-dir> <task-id> <final|partial> [--json]
# Recomputes 20-execution-timeline.json from the full event log and prints
# the human-readable (or --json) report. Read/derive only — never mutates
# task state. <project-root> is required explicitly (never reverse-engineered
# from <task-dir>, whose depth under the project root depends on the
# CONFIGURABLE tasks.runs_root value).
specrelay::timeline::render() {
  local root="$1" task_dir="$2" task_id="$3" mode="${4:-final}"; shift 4 || true
  specrelay::timeline::_available || return 0
  local budgets_json
  budgets_json="$(specrelay::timeline::_budgets_json "$root")"
  printf '%s' "$budgets_json" | python3 "$SPECRELAY_TIMELINE_LIB_PY" render "$task_dir" "$task_id" "$mode" "$@" 2>/dev/null
}

# specrelay::timeline::_budgets_json <project-root>
# Renders the effective phase_budgets config as JSON for the python renderer.
specrelay::timeline::_budgets_json() {
  local root="$1" out
  out="$(specrelay::config::phase_budgets "$root" 2>/dev/null)" || { printf '{}\n'; return 0; }
  python3 -c '
import json, sys
d = {}
for line in sys.stdin:
    line = line.strip()
    if "=" not in line:
        continue
    k, v = line.split("=", 1)
    try:
        d[k] = int(v)
    except ValueError:
        pass
print(json.dumps(d))
' <<< "$out"
}

# specrelay::timeline::report <project-root> <task-dir> <task-id> <final|partial> [--json]
# READ-ONLY variant of render: prints the report but never writes
# 20-execution-timeline.json (spec 0019, "Task Inspection" — 'task timeline'
# must never mutate task files).
specrelay::timeline::report() {
  local root="$1" task_dir="$2" task_id="$3" mode="${4:-partial}"; shift 4 || true
  specrelay::timeline::_available || return 0
  local budgets_json
  budgets_json="$(specrelay::timeline::_budgets_json "$root")"
  printf '%s' "$budgets_json" | python3 "$SPECRELAY_TIMELINE_LIB_PY" report "$task_dir" "$task_id" "$mode" "$@" 2>/dev/null
}

# specrelay::timeline::show_json <task-dir>
# READ-ONLY: prints the current derived timeline.json verbatim (or a
# {"recorded": false} placeholder for a legacy task) without recomputing
# anything. Used by 'task timeline' so inspection never mutates task files.
specrelay::timeline::show_json() {
  local task_dir="$1"
  specrelay::timeline::_available || { printf '{"recorded": false}\n'; return 0; }
  python3 "$SPECRELAY_TIMELINE_LIB_PY" show-json "$task_dir" 2>/dev/null || printf '{"recorded": false}\n'
}
