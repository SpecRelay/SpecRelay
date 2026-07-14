#!/usr/bin/env bash
# command_timing.sh — agent command timing ledger instrumentation (spec 0020,
# "Agent Command Timing Ledger"). Thin bash wrapper around
# py/command_timing_lib.py, exactly mirroring timeline.sh's relationship to
# py/timeline_lib.py.
#
# Every call is TASK-SCOPED (never a new top-level directory): the append-only
# source is <task-dir>/21-command-timing-events.jsonl (written incrementally by
# py/render_agent_events.py as it streams a live provider run) and the derived
# report is written atomically to <task-dir>/21-command-timings.json.
# Concurrent writers are already serialized by the existing per-task lock
# (lock.sh) that `specrelay run`/`resume` hold for their whole invocation — no
# separate lock namespace is introduced.

SPECRELAY_COMMAND_TIMING_LIB_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/command_timing_lib.py"

specrelay::command_timing::_available() {
  command -v python3 >/dev/null 2>&1 && [ -f "$SPECRELAY_COMMAND_TIMING_LIB_PY" ]
}

# specrelay::command_timing::events_file <task-dir>
# Prints the path to the append-only command-timing-events source (spec 0020,
# "Runtime Storage" — optional append-only source). Callers pass this to the
# claude provider adapter so the renderer can append to it directly.
specrelay::command_timing::events_file() {
  printf '%s/21-command-timing-events.jsonl\n' "$1"
}

# specrelay::command_timing::render <task-dir> <task-id> <final|partial> [--json]
# Recomputes 21-command-timings.json from the full append-only event source
# and prints the human-readable (or --json) report. Read/derive only for the
# printed report, but WRITES the derived JSON artifact — used only by the
# orchestrator's own finalization step, never by a read-only inspection
# command.
specrelay::command_timing::render() {
  local task_dir="$1" task_id="$2" mode="${3:-final}"; shift 3 || true
  specrelay::command_timing::_available || return 0
  python3 "$SPECRELAY_COMMAND_TIMING_LIB_PY" render "$task_dir" "$task_id" "$mode" "$@" 2>/dev/null
}

# specrelay::command_timing::report <task-dir> <task-id> <final|partial> [--json]
# READ-ONLY variant of render: prints the report but never writes
# 21-command-timings.json (spec 0020, "Task Inspection" — 'task timeline'/
# 'task commands' never mutate task files).
specrelay::command_timing::report() {
  local task_dir="$1" task_id="$2" mode="${3:-partial}"; shift 3 || true
  specrelay::command_timing::_available || return 0
  python3 "$SPECRELAY_COMMAND_TIMING_LIB_PY" report "$task_dir" "$task_id" "$mode" "$@" 2>/dev/null
}

# specrelay::command_timing::show_json <task-dir>
# READ-ONLY: prints the current derived 21-command-timings.json verbatim (or a
# {"recorded": false} placeholder for a legacy/never-instrumented task)
# without recomputing anything.
specrelay::command_timing::show_json() {
  local task_dir="$1"
  specrelay::command_timing::_available || { printf '{"recorded": false}\n'; return 0; }
  python3 "$SPECRELAY_COMMAND_TIMING_LIB_PY" show-json "$task_dir" 2>/dev/null || printf '{"recorded": false}\n'
}
