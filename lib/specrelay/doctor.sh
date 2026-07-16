#!/usr/bin/env bash
# doctor.sh — `specrelay doctor`: read-only readiness diagnostics (spec
# sections 17 and 55).
#
# Every check here is READ-ONLY: it inspects the filesystem, PATH, and
# .specrelay/config.yml, and never mutates any task or repository state.
# Prints a ✓/✗ line per check and returns non-zero if any MANDATORY check
# failed (spec: "Return non-zero if mandatory readiness checks fail").

specrelay::doctor::_ok() {
  printf '\xe2\x9c\x93 %s\n' "$1"
}

specrelay::doctor::_fail() {
  printf '\xe2\x9c\x97 %s\n' "$1"
  DOCTOR_FAILED=1
}

specrelay::doctor::_info() {
  printf '\xe2\x9c\x93 %s\n' "$1"
}

# Advisory warning: printed with a warning glyph but does NOT set
# DOCTOR_FAILED, so it never turns a passing `doctor` run non-zero (spec 0002
# acceptance criterion 3: "reports only intentional, documented warnings").
specrelay::doctor::_warn() {
  printf '\xe2\x9a\xa0 %s\n' "$1"
}

# specrelay::doctor::_provider_unavailable <message>
# Report that a CONFIGURED provider's CLI is absent. By default this is a
# mandatory failure: a project that selected the `claude` provider genuinely
# needs the Claude CLI, and hiding that would be dishonest. When
# SPECRELAY_PROVIDER_OPTIONAL=1 the same condition is downgraded to an advisory
# WARNING instead (spec 0007, section 2): this distinguishes required CORE
# dependencies (git, project root, config, spec root, task-runtime root — still
# mandatory here regardless) from OPTIONAL provider availability, so an
# environment that intentionally does not install the optional provider CLI —
# notably CI, which must not require a real Claude installation — gets a
# deterministic, documented, non-failing result. It never ignores exit codes
# and never affects the core checks, so real core failures are never hidden.
specrelay::doctor::_provider_unavailable() {
  if [ "${SPECRELAY_PROVIDER_OPTIONAL:-0}" = "1" ]; then
    specrelay::doctor::_warn "$1 (optional provider treated as advisory: SPECRELAY_PROVIDER_OPTIONAL=1)"
  else
    specrelay::doctor::_fail "$1"
  fi
}

# specrelay::doctor::_role_model_source <Role-label> <model>
# Read-only (spec 0012, "Doctor Command"): report whether the role's effective
# model is an EXPLICIT provider-specific model id or the `provider-default`
# sentinel, so an operator can tell at a glance whether SpecRelay will request a
# specific model or delegate model selection to the provider CLI. This never
# performs a billable model invocation and never claims a model is "available".
specrelay::doctor::_role_model_source() {
  local role="$1" model="$2"
  if [ "$model" = "provider-default" ]; then
    specrelay::doctor::_info "$role model source: provider-default (delegated to the provider CLI; SpecRelay passes no explicit model-selection argument)"
  else
    specrelay::doctor::_info "$role model source: explicit model '$model' (SpecRelay will request this exact model; the provider CLI validates that it exists)"
  fi
}

# specrelay::doctor::_role_model_support <Role-label> <normalized-provider> <model>
# Read-only advisory (spec 0009, "Doctor"): when an EXPLICIT model is configured
# for a Claude role (anything other than the `provider-default` sentinel), report
# whether the installed Claude CLI can actually accept a model. If the CLI does
# not advertise a `--model` flag, warn clearly — the run would fail rather than
# silently ignore the model. Only checked when the CLI is present (help cannot be
# inspected otherwise) and the provider is `claude`; a no-op for other providers,
# for `provider-default`, or for an absent CLI (already reported above).
specrelay::doctor::_role_model_support() {
  local role="$1" provider="$2" model="$3" bin
  [ "$model" != "provider-default" ] || return 0
  [ "$provider" = "claude" ] || return 0
  bin="$(specrelay::provider::claude::_bin)"
  command -v "$bin" >/dev/null 2>&1 || return 0
  if specrelay::provider::claude::_model_supported "$bin"; then
    specrelay::doctor::_info "$role model '$model': the Claude CLI advertises --model (an explicit model can be passed)"
  else
    specrelay::doctor::_warn "$role model '$model' is configured but the Claude CLI ('$bin') does not advertise a --model flag; the run will fail rather than silently ignore the configured model. Use model: provider-default, or install a CLI that supports model selection."
  fi
}

# specrelay::doctor::_role_model_selection <Role-label> <root> <role>
# Read-only (spec 0014, "Doctor Integration"): reports, for one role, the
# provider, the CONFIGURED model selection (canonical kind:value form), the
# RESOLVED model value, the selection kind, the validation level, and the
# configuration source. Never performs a billable invocation and never claims
# account availability unless the provider supports reliable non-billable
# discovery (the validation label is honest about what was actually checked).
# A structurally malformed or KNOWN-invalid selection is a mandatory failure —
# every run with this configuration would refuse before role execution.
specrelay::doctor::_role_model_selection() {
  local role_label="$1" root="$2" role="$3"
  local raw_provider provider selection kind resolved label source env_name env_val detail

  raw_provider="$(specrelay::workflow::role_raw_provider "$root" "$role")"
  if [ "$raw_provider" = "manual" ]; then
    specrelay::doctor::_info "$role_label model selection: not applicable (manual role — a human decides; model fields are ignored and never executed)"
    return 0
  fi

  if ! selection="$(specrelay::workflow::role_model_selection "$root" "$role" 2>/dev/null)"; then
    detail="$(specrelay::config::role_model_selection "$root" "$role" 2>/dev/null || true)"
    specrelay::doctor::_fail "$role_label model selection: INVALID — $detail (source: $(specrelay::config::path "$root"))"
    return 0
  fi

  provider="$(specrelay::workflow::role_provider "$root" "$role")"
  if ! specrelay::capability::validate_selection "$provider" "$role" "$selection" >/dev/null 2>&1; then
    specrelay::doctor::_fail "$role_label model selection: KNOWN-INVALID — configured=$selection is not valid for provider '$provider'; run 'specrelay models $raw_provider' for valid forms and aliases"
    return 0
  fi

  kind="$(specrelay::capability::selection_kind "$selection")"
  resolved="$(specrelay::capability::resolved_display "$provider" "$selection" || true)"
  label="$(specrelay::capability::validation_label "$provider" "$selection")"

  env_name="$(specrelay::workflow::_role_env "$role" MODEL)"
  env_val=""
  [ -n "$env_name" ] && env_val="${!env_name:-}"
  if [ -n "$env_val" ]; then
    source="\$$env_name (environment override)"
  elif [ -n "$(specrelay::config::get "$root" "roles.$role.model" "")" ]; then
    source="$(specrelay::config::path "$root")"
  else
    source="(built-in default)"
  fi

  specrelay::doctor::_info "$role_label model selection: provider=$provider kind=$kind configured=$selection resolved=$resolved source=$source validation=$label"
}

# specrelay::doctor::_role_context <Role-label> <root> <role>
# Read-only (spec 0015, "Doctor Integration"): reports one role's context
# configuration through the adapter capability contract — configured adapter,
# required policy, availability, capability level, and network requirement.
# Known-invalid configuration (structural errors, an unknown adapter, an
# unsupported role/adapter combination) is a MANDATORY failure: every run
# with this configuration would refuse before role execution. Availability is
# an honest, local, non-billable check; doctor never runs a preflight,
# never prepares context, and never mutates task state.
specrelay::doctor::_role_context() {
  local role_label="$1" root="$2" role="$3" parsed adapter required
  local avail_out avail reason level network readiness_out

  if ! parsed="$(specrelay::config::role_context "$root" "$role")"; then
    specrelay::doctor::_fail "$role_label context: INVALID configuration — $parsed (source: $(specrelay::config::path "$root"); inspect adapters with 'specrelay contexts')"
    return 0
  fi
  adapter="$(printf '%s\n' "$parsed" | sed -n 's/^adapter=//p')"
  required="$(printf '%s\n' "$parsed" | sed -n 's/^required=//p')"

  if ! specrelay::context::known "$adapter"; then
    specrelay::doctor::_fail "$role_label context: unknown adapter '$adapter' (known: $(specrelay::context::adapters | tr '\n' ' ' | sed 's/ $//'); inspect with 'specrelay contexts')"
    return 0
  fi
  if ! specrelay::context::role_supported "$adapter" "$role"; then
    specrelay::doctor::_fail "$role_label context: adapter '$adapter' does not support the $role role"
    return 0
  fi

  # Adapters with a richer structured readiness inspection (spec 0018) get a
  # detailed, honest report — installed/registered/connected/config source —
  # instead of the plain available/unavailable line below. Still entirely
  # read-only: runtime_readiness never runs the bounded retrieval and never
  # mutates MCP configuration.
  if readiness_out="$(specrelay::context::runtime_readiness "$adapter" "$root" 2>/dev/null)"; then
    specrelay::doctor::_render_context_readiness "$role_label" "$adapter" "$required" "$readiness_out"
    return 0
  fi

  level="$(specrelay::context::capability_level "$adapter")"
  network="$(specrelay::context::capability "$adapter" network)"
  avail_out="$(specrelay::context::availability "$adapter" "$root")"
  avail="$(printf '%s\n' "$avail_out" | sed -n '1p')"
  reason="$(printf '%s\n' "$avail_out" | sed -n '2p')"

  if [ "$avail" = "available" ]; then
    specrelay::doctor::_info "$role_label context: adapter=$adapter required=$required availability=available level=$level network=$network validation=valid"
  elif [ "$required" = "true" ]; then
    specrelay::doctor::_fail "$role_label context: adapter=$adapter required=true availability=unavailable (${reason:-reason unknown}) — a required run would refuse before role execution"
  else
    specrelay::doctor::_warn "$role_label context: adapter=$adapter required=false availability=unavailable (${reason:-reason unknown}) — runs will degrade honestly without external context"
  fi
}

# specrelay::doctor::_render_context_readiness <Role-label> <adapter> <required> <readiness-blob>
# Read-only (spec 0018, "Doctor Integration"): reports installed/registered/
# connected/configuration-source honestly for an adapter with a structured
# readiness inspection, then applies the SAME required/optional policy as
# every other doctor check (required unready -> failure; optional unready ->
# advisory warning). Never runs the bounded retrieval and never mutates MCP
# configuration.
specrelay::doctor::_render_context_readiness() {
  local role_label="$1" adapter="$2" required="$3" blob="$4"
  local status installed registered connected selected reason bin

  status="$(printf '%s\n' "$blob" | sed -n 's/^status=//p')"
  installed="$(printf '%s\n' "$blob" | sed -n 's/^installed=//p')"
  registered="$(printf '%s\n' "$blob" | sed -n 's/^registered=//p')"
  connected="$(printf '%s\n' "$blob" | sed -n 's/^connected=//p')"
  selected="$(printf '%s\n' "$blob" | sed -n 's/^selected_source=//p')"
  reason="$(printf '%s\n' "$blob" | sed -n 's/^reason=//p')"
  bin="$(printf '%s\n' "$blob" | sed -n 's/^bin=//p')"

  specrelay::doctor::_info "$role_label context adapter: $adapter"

  if [ "$installed" = "yes" ]; then
    specrelay::doctor::_ok "$role_label context executable: $bin found"
  else
    specrelay::doctor::_provider_unavailable "$role_label context executable: $bin not found"
  fi

  if [ "$registered" = "yes" ]; then
    specrelay::doctor::_ok "$role_label context MCP registration: $adapter registered"
  else
    specrelay::doctor::_info "$role_label context MCP registration: $adapter not registered"
  fi

  if [ "$registered" = "yes" ]; then
    if [ "$connected" = "yes" ]; then
      specrelay::doctor::_ok "$role_label context MCP connection: connected"
    else
      specrelay::doctor::_info "$role_label context MCP connection: not connected"
    fi
  fi

  specrelay::doctor::_info "$role_label context configuration source: $([ "$selected" = "project" ] && echo "project .mcp.json" || echo none)"

  if [ "$status" = "ready" ]; then
    specrelay::doctor::_ok "$role_label context readiness: ready"
  elif [ "$required" = "true" ]; then
    specrelay::doctor::_fail "$role_label context readiness: $status (${reason:-not ready}) — a required run would refuse before role execution"
  else
    specrelay::doctor::_warn "$role_label context readiness: $status (${reason:-not ready}) — runs will degrade honestly without external context"
  fi
}

# specrelay::doctor::_jam <root>
# Read-only Jam readiness report (spec 0023, section 18.3). Never runs
# retrieval. Jam is globally optional: absence only fails overall doctor
# readiness when a project explicitly sets jam.required: true.
specrelay::doctor::_jam() {
  local root="$1" out status reason global_required
  out="$(specrelay::jam::readiness "$root")"
  status="$(printf '%s\n' "$out" | sed -n 's/^status=//p')"
  reason="$(printf '%s\n' "$out" | sed -n 's/^reason=//p')"
  global_required="$(specrelay::jam::global_required "$root")"

  specrelay::doctor::_info "Jam capability status: $status ($reason)"
  specrelay::doctor::_info "Jam configured: $(printf '%s\n' "$out" | sed -n 's/^configured=//p')  registered: $(printf '%s\n' "$out" | sed -n 's/^registered=//p')  connected: $(printf '%s\n' "$out" | sed -n 's/^connected=//p')  authenticated: $(printf '%s\n' "$out" | sed -n 's/^authenticated=//p')  tools available: $(printf '%s\n' "$out" | sed -n 's/^tools_available=//p')"

  if [ "$status" = "ready" ]; then
    specrelay::doctor::_ok "Jam readiness: ready"
  elif [ "$global_required" = "true" ]; then
    specrelay::doctor::_fail "Jam readiness: $status — jam.required is true for this project"
  else
    specrelay::doctor::_warn "Jam readiness: $status — Jam is globally optional; a task referencing a Jam recording will block its own preflight instead"
  fi
}

# specrelay::doctor::_hook_has_nonascii_shell_punct <hook-file>
# Returns 0 (true) if the given hook file contains non-ASCII shell punctuation
# that is DANGEROUS in a shell command (spec 0002): a Unicode en/em dash used
# as an option prefix (e.g. `git rev-parse ‑abbrev-ref`), or a smart quote
# adjacent to a shell command (sed/grep/git/awk) — the exact classes that
# produce the `fatal: ambiguous argument` / `grep: illegal byte sequence` /
# `sed: invalid command code` noise. Deliberately narrow (dangerous patterns
# only, not any non-ASCII) so legitimate prose — em/en dashes and quotes in a
# hook's comments — does not trigger a false positive (see the "Scope of the
# doctor check" human decision in spec 0002). LC_ALL=C makes grep operate on
# raw bytes and avoids the illegal-byte-sequence failure itself; matching is
# done with portable ERE (no `grep -P`, which BSD/macOS grep lacks).
specrelay::doctor::_hook_has_nonascii_shell_punct() {
  local hook="$1"
  [ -f "$hook" ] || return 1
  local endash emdash ldq rdq lsq rsq
  endash="$(printf '\xe2\x80\x93')"   # U+2013 en dash
  emdash="$(printf '\xe2\x80\x94')"   # U+2014 em dash
  ldq="$(printf '\xe2\x80\x9c')"      # U+201C left double quote
  rdq="$(printf '\xe2\x80\x9d')"      # U+201D right double quote
  lsq="$(printf '\xe2\x80\x98')"      # U+2018 left single quote
  rsq="$(printf '\xe2\x80\x99')"      # U+2019 right single quote
  # Dash-as-option-prefix: en/em dash immediately followed by a letter.
  if LC_ALL=C grep -Eq "(${endash}|${emdash})[A-Za-z]" "$hook" 2>/dev/null; then
    return 0
  fi
  # Smart quote within a short span of a shell command word.
  if LC_ALL=C grep -Eq "(sed|grep|git|awk).{0,40}(${ldq}|${rdq}|${lsq}|${rsq})" "$hook" 2>/dev/null; then
    return 0
  fi
  return 1
}

# specrelay::doctor::_ai_reviewer_status <root> <specrelay-home>
# Read-only (spec 0019, "AI Reviewer Template Installation"): distinguishes
# template available / project reviewer installed / project reviewer missing
# / project reviewer customized (differs from the bundled template — never a
# failure, just an honest note that 'specrelay init' will not overwrite it).
specrelay::doctor::_ai_reviewer_status() {
  local root="$1" home="$2" template installed
  template="$home/templates/claude/agents/ai-reviewer.md"
  installed="$root/.claude/agents/ai-reviewer.md"

  if [ ! -f "$template" ]; then
    specrelay::doctor::_warn "Reviewer sub-agent template: not found in this SpecRelay installation ($template)"
    return 0
  fi
  specrelay::doctor::_ok "Reviewer sub-agent template: available ($template)"

  if [ ! -f "$installed" ]; then
    specrelay::doctor::_warn "Reviewer sub-agent: no .claude/agents/ai-reviewer.md — the Claude reviewer will run as a plain reviewer; copy templates/claude/agents/ai-reviewer.md (or re-run 'specrelay init') to enable --agent ai-reviewer"
    return 0
  fi

  if cmp -s "$template" "$installed" 2>/dev/null; then
    specrelay::doctor::_ok "Reviewer sub-agent: ai-reviewer configured (.claude/agents/ai-reviewer.md present; used as --agent ai-reviewer when the CLI advertises --agent; matches the bundled template)"
  else
    specrelay::doctor::_info "Reviewer sub-agent: ai-reviewer configured and CUSTOMIZED (.claude/agents/ai-reviewer.md present but differs from the bundled template; 'specrelay init' will not overwrite it)"
  fi
}

# specrelay::doctor::_verification_policy <root>
# Read-only (spec 0019, "Verification Policy Configuration" — "policy is
# visible through doctor or another inspection command"). A structurally
# invalid `verification:` section is a mandatory failure: every run with
# this configuration would refuse before role execution (mirrors how a
# malformed context/model configuration is reported above).
specrelay::doctor::_verification_policy() {
  local root="$1" blob
  if ! blob="$(specrelay::config::verification_policy "$root" 2>/dev/null)"; then
    specrelay::doctor::_fail "Verification policy: INVALID — $blob (source: $(specrelay::config::path "$root"))"
    return 0
  fi
  specrelay::doctor::_info "Verification policy (executor): full_suite_max_runs=$(printf '%s\n' "$blob" | sed -n 's/^executor_full_suite_max_runs=//p') smoke_max_runs=$(printf '%s\n' "$blob" | sed -n 's/^executor_smoke_max_runs=//p') doctor_max_runs=$(printf '%s\n' "$blob" | sed -n 's/^executor_doctor_max_runs=//p') version_max_runs=$(printf '%s\n' "$blob" | sed -n 's/^executor_version_max_runs=//p')"
  specrelay::doctor::_info "Verification policy (reviewer): default_mode=$(printf '%s\n' "$blob" | sed -n 's/^reviewer_default_mode=//p') focused_max_runs=$(printf '%s\n' "$blob" | sed -n 's/^reviewer_focused_max_runs=//p') targeted_max_runs=$(printf '%s\n' "$blob" | sed -n 's/^reviewer_targeted_max_runs=//p') full_suite_max_runs=$(printf '%s\n' "$blob" | sed -n 's/^reviewer_full_suite_max_runs=//p') smoke_max_runs=$(printf '%s\n' "$blob" | sed -n 's/^reviewer_smoke_max_runs=//p')"
}

# specrelay::doctor::_verification_engine <root>
# Read-only (spec 0026, section 35, "Doctor behavior"). Never executes a
# configured check command. Reports configuration mode (new/legacy/absent),
# schema validity, service/check counts, default level, changed fallback,
# concurrency, placement policy, missing service working directories, and
# the wasteful-full-suite-placement warning. Dependency cycles/unknown
# dependencies/duplicate identities/unsafe paths are all part of the SAME
# schema validation that produces "invalid" here — a structurally invalid
# `verification:` engine section is a mandatory failure, mirroring every
# other config-shape check in this file (every run with this configuration
# would refuse before check execution).
specrelay::doctor::_verification_engine() {
  local root="$1" blob mode
  blob="$(specrelay::verification_policy::doctor_summary "$root" 2>/dev/null)"
  mode="$(printf '%s' "$blob" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("mode","absent"))
except Exception:
    print("absent")' 2>/dev/null)"

  case "$mode" in
    invalid)
      local detail
      detail="$(printf '%s' "$blob" | python3 -c 'import json,sys
print(json.load(sys.stdin).get("error",""))' 2>/dev/null)"
      specrelay::doctor::_fail "Verification-policy engine: INVALID configuration — $detail (source: $(specrelay::config::path "$root"))"
      return 0
      ;;
    absent)
      specrelay::doctor::_info "Verification-policy engine (spec 0026): absent (no verification: services configured; legacy/no test-command policy applies)"
      return 0
      ;;
  esac

  printf '%s' "$blob" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("mode=%s services=%d checks=%d default_level=%s changed_fallback=%s concurrency=%s" % (
    d["mode"], d["service_count"], d["check_count"], d["defaults"]["level"],
    d["defaults"]["changed_fallback"], d["defaults"]["concurrency"],
))
print("placement: executor=%s reviewer=%s final_gate=%s" % (
    d["placement"]["executor"], d["placement"]["reviewer"], d["placement"]["final_gate"],
))
' 2>/dev/null | while IFS= read -r line; do
    specrelay::doctor::_info "Verification-policy engine: $line"
  done

  local missing
  missing="$(printf '%s' "$blob" | python3 -c 'import json,sys
d = json.load(sys.stdin)
m = d.get("missing_service_roots") or []
print(", ".join(m))' 2>/dev/null)"
  if [ -n "$missing" ]; then
    specrelay::doctor::_warn "Verification-policy engine: configured service root(s) do not exist on disk: $missing"
  fi

  printf '%s' "$blob" | python3 -c 'import json,sys
d = json.load(sys.stdin)
for w in d.get("warnings", []):
    print(w)' 2>/dev/null | while IFS= read -r w; do
    [ -n "$w" ] && specrelay::doctor::_warn "Verification-policy engine: $w"
  done

  specrelay::doctor::_ok "Verification-policy engine: ready (configuration valid; no configured command executed by doctor)"
}

# specrelay::doctor::_ui_verification <root>
# Read-only (spec 0028, section 35, "Doctor behavior"). Reports CONFIGURATION
# readiness only — never task-specific runtime readiness (that is 'ui plan's
# job for a real task) and never starts a browser or the application runtime.
specrelay::doctor::_ui_verification() {
  local root="$1" blob
  blob="$(specrelay::ui_verification::doctor_summary "$root" 2>/dev/null)"
  local valid
  valid="$(printf '%s' "$blob" | python3 -c 'import json,sys
try:
    print("yes" if json.load(sys.stdin).get("config_valid") else "no")
except Exception:
    print("no")' 2>/dev/null)"
  if [ "$valid" != "yes" ]; then
    local detail
    detail="$(printf '%s' "$blob" | python3 -c 'import json,sys
print(json.load(sys.stdin).get("error",""))' 2>/dev/null)"
    specrelay::doctor::_fail "UI verification: INVALID configuration — ${detail:-unknown error} (source: $(specrelay::config::path "$root"))"
    return 0
  fi

  printf '%s' "$blob" | python3 -c '
import json, sys
d = json.load(sys.stdin)
enabled = d.get("enabled")
if enabled is True:
    print("UI verification: required (verification.ui.enabled: true)")
elif enabled is False:
    print("UI verification: disabled (verification.ui.enabled: false)")
else:
    print("UI verification: auto (task-specific detection applies at plan/run time)")
print("Provider: %s (%s)" % (d["provider"], "available" if d["provider_available"] else "unavailable: %s" % d["provider_detail"]))
print("Browsers: %s" % ", ".join(d["browsers"]))
print("Runtime start command: %s" % ("configured" if d["runtime_start_command_configured"] else "missing"))
print("Scenario manifest (%s): %s" % (d["scenario_manifest_path"], d["scenario_manifest_status"]))
print("Expected-reference policy: %s" % d["expected_reference_policy"])
print("Publication: %s (destination: %s)" % ("enabled" if d["publication_enabled"] else "disabled", d["publication_destination"]))
' 2>/dev/null | while IFS= read -r line; do
    specrelay::doctor::_info "$line"
  done

  specrelay::doctor::_ok "UI verification: ready (configuration valid; no browser started by doctor)"
}

# specrelay::doctor::_phase_budgets <root>
# Read-only (spec 0019, "Phase Budgets"). A structurally invalid
# `performance:` section is a mandatory failure for the same reason as the
# verification policy above.
specrelay::doctor::_phase_budgets() {
  local root="$1" blob
  if ! blob="$(specrelay::config::phase_budgets "$root" 2>/dev/null)"; then
    specrelay::doctor::_fail "Phase budgets: INVALID — $blob (source: $(specrelay::config::path "$root"))"
    return 0
  fi
  specrelay::doctor::_info "Phase budgets (seconds): $(printf '%s\n' "$blob" | tr '\n' ' ')"
}

# specrelay::doctor::run <self-dir>
# specrelay::doctor::_execution_efficiency <root>
# Read-only (spec 0021, "Doctor" — "report whether execution-efficiency
# policy is enabled; resolved Executor policy; resolved Reviewer policy;
# completion-gate artifact requirements; unresolved-wait policy; whether
# command timing support from Spec 0020 is available"). A structurally
# invalid `execution_efficiency:` section is a mandatory failure, for the
# same reason as the verification policy/phase-budgets checks above: every
# run with this configuration would refuse before role execution. Never
# runs a provider and never mutates task state.
specrelay::doctor::_execution_efficiency() {
  local root="$1" blob
  if ! blob="$(specrelay::config::execution_efficiency_policy "$root" 2>/dev/null)"; then
    specrelay::doctor::_fail "Execution efficiency policy: INVALID — $blob (source: $(specrelay::config::path "$root"))"
    return 0
  fi
  local enabled
  enabled="$(printf '%s\n' "$blob" | sed -n 's/^enabled=//p')"
  specrelay::doctor::_info "Execution efficiency policy: enabled=$enabled"
  specrelay::doctor::_info "Execution efficiency policy (executor): exploration_warning_calls=$(printf '%s\n' "$blob" | sed -n 's/^executor_exploration_warning_calls=//p') repeated_verification_limit=$(printf '%s\n' "$blob" | sed -n 's/^executor_repeated_verification_limit=//p') unresolved_wait_is_failure=$(printf '%s\n' "$blob" | sed -n 's/^executor_unresolved_wait_is_failure=//p') require_artifacts_before_success=$(printf '%s\n' "$blob" | sed -n 's/^executor_require_artifacts_before_success=//p')"
  specrelay::doctor::_info "Execution efficiency policy (reviewer): exploration_warning_calls=$(printf '%s\n' "$blob" | sed -n 's/^reviewer_exploration_warning_calls=//p') repeated_verification_limit=$(printf '%s\n' "$blob" | sed -n 's/^reviewer_repeated_verification_limit=//p') unresolved_wait_is_failure=$(printf '%s\n' "$blob" | sed -n 's/^reviewer_unresolved_wait_is_failure=//p') require_artifacts_before_success=$(printf '%s\n' "$blob" | sed -n 's/^reviewer_require_artifacts_before_success=//p')"
  specrelay::doctor::_info "Completion-gate required Executor artifacts: 03-executor-log.md, 07-tests.txt, 08-executor-summary.md"
  specrelay::doctor::_info "Completion-gate required Reviewer artifacts: 09-consultant-review.md + 10-business-summary.md (ACCEPT) or 09-consultant-review.md + 11-next-executor-prompt.md (REQUEST_CHANGES)"

  if command -v python3 >/dev/null 2>&1 && [ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/command_timing_lib.py" ]; then
    specrelay::doctor::_info "Command timing support (spec 0020): available (python3 + command_timing_lib.py present)"
  else
    specrelay::doctor::_warn "Command timing support (spec 0020): unavailable (python3 or command_timing_lib.py missing); agent-efficiency classification will report zero observable operations"
  fi
}

# specrelay::doctor::_coordinator <root>
# Read-only (spec 0025, section 34, "Doctor behavior" — "must report
# coordinator readiness separately" and "must distinguish Coordinator,
# Executor, and Reviewer readiness"). Coordinator failure never affects
# Executor/Reviewer's OWN doctor checks above, and vice versa. A structurally
# invalid `roles.coordinator:` section is a mandatory failure, for the same
# reason as every other policy-shape check in this file: every run with this
# configuration would refuse before role invocation.
specrelay::doctor::_coordinator() {
  local root="$1" blob enabled
  if ! blob="$(specrelay::config::coordinator_policy "$root" 2>/dev/null)"; then
    specrelay::doctor::_fail "Coordinator: INVALID configuration — $blob (source: $(specrelay::config::path "$root"))"
    return 0
  fi
  enabled="$(printf '%s\n' "$blob" | sed -n 's/^enabled=//p')"

  if [ "$enabled" != "true" ]; then
    specrelay::doctor::_info "Coordinator: disabled (roles.coordinator.enabled is not true; existing deterministic workflow behavior is unchanged)"
    return 0
  fi

  specrelay::doctor::_ok "Coordinator: configured (roles.coordinator.enabled: true)"

  local provider model agent required
  provider="$(specrelay::coordinator::_live_provider "$root")"
  model="$(specrelay::coordinator::_live_model "$root")"
  agent="$(specrelay::coordinator::_live_agent "$root")"
  required="$(printf '%s\n' "$blob" | sed -n 's/^required=//p')"
  specrelay::doctor::_info "Coordinator role: provider=$provider model=$model agent=$agent required=$required"

  case "$provider" in
    fake)
      specrelay::doctor::_ok "Coordinator provider: fake (deterministic, always available)"
      ;;
    claude)
      if command -v "$(specrelay::provider::claude::_bin)" >/dev/null 2>&1; then
        specrelay::doctor::_ok "Coordinator provider: claude ($(command -v "$(specrelay::provider::claude::_bin)"))"
      else
        specrelay::doctor::_provider_unavailable "Coordinator provider: claude — '$(specrelay::provider::claude::_bin)' not found on PATH"
      fi
      ;;
    *)
      specrelay::doctor::_fail "Coordinator provider: unsupported provider '$provider'"
      ;;
  esac

  specrelay::doctor::_role_context "Coordinator" "$root" coordinator

  if specrelay::coordinator::_available; then
    specrelay::doctor::_ok "Coordinator decision-contract runtime: available (python3 + coordinator_lib.py present)"
  else
    specrelay::doctor::_fail "Coordinator decision-contract runtime: python3 or coordinator_lib.py missing"
  fi
}

# specrelay::doctor::_configuration_overlay <root>
# Read-only (spec 0027, section 17, "Doctor behavior"). Distinguishes: no
# local file (never an error); a valid local file; malformed local YAML; a
# type conflict during merge; local file not Git-ignored; and a trackable
# local file containing a secret-like key (mandatory failure — the one new
# secret-exposure risk this specification introduces). Never executes a
# configured command and never modifies .gitignore or the local file itself.
specrelay::doctor::_configuration_overlay() {
  local root="$1" local_path envelope ok error

  local_path="$(specrelay::config::local_path "$root")"
  envelope="$(specrelay::config::effective_envelope "$root" 2>/dev/null)"
  ok="$(printf '%s' "$envelope" | ruby -rjson -e 'd = JSON.parse(STDIN.read); print(d["ok"] ? "true" : "false")' 2>/dev/null)"

  if ! specrelay::config::local_exists "$root"; then
    specrelay::doctor::_info "Local overlay: not present (.specrelay/config.local.yml)"
    specrelay::doctor::_info "Local overlay Git ignore: not applicable (no local overlay present)"
    specrelay::doctor::_info "Secret exposure risk: none detected"
    specrelay::doctor::_ok "Merge: valid (shared configuration only)"
    specrelay::doctor::_info "Effective configuration capture: ready"
    return 0
  fi

  if [ "$ok" = "true" ]; then
    specrelay::doctor::_ok "Local overlay: present and valid ($local_path)"
    specrelay::doctor::_ok "Merge: valid"
  else
    error="$(printf '%s' "$envelope" | ruby -rjson -e 'd = JSON.parse(STDIN.read); print d["error"].to_s' 2>/dev/null)"
    specrelay::doctor::_fail "Local overlay: INVALID — $error (source: $local_path)"
    specrelay::doctor::_fail "Merge: invalid"
  fi

  # Git ignore safety (section 11.2): a warning when no secret-like field is
  # detected, a mandatory failure when a secret-like field IS present and the
  # file is trackable (not ignored).
  local ignored=0
  if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then
    if git -C "$root" check-ignore -q -- ".specrelay/config.local.yml" 2>/dev/null; then
      ignored=1
    fi
  else
    # Not a Git working tree at all: there is nothing to "track", so the
    # unignored-and-trackable failure condition cannot apply.
    ignored=1
  fi

  local has_secret=0
  if [ "$ok" = "true" ]; then
    has_secret="$(printf '%s' "$envelope" | ruby -rjson -e '
      d = JSON.parse(STDIN.read)
      markers = %w[TOKEN API_KEY APIKEY SECRET PASSWORD PASSWD COOKIE AUTHORIZATION CREDENTIAL PRIVATE_KEY ACCESS_KEY CLIENT_SECRET]
      found = (d["provenance"] || []).any? do |p|
        p["source_kind"] == "local" && markers.any? { |m| p["path"].to_s.upcase.include?(m) }
      end
      print(found ? "1" : "0")
    ' 2>/dev/null)"
    [ -n "$has_secret" ] || has_secret=0
  fi

  if [ "$ignored" -eq 1 ]; then
    specrelay::doctor::_ok "Local overlay Git ignore: safe (ignored by Git)"
    specrelay::doctor::_info "Secret exposure risk: none detected"
  elif [ "$has_secret" -eq 1 ]; then
    specrelay::doctor::_fail "Local overlay Git ignore: UNSAFE — $local_path is trackable and contains secret-like field(s); add .specrelay/config.local.yml to .gitignore"
    specrelay::doctor::_fail "Secret exposure risk: unsafe — local overlay contains secret-like field(s) and is not Git-ignored"
  else
    specrelay::doctor::_warn "Local overlay Git ignore: not ignored by Git ($local_path); add .specrelay/config.local.yml to .gitignore (run 'specrelay init', or add the line yourself)"
    specrelay::doctor::_info "Secret exposure risk: none detected"
  fi

  specrelay::doctor::_info "Effective configuration capture: ready"
}

specrelay::doctor::run() {
  local self_dir="$1"
  DOCTOR_FAILED=0

  # --- Git repository detected ------------------------------------------
  local git_root=""
  if git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    specrelay::doctor::_ok "Git repository ($git_root)"
  else
    specrelay::doctor::_fail "Git repository: not inside a git working tree"
  fi

  # --- Active Git commit hooks free of non-ASCII shell punctuation (advisory) -
  # The commit noise investigated in spec 0002 (`fatal: ambiguous argument
  # '‑abbrev-ref'`, `grep: illegal byte sequence`, `sed: invalid command
  # code`) originates in an ACTIVE Git commit hook — often a developer-global
  # one injected via `core.hooksPath` — that uses non-ASCII shell punctuation
  # (an en/em dash where `--` is required, or smart quotes around a sed/grep
  # script). Such a hook fires on every commit in every repo, so we surface it
  # here as an actionable WARNING (never a hard failure): SpecRelay does not
  # silently rewrite the developer's own hook, but it does point at the file
  # and the ASCII fix so a human can repair it.
  if [ -n "$git_root" ]; then
    local hooks_dir="" candidate_hook h
    hooks_dir="$(git config --get core.hooksPath 2>/dev/null || true)"
    if [ -z "$hooks_dir" ]; then
      hooks_dir="$(git rev-parse --git-path hooks 2>/dev/null || true)"
    fi
    local bad_hooks=""
    if [ -n "$hooks_dir" ] && [ -d "$hooks_dir" ]; then
      for h in prepare-commit-msg commit-msg pre-commit post-commit; do
        candidate_hook="$hooks_dir/$h"
        # Skip Git's shipped *.sample templates (never executed).
        case "$candidate_hook" in *.sample) continue ;; esac
        if specrelay::doctor::_hook_has_nonascii_shell_punct "$candidate_hook"; then
          bad_hooks="$bad_hooks $candidate_hook"
        fi
      done
    fi
    if [ -n "$bad_hooks" ]; then
      specrelay::doctor::_warn "Active Git commit hook contains non-ASCII shell punctuation (breaks commits with 'ambiguous argument' / 'illegal byte sequence' / 'invalid command code'):$bad_hooks"
      specrelay::doctor::_warn "  Fix: replace Unicode en/em dashes used as option prefixes with ASCII '--', and smart quotes (\xe2\x80\x9c \xe2\x80\x9d \xe2\x80\x98 \xe2\x80\x99) with ASCII \" or ' in the file(s) above."
    else
      specrelay::doctor::_ok "Active Git commit hooks: no non-ASCII shell punctuation detected"
    fi
  fi

  # --- Project root --------------------------------------------------------
  local root=""
  if root="$(specrelay::project::root 2>/dev/null)"; then
    specrelay::doctor::_ok "Project root ($root)"
  else
    specrelay::doctor::_fail "Project root: could not be discovered"
    # Nothing below can run meaningfully without a root.
    [ "$DOCTOR_FAILED" -ne 0 ] && return 1
  fi

  # --- Config readable ------------------------------------------------------
  local config_ok=1
  if specrelay::config::exists "$root"; then
    if specrelay::config::validate "$root" >/dev/null 2>&1; then
      specrelay::doctor::_ok "SpecRelay config (.specrelay/config.yml readable)"
    else
      specrelay::doctor::_fail "SpecRelay config: .specrelay/config.yml exists but is malformed"
      config_ok=0
    fi
  else
    specrelay::doctor::_fail "SpecRelay config: .specrelay/config.yml not found"
    config_ok=0
  fi

  # --- Local developer configuration overlay (spec 0027, section 17) --------
  specrelay::doctor::_configuration_overlay "$root"

  # --- Spec root exists -----------------------------------------------------
  local spec_root
  spec_root="$(specrelay::task::spec_root "$root")"
  if [ -d "$spec_root" ]; then
    specrelay::doctor::_ok "Spec root ($spec_root)"
  else
    specrelay::doctor::_fail "Spec root: $spec_root does not exist"
  fi

  # --- Task runtime root accessible -----------------------------------------
  local runs_root
  runs_root="$(specrelay::task::runs_root "$root")"
  if [ -d "$runs_root" ] && [ -r "$runs_root" ] && [ -w "$runs_root" ]; then
    specrelay::doctor::_ok "Task runtime root ($runs_root)"
  elif [ ! -e "$runs_root" ]; then
    # A fresh project may not have run anything yet, and neither the runs root
    # NOR its immediate parent need exist — they are created lazily (mkdir -p)
    # on first task creation. What actually matters is that the nearest
    # EXISTING ancestor is a writable directory. Walk up to find it.
    local ancestor
    ancestor="$(dirname "$runs_root")"
    while [ -n "$ancestor" ] && [ "$ancestor" != "/" ] && [ ! -e "$ancestor" ]; do
      ancestor="$(dirname "$ancestor")"
    done
    if [ -d "$ancestor" ] && [ -w "$ancestor" ]; then
      specrelay::doctor::_ok "Task runtime root ($runs_root; not yet created, will be created under writable $ancestor)"
    else
      specrelay::doctor::_fail "Task runtime root: $runs_root does not exist and cannot be created (nearest existing ancestor $ancestor is not writable)"
    fi
  else
    specrelay::doctor::_fail "Task runtime root: $runs_root exists but is not readable/writable"
  fi

  # --- Executor / reviewer provider available -------------------------------
  local executor_provider reviewer_provider
  executor_provider="$(specrelay::workflow::executor_provider "$root")"
  reviewer_provider="$(specrelay::workflow::reviewer_provider "$root")"

  case "$executor_provider" in
    fake)
      specrelay::doctor::_ok "Executor provider: fake (deterministic, always available)"
      ;;
    claude)
      if command -v "$(specrelay::provider::claude::_bin)" >/dev/null 2>&1; then
        specrelay::doctor::_ok "Executor provider: claude ($(command -v "$(specrelay::provider::claude::_bin)"))"
      else
        specrelay::doctor::_provider_unavailable "Executor provider: claude — '$(specrelay::provider::claude::_bin)' not found on PATH"
      fi
      ;;
    *)
      specrelay::doctor::_fail "Executor provider: unsupported provider '$executor_provider'"
      ;;
  esac

  case "$reviewer_provider" in
    manual)
      specrelay::doctor::_info "Reviewer provider: manual (a human decides accept/request-changes)"
      ;;
    fake)
      specrelay::doctor::_ok "Reviewer provider: fake (deterministic, always available)"
      ;;
    claude|claude-subagent)
      if command -v "$(specrelay::provider::claude::_bin)" >/dev/null 2>&1; then
        specrelay::doctor::_ok "Reviewer provider: $reviewer_provider ($(command -v "$(specrelay::provider::claude::_bin)"))"
      else
        specrelay::doctor::_provider_unavailable "Reviewer provider: $reviewer_provider — '$(specrelay::provider::claude::_bin)' not found on PATH"
      fi
      # Reviewer sub-agent readiness. The `--agent ai-reviewer` sub-agent runs
      # ONLY when the project provides `.claude/agents/ai-reviewer.md` (SpecRelay
      # does NOT ship it) and the CLI advertises `--agent`. Report the actual
      # situation so `claude-subagent` never silently pretends a sub-agent that
      # is not there — a missing file is a non-failing WARNING, not a hard fail,
      # because the reviewer falls back cleanly to a plain `claude` reviewer.
      specrelay::doctor::_ai_reviewer_status "$root" "$self_dir"
      ;;
    *)
      specrelay::doctor::_fail "Reviewer provider: unsupported provider '$reviewer_provider'"
      ;;
  esac

  # --- Effective role configuration (spec 0009) -----------------------------
  # Report the NORMALIZED effective provider/model/agent for each role, so an
  # operator sees exactly what SpecRelay will pass — after env overrides, config,
  # and legacy `claude-subagent` normalization are all resolved.
  local exec_prov_n exec_model exec_agent rev_prov_n rev_model rev_agent
  exec_prov_n="$(specrelay::workflow::role_provider "$root" executor)"
  exec_model="$(specrelay::workflow::role_model "$root" executor)"
  exec_agent="$(specrelay::workflow::role_agent "$root" executor)"
  rev_prov_n="$(specrelay::workflow::role_provider "$root" reviewer)"
  rev_model="$(specrelay::workflow::role_model "$root" reviewer)"
  rev_agent="$(specrelay::workflow::role_agent "$root" reviewer)"
  specrelay::doctor::_info "Executor role: provider=$exec_prov_n model=$exec_model agent=$exec_agent"
  specrelay::doctor::_info "Reviewer role: provider=$rev_prov_n model=$rev_model agent=$rev_agent"

  # Distinguish an EXPLICIT model from the provider-default sentinel (spec 0012,
  # "Doctor Command"): doctor must make it unambiguous whether SpecRelay will
  # request a specific model or delegate model selection to the provider CLI.
  specrelay::doctor::_role_model_source "Executor" "$exec_model"
  specrelay::doctor::_role_model_source "Reviewer" "$rev_model"

  # If an explicit model is configured for a Claude role but the installed CLI
  # does not advertise a --model flag, report it clearly (spec 0009): the run
  # would fail rather than silently ignore the model, so surface it here.
  specrelay::doctor::_role_model_support "Executor" "$exec_prov_n" "$exec_model"
  specrelay::doctor::_role_model_support "Reviewer" "$rev_prov_n" "$rev_model"

  # Full model-selection report per role (spec 0014, "Doctor Integration"):
  # configured selection, resolved value, kind, validation level, and source.
  # A structurally malformed or known-invalid selection is a mandatory failure.
  specrelay::doctor::_role_model_selection "Executor" "$root" executor
  specrelay::doctor::_role_model_selection "Reviewer" "$root" reviewer

  # --- Claude semantic live events availability (spec 0006) -----------------
  # Informational only: when either role uses a Claude provider, report whether
  # the semantic live-event layer (structured stream-json rendering) can run.
  # It is never mandatory — the generic stdout/stderr streaming from spec 0003
  # is the honest fallback — so this is an _info line, never a failing check.
  case "$executor_provider:$reviewer_provider" in
    *claude*)
      if [ "${SPECRELAY_SEMANTIC_EVENTS:-1}" = "0" ]; then
        specrelay::doctor::_info "Claude semantic live events: disabled (SPECRELAY_SEMANTIC_EVENTS=0); using generic stdout/stderr streaming"
      elif specrelay::provider::render_events_available; then
        specrelay::doctor::_info "Claude semantic live events: available (python3 + renderer present; used when 'claude --help' advertises stream-json)"
      else
        specrelay::doctor::_info "Claude semantic live events: unavailable (python3 or renderer missing); will use generic stdout/stderr streaming"
      fi
      ;;
  esac

  # --- Context capability adapters (spec 0015) ------------------------------
  # Per-role, read-only report through the adapter capability contract:
  # configured adapter, resolved adapter, required policy, availability,
  # capability level, network requirement, and validation result. Doctor
  # never runs a preflight or preparation and never mutates task state, and
  # adapter availability is a local, non-billable check.
  specrelay::doctor::_role_context "Executor" "$root" executor
  specrelay::doctor::_role_context "Reviewer" "$root" reviewer

  # --- Jam capability (spec 0023, section 18.3) -----------------------------
  # Reported SEPARATELY from repository context capabilities above. Jam is
  # globally optional: its absence never fails overall doctor readiness
  # unless a project explicitly sets jam.required: true. A task-specific
  # preflight (stricter than this general check) runs separately when a task
  # actually references a Jam recording (specrelay::jam::record_references).
  specrelay::doctor::_jam "$root"

  # --- Bounded verification policy + phase budgets (spec 0019) -------------
  specrelay::doctor::_verification_policy "$root"

  # --- Verification-policy ENGINE (spec 0026) -------------------------------
  # Reported separately from the spec-0019 bounded-run-count policy above —
  # these are two independent verification specs sharing the same
  # `verification:` config mapping (see config.sh's known_top comment).
  specrelay::doctor::_verification_engine "$root"

  # --- UI runtime verification (spec 0028, section 35) ----------------------
  specrelay::doctor::_ui_verification "$root"

  specrelay::doctor::_phase_budgets "$root"
  specrelay::doctor::_execution_efficiency "$root"

  # --- AI Coordinator readiness (spec 0025, section 34) ---------------------
  # Reported independently of Executor/Reviewer readiness above; a
  # coordinator failure never masks (or is masked by) their checks.
  specrelay::doctor::_coordinator "$root"

  # --- SpecRelay installation (tool) root -----------------------------------
  # Report WHERE SpecRelay itself is installed, kept explicitly distinct from
  # the project root above (spec 0086, sections 7-8). Derived from the
  # executable's own location, never from the consumer project.
  local specrelay_home="$self_dir"
  specrelay::doctor::_info "SpecRelay home ($specrelay_home)"

  # --- No obvious conflicting active engine lock ----------------------------
  local locks_dir="$runs_root/.specrelay-locks"
  local conflicting=0
  if [ -d "$locks_dir" ]; then
    local lock_dir
    for lock_dir in "$locks_dir"/*.lock; do
      [ -d "$lock_dir" ] || continue
      local owner_pid
      owner_pid="$(grep -m1 '^pid=' "$lock_dir/owner" 2>/dev/null | cut -d= -f2)"
      if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
        conflicting=1
      fi
    done
  fi
  if [ "$conflicting" -eq 0 ]; then
    specrelay::doctor::_ok "No conflicting active engine lock"
  else
    specrelay::doctor::_fail "Conflicting active engine lock: a live SpecRelay lock holder was found under $locks_dir"
  fi

  echo
  if [ "$DOCTOR_FAILED" -ne 0 ]; then
    specrelay::out::err "doctor: one or more mandatory checks failed"
    return 1
  fi
  echo "specrelay doctor: all checks passed."
  return 0
}
