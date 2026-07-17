#!/usr/bin/env bash
# finalization.sh — engine-owned executor finalization and supervised
# verification (spec 0029, "Engine-Owned Executor Finalization and
# Supervised Verification"). Owns the explicit finalization PHASE pipeline
# (section 10) that runs after the provider returns: evidence capture,
# required verification, summary finalization, completion validation, and
# their durable record (30-executor-finalization.json). Deterministic record
# generation and text rendering live in py/finalization_lib.py; process/
# session supervision lives in py/proc_supervisor.py (via provider.sh);
# lease/liveness lives in lock.sh; provenance/ownership derivation lives in
# git_guard.sh. This file coordinates those, but implements NONE of their
# internals itself (spec 0029, section 10.5 — module boundaries).

SPECRELAY_FINALIZATION_LIB_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/finalization_lib.py"

specrelay::finalization::_available() {
  command -v python3 >/dev/null 2>&1 && [ -f "$SPECRELAY_FINALIZATION_LIB_PY" ]
}

specrelay::finalization::_py() {
  python3 "$SPECRELAY_FINALIZATION_LIB_PY" "$@"
}

# --- configuration (spec 0029, section 25) ----------------------------------

specrelay::finalization::mode() {
  specrelay::config::get "$1" "executor_finalization.mode" "enabled"
}

specrelay::finalization::verification_placement() {
  specrelay::config::get "$1" "executor_finalization.verification_placement" "executor"
}

specrelay::finalization::finalizer_provider() {
  local root="$1" v
  v="$(specrelay::config::get "$root" "executor_finalization.finalizer.provider" "")"
  if [ -z "$v" ]; then
    specrelay::workflow::role_provider "$root" executor
  else
    printf '%s\n' "$v"
  fi
}

specrelay::finalization::finalizer_model() {
  specrelay::config::get "$1" "executor_finalization.finalizer.model" "provider-default"
}

specrelay::finalization::finalizer_agent() {
  specrelay::config::get "$1" "executor_finalization.finalizer.agent" "none"
}

specrelay::finalization::finalizer_timeout() {
  local v
  v="$(specrelay::config::get "$1" "executor_finalization.finalizer.timeout_seconds" "300")"
  case "$v" in ''|*[!0-9]*) v=300 ;; esac
  printf '%s\n' "$v"
}

specrelay::finalization::child_grace() {
  local v
  v="$(specrelay::config::get "$1" "executor_finalization.supervision.child_terminate_grace_seconds" "10")"
  case "$v" in ''|*[!0-9]*) v=10 ;; esac
  printf '%s\n' "$v"
}

specrelay::finalization::require_operator_confirmation_for_unproven_diff() {
  specrelay::config::get "$1" "executor_finalization.recovery.require_operator_confirmation_for_unproven_diff" "true"
}

specrelay::finalization::reviewer_independence() {
  specrelay::config::get "$1" "verification.reviewer_independence" "reuse_when_fresh"
}

# --- record lifecycle --------------------------------------------------------

specrelay::finalization::init() {
  local task_dir="$1" task_id="$2" iteration="$3" mode="$4"
  specrelay::finalization::_available || return 0
  specrelay::finalization::_py init "$task_dir" "$task_id" "$iteration" "$mode" >/dev/null
}

specrelay::finalization::record_provider_execution() {
  local task_dir="$1" iteration="$2" invocation_id="$3" prompt_file="$4" exit_code="$5" pg_terminated="${6:-false}"
  specrelay::finalization::_available || return 0
  specrelay::finalization::_py record-provider-execution "$task_dir" "$iteration" "$invocation_id" "$prompt_file" "$exit_code" "$pg_terminated" >/dev/null
}

# specrelay::finalization::resume_decision <task-dir> <iteration> <prompt-file>
# Prints "rerun:<reason>" or "finalization-only" (spec 0029, section 11.2/11.3).
specrelay::finalization::resume_decision() {
  local task_dir="$1" iteration="$2" prompt_file="$3"
  specrelay::finalization::_available || { printf 'rerun:no-terminal-result\n'; return 0; }
  specrelay::finalization::_py resume-decision "$task_dir" "$iteration" "$prompt_file"
}

specrelay::finalization::set_phase() {
  local task_dir="$1" phase="$2" result="$3" reason="${4:-}" extra="${5:-}"
  specrelay::finalization::_available || return 0
  specrelay::finalization::_py set-phase "$task_dir" "$phase" "$result" "$reason" "$extra" >/dev/null
}

specrelay::finalization::phase_result() {
  local task_dir="$1" phase="$2"
  specrelay::finalization::_available || { printf 'pending\n'; return 0; }
  specrelay::finalization::_py get-phase-result "$task_dir" "$phase"
}

specrelay::finalization::set_outcome() {
  specrelay::finalization::_available || return 0
  specrelay::finalization::_py set-outcome "$1" "$2" >/dev/null
}

specrelay::finalization::set_background() {
  specrelay::finalization::_available || return 0
  specrelay::finalization::_py set-background "$1" "$2" "$3" "$4" "$5" >/dev/null
}

specrelay::finalization::set_provenance() {
  specrelay::finalization::_available || return 0
  specrelay::finalization::_py set-provenance "$1" "${2:-}" "${3:-}" "${4:-}" >/dev/null
}

# specrelay::finalization::show_json <task-dir>
# READ-ONLY: the raw 30-executor-finalization.json verbatim, or
# {"recorded": false} for a historical task predating spec 0029 (never
# fabricated — section 28.2).
specrelay::finalization::show_json() {
  local task_dir="$1" path
  path="$task_dir/30-executor-finalization.json"
  if [ -f "$path" ]; then
    cat "$path"
  else
    printf '{"recorded": false}\n'
  fi
}

specrelay::finalization::render_card() {
  specrelay::finalization::_available || { printf 'Finalization: not recorded (python3 unavailable)\n'; return 0; }
  specrelay::finalization::_py render-card "$1"
}

# --- degraded-legacy guard (spec 0029, section 26) --------------------------

# specrelay::finalization::degraded_refusal <project-root> <task-id> <mode>
# Prints "" (allowed) or a refusal MESSAGE (degraded-legacy requested for a
# task with required verification/UI — must never silently bypass).
specrelay::finalization::degraded_refusal() {
  local root="$1" task_id="$2" mode="$3" task_dir required_verification required_ui out
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  [ "$mode" = "degraded-legacy" ] || return 0

  required_verification=false
  if specrelay::verification_runner::_available; then
    local changed_json plan_json selected_count
    changed_json="$(specrelay::verification_policy::changed_paths "$root" 2>/dev/null)"
    [ -n "$changed_json" ] || changed_json='[]'
    plan_json="$(specrelay::verification_policy::plan "$root" executor "" "$changed_json" "" --json 2>/dev/null)"
    if [ -n "$plan_json" ]; then
      selected_count="$(printf '%s' "$plan_json" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(len(d.get("selected_checks") or []))
except Exception:
    print(0)' 2>/dev/null)"
      [ "${selected_count:-0}" -gt 0 ] 2>/dev/null && required_verification=true
    fi
  fi
  required_ui="$(specrelay::ui_verification::required "$root" "$task_id" 2>/dev/null || echo false)"

  out="$(specrelay::finalization::_py degraded-check "$mode" "$required_verification" "$required_ui" 2>/dev/null)"
  case "$out" in
    ok|"") return 0 ;;
    refused:*) printf '%s\n' "${out#refused: }"; return 1 ;;
    *) return 0 ;;
  esac
}

# --- phase: executor_evidence_capture (spec 0029, sections 12, 23.2) -------

# specrelay::finalization::run_evidence_capture <root> <task-dir> <invocation-id>
# Captures git evidence (unchanged behavior), THEN records this round's
# proven-owned paths into the append-only ledger BEFORE the completion gate
# runs (section 23.2 — this is what makes a gate-failed round's diff already
# task-owned), THEN (re)generates 03-executor-log.md from observed durable
# sources when the Executor did not write one.
specrelay::finalization::run_evidence_capture() {
  local root="$1" task_dir="$2" invocation_id="$3" exit_code="${4:-}"
  specrelay::evidence::capture "$root" "$task_dir"
  specrelay::git_guard::record_round_change "$root" "$task_dir" "$invocation_id"
  specrelay::git_guard::derive_owned_from_ledger "$root" "$task_dir"

  local log_source="executor-written"
  if [ ! -s "$task_dir/03-executor-log.md" ]; then
    log_source="engine-generated"
  fi
  if specrelay::finalization::_available; then
    specrelay::finalization::_py generate-log "$task_dir" "$exit_code" \
      "$task_dir/12-executor-stdout.txt" "$task_dir/05-changed-files.txt" \
      "$task_dir/21-command-timing-events.jsonl" "see 07-tests.txt / 27-verification-summary.json" >/dev/null
  fi
  specrelay::finalization::set_provenance "$task_dir" "$log_source" "" ""
  specrelay::finalization::set_phase "$task_dir" executor_evidence_capture passed "" \
    "$(printf '{"log_source": "%s"}' "$log_source")"
}

# --- phase: executor_verification (spec 0029, sections 13, 14, 15, 16) ------

# specrelay::finalization::run_verification <root> <task-id> <task-dir>
#     <iteration>
# Runs required verification (spec 0026 multi-service engine + spec 0028 UI
# runner) as the AUTHORITATIVE placement's supervised, synchronously-waited
# execution, reusing a fresh prior result when digests match (section 14),
# then generates 07-tests.txt from the real evidence (section 16). Prints
# the finalization_outcome to use on failure ("" on success/NOT_REQUIRED).
specrelay::finalization::run_verification() {
  local root="$1" task_id="$2" task_dir="$3" iteration="$4"
  local placement diff_digest cfg_digest fresh overall="NOT_REQUIRED" ui_overall="" reused=false rc=0

  placement="$(specrelay::finalization::verification_placement "$root")"
  diff_digest=""
  [ -f "$task_dir/06-git-diff.patch" ] && diff_digest="$(specrelay::finalization::_py digest-file "$task_dir/06-git-diff.patch" 2>/dev/null)"
  cfg_digest=""
  [ -f "$task_dir/verification/effective-config.json" ] && cfg_digest="$(specrelay::finalization::_py digest-file "$task_dir/verification/effective-config.json" 2>/dev/null)"

  if [ "$placement" != "executor" ]; then
    specrelay::finalization::set_phase "$task_dir" executor_verification passed "" \
      "$(printf '{"overall_status": "NOT_REQUIRED", "authoritative_placement": "%s", "reused": false}' "$placement")"
    printf ''
    return 0
  fi

  fresh="$(specrelay::finalization::_py verification-fresh "$task_dir" "$cfg_digest" "$diff_digest" "" 2>/dev/null || echo false)"

  if [ "$fresh" = "true" ] && [ -f "$task_dir/27-verification-summary.json" ]; then
    overall="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("overall_status","UNKNOWN"))
except Exception:
    print("UNKNOWN")' "$task_dir/27-verification-summary.json" 2>/dev/null)"
    reused=true
  elif specrelay::verification_runner::_available; then
    local changed_json
    changed_json="$(specrelay::verification_policy::changed_paths "$root" 2>/dev/null || printf '[]')"
    # Suppress the human-readable report text run's own stdout would print:
    # this function's ENTIRE stdout is captured via command substitution by
    # the caller as the finalization_outcome token, so any incidental report
    # text here would corrupt that token. The structured
    # 27-verification-summary.json / 28-verification-summary.md it writes
    # are read directly below instead — nothing is lost.
    if specrelay::verification_runner::run "$root" "$task_dir" "$task_id" "$iteration" executor "" "$changed_json" >/dev/null; then
      rc=0
    else
      rc=$?
    fi
    if [ -f "$task_dir/27-verification-summary.json" ]; then
      overall="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("overall_status","UNKNOWN"))
except Exception:
    print("UNKNOWN")' "$task_dir/27-verification-summary.json" 2>/dev/null)"
    else
      overall="NOT_RECORDED"
    fi
    diff_digest="$(specrelay::finalization::_py digest-file "$task_dir/06-git-diff.patch" 2>/dev/null)"
    cfg_digest=""
    [ -f "$task_dir/verification/effective-config.json" ] && cfg_digest="$(specrelay::finalization::_py digest-file "$task_dir/verification/effective-config.json" 2>/dev/null)"
    specrelay::finalization::_py record-verification-digests "$task_dir" "$cfg_digest" "$diff_digest" "" >/dev/null
  else
    overall="NOT_REQUIRED"
  fi

  # UI runtime verification (spec 0028, integrated at completion validation —
  # spec 0029 section 15): required whenever UI-impact is detected/enabled.
  local ui_required
  ui_required="$(specrelay::ui_verification::required "$root" "$task_id" 2>/dev/null || echo false)"
  if [ "$ui_required" = "true" ]; then
    specrelay::ui_verification::run "$root" "$task_id" --json >/dev/null 2>&1 || true
    if [ -f "$task_dir/29-ui-verification/summary.json" ]; then
      ui_overall="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("overall_status","UNKNOWN"))
except Exception:
    print("UNKNOWN")' "$task_dir/29-ui-verification/summary.json" 2>/dev/null)"
    else
      ui_overall="MISSING"
    fi
  fi

  local phase_result="passed" outcome=""
  case "$overall" in
    PASSED|NOT_REQUIRED) : ;;
    FAILED) phase_result="failed"; outcome="VERIFICATION_FAILED" ;;
    BLOCKED) phase_result="failed"; outcome="VERIFICATION_BLOCKED" ;;
    *) phase_result="failed"; outcome="VERIFICATION_BLOCKED" ;;
  esac
  if [ -z "$outcome" ] && [ "$ui_required" = "true" ]; then
    case "$ui_overall" in
      PASS|"") : ;;
      FAIL) phase_result="failed"; outcome="VERIFICATION_FAILED" ;;
      *) phase_result="failed"; outcome="VERIFICATION_BLOCKED" ;;
    esac
  fi

  specrelay::finalization::set_phase "$task_dir" executor_verification "$phase_result" "$outcome" \
    "$(python3 -c 'import json,sys
print(json.dumps({
    "overall_status": sys.argv[1],
    "ui_status": sys.argv[2] or None,
    "reused": sys.argv[3] == "true",
    "authoritative_placement": "executor",
    "diff_digest": sys.argv[4],
    "effective_config_digest": sys.argv[5],
}))' "$overall" "$ui_overall" "$reused" "$diff_digest" "$cfg_digest")"

  specrelay::finalization::_py generate-tests "$task_dir" \
    "$([ -f "$task_dir/27-verification-summary.json" ] && printf '%s' "$task_dir/27-verification-summary.json")" \
    "$([ -f "$task_dir/29-ui-verification/summary.json" ] && printf '%s' "$task_dir/29-ui-verification/summary.json")" \
    "$([ -f "$task_dir/26-verification-plan.json" ] && printf '%s' "$task_dir/26-verification-plan.json")" >/dev/null
  specrelay::finalization::set_provenance "$task_dir" "" "engine-generated" ""

  printf '%s\n' "$outcome"
  [ -z "$outcome" ]
}

# --- phase: executor_summary_finalization (spec 0029, section 17) ----------

# specrelay::finalization::_run_with_timeout <timeout-seconds> -- cmd...
# A portable (no external `timeout` binary required) bounded wait: runs cmd
# in the background and polls for completion, killing it if the deadline
# passes. Returns 124 on timeout, else cmd's real exit code.
specrelay::finalization::_run_with_timeout() {
  local timeout_s="$1"; shift
  [ "${1:-}" = "--" ] && shift
  ( "$@" ) &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge "$timeout_s" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
  done
  wait "$pid"
}

# specrelay::finalization::finalize_summary <root> <task-id> <task-dir>
# Ensures 08-executor-summary.md exists and is structurally valid (section
# 17): validates the Executor-written summary first; only when it is
# missing/invalid does the sandboxed finalizer run, in an isolated temp
# directory OUTSIDE the repository, with READ-ONLY evidence copies and no
# repo cwd. Prints "" (adopted/already-valid) or a FINALIZATION_FAILED
# reason on failure.
specrelay::finalization::finalize_summary() {
  local root="$1" task_id="$2" task_dir="$3" bundle_present
  bundle_present=false
  [ -f "$task_dir/01-input-manifest.json" ] && bundle_present=true

  local verdict
  verdict="$(specrelay::finalization::_py validate-summary "$task_dir/08-executor-summary.md" "$bundle_present" 2>/dev/null)"
  if [ "$verdict" = "valid" ]; then
    specrelay::finalization::set_phase "$task_dir" executor_summary_finalization passed "" '{"source": "executor"}'
    specrelay::finalization::set_provenance "$task_dir" "" "" "executor"
    printf ''
    return 0
  fi

  # NOTE: this whole function's stdout is captured via command substitution
  # by the caller (the returned string IS the finalization_outcome/error
  # token) — every diagnostic/progress message below MUST go through
  # specrelay::out::err (stderr) or specrelay::out::log 1>&2, never plain
  # stdout, or it would corrupt that token (this bit the section-13
  # verification phase above too; fixed the same way there).
  specrelay::out::log "[executor-finalizer] 08-executor-summary.md ${verdict#invalid: }; invoking the sandboxed finalizer" 1>&2

  local sandbox provider model agent timeout_s pre_repo pre_task post_repo post_task
  sandbox="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-finalizer.XXXXXX")"
  provider="$(specrelay::finalization::finalizer_provider "$root")"
  model="$(specrelay::finalization::finalizer_model "$root")"
  agent="$(specrelay::finalization::finalizer_agent "$root")"
  timeout_s="$(specrelay::finalization::finalizer_timeout "$root")"

  local f
  for f in 03-executor-log.md 07-tests.txt 04-git-status.txt 05-changed-files.txt \
           05-git-diff-stat.txt 06-git-diff.patch 02-executor-prompt.md \
           27-verification-summary.json; do
    [ -f "$task_dir/$f" ] && { cp "$task_dir/$f" "$sandbox/$f"; chmod 444 "$sandbox/$f" 2>/dev/null || true; }
  done
  if [ -f "$task_dir/29-ui-verification/summary.json" ]; then
    mkdir -p "$sandbox/29-ui-verification"
    cp "$task_dir/29-ui-verification/summary.json" "$sandbox/29-ui-verification/summary.json"
    chmod 444 "$sandbox/29-ui-verification/summary.json" 2>/dev/null || true
  fi

  {
    echo "You are the SpecRelay executor-summary finalizer (spec 0029, section 17)."
    echo "Write a candidate 08-executor-summary.md to candidate-08-executor-summary.md,"
    echo "in THIS directory only. You have no repository access and must not attempt any."
    echo "Base it strictly on the evidence files in this sandbox (read-only copies)."
    echo "Required sections: ## Finalization Pipeline, ## Supervised Verification,"
    echo "## Evidence Provenance, ## Interrupted-Round Recovery, ## Backward Compatibility"
    [ "$bundle_present" = "true" ] && echo "## Input Coverage"
  } > "$sandbox/prompt.md"

  pre_repo="$(cd "$root" && git status --porcelain --untracked-files=all 2>/dev/null | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
  pre_task="$(specrelay::finalization::_py tree-fingerprint "$task_dir" 2>/dev/null)"

  local rc
  specrelay::finalization::_run_with_timeout "$timeout_s" -- \
    specrelay::provider::executor_finalize_summary "$provider" "$sandbox" "$sandbox/candidate-08-executor-summary.md" "$model" "$agent"
  rc=$?

  if [ "$rc" -eq 124 ]; then
    rm -rf "$sandbox"
    specrelay::finalization::set_phase "$task_dir" executor_summary_finalization failed FINALIZATION_FAILED '{}'
    printf 'FINALIZATION_FAILED: sandboxed finalizer timed out after %ss\n' "$timeout_s"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    rm -rf "$sandbox"
    specrelay::finalization::set_phase "$task_dir" executor_summary_finalization failed FINALIZATION_FAILED '{}'
    printf 'FINALIZATION_FAILED: sandboxed finalizer exited %s\n' "$rc"
    return 1
  fi

  post_repo="$(cd "$root" && git status --porcelain --untracked-files=all 2>/dev/null | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
  post_task="$(specrelay::finalization::_py tree-fingerprint "$task_dir" 2>/dev/null)"

  if [ "$pre_repo" != "$post_repo" ]; then
    local offending
    offending="$(cd "$root" && git status --porcelain --untracked-files=all 2>/dev/null)"
    rm -rf "$sandbox"
    specrelay::finalization::set_phase "$task_dir" executor_summary_finalization failed FINALIZATION_FAILED \
      '{"rejected_reason": "finalizer modified repository paths outside its sandbox"}'
    specrelay::out::err "[executor-finalizer] rejected: repository changed during the sandboxed call:"
    printf '%s\n' "$offending" | sed 's/^/  /' >&2
    printf 'FINALIZATION_FAILED: finalizer modified repository paths outside its sandbox\n'
    return 1
  fi
  if [ "$pre_task" != "$post_task" ]; then
    rm -rf "$sandbox"
    specrelay::finalization::set_phase "$task_dir" executor_summary_finalization failed FINALIZATION_FAILED \
      '{"rejected_reason": "finalizer modified task-directory paths outside its sandbox"}'
    printf 'FINALIZATION_FAILED: finalizer modified task-directory paths outside its sandbox\n'
    return 1
  fi

  local candidate="$sandbox/candidate-08-executor-summary.md" candidate_verdict
  candidate_verdict="$(specrelay::finalization::_py validate-summary "$candidate" "$bundle_present" 2>/dev/null)"
  if [ "$candidate_verdict" != "valid" ]; then
    rm -rf "$sandbox"
    specrelay::finalization::set_phase "$task_dir" executor_summary_finalization failed FINALIZATION_FAILED \
      "$(python3 -c 'import json,sys; print(json.dumps({"rejected_reason": sys.argv[1]}))' "$candidate_verdict")"
    printf 'FINALIZATION_FAILED: %s\n' "$candidate_verdict"
    return 1
  fi

  cp "$candidate" "$task_dir/08-executor-summary.md"
  {
    echo ""
    echo "## Engine-Observed Verification"
    if [ -f "$task_dir/27-verification-summary.json" ]; then
      python3 -c 'import json
d = json.load(open("'"$task_dir"'/27-verification-summary.json"))
print("- Multi-service verification overall status: " + str(d.get("overall_status")))'
    else
      echo "- Multi-service verification: not recorded"
    fi
    if [ -f "$task_dir/29-ui-verification/summary.json" ]; then
      python3 -c 'import json
d = json.load(open("'"$task_dir"'/29-ui-verification/summary.json"))
print("- UI runtime verification overall: " + str(d.get("overall_status")))'
    fi
  } >> "$task_dir/08-executor-summary.md"

  rm -rf "$sandbox"
  specrelay::finalization::set_phase "$task_dir" executor_summary_finalization passed "" '{"source": "finalizer"}'
  specrelay::finalization::set_provenance "$task_dir" "" "" "finalizer"
  printf ''
  return 0
}

# --- phase: executor_completion_validation (spec 0029, sections 19, 24) ----

# specrelay::finalization::completion_validation <root> <task-id> <task-dir>
# The strict Completion Gate over all durable inputs, plus the no-background-
# wait rule (section 19: process/durable state authoritative, text heuristics
# advisory only). Prints "" on pass, or "<OUTCOME>: <reason>" on failure.
# NEVER weakens the pre-0029 spec 0021/0023 checks — it re-runs them exactly,
# then adds the additional finalization-phase checks.
# <unresolved-wait-policy> is the caller's already-resolved (durable-first)
# execution_efficiency_effective.executor.unresolved_wait_is_failure value
# ("true"/"false") — spec 0021's pre-existing policy, unchanged by spec 0029
# and passed in rather than re-resolved here, so this module never silently
# re-reads possibly-drifted live config (module boundaries, section 10.5).
specrelay::finalization::completion_validation() {
  local root="$1" task_id="$2" task_dir="$3" unresolved_wait_policy="${4:-true}" f gate_reason=""

  for f in 03-executor-log.md 07-tests.txt 08-executor-summary.md; do
    if [ ! -s "$task_dir/$f" ]; then
      gate_reason="required Executor artifact '$f' is missing or empty"
      break
    fi
  done

  if [ -z "$gate_reason" ] && [ -f "$task_dir/01-input-manifest.json" ]; then
    if ! grep -Eqi '^#+[[:space:]]*Input Coverage' "$task_dir/08-executor-summary.md" 2>/dev/null; then
      gate_reason="08-executor-summary.md does not record an Input Coverage section (spec 0023, section 21.2)"
    fi
  fi

  # Multi-service + UI verification must both have reached a terminal,
  # non-pending result (section 15.2, 19.1.1).
  if [ -z "$gate_reason" ]; then
    local ver_result ver_outcome
    ver_result="$(specrelay::finalization::phase_result "$task_dir" executor_verification)"
    if [ "$ver_result" = "failed" ]; then
      ver_outcome="$(specrelay::finalization::_py get "$task_dir" phases.executor_verification.reason 2>/dev/null)"
      gate_reason="required verification did not pass (${ver_outcome:-VERIFICATION_FAILED})"
    fi
  fi

  # Background/no-wait rule (spec 0029, section 19, AC-10 — this DELIBERATELY
  # supersedes spec 0021's pre-0029 "unresolved_wait_is_failure blocks on text
  # detection alone" behavior for this one axis; section 19.2's own worked
  # example, test D, is exactly this shape: the AI's final text says it is
  # waiting, but no engine-owned job is actually pending and no provider-
  # spawned child survived — the engine records the warning and does NOT
  # block, because process ownership and durable verification state are
  # authoritative and text heuristics may only ever ADD a warning, never be
  # the sole reason to refuse). <unresolved_wait_policy> is still honored as
  # the switch for whether the warning itself is recorded at all — set to
  # "false" it is fully inert, matching its pre-0029 documented meaning.
  local text_wait="none"
  if [ -z "$gate_reason" ]; then
    if [ "$unresolved_wait_policy" = "true" ]; then
      text_wait="$(specrelay::agent_efficiency::detect_unresolved_wait "$task_dir/12-executor-stdout.txt")"
    fi
    specrelay::finalization::set_background "$task_dir" 0 0 "$([ "$text_wait" = "detected" ] && echo true || echo false)" "$(specrelay::finalization::_supervision_mode)"
  fi

  if [ -n "$gate_reason" ]; then
    printf 'COMPLETION_CONTRACT_FAILED: %s\n' "$gate_reason"
    return 1
  fi
  printf ''
  return 0
}

specrelay::finalization::_supervision_mode() {
  if specrelay::provider::supervision_available; then
    printf 'process-group\n'
  else
    printf 'degraded-foreground\n'
  fi
}
