#!/usr/bin/env bash
# verification.sh — bounded verification policy + verification ledger (spec
# 0019, sections A and D "Verification Ledger").
#
# Classification is COMMAND-STRING based and deliberately narrow (spec:
# "recognize... at minimum"; "do not guess from vague command text"). A
# command that does not match a known pattern is always
# agent_tool_execution_unclassified — never fabricated.

# specrelay::verification::classify <command>
# Prints one of: test_focused | test_targeted | test_full | smoke | doctor |
# version | agent_tool_execution_unclassified.
specrelay::verification::classify() {
  local cmd
  cmd="$(printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$cmd" in
    *scripts/test\ --changed*|*scripts/test\ --changed-files*)
      printf 'test_targeted\n' ;;
    *scripts/test\ --jobs*|*scripts/test\ --timings*|*scripts/test)
      # A bare `scripts/test` (or one with only runner-shape flags like
      # --jobs/--timings and no explicit file/--changed argument) runs the
      # complete standalone suite.
      printf 'test_full\n' ;;
    *scripts/test\ test/*)
      printf 'test_focused\n' ;;
    *scripts/smoke*)
      printf 'smoke\n' ;;
    *bin/specrelay\ doctor*|*specrelay\ doctor*)
      printf 'doctor\n' ;;
    *bin/specrelay\ version*|*specrelay\ version*)
      printf 'version\n' ;;
    *)
      printf 'agent_tool_execution_unclassified\n' ;;
  esac
}

# specrelay::verification::redact <command>
# Delegates to timeline_lib.py's narrow secret-shaped redaction (spec 0019,
# "Security and Privacy") so ledger commands never leak an inline secret
# assignment. A command with nothing secret-shaped passes through unchanged.
specrelay::verification::redact() {
  local cmd="$1"
  if command -v python3 >/dev/null 2>&1 && [ -f "$SPECRELAY_TIMELINE_LIB_PY" ]; then
    CMD="$cmd" python3 -c '
import os, sys
sys.path.insert(0, os.path.dirname("'"$SPECRELAY_TIMELINE_LIB_PY"'"))
import timeline_lib as t
print(t.redact_command(os.environ["CMD"]))
' 2>/dev/null && return 0
  fi
  printf '%s\n' "$cmd"
}

# specrelay::verification::record <task-dir> <role> <command> [duration-seconds] [exit-code] [reason] [source]
# Classifies <command>, redacts it, and appends a verification event to the
# task's timeline event log (spec 0019, "Verification Event Fields").
# duration/exit-code/reason are optional; an empty value is recorded honestly
# as not_available rather than fabricated.
specrelay::verification::record() {
  local task_dir="$1" role="$2" command="$3" duration="${4:-}" exit_code="${5:-}" reason="${6:-}" source="${7:-orchestrator}"
  specrelay::verification::record_op "$task_dir" "$role" "$(specrelay::verification::classify "$command")" \
    "$command" "$duration" "$exit_code" "$reason" "$source"
}

# specrelay::verification::record_op <task-dir> <role> <operation> <command> [duration-seconds] [exit-code] [reason] [source]
# Like record above, but the operation classification is ALREADY KNOWN (e.g.
# a deterministic test fixture, or a caller that classified once and wants to
# avoid re-deriving it) — never re-classified from <command>.
specrelay::verification::record_op() {
  local task_dir="$1" role="$2" operation="$3" command="$4" duration="${5:-}" exit_code="${6:-}" reason="${7:-}" source="${8:-orchestrator}"
  local redacted
  redacted="$(specrelay::verification::redact "$command")"

  local fields
  fields="$(
    ROLE="$role" OP="$operation" CMD="$redacted" DUR="$duration" EXIT="$exit_code" REASON="$reason" SRC="$source" \
    python3 -c '
import json, os
d = {
    "role": os.environ["ROLE"],
    "operation": os.environ["OP"],
    "command": os.environ["CMD"],
    "source": os.environ["SRC"],
}
dur = os.environ.get("DUR", "")
if dur:
    try:
        d["duration_seconds"] = float(dur)
    except ValueError:
        pass
ec = os.environ.get("EXIT", "")
if ec:
    try:
        d["exit_code"] = int(ec)
    except ValueError:
        pass
reason = os.environ.get("REASON", "")
if reason:
    d["reason"] = reason
print(json.dumps(d))
' 2>/dev/null
  )"
  [ -n "$fields" ] || fields='{}'
  specrelay::timeline::event "$task_dir" verification "$fields"
}

# specrelay::verification::extract_from_events <task-dir> <role> <events-jsonl-file>
# Best-effort, STRUCTURAL verification-ledger extraction from a captured
# Claude semantic event transcript (spec 0019, "Verification Operation
# Classification"): scans the transcript for `Bash` tool_use commands (the
# same JSONL already captured for live rendering — see
# py/render_agent_events.py) and records each as a classified verification
# event. Durations are intentionally NOT fabricated: the transcript does not
# reliably pair a command's start/finish, so duration_seconds is left unset
# (honest "not available") rather than guessed — spec 0019, "Metrics Must Be
# Honest". A missing transcript (e.g. the fake provider, or a run that used
# the generic streaming fallback) is a silent no-op.
specrelay::verification::extract_from_events() {
  local task_dir="$1" role="$2" events_file="$3"
  [ -f "$events_file" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local cmd
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    specrelay::verification::record "$task_dir" "$role" "$cmd" "" "" "" "claude-events"
  done < <(python3 -c '
import json, sys

path = sys.argv[1]
try:
    f = open(path)
except OSError:
    sys.exit(0)
with f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get("type") != "assistant":
            continue
        message = ev.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            if block.get("name") != "Bash":
                continue
            inp = block.get("input") or {}
            command = inp.get("command")
            if isinstance(command, str) and command.strip():
                print(command.replace("\n", " ").replace("\r", " "))
' "$events_file" 2>/dev/null)
}

# --- executor/reviewer default policy accessors (spec 0019, "Verification
# Policy Configuration") — thin, named wrappers over
# specrelay::config::verification_policy so callers never grep the raw
# key=value blob themselves.

specrelay::verification::_policy_field() {
  local root="$1" field="$2" blob
  blob="$(specrelay::config::verification_policy "$root" 2>/dev/null)" || return 1
  printf '%s\n' "$blob" | sed -n "s/^${field}=//p"
}

specrelay::verification::executor_limit() {
  specrelay::verification::_policy_field "$1" "executor_$2"
}

specrelay::verification::reviewer_limit() {
  specrelay::verification::_policy_field "$1" "reviewer_$2"
}

specrelay::verification::reviewer_default_mode() {
  specrelay::verification::_policy_field "$1" "reviewer_default_mode"
}
