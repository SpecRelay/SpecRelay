#!/usr/bin/env bash
# agent_efficiency.sh — execution-efficiency policy + completion-gate
# instrumentation (spec 0021, "Agent Execution Efficiency and Completion
# Gate"). Thin bash wrapper around py/agent_efficiency_lib.py, mirroring
# timeline.sh's / command_timing.sh's relationship to their own python
# modules.
#
# Every call is TASK-SCOPED (never a new top-level directory): completion-gate
# results are recorded as ordinary events in the SAME append-only
# <task-dir>/20-execution-events.jsonl spec 0019 already writes (a new
# event_type, "completion_gate", not a new file), classification reuses the
# SAME <task-dir>/21-command-timing-events.jsonl spec 0020 already writes, and
# the derived report is written atomically to
# <task-dir>/22-agent-efficiency.json.

SPECRELAY_AGENT_EFFICIENCY_LIB_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/agent_efficiency_lib.py"

specrelay::agent_efficiency::_available() {
  command -v python3 >/dev/null 2>&1 && [ -f "$SPECRELAY_AGENT_EFFICIENCY_LIB_PY" ]
}

# --- policy (spec 0021, "Configuration") ------------------------------------

# specrelay::agent_efficiency::_policy_field <root> <field>
specrelay::agent_efficiency::_policy_field() {
  local root="$1" field="$2" blob
  blob="$(specrelay::config::execution_efficiency_policy "$root" 2>/dev/null)" || return 1
  printf '%s\n' "$blob" | sed -n "s/^${field}=//p"
}

specrelay::agent_efficiency::enabled() {
  local v
  v="$(specrelay::agent_efficiency::_policy_field "$1" enabled)" || v="true"
  printf '%s\n' "${v:-true}"
}

specrelay::agent_efficiency::executor_field() {
  specrelay::agent_efficiency::_policy_field "$1" "executor_$2"
}

specrelay::agent_efficiency::reviewer_field() {
  specrelay::agent_efficiency::_policy_field "$1" "reviewer_$2"
}

# --- unresolved-waiting detection (spec 0021) -------------------------------

# specrelay::agent_efficiency::detect_unresolved_wait <final-output-file>
# Prints "detected" or "none". Never fatal (a missing python3 degrades to
# "none" — instrumentation must never block a real completion, and the
# caller only treats "detected" as blocking, never the reverse).
specrelay::agent_efficiency::detect_unresolved_wait() {
  local final_file="$1"
  specrelay::agent_efficiency::_available || { printf 'none\n'; return 0; }
  python3 "$SPECRELAY_AGENT_EFFICIENCY_LIB_PY" detect-unresolved-wait "$final_file" 2>/dev/null || printf 'none\n'
}

# specrelay::agent_efficiency::background_check <role>
# Where SpecRelay can reliably identify provider-owned child processes still
# alive AFTER the provider invocation has already returned, it would report
# them here (spec 0021, "Background Process Check"). SpecRelay's provider
# adapters run the provider as a synchronously-waited foreground child (see
# providers/provider.sh's run_streamed/run_agent_events, which always `wait`s
# before returning) — by the time this check runs, ownership of any process
# the provider may have spawned and detached can no longer be established
# reliably, so this HONESTLY reports not_verifiable rather than guessing from
# a process/command name. It never scans or kills unrelated system processes.
specrelay::agent_efficiency::background_check() {
  printf 'not_verifiable\n'
}

# specrelay::agent_efficiency::record_completion_gate <task-dir> <role> <passed|failed> [reason]
# Appends a `completion_gate` event to the task's existing execution-events
# log (spec 0019's 20-execution-events.jsonl) — no new file.
specrelay::agent_efficiency::record_completion_gate() {
  local task_dir="$1" role="$2" result="$3" reason="${4:-}"
  local fields
  fields="$(ROLE="$role" RESULT="$result" REASON="$reason" python3 -c '
import json, os
d = {"role": os.environ["ROLE"], "result": os.environ["RESULT"]}
reason = os.environ.get("REASON", "")
if reason:
    d["reason"] = reason
print(json.dumps(d))
' 2>/dev/null)"
  [ -n "$fields" ] || fields='{}'
  specrelay::timeline::event "$task_dir" completion_gate "$fields"
}

# --- reporting ---------------------------------------------------------------

# specrelay::agent_efficiency::render <task-dir> <task-id> <final|partial> [--json]
# WRITES 22-agent-efficiency.json (atomic replace) — used only by the
# orchestrator's own finalization step.
specrelay::agent_efficiency::render() {
  local task_dir="$1" task_id="$2" mode="${3:-final}"; shift 3 || true
  specrelay::agent_efficiency::_available || return 0
  python3 "$SPECRELAY_AGENT_EFFICIENCY_LIB_PY" render "$task_dir" "$task_id" "$mode" "$@" 2>/dev/null
}

# specrelay::agent_efficiency::report <task-dir> <task-id> <final|partial> [--json]
# READ-ONLY variant of render: never writes 22-agent-efficiency.json (spec
# 0021, "Task Inspection" — read-only inspection must not mutate task files).
specrelay::agent_efficiency::report() {
  local task_dir="$1" task_id="$2" mode="${3:-partial}"; shift 3 || true
  specrelay::agent_efficiency::_available || return 0
  python3 "$SPECRELAY_AGENT_EFFICIENCY_LIB_PY" report "$task_dir" "$task_id" "$mode" "$@" 2>/dev/null
}

# specrelay::agent_efficiency::show_json <task-dir>
# READ-ONLY: prints the current derived 22-agent-efficiency.json verbatim (or
# a {"recorded": false} placeholder for a legacy task) without recomputing.
specrelay::agent_efficiency::show_json() {
  local task_dir="$1"
  specrelay::agent_efficiency::_available || { printf '{"recorded": false}\n'; return 0; }
  python3 "$SPECRELAY_AGENT_EFFICIENCY_LIB_PY" show-json "$task_dir" 2>/dev/null || printf '{"recorded": false}\n'
}
