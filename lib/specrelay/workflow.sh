#!/usr/bin/env bash
# workflow.sh — the SpecRelay orchestrator (spec sections 13, 39).
#
# This is the ONLY code that composes transitions + providers + context
# adapters + locking into the full lifecycle. It owns the runner-owned
# submit transition (mint -> submit -> cleanup) and the "specrelay run"
# iteration loop, mirroring the legacy run-executor.sh / run-reviewer.sh /
# run-workflow.sh / run-ai-loop.sh composition (see
# docs/current-workflow-contract.md) as SpecRelay's own engine code.

# --- project-policy accessors (never hardcoded — always read from config) --

specrelay::workflow::executor_provider() {
  specrelay::config::get "$1" "roles.executor.provider" "claude"
}

specrelay::workflow::reviewer_provider() {
  specrelay::config::get "$1" "roles.reviewer.provider" "manual"
}

# --- normalized role config: provider / model / agent (spec 0009) ----------
#
# Spec 0009 separates three concerns that used to be conflated in a single
# "provider" string:
#   provider = which adapter/CLI runs the role
#   model    = which model id the provider should use (opaque string), or the
#              sentinel "provider-default" (pass no explicit model flag)
#   agent    = which provider-specific agent/profile/subagent to use, or "none"
#
# The accessors below compute the EFFECTIVE, NORMALIZED value for a role,
# honoring this precedence (spec "Environment overrides"):
#   1. role-specific env override
#   2. .specrelay/config.yml
#   3. normalized legacy provider behavior (e.g. reviewer `claude-subagent`)
#   4. provider default
# They are the single source of truth for doctor reporting, runtime evidence
# metadata, and what the provider dispatch actually passes to the adapter.

# specrelay::workflow::_role_env <role> <MODEL|AGENT>
# Prints the role-specific env override variable NAME for a role/kind (empty
# for an unknown role, so a caller never dereferences a bogus name).
specrelay::workflow::_role_env() {
  local role="$1" kind="$2"
  case "$role" in
    executor) printf 'SPECRELAY_EXECUTOR_%s\n' "$kind" ;;
    reviewer) printf 'SPECRELAY_REVIEWER_%s\n' "$kind" ;;
    *) printf '\n' ;;
  esac
}

# specrelay::workflow::role_raw_provider <root> <role>
# The provider EXACTLY as configured (may be the legacy `claude-subagent`),
# used both for the default computation below and for the provider dispatch's
# own case arms (which still accept `claude-subagent` for backward compat).
specrelay::workflow::role_raw_provider() {
  local root="$1" role="$2"
  case "$role" in
    executor) specrelay::config::get "$root" "roles.executor.provider" "claude" ;;
    reviewer) specrelay::config::get "$root" "roles.reviewer.provider" "manual" ;;
  esac
}

# specrelay::workflow::role_provider <root> <role>
# The NORMALIZED provider: the legacy `claude-subagent` shorthand collapses to
# the real provider `claude` (its sub-agent selection is expressed via `agent`
# below), everything else passes through unchanged.
specrelay::workflow::role_provider() {
  local raw
  raw="$(specrelay::workflow::role_raw_provider "$1" "$2")"
  case "$raw" in
    claude-subagent) printf 'claude\n' ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

# specrelay::workflow::role_model_selection <root> <role>
# The effective CONFIGURED model selection, as a canonical selection string
# (provider-default | alias:<name> | id:<value> — see config.sh, spec 0014):
# role-specific env override first, else the configured model. An env override
# is a plain string and keeps the legacy string semantics: the literal
# provider-default sentinel, or a raw provider model id. Propagates the config
# parser's failure (non-zero, error detail on stdout) for a malformed
# structured model.
specrelay::workflow::role_model_selection() {
  local root="$1" role="$2" env_name env_val
  env_name="$(specrelay::workflow::_role_env "$role" MODEL)"
  if [ -n "$env_name" ]; then
    env_val="${!env_name:-}"
    if [ -n "$env_val" ]; then
      if [ "$env_val" = "provider-default" ]; then
        printf 'provider-default\n'
      else
        printf 'id:%s\n' "$env_val"
      fi
      return 0
    fi
  fi
  specrelay::config::role_model_selection "$root" "$role"
}

# specrelay::workflow::role_model <root> <role>
# Effective RESOLVED model: the configured selection resolved through the
# provider's capability adapter (spec 0014) — the provider-default sentinel
# stays as-is (adapters omit the model argument for it), an alias resolves to
# the adapter's deterministic argument, and a raw id passes through
# byte-for-byte. A selection that cannot be parsed or resolved falls back to a
# best-effort display of the configured value; assert_role_model_valid reports
# the real error before any provider execution.
specrelay::workflow::role_model() {
  local root="$1" role="$2" selection provider resolved
  if ! selection="$(specrelay::workflow::role_model_selection "$root" "$role" 2>/dev/null)"; then
    specrelay::config::get "$root" "roles.$role.model" "provider-default"
    return 0
  fi
  provider="$(specrelay::workflow::role_provider "$root" "$role")"
  if resolved="$(specrelay::capability::resolve_selection "$provider" "$selection" 2>/dev/null)"; then
    printf '%s\n' "$resolved"
  else
    specrelay::capability::selection_value "$selection"
  fi
}

# specrelay::workflow::role_agent <root> <role>
# Effective agent: role-specific env override, else configured agent, else the
# normalized-legacy default (reviewer + legacy `claude-subagent` -> ai-reviewer),
# else `none`.
specrelay::workflow::role_agent() {
  local root="$1" role="$2" env_name env_val cfg raw
  env_name="$(specrelay::workflow::_role_env "$role" AGENT)"
  if [ -n "$env_name" ]; then
    env_val="${!env_name:-}"
    if [ -n "$env_val" ]; then
      printf '%s\n' "$env_val"
      return 0
    fi
  fi
  cfg="$(specrelay::config::get "$root" "roles.$role.agent" "")"
  if [ -n "$cfg" ]; then
    printf '%s\n' "$cfg"
    return 0
  fi
  raw="$(specrelay::workflow::role_raw_provider "$root" "$role")"
  if [ "$role" = "reviewer" ] && [ "$raw" = "claude-subagent" ]; then
    printf 'ai-reviewer\n'
    return 0
  fi
  printf 'none\n'
}

# --- durable (captured) role configuration — spec 0012 resume determinism ---
#
# The accessors above (role_provider/role_model/role_agent) resolve the effective
# config from env + .specrelay/config.yml + normalization on EVERY call. That is
# correct at task creation, but a task that has already captured its effective
# role configuration must keep using THAT captured configuration for the rest of
# its life — resume must not silently re-resolve possibly-changed project config
# and switch a running task to a different model (spec 0012, "Resume Behavior").
# The captured_* / effective_* helpers below implement "captured is
# authoritative, live config is only the fallback for a task that has not
# captured yet".

# specrelay::workflow::captured_role <root> <task-id> <role> <field>
# Prints the durable roles_effective.<role>.<field> from the task's state.json
# when present and non-empty; returns non-zero (prints nothing) otherwise. This
# is the AUTHORITATIVE source for a task that has already captured its effective
# role configuration.
specrelay::workflow::captured_role() {
  local root="$1" task_id="$2" role="$3" field="$4" state_file blob
  state_file="$(specrelay::state::path "$(specrelay::task::dir "$root" "$task_id")")"
  [ -f "$state_file" ] || return 1
  blob="$(specrelay::state::get "$state_file" roles_effective 2>/dev/null || true)"
  [ -n "$blob" ] && [ "$blob" != "null" ] || return 1
  printf '%s' "$blob" | ROLE="$role" FIELD="$field" python3 -c '
import json, os, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)
role = data.get(os.environ["ROLE"])
if not isinstance(role, dict):
    sys.exit(1)
val = role.get(os.environ["FIELD"])
if val is None or val == "":
    sys.exit(1)
print(val)
'
}

# specrelay::workflow::effective_role_provider|model|agent <root> <task-id> <role>
# Durable-first resolution: the task's captured roles_effective value when it has
# already been captured, otherwise the freshly resolved value. Both the executor
# and reviewer iterations dispatch through these, so a resumed task deterministically
# reuses its captured provider/model/agent even if .specrelay/config.yml changed
# after the task was created (spec 0012).
specrelay::workflow::effective_role_provider() {
  local root="$1" task_id="$2" role="$3" v
  if v="$(specrelay::workflow::captured_role "$root" "$task_id" "$role" provider)"; then
    printf '%s\n' "$v"; return 0
  fi
  specrelay::workflow::role_provider "$root" "$role"
}
specrelay::workflow::effective_role_model() {
  local root="$1" task_id="$2" role="$3" v
  if v="$(specrelay::workflow::captured_role "$root" "$task_id" "$role" model)"; then
    printf '%s\n' "$v"; return 0
  fi
  specrelay::workflow::role_model "$root" "$role"
}
specrelay::workflow::effective_role_agent() {
  local root="$1" task_id="$2" role="$3" v
  if v="$(specrelay::workflow::captured_role "$root" "$task_id" "$role" agent)"; then
    printf '%s\n' "$v"; return 0
  fi
  specrelay::workflow::role_agent "$root" "$role"
}

# specrelay::workflow::captured_role_model_configured <root> <task-id> <role>
# Prints the durable CONFIGURED model selection captured for a role (as the
# canonical selection string, e.g. provider-default / alias:opus / id:<raw>)
# from roles_effective.<role>.model_configured. Returns non-zero (prints
# nothing) when the task predates spec 0014 and captured only the string model
# — old state files stay fully readable; this metadata is simply absent.
specrelay::workflow::captured_role_model_configured() {
  local root="$1" task_id="$2" role="$3" state_file blob
  state_file="$(specrelay::state::path "$(specrelay::task::dir "$root" "$task_id")")"
  [ -f "$state_file" ] || return 1
  blob="$(specrelay::state::get "$state_file" roles_effective 2>/dev/null || true)"
  [ -n "$blob" ] && [ "$blob" != "null" ] || return 1
  printf '%s' "$blob" | ROLE="$role" python3 -c '
import json, os, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)
role = data.get(os.environ["ROLE"])
if not isinstance(role, dict):
    sys.exit(1)
mc = role.get("model_configured")
if not isinstance(mc, dict):
    sys.exit(1)
kind = mc.get("kind")
value = mc.get("value")
if not kind:
    sys.exit(1)
if kind == "provider-default":
    print("provider-default")
else:
    print(f"{kind}:{value}")
'
}

# specrelay::workflow::assert_role_model_valid <root> <task-id> <role>
# Fails (non-zero, clear actionable error) when the role's CONFIGURED model is
# KNOWN-invalid (spec 0012 structural shape; spec 0014 provider-aware rules:
# unknown alias, unsupported explicit model, unknown id under exact
# discovery). Runs during task preflight BEFORE the role is claimed, so a
# known-invalid model never enters EXECUTOR_RUNNING / REVIEWER_RUNNING and the
# provider is never launched with it. A task that has already captured a model
# for the role is authoritative and was validated at capture time, so a later
# (possibly now-invalid) config change must NOT retroactively fail a
# deterministic resume — the captured value is skipped here.
specrelay::workflow::assert_role_model_valid() {
  local root="$1" task_id="$2" role="$3" selection provider
  if specrelay::workflow::captured_role "$root" "$task_id" "$role" model >/dev/null 2>&1; then
    return 0
  fi
  # 1. Structural shape of the configured model (string + structured forms).
  if ! specrelay::config::validate_role_model "$root" "$role"; then
    return 1
  fi
  # 2. Provider-aware validation of the EFFECTIVE selection (env included),
  #    through the provider's own capability adapter.
  if ! selection="$(specrelay::workflow::role_model_selection "$root" "$role")"; then
    specrelay::out::err "invalid model configuration for role $role: $selection"
    return 1
  fi
  provider="$(specrelay::workflow::role_provider "$root" "$role")"
  specrelay::capability::validate_selection "$provider" "$role" "$selection"
}

# specrelay::workflow::record_effective_roles <root> <task-id>
# Persists the effective, NORMALIZED role metadata (provider/model/agent for
# both roles) into the task's state.json under "roles_effective" (spec 0009,
# "Runtime evidence"). Based strictly on the normalized effective config above,
# never the raw legacy config. A missing state.json is a no-op (nothing to
# annotate yet).
#
# CAPTURE-ONCE (spec 0012, "Resume Behavior"): the effective role configuration
# is captured the FIRST time a task reaches an executor iteration and is
# AUTHORITATIVE thereafter. Once roles_effective is present it is NEVER
# overwritten here, so resuming a task after project configuration changed does
# not silently switch it to a different model — the durable value captured at
# creation remains the one used by every subsequent executor/reviewer step.
# specrelay::workflow::record_effective_verification_policy <root> <task-id>
# CAPTURE-ONCE (spec 0019, "Verification Policy Configuration" — "policy is
# captured durably for each task"), mirroring record_effective_roles above:
# persists the effective verification policy (executor/reviewer limits) into
# state.json under "verification_policy_effective" the first time a task
# reaches an executor iteration. Never overwritten thereafter, so a later
# project-config change never silently changes the budget an in-flight
# task's Reviewer is held to mid-review.
specrelay::workflow::record_effective_verification_policy() {
  local root="$1" task_id="$2" state_file existing blob
  state_file="$(specrelay::state::path "$(specrelay::task::dir "$root" "$task_id")")"
  [ -f "$state_file" ] || return 0

  existing="$(specrelay::state::get "$state_file" verification_policy_effective 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    return 0
  fi

  blob="$(specrelay::config::verification_policy "$root" 2>/dev/null)" || return 0
  local set_json
  set_json="$(printf '%s' "$blob" | python3 -c '
import json, sys
policy = {}
for line in sys.stdin:
    line = line.strip()
    if "=" not in line:
        continue
    k, v = line.split("=", 1)
    policy[k] = int(v) if v.isdigit() else v
print(json.dumps({"verification_policy_effective": policy}))
' 2>/dev/null)"
  [ -n "$set_json" ] || return 0
  specrelay::state::set "$state_file" "$set_json" >/dev/null
}

# specrelay::workflow::record_effective_execution_efficiency_policy <root> <task-id>
# CAPTURE-ONCE (spec 0021, "Durable Effective Policy" — "resume must use the
# captured policy rather than silently adopting later config changes"),
# mirroring record_effective_verification_policy above: persists the
# resolved execution-efficiency policy into state.json under
# "execution_efficiency_effective" the first time a task reaches an executor
# iteration. Never overwritten thereafter.
specrelay::workflow::record_effective_execution_efficiency_policy() {
  local root="$1" task_id="$2" state_file existing blob
  state_file="$(specrelay::state::path "$(specrelay::task::dir "$root" "$task_id")")"
  [ -f "$state_file" ] || return 0

  existing="$(specrelay::state::get "$state_file" execution_efficiency_effective 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    return 0
  fi

  blob="$(specrelay::config::execution_efficiency_policy "$root" 2>/dev/null)" || return 0
  local set_json
  set_json="$(printf '%s' "$blob" | python3 -c '
import json, sys
flat = {}
for line in sys.stdin:
    line = line.strip()
    if "=" not in line:
        continue
    k, v = line.split("=", 1)
    if v in ("true", "false"):
        flat[k] = (v == "true")
    elif v.isdigit():
        flat[k] = int(v)
    else:
        flat[k] = v

def role_block(prefix):
    return {
        "exploration_warning_calls": flat.get(prefix + "_exploration_warning_calls"),
        "repeated_verification_limit": flat.get(prefix + "_repeated_verification_limit"),
        "unresolved_wait_is_failure": flat.get(prefix + "_unresolved_wait_is_failure"),
        "require_artifacts_before_success": flat.get(prefix + "_require_artifacts_before_success"),
    }

policy = {
    "enabled": flat.get("enabled", True),
    "executor": role_block("executor"),
    "reviewer": role_block("reviewer"),
}
print(json.dumps({"execution_efficiency_effective": policy}))
' 2>/dev/null)"
  [ -n "$set_json" ] || return 0
  specrelay::state::set "$state_file" "$set_json" >/dev/null
}

# specrelay::workflow::effective_execution_efficiency_field <root> <task-id> <role> <field>
# Durable-first resolution (spec 0021, "resume uses the captured policy"):
# the task's captured execution_efficiency_effective value when present,
# otherwise the live resolved config. <role> may also be the bare string
# "enabled" for the top-level policy switch.
specrelay::workflow::effective_execution_efficiency_field() {
  local root="$1" task_id="$2" role="$3" field="$4" state_file blob v
  state_file="$(specrelay::state::path "$(specrelay::task::dir "$root" "$task_id")")"
  if [ -f "$state_file" ]; then
    blob="$(specrelay::state::get "$state_file" execution_efficiency_effective 2>/dev/null || true)"
    if [ -n "$blob" ] && [ "$blob" != "null" ]; then
      if [ "$role" = "enabled" ]; then
        v="$(printf '%s' "$blob" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
val = d.get("enabled")
if val is None:
    sys.exit(1)
print("true" if val else "false")
' 2>/dev/null)"
      else
        v="$(printf '%s' "$blob" | ROLE="$role" FIELD="$field" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
role = d.get(os.environ["ROLE"])
if not isinstance(role, dict):
    sys.exit(1)
val = role.get(os.environ["FIELD"])
if val is None:
    sys.exit(1)
print("true" if val is True else ("false" if val is False else val))
' 2>/dev/null)"
      fi
      if [ -n "$v" ]; then
        printf '%s\n' "$v"
        return 0
      fi
    fi
  fi
  if [ "$role" = "enabled" ]; then
    specrelay::agent_efficiency::enabled "$root"
  else
    specrelay::agent_efficiency::_policy_field "$root" "${role}_${field}"
  fi
}

specrelay::workflow::record_effective_roles() {
  local root="$1" task_id="$2" state_file existing
  state_file="$(specrelay::state::path "$(specrelay::task::dir "$root" "$task_id")")"
  [ -f "$state_file" ] || return 0

  existing="$(specrelay::state::get "$state_file" roles_effective 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    return 0
  fi

  # The captured "model" is the RESOLVED value (what the provider invocation
  # receives; the provider-default sentinel stays distinguishable from a known
  # exact model). "model_configured" additionally preserves the user's
  # configured selection — kind (provider-default | alias | id) and value —
  # so an alias is never silently re-resolved differently after task creation
  # and diagnostics can show configured vs resolved (spec 0014, "Task State").
  local exec_sel rev_sel
  exec_sel="$(specrelay::workflow::_role_selection_for_capture "$root" executor)"
  rev_sel="$(specrelay::workflow::_role_selection_for_capture "$root" reviewer)"

  local set_json
  set_json="$(
    EP="$(specrelay::workflow::role_provider "$root" executor)" \
    EM="$(specrelay::workflow::role_model "$root" executor)" \
    EA="$(specrelay::workflow::role_agent "$root" executor)" \
    EK="$(specrelay::capability::selection_kind "$exec_sel")" \
    EV="$(specrelay::capability::selection_value "$exec_sel")" \
    RP="$(specrelay::workflow::role_provider "$root" reviewer)" \
    RM="$(specrelay::workflow::role_model "$root" reviewer)" \
    RA="$(specrelay::workflow::role_agent "$root" reviewer)" \
    RK="$(specrelay::capability::selection_kind "$rev_sel")" \
    RV="$(specrelay::capability::selection_value "$rev_sel")" \
    python3 -c '
import json, os
print(json.dumps({"roles_effective": {
    "executor": {"provider": os.environ["EP"], "model": os.environ["EM"], "agent": os.environ["EA"],
                 "model_configured": {"kind": os.environ["EK"], "value": os.environ["EV"]}},
    "reviewer": {"provider": os.environ["RP"], "model": os.environ["RM"], "agent": os.environ["RA"],
                 "model_configured": {"kind": os.environ["RK"], "value": os.environ["RV"]}},
}}))
')"
  specrelay::state::set "$state_file" "$set_json" >/dev/null
}

# specrelay::workflow::_role_selection_for_capture <root> <role>
# The effective selection for capture, with a best-effort fallback for a
# selection that cannot be parsed (only reachable for a role whose validation
# is intentionally skipped, e.g. a manual reviewer whose model fields are
# documented as ignored): the raw configured value is preserved as an id-kind
# record rather than losing it.
specrelay::workflow::_role_selection_for_capture() {
  local root="$1" role="$2" selection
  if selection="$(specrelay::workflow::role_model_selection "$root" "$role" 2>/dev/null)"; then
    printf '%s\n' "$selection"
  else
    printf 'id:%s\n' "$(specrelay::config::get "$root" "roles.$role.model" "provider-default")"
  fi
}

# --- context capability configuration (spec 0015) ---------------------------
#
# Context adapters are role-aware: the executor and reviewer each resolve
# their OWN adapter and required policy (role-specific config -> global
# config -> adapter: none / required: false; see config.sh). Like role
# models (spec 0012/0014), the effective context configuration is captured
# into durable task state the first time a task runs, and the CAPTURED
# configuration is authoritative thereafter — resume never silently switches
# adapters because the project config changed.

# specrelay::workflow::context_adapter / context_required <root>
# The GLOBAL configured values (kept for read-only diagnostics and backward
# compatibility); role execution always goes through the role-aware
# accessors below.
specrelay::workflow::context_adapter() {
  specrelay::config::get "$1" "context.adapter" "none"
}

specrelay::workflow::context_required() {
  specrelay::config::get "$1" "context.required" "false"
}

# specrelay::workflow::role_context_field <root> <role> <adapter|required>
# One resolved field from the role's LIVE context configuration. Propagates
# the parser's failure (non-zero) for a structurally invalid context section.
specrelay::workflow::role_context_field() {
  local root="$1" role="$2" field="$3" parsed
  parsed="$(specrelay::config::role_context "$root" "$role")" || return 1
  printf '%s\n' "$parsed" | sed -n "s/^${field}=//p"
}

# specrelay::workflow::captured_context <root> <task-id> <role> <field>
# Prints the durable context_effective.<role>.<field> from the task's
# state.json when present; returns non-zero (prints nothing) otherwise.
# Booleans are printed as JSON (true/false), never Python's True/False.
specrelay::workflow::captured_context() {
  local root="$1" task_id="$2" role="$3" field="$4" state_file blob
  state_file="$(specrelay::state::path "$(specrelay::task::dir "$root" "$task_id")")"
  [ -f "$state_file" ] || return 1
  blob="$(specrelay::state::get "$state_file" context_effective 2>/dev/null || true)"
  [ -n "$blob" ] && [ "$blob" != "null" ] || return 1
  printf '%s' "$blob" | ROLE="$role" FIELD="$field" python3 -c '
import json, os, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)
role = data.get(os.environ["ROLE"])
if not isinstance(role, dict):
    sys.exit(1)
if os.environ["FIELD"] not in role:
    sys.exit(1)
val = role[os.environ["FIELD"]]
if val is None or val == "":
    sys.exit(1)
if isinstance(val, bool):
    print("true" if val else "false")
else:
    print(val)
'
}

# specrelay::workflow::effective_role_context_adapter|required <root> <task-id> <role>
# Durable-first resolution (spec 0015, "Resume Behavior"): the task's captured
# context_effective value when present, otherwise the live resolved config.
specrelay::workflow::effective_role_context_adapter() {
  local root="$1" task_id="$2" role="$3" v
  if v="$(specrelay::workflow::captured_context "$root" "$task_id" "$role" adapter)"; then
    printf '%s\n' "$v"; return 0
  fi
  specrelay::workflow::role_context_field "$root" "$role" adapter || printf 'none\n'
}
specrelay::workflow::effective_role_context_required() {
  local root="$1" task_id="$2" role="$3" v
  if v="$(specrelay::workflow::captured_context "$root" "$task_id" "$role" required)"; then
    printf '%s\n' "$v"; return 0
  fi
  specrelay::workflow::role_context_field "$root" "$role" required || printf 'false\n'
}

# specrelay::workflow::assert_role_context_valid <root> <task-id> <role>
# Fails (non-zero, actionable error naming the role, the adapter, the config
# source, the expected syntax, and the inspection command) when the role's
# context configuration is KNOWN-invalid: a structurally malformed context
# section, an unknown adapter, or an unsupported role/adapter combination.
# Runs BEFORE the role's running-state transition, so a known-invalid context
# configuration never enters EXECUTOR_RUNNING / REVIEWER_RUNNING. A task that
# already captured its context configuration is authoritative (validated at
# capture time) and is skipped here — a later config change must not
# retroactively fail a deterministic resume.
specrelay::workflow::assert_role_context_valid() {
  local root="$1" task_id="$2" role="$3" parsed adapter
  if specrelay::workflow::captured_context "$root" "$task_id" "$role" adapter >/dev/null 2>&1; then
    return 0
  fi
  if ! parsed="$(specrelay::config::role_context "$root" "$role")"; then
    specrelay::out::err "invalid $role context configuration in $(specrelay::config::path "$root"): $parsed"
    {
      echo "Expected context configuration forms:"
      echo "  Global:"
      echo "    context:"
      echo "      adapter: <adapter-name>"
      echo "      required: false"
      echo "  Role-specific override:"
      echo "    context:"
      echo "      $role:"
      echo "        adapter: <adapter-name>"
      echo "        required: true"
      echo "Inspect adapters with:"
      echo "  bin/specrelay contexts"
    } >&2
    return 1
  fi
  adapter="$(printf '%s\n' "$parsed" | sed -n 's/^adapter=//p')"
  if ! specrelay::context::known "$adapter"; then
    specrelay::out::err "invalid $role context adapter '$adapter'"
    {
      echo "Configuration source: $(specrelay::config::path "$root")"
      echo "Known adapters:"
      local a
      while IFS= read -r a; do
        [ -n "$a" ] && echo "  $a"
      done < <(specrelay::context::adapters)
      echo "Inspect adapters with:"
      echo "  bin/specrelay contexts"
    } >&2
    return 1
  fi
  if ! specrelay::context::role_supported "$adapter" "$role"; then
    specrelay::out::err "context adapter '$adapter' does not support the $role role (configuration source: $(specrelay::config::path "$root")); inspect it with: bin/specrelay contexts $adapter"
    return 1
  fi
  specrelay::context::validate_config "$adapter" "$root" "$role"
}

# specrelay::workflow::record_effective_context <root> <task-id>
# CAPTURE-ONCE (spec 0015, "Durable Task State" / "Resume Behavior"): persists
# both roles' effective context adapter + required policy into the task's
# state.json under "context_effective" the first time the task reaches an
# executor context step. Once present it is never overwritten here, so resume
# deterministically reuses the captured adapters even if the project
# configuration changed. Preparation status/artifact fields are updated per
# role by record_context_result below. Never stores secrets — adapter names,
# booleans, statuses, and artifact references only.
specrelay::workflow::record_effective_context() {
  local root="$1" task_id="$2" state_file existing
  state_file="$(specrelay::state::path "$(specrelay::task::dir "$root" "$task_id")")"
  [ -f "$state_file" ] || return 0

  existing="$(specrelay::state::get "$state_file" context_effective 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    return 0
  fi

  local ea er ra rr set_json
  ea="$(specrelay::workflow::role_context_field "$root" executor adapter 2>/dev/null)" || ea="none"
  er="$(specrelay::workflow::role_context_field "$root" executor required 2>/dev/null)" || er="false"
  ra="$(specrelay::workflow::role_context_field "$root" reviewer adapter 2>/dev/null)" || ra="none"
  rr="$(specrelay::workflow::role_context_field "$root" reviewer required 2>/dev/null)" || rr="false"

  set_json="$(EA="$ea" ER="$er" RA="$ra" RR="$rr" python3 -c '
import json, os
print(json.dumps({"context_effective": {
    "executor": {"adapter": os.environ["EA"], "required": os.environ["ER"] == "true", "status": "pending"},
    "reviewer": {"adapter": os.environ["RA"], "required": os.environ["RR"] == "true", "status": "pending"},
}}))
')"
  specrelay::state::set "$state_file" "$set_json" >/dev/null
}

# specrelay::workflow::record_context_result <root> <task-id> <role> <adapter>
#     <required(true|false)> <status> <prepared_at> <artifact_kind>
#     <artifact_reference> <freshness>
# Updates ONE role's durable context result in state.json (merging with the
# other role's entry) and writes the role's context evidence file
# (14-executor-context.json / 17-reviewer-context.json — 15/16 are the
# reviewer stdout/stderr captures in this repository's numbering). The
# captured adapter/required are preserved once present (capture-once); only
# the preparation result fields are updated. Evidence contains metadata only:
# no credentials, no secrets, no environment dumps.
specrelay::workflow::record_context_result() {
  local root="$1" task_id="$2" role="$3" adapter="$4" required="$5" status="$6"
  local prepared_at="$7" kind="$8" ref="$9" freshness="${10}"
  local task_dir state_file existing set_json evidence_file
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"
  [ -f "$state_file" ] || return 0

  existing="$(specrelay::state::get "$state_file" context_effective 2>/dev/null || true)"
  [ "$existing" = "null" ] && existing=""

  set_json="$(printf '%s' "$existing" | \
    ROLE="$role" ADAPTER="$adapter" REQUIRED="$required" STATUS="$status" \
    PREPARED_AT="$prepared_at" KIND="$kind" REF="$ref" FRESHNESS="$freshness" \
    python3 -c '
import json, os, sys
raw = sys.stdin.read().strip()
try:
    data = json.loads(raw) if raw else {}
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
role = os.environ["ROLE"]
entry = data.get(role)
if not isinstance(entry, dict):
    entry = {}
# capture-once: adapter/required stick once recorded
entry.setdefault("adapter", os.environ["ADAPTER"])
entry.setdefault("required", os.environ["REQUIRED"] == "true")
entry["status"] = os.environ["STATUS"]
for key, env in (("prepared_at", "PREPARED_AT"), ("artifact_kind", "KIND"),
                 ("artifact_reference", "REF"), ("freshness", "FRESHNESS")):
    val = os.environ[env]
    if val:
        entry[key] = val
    else:
        entry.pop(key, None)
data[role] = entry
print(json.dumps({"context_effective": data}))
')"
  specrelay::state::set "$state_file" "$set_json" >/dev/null

  # Context evidence is written for real context outcomes (prepared, degraded,
  # failed); the none adapter's "nothing was requested" produces no evidence
  # file — evidence never implies external context that was not involved.
  [ "$status" != "none" ] || return 0
  case "$role" in
    executor) evidence_file="$task_dir/14-executor-context.json" ;;
    reviewer) evidence_file="$task_dir/17-reviewer-context.json" ;;
    *) return 0 ;;
  esac
  ROLE="$role" ADAPTER="$adapter" REQUIRED="$required" STATUS="$status" \
    PREPARED_AT="$prepared_at" KIND="$kind" REF="$ref" FRESHNESS="$freshness" \
    python3 -c '
import json, os, sys
doc = {
    "role": os.environ["ROLE"],
    "adapter": os.environ["ADAPTER"],
    "required": os.environ["REQUIRED"] == "true",
    "status": os.environ["STATUS"],
}
for key, env in (("prepared_at", "PREPARED_AT"), ("artifact_kind", "KIND"),
                 ("artifact_reference", "REF"), ("freshness", "FRESHNESS")):
    val = os.environ[env]
    if val:
        doc[key] = val
print(json.dumps(doc, indent=2))
' > "$evidence_file"
}

# specrelay::workflow::_context_role_failure <root> <task-id> <role> <adapter>
#     <required(true|false)> <what-failed>
# Applies the required/optional policy to a context availability, preflight,
# or preparation failure (spec 0015, "Required and Optional Policy"):
#   required -> the role must not enter its running state (return 1);
#   optional -> degrade HONESTLY: log that SpecRelay is continuing WITHOUT
#               external context (never pretending preparation succeeded) and
#               record status=degraded durably (return 0).
specrelay::workflow::_context_role_failure() {
  local root="$1" task_id="$2" role="$3" adapter="$4" required="$5" what="$6"
  if [ "$required" = "true" ]; then
    specrelay::out::err "[$role] context: required context $what for adapter '$adapter'; refusing to launch the $role"
    specrelay::workflow::record_context_result "$root" "$task_id" "$role" \
      "$adapter" "$required" "failed" "" "" "" ""
    return 1
  fi
  specrelay::out::log "[$role] context: adapter '$adapter' $what"
  specrelay::out::log "[$role] context: continuing without external context because required=false"
  specrelay::workflow::record_context_result "$root" "$task_id" "$role" \
    "$adapter" "$required" "degraded" "" "" "" ""
  return 0
}

# specrelay::workflow::run_role_context <root> <task-id> <role> <provider>
# The full per-role context step (spec 0015, "Preflight Contract"), run BEFORE
# the role's running-state transition:
#   context validation -> availability -> preflight -> preparation (when the
#   adapter supports it, with the documented reuse/reprepare resume policy)
# On success, sets the global SPECRELAY_CONTEXT_HANDOFF to the normalized
# handoff for this role ("<artifact-kind>:<artifact-reference>", or "none"
# when there is no prepared context) — the ONLY context value the provider
# invocation receives. Returns 0 to proceed (including honest optional
# degradation) and 1 when a required context failure must block the role.
specrelay::workflow::run_role_context() {
  local root="$1" task_id="$2" role="$3" provider="$4"
  local task_dir adapter required
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  SPECRELAY_CONTEXT_HANDOFF="none"

  if ! specrelay::workflow::assert_role_context_valid "$root" "$task_id" "$role"; then
    return 1
  fi

  adapter="$(specrelay::workflow::effective_role_context_adapter "$root" "$task_id" "$role")"
  required="$(specrelay::workflow::effective_role_context_required "$root" "$task_id" "$role")"
  [ "$required" = "true" ] || required="false"

  specrelay::out::log "[$role] task '$task_id': context validation and preflight (adapter: $adapter, required=$required)"

  # Availability (read-only, never billable).
  local avail_out avail_reason
  if ! avail_out="$(specrelay::context::availability "$adapter" "$root")"; then
    avail_reason="$(printf '%s\n' "$avail_out" | sed -n '2p')"
    specrelay::out::err "[$role] context: adapter '$adapter' unavailable${avail_reason:+: $avail_reason}"
    specrelay::workflow::_context_role_failure "$root" "$task_id" "$role" "$adapter" "$required" "unavailable"
    return $?
  fi

  # Preflight.
  if ! specrelay::context::preflight "$adapter" "$role" "$root" "$task_id" "$provider"; then
    specrelay::workflow::_context_role_failure "$root" "$task_id" "$role" "$adapter" "$required" "preflight failed"
    return $?
  fi

  # Preparation (adapters that support it), with the documented resume policy.
  if ! specrelay::context::supports_prepare "$adapter"; then
    # Nothing is prepared and SpecRelay says so — no artifact, no handoff.
    specrelay::workflow::record_context_result "$root" "$task_id" "$role" \
      "$adapter" "$required" "none" "" "none" "" "not-applicable"
    return 0
  fi

  local prev_status prev_kind prev_ref prev_fresh prev_at decision
  prev_status="$(specrelay::workflow::captured_context "$root" "$task_id" "$role" status 2>/dev/null || true)"
  prev_kind="$(specrelay::workflow::captured_context "$root" "$task_id" "$role" artifact_kind 2>/dev/null || true)"
  prev_ref="$(specrelay::workflow::captured_context "$root" "$task_id" "$role" artifact_reference 2>/dev/null || true)"
  prev_fresh="$(specrelay::workflow::captured_context "$root" "$task_id" "$role" freshness 2>/dev/null || true)"
  prev_at="$(specrelay::workflow::captured_context "$root" "$task_id" "$role" prepared_at 2>/dev/null || true)"

  if [ "$prev_status" = "prepared" ] && [ -n "$prev_ref" ]; then
    decision="$(specrelay::context::reuse_decision "$adapter" "$role" "$root" "$task_dir" \
      "$prev_kind" "$prev_ref" "$prev_fresh" 2>/dev/null || printf 'reprepare\n')"
    if [ "$decision" = "reuse" ]; then
      specrelay::out::log "[$role] context: reusing previously prepared artifact ($prev_kind: $prev_ref)"
      specrelay::workflow::record_context_result "$root" "$task_id" "$role" \
        "$adapter" "$required" "prepared" "$prev_at" "$prev_kind" "$prev_ref" "$prev_fresh"
      SPECRELAY_CONTEXT_HANDOFF="$prev_kind:$prev_ref"
      specrelay::workflow::_context_card "$role" "$adapter" "$required" "prepared" "$prev_ref" "$prev_fresh"
      return 0
    fi
    specrelay::out::log "[$role] context: previously prepared artifact is not reusable (adapter decision: $decision); re-preparing"
  fi

  local prep_out prepared_at kind ref freshness status
  if ! prep_out="$(specrelay::context::prepare "$adapter" "$role" "$root" "$task_dir" "$task_id" "$provider")"; then
    specrelay::workflow::_context_role_failure "$root" "$task_id" "$role" "$adapter" "$required" "preparation failed"
    return $?
  fi
  status="$(printf '%s\n' "$prep_out" | sed -n 's/^status=//p')"
  kind="$(printf '%s\n' "$prep_out" | sed -n 's/^artifact_kind=//p')"
  ref="$(printf '%s\n' "$prep_out" | sed -n 's/^artifact_reference=//p')"
  freshness="$(printf '%s\n' "$prep_out" | sed -n 's/^freshness=//p')"
  [ -n "$status" ] || status="prepared"
  [ -n "$freshness" ] || freshness="unknown"
  prepared_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"

  # A prepared-but-missing/unreadable required artifact must block (spec 0015,
  # "Required Context"): never hand a provider a reference that is not there.
  if [ "$status" = "prepared" ] && [ "$kind" = "file" ] && [ ! -r "$root/$ref" ]; then
    specrelay::workflow::_context_role_failure "$root" "$task_id" "$role" "$adapter" "$required" "artifact missing or unreadable ($ref)"
    return $?
  fi

  # Freshness policy (spec 0015, "Context Freshness"): stale blocks only a
  # REQUIRED role whose adapter declares freshness mandatory; an optional
  # stale artifact warns and continues. Never guessed — the value comes from
  # the adapter's own report.
  if [ "$freshness" = "stale" ]; then
    if [ "$required" = "true" ] && specrelay::context::freshness_mandatory "$adapter"; then
      specrelay::workflow::_context_role_failure "$root" "$task_id" "$role" "$adapter" "$required" "artifact is stale (adapter policy: freshness is mandatory)"
      return $?
    fi
    specrelay::out::log "[$role] context: adapter '$adapter' reports a STALE artifact; continuing (freshness is not mandatory for this role)"
  fi

  specrelay::workflow::record_context_result "$root" "$task_id" "$role" \
    "$adapter" "$required" "$status" "$prepared_at" "$kind" "$ref" "$freshness"

  if [ "$status" = "prepared" ] && [ -n "$ref" ]; then
    SPECRELAY_CONTEXT_HANDOFF="$kind:$ref"
  fi
  specrelay::workflow::_context_card "$role" "$adapter" "$required" "$status" "$ref" "$freshness"
  return 0
}

# specrelay::workflow::_context_card <role> <adapter> <required> <status> <ref> <freshness>
# The pre-execution context card (spec 0015, "Logging"). The none adapter
# announces itself with its own single log line instead, so a card never
# implies external context that was not requested.
specrelay::workflow::_context_card() {
  local role="$1" adapter="$2" required="$3" status="$4" ref="$5" freshness="$6" title req_label
  [ "$adapter" = "none" ] && return 0
  case "$role" in
    executor) title="Executor Context" ;;
    reviewer) title="Reviewer Context" ;;
    *) title="Context" ;;
  esac
  if [ "$required" = "true" ]; then req_label="yes"; else req_label="no"; fi
  specrelay::out::card blue "$title" \
    "$(printf '%-10s%s' Adapter "$adapter")" \
    "$(printf '%-10s%s' Required "$req_label")" \
    "$(printf '%-10s%s' Status "$status")" \
    "$(printf '%-10s%s' Artifact "${ref:-(none)}")" \
    "$(printf '%-10s%s' Freshness "${freshness:-not-applicable}")"
}

specrelay::workflow::max_iterations() {
  specrelay::config::get "$1" "tasks.max_iterations" "3"
}

specrelay::workflow::_truthy() {
  case "$1" in
    1|true|True|TRUE|yes) return 0 ;;
    *) return 1 ;;
  esac
}

# --- reviewer prompt reconstruction (isolation — spec section 23) ----------

# specrelay::workflow::build_reviewer_prompt <project-root> <task-id>
# Prints the path to a freshly written, temporary prompt file reconstructed
# from the spec/task/evidence files — NEVER from any executor conversation
# state (there is none to reuse: the reviewer provider is always a brand new
# process, see providers/claude.sh).
specrelay::workflow::build_reviewer_prompt() {
  local root="$1" task_id="$2" task_dir task_rel tmp
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  task_rel="${task_dir#"$root"/}"
  tmp="$(mktemp "${TMPDIR:-/tmp}/specrelay-reviewer-prompt.XXXXXX")"

  # The plain (non-Claude-subagent) reviewer prompt carries the SAME critical
  # policy as templates/claude/agents/ai-reviewer.md (spec 0019, "Reviewer
  # Prompt Contract" — this must not depend exclusively on Claude sub-agent
  # installation): risk classification, evidence inspection, bounded
  # verification, structured artifacts, a mandatory marker, and a stop
  # condition.
  local focused_max targeted_max full_max smoke_max
  focused_max="$(specrelay::verification::reviewer_limit "$root" focused_max_runs 2>/dev/null || echo 3)"
  targeted_max="$(specrelay::verification::reviewer_limit "$root" targeted_max_runs 2>/dev/null || echo 1)"
  full_max="$(specrelay::verification::reviewer_limit "$root" full_suite_max_runs 2>/dev/null || echo 0)"
  smoke_max="$(specrelay::verification::reviewer_limit "$root" smoke_max_runs 2>/dev/null || echo 0)"

  {
    echo "You are an INDEPENDENT reviewer for SpecRelay task '$task_id'."
    echo "You are a fresh context: you are NOT a continuation of the executor's session."
    echo "You are NOT a second executor: do not repeat every executor command"
    echo "automatically, and do not run the complete test suite merely because it"
    echo "is available. Inspect executor evidence, assess RISK, and independently"
    echo "verify only the highest-risk claims."
    echo
    echo "1. Classify this change's risk level: low | medium | high | critical"
    echo "   (state-machine/orchestrator/provider/git-guard/test-runner/security"
    echo "   changes are high or critical; docs/formatting/narrow non-behavioral"
    echo "   changes are low)."
    echo "2. Inspect the real working tree and current diff (git status --short,"
    echo "   git diff) — never only the executor's narrative."
    echo "3. Inspect the executor evidence below."
    echo "4. Select the MINIMUM sufficient independent verification for that risk"
    echo "   level. Your default verification budget for this review:"
    echo "     Focused test runs: $focused_max"
    echo "     Targeted runs:     $targeted_max"
    echo "     Full-suite runs:   $full_max by default"
    echo "     Smoke runs:        $smoke_max by default"
    echo "   Exceeding this budget requires recording, BEFORE the extra run:"
    echo "     ADDITIONAL_VERIFICATION_REASON: <why>"
    echo "   Running the full suite 'because it is available' is never sufficient."
    echo "5. Evaluate every acceptance criterion in the spec below explicitly."
    echo "6. Decide exactly one of ACCEPT or REQUEST_CHANGES. Use severities"
    echo "   BLOCKER/HIGH -> REQUEST_CHANGES, MEDIUM -> your judgment (explain),"
    echo "   LOW/NOTE -> ACCEPT. Never reject solely for style preference."
    echo "7. STOP once every acceptance criterion is assessed, sufficient"
    echo "   independent evidence exists, and a decision is justified — do not"
    echo "   keep exploring the repository past that point."
    echo
    echo "Reviewer completion contract (spec 0021, 'Agent Execution Efficiency"
    echo "and Completion Gate'):"
    echo "- Review independently, but do not repeat the Executor's entire"
    echo "  verification without a concrete risk-based reason."
    echo "- Prefer inspection of changed files and focused tests."
    echo "- Run the full suite only when required by policy or justified by"
    echo "  identified risk."
    echo "- Do not end while waiting for background verification."
    echo "- Before finishing, write $task_rel/09-consultant-review.md and"
    echo "  $task_rel/10-business-summary.md."
    echo "- End with exactly one explicit marker: 'DECISION: ACCEPT' or"
    echo "  'DECISION: REQUEST_CHANGES'."
    echo "- Once sufficient evidence exists, decide and stop."
    echo
    echo "Before you answer, write your review to $task_rel/09-consultant-review.md"
    echo "(risk level, acceptance-criteria table, independent verification"
    echo "performed, findings by severity, residual risks, and the verification"
    echo "budget you actually used)."
    echo "If you decide ACCEPT, also write $task_rel/10-business-summary.md (a short"
    echo "plain-language summary of what changed, for a non-technical reader)."
    echo "If you decide REQUEST_CHANGES, also write"
    echo "$task_rel/11-next-executor-prompt.md (the next executor prompt, explaining"
    echo "exactly what must change)."
    echo "End your reply with exactly one line, verbatim, as the FINAL non-empty"
    echo "line of your entire response: 'DECISION: ACCEPT' or"
    echo "'DECISION: REQUEST_CHANGES'. Never emit both, never emit it twice, and"
    echo "never guess a decision from prose."
    echo
    echo "=== User request (00-user-request.md) ==="
    cat "$task_dir/00-user-request.md" 2>/dev/null
    echo
    echo "=== Executor prompt (02-executor-prompt.md) ==="
    cat "$task_dir/02-executor-prompt.md" 2>/dev/null
    echo
    echo "=== Executor log (03-executor-log.md) ==="
    cat "$task_dir/03-executor-log.md" 2>/dev/null
    echo
    echo "=== Tests (07-tests.txt) ==="
    cat "$task_dir/07-tests.txt" 2>/dev/null
    echo
    echo "=== Executor summary (08-executor-summary.md) ==="
    cat "$task_dir/08-executor-summary.md" 2>/dev/null
    echo
    echo "=== Changed files (05-changed-files.txt) ==="
    cat "$task_dir/05-changed-files.txt" 2>/dev/null
    echo
    echo "=== Diff stat (05-git-diff-stat.txt) ==="
    cat "$task_dir/05-git-diff-stat.txt" 2>/dev/null
    echo
    echo "Also independently inspect the real working tree (git status --short, git diff) under $root before deciding."
  } > "$tmp"
  printf '%s\n' "$tmp"
}

# --- task seeding from a spec (real, non-fake executor content) ------------

# specrelay::workflow::seed_task_from_spec <project-root> <task-id> <spec-abs-path>
# Fills 00/01/02 from the spec, in the numbered-prompt format this
# repository's own protocol requires (see CLAUDE.md: every implementation
# prompt starts with "Prompt #N — Title"), and always appends the
# ownership-contract footer.
specrelay::workflow::seed_task_from_spec() {
  local root="$1" task_id="$2" spec_abs="$3" task_dir spec_rel task_rel
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  spec_rel="${spec_abs#"$root"/}"
  task_rel="${task_dir#"$root"/}"

  {
    echo "# User Request — SpecRelay Task $task_id"
    echo
    echo "Spec source: $spec_rel"
    echo
    cat "$spec_abs"
  } > "$task_dir/00-user-request.md"

  {
    echo "# Consultant Analysis — SpecRelay Task $task_id"
    echo
    echo "Auto-generated by 'specrelay run'. The spec file on disk ($spec_rel) is the"
    echo "single source of truth; this file only records that fact."
  } > "$task_dir/01-consultant-analysis.md"

  local full_max smoke_max doctor_max version_max
  full_max="$(specrelay::verification::executor_limit "$root" full_suite_max_runs 2>/dev/null || echo 1)"
  smoke_max="$(specrelay::verification::executor_limit "$root" smoke_max_runs 2>/dev/null || echo 1)"
  doctor_max="$(specrelay::verification::executor_limit "$root" doctor_max_runs 2>/dev/null || echo 1)"
  version_max="$(specrelay::verification::executor_limit "$root" version_max_runs 2>/dev/null || echo 1)"

  {
    echo "Prompt #1 — Implement Spec Task $task_id"
    echo
    echo "Implement exactly what $spec_rel requires. Do not add, remove, or"
    echo "reinterpret requirements. If the spec is unclear or contradictory,"
    echo "stop and report a blocking issue instead of guessing."
    echo
    echo "Write these files in $task_rel/ (the task's runtime evidence folder,"
    echo "NOT the spec's own directory):"
    echo "  - $task_rel/03-executor-log.md"
    echo "  - $task_rel/07-tests.txt"
    echo "  - $task_rel/08-executor-summary.md"
    echo
    echo "Verification policy (spec 0019, 'Bounded Verification Policy'): prefer"
    echo "focused/targeted tests during implementation; run the full standalone"
    echo "suite once at the end, not after every edit. Default limits without a"
    echo "recorded reason: full-suite runs <= $full_max, smoke runs <= $smoke_max,"
    echo "doctor runs <= $doctor_max, version runs <= $version_max. Any additional run"
    echo "beyond these needs a recorded reason:"
    echo "  ADDITIONAL_VERIFICATION_REASON: <why>"
    echo
    echo "Completion contract (spec 0021, 'Agent Execution Efficiency and"
    echo "Completion Gate'):"
    echo "- Do not continue broad repository exploration after sufficient"
    echo "  implementation context has been obtained."
    echo "- Prefer focused verification before broader verification."
    echo "- Do not rerun an already-passing verification command unless source"
    echo "  changed or a concrete reason is recorded."
    echo "- Do not end by saying that you are waiting for a background task."
    echo "- Before finishing, ensure all required Executor artifacts are"
    echo "  non-empty: $task_rel/03-executor-log.md, $task_rel/07-tests.txt,"
    echo "  $task_rel/08-executor-summary.md."
    echo "- After required verification passes, write the deliverables and"
    echo "  finish."
    echo "- Do not run additional exploratory commands after completion"
    echo "  criteria are met unless a concrete blocker or inconsistency is"
    echo "  discovered."
    echo "A provider exit code of zero is not sufficient on its own: SpecRelay"
    echo "requires the artifacts above to be non-empty and requires that you not"
    echo "declare unresolved background work before it accepts this round as"
    echo "complete."
    echo
    echo "=== Spec ($spec_rel) ==="
    cat "$spec_abs"
    echo
    cat "$SPECRELAY_CONTRACT_FOOTER"
  } > "$task_dir/02-executor-prompt.md"
}

# --- one executor round -----------------------------------------------------

# specrelay::workflow::executor_iteration <project-root> <task-id>
# Requires the task to already be READY_FOR_EXECUTOR. Runs the full
# claim -> guard -> context preflight -> provider -> evidence -> submit
# sequence (spec section 6's contract, migrated).
specrelay::workflow::executor_iteration() {
  local root="$1" task_id="$2" task_dir state_file current
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"

  current="$(specrelay::state::canonical "$state_file")"
  if [ "$current" != "READY_FOR_EXECUTOR" ]; then
    specrelay::out::err "cannot run executor iteration: task '$task_id' is not READY_FOR_EXECUTOR (current: $current)"
    return 1
  fi

  # Reject malformed model configuration BEFORE any provider execution (spec
  # 0012, "Validation"). The executor's own model always, and the reviewer's
  # model when an automated reviewer is configured — record_effective_roles
  # captures BOTH roles at this iteration, so a garbage reviewer model must be
  # caught before it is captured and later reused on resume. A task that already
  # captured its models skips this (captured config is authoritative on resume).
  if ! specrelay::workflow::assert_role_model_valid "$root" "$task_id" executor; then
    return 1
  fi
  if [ "$(specrelay::workflow::reviewer_provider "$root")" != "manual" ]; then
    if ! specrelay::workflow::assert_role_model_valid "$root" "$task_id" reviewer; then
      return 1
    fi
  fi

  specrelay::out::log "[executor] task '$task_id': checking working-tree guard"
  if ! specrelay::git_guard::check "$root" "$task_dir"; then
    return 1
  fi

  local provider model agent
  provider="$(specrelay::workflow::effective_role_provider "$root" "$task_id" executor)"
  model="$(specrelay::workflow::effective_role_model "$root" "$task_id" executor)"
  agent="$(specrelay::workflow::effective_role_agent "$root" "$task_id" executor)"

  # Context capability step (spec 0015): validation -> preflight -> preparation,
  # all BEFORE the claim below, so a known context failure never enters
  # EXECUTOR_RUNNING and the provider is never launched for it. Both roles'
  # context configuration is validated here (like role models above) because
  # record_effective_context captures BOTH roles' effective adapters at this
  # iteration — a garbage reviewer context must be caught before it is captured
  # and later reused on resume. Validation is skipped for a task that already
  # captured its context configuration (captured config is authoritative).
  if ! specrelay::workflow::assert_role_context_valid "$root" "$task_id" executor; then
    return 1
  fi
  if [ "$(specrelay::workflow::reviewer_provider "$root")" != "manual" ]; then
    if ! specrelay::workflow::assert_role_context_valid "$root" "$task_id" reviewer; then
      return 1
    fi
  fi
  specrelay::workflow::record_effective_context "$root" "$task_id"

  local executor_context_handoff
  specrelay::timeline::start "$task_dir" executor_context_preflight executor
  if ! specrelay::workflow::run_role_context "$root" "$task_id" executor "$provider"; then
    specrelay::timeline::finish "$task_dir" executor_context_preflight failed
    specrelay::out::err "[executor] context capability failed and is required; refusing to claim/launch the executor"
    return 1
  fi
  specrelay::timeline::finish "$task_dir" executor_context_preflight passed
  executor_context_handoff="${SPECRELAY_CONTEXT_HANDOFF:-none}"

  specrelay::out::log "[executor] task '$task_id': claiming"
  specrelay::timeline::start "$task_dir" executor_claim executor
  if ! specrelay::transitions::claim "$root" "$task_id"; then
    specrelay::timeline::finish "$task_dir" executor_claim failed
    return 1
  fi
  specrelay::timeline::finish "$task_dir" executor_claim passed

  # Record effective (normalized) role metadata into durable state (spec 0009,
  # "Runtime evidence"): provider/model/agent for both roles.
  specrelay::workflow::record_effective_roles "$root" "$task_id"
  specrelay::workflow::record_effective_verification_policy "$root" "$task_id"
  specrelay::workflow::record_effective_execution_efficiency_policy "$root" "$task_id"

  local round rc started ended duration
  round="$(specrelay::state::get "$state_file" "iteration" 2>/dev/null || true)"
  [ -n "$round" ] || round=1

  # Level 3 (spec 0013): the executor role-execution header. Provider output
  # (Level 4) continues exactly as today, immediately below this card.
  specrelay::out::card blue "Executor · Round $round" \
    "$(printf '%-10s%s' Provider "$provider")" \
    "$(printf '%-10s%s' Model "$model")" \
    "$(printf '%-10s%s' Agent "$agent")"

  specrelay::out::log "[executor] task '$task_id': running provider '$provider' (round $round, model=$model agent=$agent)"
  started="$(date +%s 2>/dev/null || echo '')"
  specrelay::timeline::start "$task_dir" executor_provider_execution executor
  local invocation_id
  invocation_id="$(specrelay::timeline::current_invocation_id "$task_dir")"
  if specrelay::provider::executor_run "$provider" "$root" "$task_dir" "$round" "$task_dir/02-executor-prompt.md" "$model" "$agent" "$executor_context_handoff" "$invocation_id"; then
    rc=0
  else
    rc=$?
  fi
  ended="$(date +%s 2>/dev/null || echo '')"
  if [ "$rc" -eq 0 ]; then
    specrelay::timeline::finish "$task_dir" executor_provider_execution passed
  else
    specrelay::timeline::finish "$task_dir" executor_provider_execution failed
  fi
  # Best-effort verification-ledger extraction from the captured semantic
  # event transcript (spec 0019, "Verification Operation Classification"):
  # structurally real (parsed tool_use commands), never fabricated from
  # prose. A no-op when no such transcript exists (e.g. the fake provider,
  # or a run that used the generic streaming fallback).
  specrelay::verification::extract_from_events "$task_dir" executor "$task_dir/19-executor-events.jsonl"

  specrelay::out::log "[executor] task '$task_id': capturing evidence"
  specrelay::timeline::start "$task_dir" executor_evidence_capture executor
  specrelay::evidence::capture "$root" "$task_dir"
  specrelay::timeline::finish "$task_dir" executor_evidence_capture passed

  if [ -n "$started" ] && [ -n "$ended" ]; then
    duration="$(specrelay::out::format_duration "$((ended - started))")"
  else
    duration="unknown"
  fi

  if [ "$rc" -ne 0 ]; then
    specrelay::out::card red "Executor Result" "FAILED (exit $rc)" "Duration $duration"
    specrelay::out::err "[executor] task '$task_id': provider exited non-zero ($rc); not submitted for review"
    return 1
  fi

  # Executor completion gate (spec 0021, "Required Executor Artifacts" /
  # "Unresolved Waiting Detection"): a provider exit code of zero is NOT
  # sufficient evidence of successful role completion by itself. This check
  # runs, and any resulting card is printed, BEFORE the SUCCESS card — never
  # after — so a completion-gate failure can never be preceded by a false
  # "Executor Result: SUCCESS" card (the exact incorrect behavior spec 0021
  # exists to prevent).
  local gate_reason=""
  local f
  for f in 03-executor-log.md 07-tests.txt 08-executor-summary.md; do
    if [ ! -s "$task_dir/$f" ]; then
      gate_reason="required Executor artifact '$f' is missing or empty"
      break
    fi
  done

  if [ -z "$gate_reason" ]; then
    local unresolved_wait_policy
    unresolved_wait_policy="$(specrelay::workflow::effective_execution_efficiency_field "$root" "$task_id" executor unresolved_wait_is_failure)"
    if [ "$unresolved_wait_policy" = "true" ] && \
       [ "$(specrelay::agent_efficiency::detect_unresolved_wait "$task_dir/12-executor-stdout.txt")" = "detected" ]; then
      gate_reason="provider exited without completing its declared background work"
    fi
  fi

  if [ -n "$gate_reason" ]; then
    specrelay::out::card red "Executor Result" "INCOMPLETE" "Duration $duration"
    specrelay::out::err "[executor] task '$task_id': provider exited successfully, but Executor completion contract failed: $gate_reason; not submitted for review"
    specrelay::agent_efficiency::record_completion_gate "$task_dir" executor failed "$gate_reason"
    return 1
  fi

  specrelay::agent_efficiency::record_completion_gate "$task_dir" executor passed
  specrelay::out::card green "Executor Result" "SUCCESS" "Duration $duration"

  # Snapshot task-owned working-tree paths BEFORE submitting, so the NEXT
  # claim's guard allows this round's accumulated diff to persist into the
  # next iteration (spec sections 31-33 — the rework-loop fix).
  specrelay::git_guard::snapshot_owned "$root" "$task_dir"

  local token rc2
  specrelay::timeline::start "$task_dir" executor_submission executor
  token="$(specrelay::auth::mint "$root" "$task_id")"
  if specrelay::transitions::submit "$root" "$task_id" "$token"; then
    rc2=0
  else
    rc2=$?
  fi
  specrelay::auth::cleanup "$root" "$task_id"
  if [ "$rc2" -ne 0 ]; then
    specrelay::timeline::finish "$task_dir" executor_submission failed
    return 1
  fi
  specrelay::timeline::finish "$task_dir" executor_submission passed

  specrelay::out::log "[executor] task '$task_id': submitted for review (READY_FOR_REVIEW)"
  return 0
}

# --- one reviewer round ------------------------------------------------------

# specrelay::workflow::reviewer_iteration <project-root> <task-id>
# Requires the task to be READY_FOR_REVIEW or (resuming an interrupted
# automated review — spec 0011) REVIEWER_RUNNING. Returns 0 on a decision
# (accept or request-changes, either is "success" for the loop), 1 on a
# provider failure (no decision — the task stays REVIEWER_RUNNING once the
# review has started, so a later resume continues from there), 2 when the
# configured reviewer provider is 'manual' (no automated decision is possible;
# state unchanged at READY_FOR_REVIEW, a human must run 'specrelay task
# accept|request-changes').
#
# For an AUTOMATED reviewer the state machine is (spec 0011):
#   READY_FOR_REVIEW -> REVIEWER_RUNNING -> READY_FOR_HUMAN_REVIEW | CHANGES_REQUESTED
# The transition into REVIEWER_RUNNING happens BEFORE the reviewer executes, so
# review-in-progress is observable and an interrupted review is recoverable by
# resume (it never rolls back to READY_FOR_REVIEW).
specrelay::workflow::reviewer_iteration() {
  local root="$1" task_id="$2" task_dir state_file current
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"

  current="$(specrelay::state::canonical "$state_file")"
  case "$current" in
    READY_FOR_REVIEW|REVIEWER_RUNNING) : ;;
    *)
      specrelay::out::err "cannot run reviewer iteration: task '$task_id' is not READY_FOR_REVIEW or REVIEWER_RUNNING (current: $current)"
      return 1
      ;;
  esac

  local provider
  provider="$(specrelay::workflow::reviewer_provider "$root")"

  if [ "$provider" = "manual" ]; then
    specrelay::out::log "[reviewer] task '$task_id': reviewer provider is 'manual'; a human must decide (specrelay task accept|request-changes). State unchanged."
    return 2
  fi

  # Reject malformed reviewer model configuration before launching the reviewer
  # provider (spec 0012, "Validation"). Skipped once the task has captured its
  # reviewer model (captured config is authoritative on resume).
  if ! specrelay::workflow::assert_role_model_valid "$root" "$task_id" reviewer; then
    return 1
  fi

  # INDEPENDENT reviewer context step (spec 0015): validation -> preflight ->
  # preparation, all BEFORE the REVIEWER_RUNNING transition below, so a known
  # context failure never enters REVIEWER_RUNNING and the reviewer provider is
  # never launched for it. This is a separate, role-specific preparation event —
  # never a reuse of the executor's transient context session.
  specrelay::out::log "[reviewer] task '$task_id': independent context capability step"
  local reviewer_context_handoff
  specrelay::timeline::start "$task_dir" reviewer_context_preflight reviewer
  if ! specrelay::workflow::run_role_context "$root" "$task_id" reviewer "$provider"; then
    specrelay::timeline::finish "$task_dir" reviewer_context_preflight failed
    specrelay::out::err "[reviewer] context capability failed and is required; refusing to launch the reviewer"
    return 1
  fi
  specrelay::timeline::finish "$task_dir" reviewer_context_preflight passed
  reviewer_context_handoff="${SPECRELAY_CONTEXT_HANDOFF:-none}"

  # Enter REVIEWER_RUNNING before executing the reviewer (spec 0011). Only when
  # the task is still READY_FOR_REVIEW: when resuming an interrupted review the
  # task is already REVIEWER_RUNNING and must NOT be transitioned again. A
  # preflight refusal above returns early, so it never marks a review "running"
  # that was never launched (that is not a reviewer crash — no state change).
  if [ "$current" = "READY_FOR_REVIEW" ]; then
    specrelay::out::log "[reviewer] task '$task_id': entering REVIEWER_RUNNING (automated review in progress)"
    specrelay::timeline::start "$task_dir" reviewer_start reviewer
    if ! specrelay::transitions::start_review "$root" "$task_id" "$provider"; then
      specrelay::timeline::finish "$task_dir" reviewer_start failed
      specrelay::out::err "[reviewer] task '$task_id': could not enter REVIEWER_RUNNING; task stays READY_FOR_REVIEW"
      return 1
    fi
    specrelay::timeline::finish "$task_dir" reviewer_start passed
  else
    specrelay::out::log "[reviewer] task '$task_id': resuming an interrupted review from REVIEWER_RUNNING"
  fi

  local round prompt_file decision rc model agent
  model="$(specrelay::workflow::effective_role_model "$root" "$task_id" reviewer)"
  agent="$(specrelay::workflow::effective_role_agent "$root" "$task_id" reviewer)"
  round="$(specrelay::state::get "$state_file" "iteration" 2>/dev/null || true)"
  [ -n "$round" ] || round=1
  prompt_file="$(specrelay::workflow::build_reviewer_prompt "$root" "$task_id")"

  # Level 3 (spec 0013): the reviewer role-execution header (magenta = review).
  # Provider output (Level 4) continues exactly as today, below this card.
  specrelay::out::card magenta "Reviewer · Round $round" \
    "$(printf '%-10s%s' Provider "$provider")" \
    "$(printf '%-10s%s' Model "$model")" \
    "$(printf '%-10s%s' Agent "$agent")"

  specrelay::out::log "[reviewer] task '$task_id': running provider '$provider' (round $round, model=$model agent=$agent, isolated context)"
  specrelay::timeline::start "$task_dir" reviewer_provider_execution reviewer
  local invocation_id
  invocation_id="$(specrelay::timeline::current_invocation_id "$task_dir")"
  if decision="$(specrelay::provider::reviewer_run "$provider" "$root" "$task_dir" "$round" "$prompt_file" "$model" "$agent" "$reviewer_context_handoff" "$invocation_id")"; then
    rc=0
  else
    rc=$?
  fi
  rm -f "$prompt_file"
  specrelay::verification::extract_from_events "$task_dir" reviewer "$task_dir/20-reviewer-events.jsonl"

  # Reviewer completion gate, unresolved-waiting check (spec 0021,
  # "Unresolved Waiting Detection"): inspected on the provider's FINAL
  # extracted output ONLY (15-reviewer-stdout.txt), before any marker-only
  # recovery is attempted, and before a rc=0/rc=2 outcome is otherwise
  # treated as reviewer completion. A provider crash (rc not in {0,2}) is a
  # distinct, already-handled failure mode and is left to the existing
  # branch below.
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
    local reviewer_wait_policy
    reviewer_wait_policy="$(specrelay::workflow::effective_execution_efficiency_field "$root" "$task_id" reviewer unresolved_wait_is_failure)"
    if [ "$reviewer_wait_policy" = "true" ] && \
       [ "$(specrelay::agent_efficiency::detect_unresolved_wait "$task_dir/15-reviewer-stdout.txt")" = "detected" ]; then
      specrelay::timeline::finish "$task_dir" reviewer_provider_execution passed
      specrelay::agent_efficiency::record_completion_gate "$task_dir" reviewer failed \
        "provider exited without completing its declared background work"
      specrelay::out::err "[reviewer] task '$task_id': provider exited successfully, but Reviewer completion contract failed: provider exited without completing its declared background work; task stays REVIEWER_RUNNING"
      return 1
    fi
  fi

  # rc=2 (spec 0019, marker.sh/providers/claude.sh): the provider itself
  # succeeded but produced no valid DECISION marker. Before treating this as
  # an ordinary failure, attempt ONE narrow marker-only recovery — never a
  # repeat of the whole review — when the artifacts already written strongly
  # indicate the decision was reached (marker_recovery.sh's eligibility
  # check). Any other outcome (rc=1 real failure, ineligible artifacts, or a
  # failed corrective attempt) falls through to the existing "stays
  # REVIEWER_RUNNING" behavior unchanged.
  if [ "$rc" -eq 2 ]; then
    specrelay::timeline::finish "$task_dir" reviewer_provider_execution passed
    specrelay::out::log "[reviewer] task '$task_id': provider succeeded but produced no valid decision marker; checking whether artifacts allow narrow marker-only recovery"
    local inferred
    if inferred="$(specrelay::marker_recovery::eligible "$task_dir")"; then
      specrelay::out::log "[reviewer] task '$task_id': attempting the one allowed marker-only corrective attempt (inferred decision: $inferred)"
      if decision="$(specrelay::marker_recovery::attempt "$root" "$task_dir" "$task_id" "$provider" "$model" "$agent")"; then
        rc=0
        specrelay::out::log "[reviewer] task '$task_id': marker-only recovery succeeded (decision: $decision); the full review was NOT repeated"
      else
        specrelay::out::err "[reviewer] task '$task_id': marker-only recovery failed; task stays REVIEWER_RUNNING (no second attempt, no fabricated decision)"
        return 1
      fi
    else
      specrelay::out::err "[reviewer] task '$task_id': marker-only recovery is not safe (artifacts missing/empty/contradictory or no complete decision); task stays REVIEWER_RUNNING"
      return 1
    fi
  elif [ "$rc" -ne 0 ]; then
    specrelay::timeline::finish "$task_dir" reviewer_provider_execution failed
    specrelay::timeline::start "$task_dir" reviewer_marker_recovery reviewer
    specrelay::timeline::finish "$task_dir" reviewer_marker_recovery skipped
    specrelay::out::err "[reviewer] task '$task_id': provider exited non-zero or produced no clear decision; task stays REVIEWER_RUNNING for recovery/resume (spec 0011: no rollback)"
    return 1
  else
    specrelay::timeline::finish "$task_dir" reviewer_provider_execution passed
    # A clean, marker-present decision needed no recovery — record it as
    # SKIPPED (spec 0019 example table) rather than simply absent.
    specrelay::timeline::start "$task_dir" reviewer_marker_recovery reviewer
    specrelay::timeline::finish "$task_dir" reviewer_marker_recovery skipped
  fi

  decision="$(printf '%s\n' "$decision" | tail -n1 | tr -d '[:space:]')"

  # Result card (spec 0013 / spec 0021): the reviewer's completion decision.
  # Printed ONLY after the completion gate (required Reviewer artifacts —
  # spec 0021, "Required Reviewer Artifacts") has actually passed, inside the
  # success branches below — never here, and never before that check — so a
  # card never asserts a decision that the completion gate went on to reject.
  #
  # Re-read the canonical state AFTER the reviewer provider ran. A real
  # reviewer agent runs under `claude --print --dangerously-skip-permissions`
  # and CAN itself enact the accept/request-changes transition (neither is
  # runner-owned), so by the time control returns here the task may already be
  # in the decision's target state. Own the transition state-aware: apply it
  # only when the task is still REVIEWER_RUNNING, and otherwise stop cleanly
  # instead of attempting a second, invalid transition out of an already-final
  # state (spec 0004). This does NOT weaken any guard — transitions.sh still
  # refuses genuinely invalid transitions; the runner simply stops making the
  # redundant call that produced the confusing "Refusing to transition task in
  # state 'READY_FOR_HUMAN_REVIEW'" warning.
  current="$(specrelay::state::canonical "$state_file")"
  specrelay::timeline::start "$task_dir" reviewer_transition reviewer
  case "$decision" in
    ACCEPT)
      case "$current" in
        REVIEWER_RUNNING)
          if ! specrelay::marker::artifacts_consistent "$task_dir" ACCEPT; then
            specrelay::timeline::finish "$task_dir" reviewer_transition failed
            specrelay::agent_efficiency::record_completion_gate "$task_dir" reviewer failed \
              "required Reviewer artifact for ACCEPT is missing or empty (09-consultant-review.md / 10-business-summary.md)"
            return 1
          fi
          if ! specrelay::transitions::accept "$root" "$task_id" "$provider"; then
            specrelay::timeline::finish "$task_dir" reviewer_transition failed
            return 1
          fi
          specrelay::timeline::finish "$task_dir" reviewer_transition passed
          specrelay::agent_efficiency::record_completion_gate "$task_dir" reviewer passed
          specrelay::out::card green "Reviewer Result" "ACCEPT"
          specrelay::out::log "[reviewer] task '$task_id': accepted -> READY_FOR_HUMAN_REVIEW"
          ;;
        READY_FOR_HUMAN_REVIEW)
          specrelay::timeline::finish "$task_dir" reviewer_transition passed
          specrelay::agent_efficiency::record_completion_gate "$task_dir" reviewer passed
          specrelay::out::card green "Reviewer Result" "ACCEPT"
          specrelay::out::log "[reviewer] task '$task_id': already accepted -> READY_FOR_HUMAN_REVIEW (reviewer enacted the transition; runner stops cleanly)"
          ;;
        *)
          specrelay::timeline::finish "$task_dir" reviewer_transition failed
          specrelay::out::err "[reviewer] task '$task_id': reviewer decided ACCEPT but task is in unexpected state '$current'; refusing to transition"
          return 1
          ;;
      esac
      ;;
    REQUEST_CHANGES)
      case "$current" in
        REVIEWER_RUNNING)
          if ! specrelay::marker::artifacts_consistent "$task_dir" REQUEST_CHANGES; then
            specrelay::timeline::finish "$task_dir" reviewer_transition failed
            specrelay::agent_efficiency::record_completion_gate "$task_dir" reviewer failed \
              "required Reviewer artifact for REQUEST_CHANGES is missing or empty (09-consultant-review.md / 11-next-executor-prompt.md)"
            return 1
          fi
          local reason
          reason="$(head -c 500 "$task_dir/09-consultant-review.md" 2>/dev/null)"
          [ -n "$reason" ] || reason="changes requested"
          if ! specrelay::transitions::request_changes "$root" "$task_id" "$reason" "$provider"; then
            specrelay::timeline::finish "$task_dir" reviewer_transition failed
            return 1
          fi
          specrelay::timeline::finish "$task_dir" reviewer_transition passed
          specrelay::agent_efficiency::record_completion_gate "$task_dir" reviewer passed
          specrelay::out::card yellow "Reviewer Result" "REQUEST_CHANGES"
          specrelay::out::log "[reviewer] task '$task_id': changes requested -> CHANGES_REQUESTED"
          ;;
        CHANGES_REQUESTED)
          specrelay::timeline::finish "$task_dir" reviewer_transition passed
          specrelay::agent_efficiency::record_completion_gate "$task_dir" reviewer passed
          specrelay::out::card yellow "Reviewer Result" "REQUEST_CHANGES"
          specrelay::out::log "[reviewer] task '$task_id': changes already requested -> CHANGES_REQUESTED (reviewer enacted the transition; runner stops cleanly)"
          ;;
        *)
          specrelay::timeline::finish "$task_dir" reviewer_transition failed
          specrelay::out::err "[reviewer] task '$task_id': reviewer decided REQUEST_CHANGES but task is in unexpected state '$current'; refusing to transition"
          return 1
          ;;
      esac
      ;;
    *)
      specrelay::timeline::finish "$task_dir" reviewer_transition failed
      specrelay::out::err "[reviewer] task '$task_id': unrecognized decision '$decision'; refusing to transition"
      return 1
      ;;
  esac
  return 0
}

# --- the shared executor<->reviewer automation loop (spec 0010) -------------

# specrelay::workflow::drive <project-root> <task-id>
# The single automation loop shared by BOTH `specrelay run <spec>` and
# `specrelay resume <task>`. Given a task whose state.json already exists, it
# repeatedly dispatches the one safe next step for the current state until a
# terminal or explicit-stop state is reached. This is what makes automated
# reviewer continuation work (spec 0010): after the executor submits and the
# task becomes READY_FOR_REVIEW, the SAME invocation runs the reviewer instead
# of leaving the operator to start it by hand.
#
# It NEVER stops silently at READY_FOR_REVIEW. `READY_FOR_REVIEW` is an internal
# handoff state for automated review; the loop only rests there when the
# effective reviewer provider is 'manual' (an explicit opt-out) or the automated
# reviewer fails/is unavailable — and in both cases it logs an explicit reason
# (spec 0010, section 4). The normal successful path continues through the
# reviewer to `READY_FOR_HUMAN_REVIEW` in the same invocation.
#
# Exit codes (spec section 54):
#   0  reached READY_FOR_HUMAN_REVIEW
#   1  usage/config/lookup error (or the internal safety limit — an engine bug)
#   2  reviewer provider is 'manual' — automated loop stops; human action required
#   3  task is BLOCKED
#   4  provider (executor or reviewer) failure — task remains READY_FOR_REVIEW
#   5  maximum iterations reached without acceptance
specrelay::workflow::drive() {
  local root="$1" task_id="$2" task_dir state_file
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"

  local max_iter safety_limit safety_count current rc
  max_iter="$(specrelay::workflow::max_iterations "$root")"
  case "$max_iter" in ''|*[!0-9]*) max_iter=3 ;; esac
  safety_limit=$((max_iter * 2 + 6))
  safety_count=0
  rc=0

  while :; do
    safety_count=$((safety_count + 1))
    if [ "$safety_count" -gt "$safety_limit" ]; then
      specrelay::out::err "[specrelay] internal safety limit reached without a terminal state; stopping (this indicates an engine bug, not a normal outcome)"
      rc=1
      break
    fi

    current="$(specrelay::state::canonical "$state_file")"
    case "$current" in
      READY_FOR_HUMAN_REVIEW)
        specrelay::out::log "[specrelay] task '$task_id' reached READY_FOR_HUMAN_REVIEW."
        # Final summary card (spec 0013): the terminal task result.
        specrelay::out::card green "SpecRelay Result" "READY_FOR_HUMAN_REVIEW"
        rc=0
        break
        ;;
      BLOCKED)
        specrelay::out::err "[specrelay] task '$task_id' is BLOCKED."
        # Final summary card (spec 0013): the terminal task result.
        specrelay::out::card red "SpecRelay Result" "BLOCKED"
        rc=3
        break
        ;;
      READY_FOR_EXECUTOR)
        local iteration
        iteration="$(specrelay::state::get "$state_file" "iteration" 2>/dev/null || true)"
        [ -n "$iteration" ] || iteration=1
        if [ "$iteration" -gt "$max_iter" ] 2>/dev/null; then
          specrelay::out::err "[specrelay] task '$task_id' reached the maximum of $max_iter iteration(s) without acceptance."
          rc=5
          break
        fi
        if ! specrelay::workflow::executor_iteration "$root" "$task_id"; then
          rc=4
          break
        fi
        ;;
      CHANGES_REQUESTED)
        specrelay::out::log "[specrelay] requeuing task '$task_id' for its next iteration"
        if ! specrelay::transitions::requeue "$root" "$task_id"; then
          rc=1
          break
        fi
        ;;
      READY_FOR_REVIEW|REVIEWER_RUNNING)
        # Both the initial handoff (READY_FOR_REVIEW) and an interrupted
        # automated review (REVIEWER_RUNNING — spec 0011) are driven by the same
        # reviewer iteration: it enters REVIEWER_RUNNING when needed, executes
        # the reviewer, and transitions to the decision state. Resuming a task
        # left in REVIEWER_RUNNING continues the review from there (no rollback).
        specrelay::workflow::reviewer_iteration "$root" "$task_id"
        rc=$?
        case "$rc" in
          0) rc=0 ;;
          2)
            specrelay::out::log "[reviewer] reviewer provider is 'manual'; stopping at READY_FOR_REVIEW for human review. Run 'specrelay task accept' or 'specrelay task request-changes' when ready."
            break
            ;;
          *)
            local failed_state
            failed_state="$(specrelay::state::canonical "$state_file")"
            specrelay::out::err "[reviewer] automated reviewer failed; task remains ${failed_state:-READY_FOR_REVIEW} for recovery/resume."
            rc=4
            break
            ;;
        esac
        ;;
      *)
        specrelay::out::err "[specrelay] task '$task_id' has state '$current' with no safe automated step."
        rc=1
        break
        ;;
    esac
  done

  return "$rc"
}

# specrelay::workflow::assert_engine_compat <state-file>
# Resume/version safety (SDD 0087, sections 30/32/33). Compares the engine
# version recorded in a task's state.json with the engine version now trying
# to act on it, and refuses an UNSAFE cross-version action rather than
# silently resuming old task state with an incompatible engine.
#
# Compatibility policy (see docs/versioning.md):
#   * No recorded engine_version (historical task) -> allowed (nothing to
#     compare against).
#   * Same MAJOR version -> compatible (minor/patch are backward compatible).
#   * Different MAJOR version -> UNSAFE; refuse.
#   * A task recorded with a NEWER engine than the one running now -> UNSAFE
#     (a downgraded engine cannot safely resume newer task state); refuse.
# An explicit, per-invocation override (SPECRELAY_ALLOW_ENGINE_MISMATCH=1)
# exists for deliberate human recovery; it is never the default and always
# logs that it was used.
# --- execution timeline: invocation lifecycle + final report (spec 0019) ----

# specrelay::workflow::_report_mode <exit-code>
# "final" when the task reached a genuinely terminal-for-now outcome
# (READY_FOR_HUMAN_REVIEW, BLOCKED, or the max-iterations stop); "partial"
# for every other exit (manual-reviewer stop, a provider failure leaving the
# task recoverable, or an internal safety-limit/usage error) — spec 0019,
# "Terminal and Non-Terminal Reports".
specrelay::workflow::_report_mode() {
  case "$1" in
    0|3|5) printf 'final\n' ;;
    *) printf 'partial\n' ;;
  esac
}

# specrelay::workflow::_finalize_invocation <root> <task-id> <invocation-id> <exit-code>
# Times the `finalization` phase, closes out the invocation record, and
# prints the (final or partial) execution-timeline report. Never mutates
# task state; a missing python3/timeline module degrades to a silent no-op
# (instrumentation must never break the workflow it observes).
specrelay::workflow::_finalize_invocation() {
  local root="$1" task_id="$2" invocation_id="$3" rc="$4" task_dir state_file final_state mode
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"
  final_state="$(specrelay::state::canonical "$state_file" 2>/dev/null || true)"
  [ -n "$final_state" ] || final_state="unknown"

  # finalization is timed and closed out BEFORE the report is rendered: the
  # report is a read-only snapshot of the event log, so it can never include
  # its own still-open "finalization" phase — closing it first is what makes
  # the printed/derived report show finalization as a complete, non-empty
  # entry rather than a self-referential "interrupted" one.
  specrelay::timeline::start "$task_dir" finalization
  specrelay::timeline::invocation_finish "$task_dir" "$invocation_id" "$final_state" "$rc"
  specrelay::timeline::finish "$task_dir" finalization passed

  mode="$(specrelay::workflow::_report_mode "$rc")"
  specrelay::timeline::render "$root" "$task_dir" "$task_id" "$mode"

  # Command-timing ledger (spec 0020): rendered AFTER the execution timeline,
  # exactly matching the spec's "Terminal Report" ("print a compact section
  # after the execution timeline"). Writes 21-command-timings.json (a no-op,
  # honest degrade when no command-timing events were ever recorded for this
  # task — e.g. the fake provider, or a run that used the generic streaming
  # fallback with no renderer).
  specrelay::command_timing::render "$task_dir" "$task_id" "$mode"

  # Agent-efficiency report (spec 0021, "Terminal Output"): rendered AFTER
  # the command-timing ledger, exactly matching the spec's own ordering
  # ("Agent Efficiency" section follows the execution timeline/command
  # timing). Writes 22-agent-efficiency.json (a no-op, honest degrade when
  # this task recorded no completion-gate result and no command-timing
  # events at all — e.g. the fake provider without any recorded gate, or a
  # legacy task).
  specrelay::agent_efficiency::render "$task_dir" "$task_id" "$mode"
}

specrelay::workflow::assert_engine_compat() {
  local state_file="$1" task_ev cur_ev
  [ -f "$state_file" ] || return 0
  task_ev="$(specrelay::state::get "$state_file" "engine_version" 2>/dev/null || true)"
  if [ -z "$task_ev" ] || [ "$task_ev" = "null" ]; then
    return 0
  fi
  cur_ev=""
  if [ -n "${SPECRELAY_HOME:-}" ] && [ -f "$SPECRELAY_HOME/VERSION" ]; then
    cur_ev="$(tr -d '[:space:]' < "$SPECRELAY_HOME/VERSION")"
  fi
  [ -n "$cur_ev" ] || return 0
  [ "$task_ev" = "$cur_ev" ] && return 0

  local task_major cur_major smaller unsafe=0 reason=""
  task_major="${task_ev%%.*}"
  cur_major="${cur_ev%%.*}"
  if [ "$task_major" != "$cur_major" ]; then
    unsafe=1; reason="different major version"
  else
    smaller="$(printf '%s\n%s\n' "$task_ev" "$cur_ev" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)"
    if [ "$smaller" = "$cur_ev" ]; then
      unsafe=1; reason="task was created by a NEWER engine ($task_ev) than the one running now ($cur_ev)"
    fi
  fi

  if [ "$unsafe" -eq 1 ]; then
    if [ "${SPECRELAY_ALLOW_ENGINE_MISMATCH:-}" = "1" ]; then
      specrelay::out::err "[specrelay] WARNING: resuming across incompatible engine versions ($reason) because SPECRELAY_ALLOW_ENGINE_MISMATCH=1 was set."
      return 0
    fi
    specrelay::out::err "[specrelay] refusing to resume task: incompatible engine version ($reason)."
    specrelay::out::err "  task engine_version: $task_ev"
    specrelay::out::err "  running engine:      $cur_ev"
    specrelay::out::err "  Install the matching engine version, or set SPECRELAY_ALLOW_ENGINE_MISMATCH=1 to override deliberately."
    return 1
  fi
  return 0
}

# specrelay::workflow::assert_schema_compat <state-file>
# state.json schema compatibility guard (spec 0005, section 4). Complements the
# engine-version guard above: it compares the SCHEMA version recorded in a
# task's state.json with the schema version this engine writes for new tasks,
# and refuses to mutate a task written by an UNKNOWN FUTURE schema rather than
# silently resuming state it may not fully understand.
#
# Compatibility policy (see docs/versioning.md):
#   * No recorded schema_version (historical task) -> allowed (implicit v1).
#   * schema_version <= current -> allowed (schema is additive within a major
#     engine version; older/current shapes still read).
#   * schema_version > current  -> UNSAFE (written by a newer engine's schema);
#     refuse the mutating action.
# The per-invocation override SPECRELAY_ALLOW_SCHEMA_MISMATCH=1 exists for
# deliberate human recovery; it is never the default and always logs its use.
# Read-only inspection (show/status/list) never calls this — only mutating
# resume/run.
specrelay::workflow::assert_schema_compat() {
  local state_file="$1" task_sv cur_sv
  [ -f "$state_file" ] || return 0
  task_sv="$(specrelay::state::get "$state_file" "schema_version" 2>/dev/null || true)"
  if [ -z "$task_sv" ] || [ "$task_sv" = "null" ]; then
    return 0
  fi
  # A non-integer schema_version is unreadable metadata, not a safe resume.
  case "$task_sv" in
    ''|*[!0-9]*)
      specrelay::out::err "[specrelay] refusing to resume task: unreadable schema_version '$task_sv' in state.json."
      specrelay::out::err "  Inspect it read-only with 'specrelay task show', then recover deliberately."
      return 1
      ;;
  esac
  cur_sv="$(specrelay::state::current_schema_version 2>/dev/null || true)"
  [ -n "$cur_sv" ] || return 0
  if [ "$task_sv" -le "$cur_sv" ]; then
    return 0
  fi

  if [ "${SPECRELAY_ALLOW_SCHEMA_MISMATCH:-}" = "1" ]; then
    specrelay::out::err "[specrelay] WARNING: resuming a task written by a newer state schema (task schema_version=$task_sv, this engine writes $cur_sv) because SPECRELAY_ALLOW_SCHEMA_MISMATCH=1 was set."
    return 0
  fi
  specrelay::out::err "[specrelay] refusing to resume task: incompatible state schema (task was written by a newer engine)."
  specrelay::out::err "  task schema_version: $task_sv"
  specrelay::out::err "  this engine writes:  $cur_sv"
  specrelay::out::err "  Install a newer SpecRelay engine, or set SPECRELAY_ALLOW_SCHEMA_MISMATCH=1 to override deliberately."
  return 1
}

# --- resume (spec section 39) -----------------------------------------------

# specrelay::workflow::resume <project-root> <task-id>
# Resumes an existing task from its persisted state and drives the shared
# executor<->reviewer automation loop (specrelay::workflow::drive) to the next
# terminal or explicit-stop state — it never blindly restarts a task from the
# beginning. Because it uses the same loop as `specrelay run`, resuming an
# automated-reviewer task continues from READY_FOR_REVIEW into reviewer
# execution in the SAME invocation and reaches READY_FOR_HUMAN_REVIEW without a
# second manual `resume` (spec 0010). It shares `run`'s exit-code contract.
specrelay::workflow::resume() {
  local root="$1" task_id="$2" task_dir
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  if [ ! -d "$task_dir" ]; then
    specrelay::out::err "task not found: $task_dir"
    return 1
  fi

  # Level 1 (spec 0013): the major execution-section banner for this resume.
  local resume_spec
  resume_spec="$(specrelay::state::get "$(specrelay::state::path "$task_dir")" spec_source 2>/dev/null || true)"
  specrelay::out::card blue "SpecRelay Task" "Task $task_id" "Spec ${resume_spec:-(resumed)}"

  if ! specrelay::workflow::assert_engine_compat "$(specrelay::state::path "$task_dir")"; then
    return 1
  fi
  if ! specrelay::workflow::assert_schema_compat "$(specrelay::state::path "$task_dir")"; then
    return 1
  fi
  if ! specrelay::lock::acquire "$root" "$task_id"; then
    return 1
  fi

  local invocation_id initial_state
  invocation_id="$(specrelay::timeline::next_invocation_id "$task_dir")"
  initial_state="$(specrelay::state::canonical "$(specrelay::state::path "$task_dir")" 2>/dev/null || true)"
  specrelay::timeline::invocation_start "$task_dir" "$invocation_id" "${initial_state:-unknown}"

  specrelay::workflow::drive "$root" "$task_id"
  local rc=$?
  specrelay::workflow::_finalize_invocation "$root" "$task_id" "$invocation_id" "$rc"
  specrelay::lock::release "$root" "$task_id"
  return "$rc"
}

# --- full lifecycle: `specrelay run <spec>` ---------------------------------
#
# Exit codes (spec section 54):
#   0  reached READY_FOR_HUMAN_REVIEW
#   1  usage/config/lookup error
#   2  a reviewer provider is 'manual' — automated loop stops; human action required
#   3  task is BLOCKED
#   4  provider (executor or reviewer) failure
#   5  maximum iterations reached without acceptance

# specrelay::workflow::run <project-root> <spec-arg> [task-id-override] [allow-dirty(0|1)]
specrelay::workflow::run() {
  local root="$1" spec_arg="$2" task_id_override="${3:-}" allow_dirty="${4:-0}"
  local spec_abs spec_rel task_id task_dir

  spec_abs="$(specrelay::task::resolve_spec_path "$root" "$spec_arg")" || return 1
  spec_rel="${spec_abs#"$root"/}"

  if [ -n "$task_id_override" ]; then
    task_id="$task_id_override"
  else
    task_id="$(specrelay::task::id_from_spec_path "$spec_abs")"
  fi
  if ! specrelay::task::valid_id "$task_id"; then
    specrelay::out::err "could not derive a safe task id from spec path: $spec_arg"
    return 1
  fi

  task_dir="$(specrelay::task::dir "$root" "$task_id")"

  # Level 1 (spec 0013): the major execution-section banner for this run.
  specrelay::out::card blue "SpecRelay Task" "Task $task_id" "Spec $spec_rel"

  if ! specrelay::lock::acquire "$root" "$task_id"; then
    return 1
  fi

  # Invocation/phase timing (spec 0019) is recorded ONLY once the task
  # directory legitimately exists — never before: a brand-new task's
  # directory does not exist yet at this point, and specrelay::transitions::create
  # below refuses if it already does. Timeline instrumentation must never be
  # the thing that creates it (that would corrupt the exists-check).
  local invocation_id was_new=0
  invocation_id="$(specrelay::timeline::next_invocation_id "$task_dir")"

  if [ ! -d "$task_dir" ]; then
    was_new=1
    specrelay::out::log "[specrelay] creating task '$task_id' from spec: $spec_rel"
    if ! specrelay::transitions::create "$root" "$task_id" "$spec_rel" "$allow_dirty"; then
      specrelay::lock::release "$root" "$task_id"
      return 1
    fi
    specrelay::workflow::seed_task_from_spec "$root" "$task_id" "$spec_abs"
    specrelay::timeline::invocation_start "$task_dir" "$invocation_id" DRAFT
    specrelay::timeline::start "$task_dir" task_initialization
    specrelay::timeline::finish "$task_dir" task_initialization passed
  else
    specrelay::out::log "[specrelay] resuming existing task '$task_id'"
    specrelay::timeline::invocation_start "$task_dir" "$invocation_id" \
      "$(specrelay::state::canonical "$(specrelay::state::path "$task_dir")" 2>/dev/null || echo unknown)"
    specrelay::timeline::start "$task_dir" task_initialization
    if ! specrelay::workflow::assert_engine_compat "$(specrelay::state::path "$task_dir")"; then
      specrelay::timeline::finish "$task_dir" task_initialization failed
      specrelay::lock::release "$root" "$task_id"
      return 1
    fi
    if ! specrelay::workflow::assert_schema_compat "$(specrelay::state::path "$task_dir")"; then
      specrelay::timeline::finish "$task_dir" task_initialization failed
      specrelay::lock::release "$root" "$task_id"
      return 1
    fi
    specrelay::timeline::finish "$task_dir" task_initialization passed
  fi

  local state_file current
  state_file="$(specrelay::state::path "$task_dir")"

  # --allow-dirty-baseline is an explicit, per-invocation human override; it
  # applies even when resuming an already-created task (the human is
  # providing it right now, not only at the moment of creation).
  if [ "$allow_dirty" = "1" ]; then
    specrelay::state::set "$state_file" '{"allow_pre_existing_dirty": true}' >/dev/null
  fi

  current="$(specrelay::state::canonical "$state_file")"

  case "$current" in
    DRAFT|WAITING_FOR_HUMAN)
      specrelay::out::log "[specrelay] approving task '$task_id' (this 'specrelay run' invocation IS the human approval — see docs/engine-parity.md, 'Approval semantics')"
      specrelay::timeline::start "$task_dir" task_approval
      if ! specrelay::transitions::approve "$root" "$task_id"; then
        specrelay::timeline::finish "$task_dir" task_approval failed
        specrelay::workflow::_finalize_invocation "$root" "$task_id" "$invocation_id" 1
        specrelay::lock::release "$root" "$task_id"
        return 1
      fi
      specrelay::timeline::finish "$task_dir" task_approval passed
      ;;
  esac

  # Drive the shared executor<->reviewer automation loop to a terminal or
  # explicit-stop state. This is the SAME loop `specrelay resume` uses, so both
  # commands continue automated reviewer execution identically (spec 0010).
  local rc
  specrelay::workflow::drive "$root" "$task_id"
  rc=$?

  specrelay::workflow::_finalize_invocation "$root" "$task_id" "$invocation_id" "$rc"
  specrelay::lock::release "$root" "$task_id"
  return "$rc"
}
