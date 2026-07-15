#!/usr/bin/env bash
# verification_policy.sh — configuration, changed-path discovery, planning,
# and read-only reporting for the verification-policy ENGINE (spec 0026,
# "Configurable Verification Policy and Multi-Service Execution"). Thin bash
# wrapper around py/verification_policy_lib.py, mirroring command_timing.sh's
# and coordinator.sh's relationship to their own python modules.
#
# Execution (actually running configured checks) lives in
# verification_runner.sh, kept separate so a read-only inspection command
# (doctor, `verification plan`, `task show`/`report`) can never accidentally
# execute a configured command — only verification_runner.sh's ::run ever
# shells out to project-configured commands.
#
# NOT to be confused with lib/specrelay/verification.sh (spec 0019's bounded
# verification-operation LEDGER + classifier) — that module is unrelated and
# unchanged by this one; both happen to use the word "verification" for
# distinct, older and newer, specs.

SPECRELAY_VERIFICATION_POLICY_LIB_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/verification_policy_lib.py"

specrelay::verification_policy::_available() {
  command -v python3 >/dev/null 2>&1 && [ -f "$SPECRELAY_VERIFICATION_POLICY_LIB_PY" ]
}

# specrelay::verification_policy::_raw_config <root>
# Prints the raw (unvalidated) JSON blob {"legacy_full_test_command":...,
# "verification":...} that config.sh's Ruby YAML loader extracted.
specrelay::verification_policy::_raw_config() {
  specrelay::config::verification_engine_raw "$1"
}

# specrelay::verification_policy::changed_paths <root> [<from-ref>]
# Prints a JSON array of repository-relative changed paths: the working tree
# vs. <from-ref> (default: HEAD), PLUS any untracked new files, PLUS both the
# old and new path of a rename (spec section 15.4, "deleted and renamed files
# ... participate in matching using both old and new paths"). Never fails the
# caller when this is not a git repository or git is unavailable — prints an
# empty array, which safely resolves to the configured changed_fallback.
specrelay::verification_policy::changed_paths() {
  local root="$1" from_ref="${2:-HEAD}"
  if ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    printf '[]\n'
    return 0
  fi
  (
    cd "$root" 2>/dev/null || exit 0
    {
      git diff --name-status "$from_ref" -- 2>/dev/null
      git ls-files --others --exclude-standard 2>/dev/null | sed 's/^/A\t/'
    } | python3 -c '
import sys, json
paths = set()
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    status = parts[0]
    if status.startswith("R") or status.startswith("C"):
        if len(parts) >= 3:
            paths.add(parts[1])
            paths.add(parts[2])
    elif len(parts) >= 2:
        paths.add(parts[1])
print(json.dumps(sorted(paths)))
'
  )
}

# specrelay::verification_policy::mode <root>
# Prints "new" | "legacy" | "absent" | "invalid: <detail>" (plus any
# warning: lines) — never executes anything.
specrelay::verification_policy::mode() {
  local root="$1"
  specrelay::verification_policy::_available || { printf 'absent\n'; return 0; }
  RAW="$(specrelay::verification_policy::_raw_config "$root")" python3 -c '
import json, os
print(json.dumps({"raw_config": json.loads(os.environ["RAW"])}))
' | python3 "$SPECRELAY_VERIFICATION_POLICY_LIB_PY" mode
}

# specrelay::verification_policy::doctor_summary <root>
# Read-only structured JSON for doctor.sh (spec section 35).
specrelay::verification_policy::doctor_summary() {
  local root="$1"
  specrelay::verification_policy::_available || { printf '{"mode": "absent"}\n'; return 0; }
  RAW="$(specrelay::verification_policy::_raw_config "$root")" ROOT="$root" python3 -c '
import json, os
print(json.dumps({"raw_config": json.loads(os.environ["RAW"]), "root": os.environ["ROOT"]}))
' | python3 "$SPECRELAY_VERIFICATION_POLICY_LIB_PY" doctor-summary
}

# specrelay::verification_policy::plan <root> <phase> <requested-level>
#     <changed-paths-json> [<task-dir>] [--json]
# Read-only: computes (and, when <task-dir> is non-empty, WRITES)
# 26-verification-plan.json + verification/selection.json. Never executes a
# configured command (spec section 34, "perform no verification command
# execution").
specrelay::verification_policy::plan() {
  local root="$1" phase="$2" level="$3" changed_json="$4" task_dir="${5:-}"; shift 5 || true
  specrelay::verification_policy::_available || { specrelay::out::err "verification plan: python3 or verification_policy_lib.py unavailable"; return 1; }
  RAW="$(specrelay::verification_policy::_raw_config "$root")" \
  PHASE="$phase" LEVEL="$level" CHANGED="$changed_json" TASKDIR="$task_dir" python3 -c '
import json, os
level = os.environ["LEVEL"] or None
print(json.dumps({
    "raw_config": json.loads(os.environ["RAW"]),
    "phase": os.environ["PHASE"] or None,
    "requested_level": level,
    "changed_paths": json.loads(os.environ["CHANGED"] or "[]"),
    "task_dir": os.environ["TASKDIR"] or None,
}))
' | python3 "$SPECRELAY_VERIFICATION_POLICY_LIB_PY" plan "$@"
}

# specrelay::verification_policy::report <task-dir> [--json]
# Read-only: prints the existing 27-verification-summary.json (or an honest
# "not recorded" for a task that never ran the engine — spec section 40,
# "Historical tasks").
specrelay::verification_policy::report() {
  local task_dir="$1"; shift || true
  specrelay::verification_policy::_available || { printf 'Verification policy: not recorded\n'; return 0; }
  python3 "$SPECRELAY_VERIFICATION_POLICY_LIB_PY" report "$task_dir" "$@"
}

# specrelay::verification_policy::report_json <task-dir>
specrelay::verification_policy::report_json() {
  specrelay::verification_policy::report "$1" --json
}

# specrelay::verification_policy::prompt_block <root> <task-dir> <phase>
# Prints the Executor/Reviewer prompt section spec 0026 section 25/26
# requires: effective placement, selected level/services/checks,
# required/optional classification, evidence locations, and the no-silent-
# skip rule. A read-only PREVIEW only (never writes 26-verification-plan.json
# — that artifact is written only when the role actually runs
# 'specrelay verification run', so a preview computed here can never go
# stale relative to what the role later executes).
specrelay::verification_policy::prompt_block() {
  local root="$1" task_dir="$2" phase="$3" mode
  mode="$(specrelay::verification_policy::mode "$root" 2>/dev/null | head -n1)"

  echo "Verification-policy engine (spec 0026):"
  case "$mode" in
    new|legacy)
      local changed_json plan_json
      changed_json="$(specrelay::verification_policy::changed_paths "$root" 2>/dev/null)"
      [ -n "$changed_json" ] || changed_json='[]'
      plan_json="$(specrelay::verification_policy::plan "$root" "$phase" "" "$changed_json" "" --json 2>/dev/null)"
      if [ -n "$plan_json" ]; then
        printf '%s' "$plan_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("- Configuration mode: %s" % "'"$mode"'")
print("- Effective placement/level for this phase: %s" % d["effective_level"])
print("- Selected services: %s" % (", ".join(d["selected_services"]) or "(none)"))
print("- Selected checks: %s" % (", ".join(d["selected_checks"]) or "(none)"))
if d["fallback_reason"]:
    print("- Fallback/escalation: %s" % d["fallback_reason"])
if d["matched_risk_rules"]:
    print("- Matched risk rules: %s" % ", ".join(d["matched_risk_rules"]))
' 2>/dev/null
      fi
      echo "- Run it with: specrelay verification run --phase $phase [--level changed|full|flexible]"
      echo "- Evidence: 26-verification-plan.json, 27-verification-summary.json,"
      echo "  28-verification-summary.md, and verification/services/<service>/<check>/"
      echo "  {command.json,stdout.txt,stderr.txt,result.json} in this task's directory."
      ;;
    *)
      echo "- No verification-policy engine configuration is present for this project"
      echo "  (mode: ${mode:-absent}); the spec 0019 bounded-verification-policy budget"
      echo "  above still applies."
      ;;
  esac
  echo "- A required selected check must never be silently skipped: an unavailable"
  echo "  or failing required check is BLOCKED/FAILED, never reported as passed."
}
