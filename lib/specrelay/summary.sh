#!/usr/bin/env bash
# summary.sh — the default, concise "operator summary" final terminal output
# (spec 0022, section 7 "Summary-first terminal output"). Replaces the
# automatic full timeline/command-timing/agent-efficiency dump that used to
# print at the end of every run; those stay fully available via
# 'specrelay task report|timeline|commands|efficiency' and --verbose.

SPECRELAY_SUMMARY_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/summary_lib.py"

# specrelay::summary::_color_for_state <state>
specrelay::summary::_color_for_state() {
  case "$1" in
    READY_FOR_HUMAN_REVIEW) printf 'green\n' ;;
    BLOCKED) printf 'red\n' ;;
    CHANGES_REQUESTED) printf 'yellow\n' ;;
    *) printf 'yellow\n' ;;
  esac
}

# specrelay::summary::render <root> <task-dir> <task-id> <final-state>
# Always prints the concise summary card + (if any) collapsed warnings +
# a "Details" hint pointing at the full report command. Never mutates task
# state; reads only the already-persisted 20-execution-timeline.json and
# state.json (rendered earlier in the SAME finalize step).
specrelay::summary::render() {
  local root="$1" task_dir="$2" task_id="$3" final_state="$4"
  command -v python3 >/dev/null 2>&1 && [ -f "$SPECRELAY_SUMMARY_PY" ] || return 0

  local context_required=0
  case "$(specrelay::config::get "$root" "context.required" "false" 2>/dev/null)" in
    true|1) context_required=1 ;;
  esac

  local blob
  blob="$(python3 "$SPECRELAY_SUMMARY_PY" build "$task_dir" "$task_id" "$context_required" 2>/dev/null)"
  [ -n "$blob" ] || return 0

  local color
  color="$(specrelay::summary::_color_for_state "$final_state")"

  local body=()
  while IFS= read -r line; do
    body+=("$line")
  done < <(BLOB="$blob" TASK_ID="$task_id" STATE="$final_state" python3 -c '
import json, os
d = json.loads(os.environ["BLOB"])

def role_field(role):
    if role is None:
        return "not run"
    dur = role.get("duration_seconds")
    dur_str = "not recorded" if dur is None else ("%ds" % int(dur) if dur < 60 else "%dm %ds" % (int(dur) // 60, int(dur) % 60))
    return "%s . %s" % (role.get("status", "unknown"), dur_str)

lines = []
lines.append(os.environ["STATE"].replace("_", " "))
lines.append("%-12s%s" % ("Task", os.environ["TASK_ID"]))
lines.append("%-12s%s" % ("Executor", role_field(d.get("executor"))))
lines.append("%-12s%s" % ("Reviewer", role_field(d.get("reviewer"))))
lines.append("%-12s%s" % ("Tests", d.get("tests", "not recorded")))
lines.append("%-12s%s" % ("Context", d.get("context", "not required")))
lines.append("%-12s%s" % ("Active time", d.get("active_time", "not recorded")))
lines.append("%-12s%d" % ("Warnings", d.get("warning_count", 0)))
for line in lines:
    print(line)
')
  specrelay::out::card "$color" "SpecRelay Result" "${body[@]}"

  local warning_count
  warning_count="$(printf '%s' "$blob" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("warning_count",0))' 2>/dev/null)"
  if [ "${warning_count:-0}" -gt 0 ] 2>/dev/null; then
    echo
    echo "Warnings"
    printf '%s' "$blob" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for line in d.get("warning_lines", []):
    print("  ⚠ %s" % line)
'
  fi

  echo
  echo "Details"
  echo "  specrelay task report $task_id"
  return 0
}
