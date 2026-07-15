#!/usr/bin/env bash
# coordinator.sh — the AI Coordinator advisory decision role (spec 0025, "AI
# Coordinator and Decision Contract").
#
# Central design rule (spec section 4), enforced structurally by this file:
#
#   The coordinator decides what should be attempted next.
#   The deterministic engine decides whether that action is allowed and
#   performs it.
#
# Every function below either (a) computes something deterministically in
# bash/python with NO provider call (allowed-actions, validation, artifact
# recording, reporting), or (b) makes exactly ONE bounded, read-only provider
# call per attempt through the SAME restricted adapter shape as
# providers/provider.sh's reviewer_recover_marker (spec section 18: "a
# read-only adapter and accepting only the structured decision output").
#
# specrelay::coordinator::_dispatch is the ONLY place a coordinator decision
# can lead to a repository mutation, and even there it never mutates
# anything itself — it calls the SAME pre-existing transitions.sh functions
# every other caller uses (specrelay::transitions::block), which independently
# re-validate the current state before doing anything (spec section 16, "An
# invalid coordinator response must not mutate task state"; section 17,
# "coordinator authority boundaries"). Every other decision value is either a
# read-only report (REQUEST_HUMAN_DECISION writes an evidence file describing
# what a human should do; NO_ACTION does nothing) or an explicitly DEFERRED
# recommendation (spec section 8: "This specification does not yet implement
# unrestricted automatic artifact repair or a fully autonomous multi-round
# workflow") that is durably recorded for a human or a future specification to
# act on, never silently executed.

SPECRELAY_COORDINATOR_LIB_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/coordinator_lib.py"

specrelay::coordinator::_available() {
  command -v python3 >/dev/null 2>&1 && [ -f "$SPECRELAY_COORDINATOR_LIB_PY" ]
}

specrelay::coordinator::_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# --- role policy accessors (spec sections 19-20) ----------------------------

specrelay::coordinator::enabled() {
  local v
  v="$(specrelay::config::coordinator_policy "$1" 2>/dev/null | sed -n 's/^enabled=//p')"
  printf '%s\n' "${v:-false}"
}

specrelay::coordinator::required() {
  local v
  v="$(specrelay::config::coordinator_policy "$1" 2>/dev/null | sed -n 's/^required=//p')"
  printf '%s\n' "${v:-false}"
}

specrelay::coordinator::max_decision_attempts() {
  local v
  v="$(specrelay::config::coordinator_policy "$1" 2>/dev/null | sed -n 's/^max_decision_attempts=//p')"
  printf '%s\n' "${v:-2}"
}

specrelay::coordinator::timeout_seconds() {
  local v
  v="$(specrelay::config::coordinator_policy "$1" 2>/dev/null | sed -n 's/^timeout_seconds=//p')"
  printf '%s\n' "${v:-300}"
}

specrelay::coordinator::confidence_threshold() {
  local v
  v="$(specrelay::config::coordinator_policy "$1" 2>/dev/null | sed -n 's/^confidence_threshold=//p')"
  printf '%s\n' "${v:-none}"
}

# Live (unresolved-context) provider/model/agent — mirrors
# workflow.sh's role_provider/role_model/role_agent, but coordinator has its
# own defaults (provider: claude, agent: ai-coordinator) and is not one of
# workflow.sh's hardcoded executor/reviewer role arms.
specrelay::coordinator::_live_provider() {
  specrelay::config::get "$1" "roles.coordinator.provider" "claude"
}

specrelay::coordinator::_live_model() {
  local root="$1" selection provider resolved
  if ! selection="$(specrelay::config::role_model_selection "$root" coordinator 2>/dev/null)"; then
    printf 'provider-default\n'
    return 0
  fi
  provider="$(specrelay::coordinator::_live_provider "$root")"
  if resolved="$(specrelay::capability::resolve_selection "$provider" "$selection" 2>/dev/null)"; then
    printf '%s\n' "$resolved"
  else
    specrelay::capability::selection_value "$selection"
  fi
}

specrelay::coordinator::_live_agent() {
  specrelay::config::get "$1" "roles.coordinator.agent" "ai-coordinator"
}

# specrelay::coordinator::effective_provider|model|agent <root> <task-id>
# Durable-first resolution (spec section 35, "Effective configuration
# capture"): the task's captured roles_effective.coordinator.* value once
# present, otherwise the live resolved config. Reuses
# specrelay::workflow::captured_role, which is generic over the role name.
specrelay::coordinator::effective_provider() {
  local root="$1" task_id="$2" v
  if v="$(specrelay::workflow::captured_role "$root" "$task_id" coordinator provider)"; then
    printf '%s\n' "$v"; return 0
  fi
  specrelay::coordinator::_live_provider "$root"
}
specrelay::coordinator::effective_model() {
  local root="$1" task_id="$2" v
  if v="$(specrelay::workflow::captured_role "$root" "$task_id" coordinator model)"; then
    printf '%s\n' "$v"; return 0
  fi
  specrelay::coordinator::_live_model "$root"
}
specrelay::coordinator::effective_agent() {
  local root="$1" task_id="$2" v
  if v="$(specrelay::workflow::captured_role "$root" "$task_id" coordinator agent)"; then
    printf '%s\n' "$v"; return 0
  fi
  specrelay::coordinator::_live_agent "$root"
}

# specrelay::coordinator::_record_effective_config <root> <task-id> <provider> <model> <agent>
# CAPTURE-ONCE (spec section 35), merged into the SAME roles_effective blob
# executor/reviewer already use — never clobbers their entries, and is never
# overwritten once present (a later project-config change never silently
# switches a running task's coordinator identity).
specrelay::coordinator::_record_effective_config() {
  local root="$1" task_id="$2" provider="$3" model="$4" agent="$5" task_dir state_file existing set_json
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"
  [ -f "$state_file" ] || return 0

  if specrelay::workflow::captured_role "$root" "$task_id" coordinator provider >/dev/null 2>&1; then
    return 0
  fi

  existing="$(specrelay::state::get "$state_file" roles_effective 2>/dev/null || true)"
  [ "$existing" = "null" ] && existing=""
  set_json="$(printf '%s' "$existing" | PROVIDER="$provider" MODEL="$model" AGENT="$agent" python3 -c '
import json, os, sys
raw = sys.stdin.read().strip()
try:
    data = json.loads(raw) if raw else {}
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
data["coordinator"] = {"provider": os.environ["PROVIDER"], "model": os.environ["MODEL"], "agent": os.environ["AGENT"]}
print(json.dumps({"roles_effective": data}))
')"
  [ -n "$set_json" ] || return 0
  specrelay::state::set "$state_file" "$set_json" >/dev/null
}

# --- allowed-actions / validation (spec sections 15-16) ---------------------

# specrelay::coordinator::allowed_actions <invocation-point> <situation-json>
# Prints {"allowed_next_actions": [...], "forbidden_next_actions": [...]}.
specrelay::coordinator::allowed_actions() {
  local invocation_point="$1" situation_json="${2:-{\}}"
  printf '%s' "$situation_json" | python3 "$SPECRELAY_COORDINATOR_LIB_PY" allowed-actions "$invocation_point"
}

# specrelay::coordinator::validate <raw-output-file> <task-id> <invocation-point> <allowed-actions-json>
# Prints {"valid": bool, "errors": [...], "decision": {...}|null}. Exit 0 when
# valid, 1 otherwise (mirrors config.sh's ok/bad convention).
specrelay::coordinator::validate() {
  local raw_file="$1" task_id="$2" invocation_point="$3" allowed_json="$4"
  python3 "$SPECRELAY_COORDINATOR_LIB_PY" validate "$raw_file" "$task_id" "$invocation_point" "$allowed_json"
}

specrelay::coordinator::engine_action_description() {
  python3 "$SPECRELAY_COORDINATOR_LIB_PY" engine-action "$1"
}

# --- durable artifacts (spec sections 23-26) --------------------------------

specrelay::coordinator::decisions_path() {
  printf '%s/23-coordinator-decisions.jsonl\n' "$1"
}

specrelay::coordinator::state_artifact_path() {
  printf '%s/23-coordinator-state.json\n' "$1"
}

specrelay::coordinator::human_packet_path() {
  printf '%s/24-human-decision-request.md\n' "$1"
}

# specrelay::coordinator::_state_field <task-dir> <field> [default]
specrelay::coordinator::_state_field() {
  local task_dir="$1" field="$2" default="${3:-}" path v
  path="$(specrelay::coordinator::state_artifact_path "$task_dir")"
  v="$(python3 "$SPECRELAY_COORDINATOR_LIB_PY" state-get "$path" "$field" 2>/dev/null)"
  printf '%s\n' "${v:-$default}"
}

# specrelay::coordinator::record_decision <task-dir> <record-json>
# Appends ONE line to 23-coordinator-decisions.jsonl. Never overwrites
# earlier decisions (spec section 23, "Do not overwrite earlier decisions").
specrelay::coordinator::record_decision() {
  local task_dir="$1" record_json="$2" path
  path="$(specrelay::coordinator::decisions_path "$task_dir")"
  python3 "$SPECRELAY_COORDINATOR_LIB_PY" record "$path" "$record_json"
}

# specrelay::coordinator::_bump_state <task-dir> <task-id> <invocation-point>
#     <valid-decision-or-empty> <attempts> <invalid-count> <human-requested(0|1)>
# Updates the compact 23-coordinator-state.json (spec section 24). Canonical
# workflow state remains in state.json — this artifact is informational only.
specrelay::coordinator::_bump_state() {
  local task_dir="$1" task_id="$2" invocation_point="$3" valid_decision="$4" \
    attempts="$5" invalid_count="$6" human_requested="$7"
  local path prev_invocations prev_attempts prev_invalid prev_repair prev_human
  path="$(specrelay::coordinator::state_artifact_path "$task_dir")"

  prev_invocations="$(specrelay::coordinator::_state_field "$task_dir" invocations 0)"
  prev_attempts="$(specrelay::coordinator::_state_field "$task_dir" decision_attempts 0)"
  prev_invalid="$(specrelay::coordinator::_state_field "$task_dir" invalid_decisions 0)"
  prev_repair="$(specrelay::coordinator::_state_field "$task_dir" repair_recommendations 0)"
  prev_human="$(specrelay::coordinator::_state_field "$task_dir" human_decision_requests 0)"

  local next_repair="$prev_repair" next_human="$prev_human"
  [ "$valid_decision" = "REPAIR_ARTIFACTS" ] && next_repair=$((prev_repair + 1))
  [ "$human_requested" = "1" ] && next_human=$((prev_human + 1))

  local fields_json
  fields_json="$(
    TASK_ID="$task_id" INV_POINT="$invocation_point" LAST_DECISION="$valid_decision" \
    INVOCATIONS=$((prev_invocations + 1)) ATTEMPTS=$((prev_attempts + attempts)) \
    INVALID=$((prev_invalid + invalid_count)) REPAIR="$next_repair" HUMAN="$next_human" \
    UPDATED_AT="$(specrelay::coordinator::_now)" python3 -c '
import json, os
d = {
    "schema_version": 1,
    "task_id": os.environ["TASK_ID"],
    "last_invocation_point": os.environ["INV_POINT"],
    "last_valid_decision": os.environ["LAST_DECISION"] or None,
    "invocations": int(os.environ["INVOCATIONS"]),
    "decision_attempts": int(os.environ["ATTEMPTS"]),
    "invalid_decisions": int(os.environ["INVALID"]),
    "repair_recommendations": int(os.environ["REPAIR"]),
    "human_decision_requests": int(os.environ["HUMAN"]),
    "updated_at": os.environ["UPDATED_AT"],
}
print(json.dumps(d))
'
  )"
  python3 "$SPECRELAY_COORDINATOR_LIB_PY" state-write "$path" "$fields_json"
}

# specrelay::coordinator::_write_human_packet <root> <task-id> <decision> <reason>
specrelay::coordinator::_write_human_packet() {
  local root="$1" task_id="$2" decision="$3" reason="$4" task_dir state_file ctx_json out_path
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"
  out_path="$(specrelay::coordinator::human_packet_path "$task_dir")"

  ctx_json="$(
    TASK_ID="$task_id" STATE="$(specrelay::state::canonical "$state_file" 2>/dev/null || true)" \
    DECISION="$decision" REASON="$reason" python3 -c '
import json, os
print(json.dumps({
    "task_id": os.environ["TASK_ID"],
    "state": os.environ.get("STATE", "unknown"),
    "what_happened": "The AI coordinator (or the deterministic fallback policy) recommended stopping automatic progress for this task.",
    "why_stopped": os.environ["REASON"],
    "recommendation_decision": os.environ["DECISION"],
    "recommendation_reason": os.environ["REASON"],
    "human_choices": [
        {"choice": "specrelay task accept <task-ref>", "effect": "accept the current review result and proceed to human final review"},
        {"choice": "specrelay task request-changes <task-ref>", "effect": "send the task back to the Executor with feedback"},
        {"choice": "specrelay task block <task-ref> <reason>", "effect": "stop the task explicitly, recording why"},
        {"choice": "specrelay task requeue <task-ref>", "effect": "resume execution from CHANGES_REQUESTED"},
    ],
    "evidence_paths": [
        "23-coordinator-decisions.jsonl",
        "23-coordinator-state.json",
    ],
}))
'
  )"
  printf '%s' "$ctx_json" | python3 "$SPECRELAY_COORDINATOR_LIB_PY" human-packet "$out_path"
}

# --- dispatch: the ONLY code path that may enact a coordinator decision ----

# specrelay::coordinator::dispatch <root> <task-id> <decision> <reason>
# Prints the deterministic engine-action description (spec section 31).
# BLOCK_TASK and REQUEST_HUMAN_DECISION are the only decisions ENACTED here,
# and only through pre-existing, independently-guarded engine code
# (transitions.sh / the human-packet writer); every other decision is
# recorded as a deferred recommendation (spec section 8).
specrelay::coordinator::dispatch() {
  local root="$1" task_id="$2" decision="$3" reason="$4" task_dir state_file current desc
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"
  desc="$(specrelay::coordinator::engine_action_description "$decision")"

  case "$decision" in
    BLOCK_TASK)
      current="$(specrelay::state::canonical "$state_file" 2>/dev/null || true)"
      if [ "$current" = "EXECUTOR_RUNNING" ] && specrelay::transitions::block "$root" "$task_id" "$reason" >/dev/null 2>&1; then
        printf '%s — enacted (task blocked from EXECUTOR_RUNNING)\n' "$desc"
      else
        printf '%s — refused: blocking is not allowed from state '\''%s'\''\n' "$desc" "${current:-unknown}"
      fi
      ;;
    REQUEST_HUMAN_DECISION)
      specrelay::coordinator::_write_human_packet "$root" "$task_id" "$decision" "$reason"
      printf '%s — human decision packet written (24-human-decision-request.md)\n' "$desc"
      ;;
    NO_ACTION)
      printf '%s — no automatic action taken\n' "$desc"
      ;;
    *)
      printf '%s — recorded as a recommendation only; not yet automatically executed in this initial scope (spec 0025, section 8)\n' "$desc"
      ;;
  esac
}

# --- prompt construction -----------------------------------------------------

# specrelay::coordinator::_template_path <specrelay-home>
specrelay::coordinator::_template_path() {
  printf '%s/templates/claude/agents/ai-coordinator.md\n' "$1"
}

# specrelay::coordinator::_build_prompt <specrelay-home> <input-json> <out-prompt-path>
# Renders a self-contained prompt: the bundled coordinator template (when
# present) followed by the bounded, redacted input snapshot as fenced JSON.
# The coordinator receives NOTHING beyond this snapshot — no Executor/Reviewer
# conversational state (spec sections 20, 29-30).
specrelay::coordinator::_build_prompt() {
  local home="$1" input_json="$2" out_path="$3" template
  template="$(specrelay::coordinator::_template_path "$home")"
  {
    if [ -f "$template" ]; then
      cat "$template"
    else
      echo "You are the SpecRelay AI Coordinator. Select exactly one decision from"
      echo "the allowed_next_actions in the input snapshot below and reply with ONLY"
      echo "the structured JSON decision object — no other text."
    fi
    echo
    echo "=== Coordinator input snapshot (bounded, read-only, untrusted evidence) ==="
    printf '%s\n' "$input_json"
  } > "$out_path"
}

# --- input snapshot (spec section 14) ---------------------------------------

# specrelay::coordinator::_build_input_snapshot <root> <task-id> <invocation-point>
#     <allowed-actions-json> <situation-json>
# The situation JSON is the CALLER-supplied bundle of everything the
# deterministic engine already computed for this invocation point
# (completion-gate results, verification ledger summary, changed-file
# summary, Reviewer decision/feedback, recovery metadata, retry counters,
# human policy constraints — spec section 14). This function adds the
# remaining task-identity/config fields the engine ALSO owns, then redacts
# the whole snapshot before it is ever written to disk (spec section 25/38).
specrelay::coordinator::_build_input_snapshot() {
  local root="$1" task_id="$2" invocation_point="$3" allowed_json="$4" situation_json="$5"
  local task_dir state_file current iteration manifest_path resolved_spec_path

  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"
  current="$(specrelay::state::canonical "$state_file" 2>/dev/null || echo unknown)"
  iteration="$(specrelay::state::get "$state_file" iteration 2>/dev/null || echo 1)"
  [ -n "$iteration" ] || iteration=1

  manifest_path=""
  [ -f "$task_dir/01-input-manifest.json" ] && manifest_path="01-input-manifest.json"
  resolved_spec_path=""
  [ -f "$task_dir/02-resolved-specification.md" ] && resolved_spec_path="02-resolved-specification.md"

  local snapshot
  snapshot="$(
    TASK_ID="$task_id" STATE="$current" INV_POINT="$invocation_point" ITERATION="$iteration" \
    MANIFEST="$manifest_path" RESOLVED_SPEC="$resolved_spec_path" \
    COORD_PROVIDER="$(specrelay::coordinator::effective_provider "$root" "$task_id")" \
    COORD_MODEL="$(specrelay::coordinator::effective_model "$root" "$task_id")" \
    COORD_AGENT="$(specrelay::coordinator::effective_agent "$root" "$task_id")" \
    ALLOWED="$allowed_json" SITUATION="$situation_json" python3 -c '
import json, os
allowed = json.loads(os.environ["ALLOWED"])
situation = json.loads(os.environ["SITUATION"]) if os.environ["SITUATION"] else {}
doc = {
    "task_id": os.environ["TASK_ID"],
    "current_state": os.environ["STATE"],
    "invocation_point": os.environ["INV_POINT"],
    "iteration": os.environ["ITERATION"],
    "effective_role_configuration": {
        "coordinator": {
            "provider": os.environ["COORD_PROVIDER"],
            "model": os.environ["COORD_MODEL"],
            "agent": os.environ["COORD_AGENT"],
        }
    },
    "resolved_specification_path": os.environ["RESOLVED_SPEC"] or None,
    "immutable_input_manifest_path": os.environ["MANIFEST"] or None,
    "allowed_next_actions": allowed.get("allowed_next_actions", []),
    "forbidden_next_actions": allowed.get("forbidden_next_actions", []),
    "situation": situation,
}
print(json.dumps(doc, indent=2, sort_keys=True))
'
  )"
  printf '%s' "$snapshot" | python3 "$SPECRELAY_COORDINATOR_LIB_PY" redact-snapshot
}

# --- the one entrypoint: a full, bounded coordinator round ------------------

# specrelay::coordinator::invoke <specrelay-home> <root> <task-id>
#     <invocation-point> <situation-json> [<fake-scenario>]
# Runs ONE full coordinator round: allowed-actions -> input snapshot -> prompt
# -> bounded provider retry loop -> validation -> durable recording -> safe
# dispatch. Exit codes: 0 = a decision was validated and dispatched (or a
# safe fallback was dispatched after exhausting retries — coordinator FAILURE
# is always a safe, recorded outcome, never a caller-visible error, per spec
# section 27); 10 = coordinator disabled (existing deterministic behavior
# continues unchanged, spec section 32).
specrelay::coordinator::invoke() {
  local home="$1" root="$2" task_id="$3" invocation_point="$4" situation_json="${5:-{\}}" scenario="${6:-valid_request_human}"
  local task_dir state_file
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"

  if [ "$(specrelay::coordinator::enabled "$root")" != "true" ]; then
    echo "coordinator: disabled (roles.coordinator.enabled is not true) — existing deterministic workflow behavior is unchanged"
    return 10
  fi

  if ! specrelay::coordinator::_available; then
    specrelay::out::err "coordinator: python3 or coordinator_lib.py unavailable; treating as a coordinator failure (safe fallback)"
    specrelay::coordinator::dispatch "$root" "$task_id" REQUEST_HUMAN_DECISION \
      "coordinator runtime unavailable (python3 or coordinator_lib.py missing)"
    return 0
  fi

  local provider model agent max_attempts
  provider="$(specrelay::coordinator::effective_provider "$root" "$task_id")"
  model="$(specrelay::coordinator::effective_model "$root" "$task_id")"
  agent="$(specrelay::coordinator::effective_agent "$root" "$task_id")"
  max_attempts="$(specrelay::coordinator::max_decision_attempts "$root")"
  [ -n "$max_attempts" ] && [ "$max_attempts" -gt 0 ] 2>/dev/null || max_attempts=2

  specrelay::coordinator::_record_effective_config "$root" "$task_id" "$provider" "$model" "$agent"

  local allowed_json
  allowed_json="$(specrelay::coordinator::allowed_actions "$invocation_point" "$situation_json")"

  local inv_num inv_dir
  inv_num=$(( $(specrelay::coordinator::_state_field "$task_dir" invocations 0) + 1 ))
  inv_dir="$task_dir/23-coordinator/invocation-$(printf '%03d' "$inv_num")"
  mkdir -p "$inv_dir"

  local input_json
  input_json="$(specrelay::coordinator::_build_input_snapshot "$root" "$task_id" "$invocation_point" "$allowed_json" "$situation_json")"
  printf '%s\n' "$input_json" > "$inv_dir/input.json"
  specrelay::coordinator::_build_prompt "$home" "$input_json" "$inv_dir/prompt.md"

  local start_ts attempt=0 valid=0 raw_file="" validation_json="" invalid_count=0 provider_failed=0
  start_ts="$(date -u +%s)"

  while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$((attempt + 1))
    raw_file="$inv_dir/raw-output-$attempt.txt"
    : > "$raw_file"
    if ! specrelay::provider::coordinator_run "$provider" "$root" "$task_dir" "$inv_dir/prompt.md" "$raw_file" \
        "$task_id" "$invocation_point" "$model" "$agent" "$scenario"; then
      provider_failed=1
      validation_json='{"valid": false, "errors": ["coordinator provider invocation failed or timed out"], "decision": null}'
      break
    fi
    validation_json="$(specrelay::coordinator::validate "$raw_file" "$task_id" "$invocation_point" "$allowed_json")"
    if printf '%s' "$validation_json" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("valid") else 1)'; then
      valid=1
      break
    fi
    invalid_count=$((invalid_count + 1))
  done

  cp "$raw_file" "$inv_dir/raw-output.txt" 2>/dev/null || true
  printf '%s\n' "$validation_json" > "$inv_dir/validation.json"

  local end_ts duration decision_value reason_text validation_outcome refusal_reason engine_action human_flag
  end_ts="$(date -u +%s)"
  duration=$((end_ts - start_ts))
  human_flag=0

  if [ "$valid" = "1" ]; then
    decision_value="$(printf '%s' "$validation_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["decision"]["decision"])')"
    reason_text="$(printf '%s' "$validation_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["decision"]["reason"])')"
    printf '%s' "$validation_json" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["decision"], indent=2, sort_keys=True))' > "$inv_dir/decision.json"
    validation_outcome="valid"
    refusal_reason="null"
  else
    # Safe deterministic fallback (spec section 27): a coordinator that fails
    # or exhausts its retries never blocks silently and never mutates state —
    # it degrades to the documented fallback policy.
    decision_value="REQUEST_HUMAN_DECISION"
    if [ "$provider_failed" = "1" ]; then
      reason_text="coordinator provider invocation failed or timed out after $attempt attempt(s); falling back to a human decision request"
    else
      reason_text="coordinator produced no valid decision after $attempt attempt(s) (see validation.json); falling back to a human decision request"
    fi
    validation_outcome="invalid"
    refusal_reason="$(printf '%s' "$validation_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps("; ".join(d.get("errors", []))))')"
  fi

  [ "$decision_value" = "REQUEST_HUMAN_DECISION" ] && human_flag=1

  engine_action="$(specrelay::coordinator::dispatch "$root" "$task_id" "$decision_value" "$reason_text")"

  local record_json
  record_json="$(
    TS="$(specrelay::coordinator::_now)" TASK_ID="$task_id" INV_NUM="$inv_num" INV_POINT="$invocation_point" \
    INPUT_REF="23-coordinator/invocation-$(printf '%03d' "$inv_num")/input.json" \
    PROVIDER="$provider" MODEL="$model" AGENT="$agent" \
    RAW_REF="23-coordinator/invocation-$(printf '%03d' "$inv_num")/raw-output.txt" \
    VALIDATION_OUTCOME="$validation_outcome" ENGINE_ACTION="$engine_action" \
    REFUSAL_REASON="$refusal_reason" DURATION="$duration" ATTEMPTS="$attempt" \
    DECISION_JSON="$(printf '%s' "$validation_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("decision")))' 2>/dev/null || echo null)" \
    python3 -c '
import json, os
refusal = json.loads(os.environ["REFUSAL_REASON"]) if os.environ["REFUSAL_REASON"] not in ("", "null") else None
record = {
    "timestamp": os.environ["TS"],
    "task_id": os.environ["TASK_ID"],
    "invocation_number": int(os.environ["INV_NUM"]),
    "invocation_point": os.environ["INV_POINT"],
    "input_snapshot_ref": os.environ["INPUT_REF"],
    "provider": os.environ["PROVIDER"],
    "model": os.environ["MODEL"],
    "agent": os.environ["AGENT"],
    "raw_decision_result_path": os.environ["RAW_REF"],
    "validated_decision": json.loads(os.environ["DECISION_JSON"]),
    "validation_outcome": os.environ["VALIDATION_OUTCOME"],
    "engine_action": os.environ["ENGINE_ACTION"],
    "refusal_reason": refusal if os.environ["VALIDATION_OUTCOME"] != "valid" else None,
    "duration_seconds": int(os.environ["DURATION"]),
    "attempts": int(os.environ["ATTEMPTS"]),
    "usage_metadata": None,
}
print(json.dumps(record, sort_keys=True))
'
  )"
  specrelay::coordinator::record_decision "$task_dir" "$record_json"
  specrelay::coordinator::_bump_state "$task_dir" "$task_id" "$invocation_point" \
    "$([ "$valid" = "1" ] && printf '%s' "$decision_value" || printf '')" "$attempt" "$invalid_count" "$human_flag"

  echo "Coordinator decision: $decision_value (validation: $validation_outcome)"
  echo "Engine action: $engine_action"
  echo "Decision record: $(specrelay::coordinator::decisions_path "$task_dir")"
  return 0
}

# --- read-only reporting (spec sections 33, 36) -----------------------------

# specrelay::coordinator::report_text <task-dir>
# Human-readable summary for `task show`/`task report`. Honest "not
# recorded" for a task that never ran the coordinator (spec section 32,
# "Missing coordinator artifacts in historical tasks must be reported as: not
# recorded").
specrelay::coordinator::report_text() {
  local task_dir="$1" state_path
  state_path="$(specrelay::coordinator::state_artifact_path "$task_dir")"
  if [ ! -f "$state_path" ]; then
    echo "Coordinator: not recorded"
    return 0
  fi
  local last_point last_decision invocations invalid repairs human_reqs updated_at
  last_point="$(specrelay::coordinator::_state_field "$task_dir" last_invocation_point "(none)")"
  last_decision="$(specrelay::coordinator::_state_field "$task_dir" last_valid_decision "(none)")"
  invocations="$(specrelay::coordinator::_state_field "$task_dir" invocations 0)"
  invalid="$(specrelay::coordinator::_state_field "$task_dir" invalid_decisions 0)"
  repairs="$(specrelay::coordinator::_state_field "$task_dir" repair_recommendations 0)"
  human_reqs="$(specrelay::coordinator::_state_field "$task_dir" human_decision_requests 0)"
  updated_at="$(specrelay::coordinator::_state_field "$task_dir" updated_at "(unknown)")"

  echo "Coordinator: recorded"
  echo "Coordinator last invocation point: $last_point"
  echo "Coordinator last validated decision: ${last_decision:-(none)}"
  echo "Coordinator invocations: $invocations"
  echo "Coordinator invalid decisions: $invalid"
  echo "Coordinator repair recommendations: $repairs"
  echo "Coordinator human-decision requests: $human_reqs"
  echo "Coordinator last updated: $updated_at"
  echo "Coordinator decision log: $(specrelay::coordinator::decisions_path "$task_dir")"
}

# specrelay::coordinator::report_json <task-dir>
specrelay::coordinator::report_json() {
  local task_dir="$1" state_path
  state_path="$(specrelay::coordinator::state_artifact_path "$task_dir")"
  if [ ! -f "$state_path" ]; then
    printf '{"recorded": false}\n'
    return 0
  fi
  python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
data["recorded"] = True
print(json.dumps(data, sort_keys=True))
' "$state_path"
}
