#!/usr/bin/env bash
# providers/capability.sh — provider MODEL-SELECTION capability dispatch
# (spec 0014). Generic workflow/CLI code calls ONLY the functions below; all
# provider-specific model knowledge (declared aliases, alias resolution,
# discovery availability) lives in the provider adapters
# (providers/claude.sh, providers/fake.sh), never here and never in
# workflow.sh. Adding a new provider's capabilities means adding case arms
# plus adapter functions — never touching the generic engine.
#
# Capability levels (spec 0014, "Discovery Levels") — each provider declares
# exactly one practical level:
#   exact       reliable, non-billable machine-readable model list; ids may be
#               validated locally against it
#   aliases     no reliable complete list, but a small adapter-owned set of
#               provider-recognized aliases is validated locally ("Declared
#               Aliases Only")
#   structural  neither reliable discovery nor safe aliases; only configuration
#               shape and forwarding are validated — model availability is
#               ultimately validated by the provider
#   none        the provider does not support explicit model selection at all;
#               explicit alias/raw-id configuration fails before role execution
#
# Model SELECTIONS are the canonical strings produced by
# specrelay::config::role_model_selection:
#   provider-default | alias:<name> | id:<provider-model-id>
# Nothing in this file performs a billable or remote provider call.

# specrelay::capability::normalize_provider <provider>
# The legacy `claude-subagent` shorthand shares the claude adapter's capability
# data (same underlying CLI); everything else passes through unchanged. Callers
# that DISPLAY a provider keep the configured name — only capability lookups
# normalize.
specrelay::capability::normalize_provider() {
  case "$1" in
    claude-subagent) printf 'claude\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# specrelay::capability::known <provider>
# True when a capability adapter exists for the (possibly legacy-named)
# AUTOMATED provider. `manual` is deliberately NOT a capability provider: a
# manual role never executes model selection.
specrelay::capability::known() {
  case "$(specrelay::capability::normalize_provider "$1")" in
    claude|fake) return 0 ;;
    *) return 1 ;;
  esac
}

# specrelay::capability::supported_providers
# The automated provider names a user may pass to `specrelay models <provider>`
# (one per line, including the legacy shorthand).
specrelay::capability::supported_providers() {
  printf 'claude\nclaude-subagent\nfake\n'
}

# --- adapter dispatch ---------------------------------------------------------

# specrelay::capability::level <provider> -> exact|aliases|structural|none
# An UNKNOWN provider reports `structural`: SpecRelay has no knowledge of it,
# so it must neither invent aliases nor falsely reject ids — the provider
# dispatch itself rejects genuinely unsupported providers before any run.
specrelay::capability::level() {
  case "$(specrelay::capability::normalize_provider "$1")" in
    claude) specrelay::provider::claude::capability_level ;;
    fake) specrelay::provider::fake::capability_level ;;
    *) printf 'structural\n' ;;
  esac
}

specrelay::capability::supports_explicit_model() {
  [ "$(specrelay::capability::level "$1")" != "none" ]
}

# specrelay::capability::declared_aliases <provider> — one alias per line
# (possibly empty). Aliases are strictly provider-scoped: only the selected
# provider's own adapter is ever consulted, so an alias declared by one
# provider is never accepted for another.
specrelay::capability::declared_aliases() {
  case "$(specrelay::capability::normalize_provider "$1")" in
    claude) specrelay::provider::claude::capability_declared_aliases ;;
    fake) specrelay::provider::fake::capability_declared_aliases ;;
    *) : ;;
  esac
}

# specrelay::capability::resolve_alias <provider> <alias>
# Prints the adapter's deterministic resolution (a provider-recognized alias
# argument OR an exact provider model id); non-zero for an unknown alias.
specrelay::capability::resolve_alias() {
  case "$(specrelay::capability::normalize_provider "$1")" in
    claude) specrelay::provider::claude::capability_resolve_alias "$2" ;;
    fake) specrelay::provider::fake::capability_resolve_alias "$2" ;;
    *) return 1 ;;
  esac
}

# specrelay::capability::discovery_status <provider>
# Prints exactly one of: "available <source>" | "unavailable" | "failed <reason>".
# A discovery FAILURE is a provider/environment condition, kept explicitly
# distinct from an invalid user model configuration.
specrelay::capability::discovery_status() {
  case "$(specrelay::capability::normalize_provider "$1")" in
    claude) specrelay::provider::claude::capability_discovery_status ;;
    fake) specrelay::provider::fake::capability_discovery_status ;;
    *) printf 'unavailable\n' ;;
  esac
}

# specrelay::capability::discovered_models <provider> — one id per line;
# non-zero when discovery is unavailable or failed.
specrelay::capability::discovered_models() {
  case "$(specrelay::capability::normalize_provider "$1")" in
    claude) specrelay::provider::claude::capability_discovered_models ;;
    fake) specrelay::provider::fake::capability_discovered_models ;;
    *) return 1 ;;
  esac
}

# --- selection helpers ---------------------------------------------------------

# specrelay::capability::selection_kind <selection> -> provider-default|alias|id
specrelay::capability::selection_kind() {
  case "$1" in
    provider-default) printf 'provider-default\n' ;;
    alias:*) printf 'alias\n' ;;
    id:*) printf 'id\n' ;;
    *) printf 'id\n' ;;
  esac
}

# specrelay::capability::selection_value <selection> — the value after the kind
# prefix (the sentinel itself for provider-default).
specrelay::capability::selection_value() {
  case "$1" in
    provider-default) printf 'provider-default\n' ;;
    alias:*) printf '%s\n' "${1#alias:}" ;;
    id:*) printf '%s\n' "${1#id:}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# specrelay::capability::resolve_selection <provider> <selection>
# Prints the RESOLVED model value the provider invocation will receive:
#   provider-default -> the sentinel "provider-default" (adapters already omit
#                       the model argument for it — it is NEVER forwarded as a
#                       literal remote model id)
#   alias:<a>        -> the adapter's deterministic resolution (fails for an
#                       unknown alias — validation reports the actionable error)
#   id:<v>           -> <v>, byte-for-byte (never rewritten, prefixed, or
#                       normalized)
specrelay::capability::resolve_selection() {
  local provider="$1" selection="$2"
  case "$selection" in
    provider-default)
      printf 'provider-default\n'
      ;;
    alias:*)
      specrelay::capability::resolve_alias "$provider" "${selection#alias:}"
      ;;
    id:*)
      printf '%s\n' "${selection#id:}"
      ;;
    *)
      printf '%s\n' "$selection"
      ;;
  esac
}

# specrelay::capability::suggest_alias <provider> <unknown-alias>
# Lightweight nearest-match suggestion for an unknown alias: printed ONLY when
# the close match is unambiguous (exactly one candidate). Never rewrites
# configuration — this is display guidance only. Prints nothing (exit 0) when
# no unambiguous suggestion exists or python3 is unavailable.
specrelay::capability::suggest_alias() {
  local provider="$1" alias="$2" declared
  command -v python3 >/dev/null 2>&1 || return 0
  declared="$(specrelay::capability::declared_aliases "$provider")"
  [ -n "$declared" ] || return 0
  # shellcheck disable=SC2086  # declared aliases are word-split on purpose
  python3 -c '
import difflib, sys
bad = sys.argv[1]
aliases = [a for a in sys.argv[2:] if a]
matches = difflib.get_close_matches(bad, aliases, n=2, cutoff=0.6)
if len(matches) == 1:
    print(matches[0])
' "$alias" $declared 2>/dev/null || true
}

# specrelay::capability::_alias_error <provider> <role> <alias>
# The actionable invalid-alias error (spec 0014, "Actionable Errors"): names
# the role, provider, and invalid value; suggests a near match when
# unambiguous; lists the provider's declared aliases; and shows every valid
# configuration form plus the inspection command.
specrelay::capability::_alias_error() {
  local provider="$1" role="$2" alias="$3" suggestion declared a
  specrelay::out::err "invalid $role model alias '$alias' for provider '$provider'"
  suggestion="$(specrelay::capability::suggest_alias "$provider" "$alias")"
  {
    [ -n "$suggestion" ] && echo "Did you mean: $suggestion"
    declared="$(specrelay::capability::declared_aliases "$provider")"
    if [ -n "$declared" ]; then
      echo "Supported aliases:"
      while IFS= read -r a; do
        [ -n "$a" ] && echo "  $a"
      done <<< "$declared"
    else
      echo "Provider '$provider' declares no model aliases."
    fi
    echo "Use the provider default:"
    echo "  model: provider-default"
    echo "Or configure an exact provider model ID:"
    echo "  model:"
    echo "    id: <exact-provider-model-id>"
    echo "Inspect model options with:"
    echo "  specrelay models $provider"
  } >&2
}

# specrelay::capability::validate_selection <provider> <role> <selection>
# Provider-aware validation of an already structurally-parsed selection
# (spec 0014, "Validation Rules"). Returns non-zero — with an actionable error
# on stderr — for a KNOWN-invalid configuration; emits an honest advisory (and
# returns 0) where availability simply cannot be verified locally. Never
# performs a remote call, and never rejects an id based on an incomplete list.
specrelay::capability::validate_selection() {
  local provider="$1" role="$2" selection="$3" level value
  level="$(specrelay::capability::level "$provider")"

  case "$selection" in
    provider-default)
      # Always structurally valid for automated providers: the model argument
      # is omitted and the provider chooses its own configured default.
      return 0
      ;;
    alias:*)
      value="${selection#alias:}"
      if [ "$level" = "none" ]; then
        specrelay::out::err "invalid $role model configuration: provider '$provider' does not support explicit model selection; use model: provider-default (or omit the model key)"
        return 1
      fi
      if specrelay::capability::resolve_alias "$provider" "$value" >/dev/null; then
        return 0
      fi
      specrelay::capability::_alias_error "$provider" "$role" "$value"
      return 1
      ;;
    id:*)
      value="${selection#id:}"
      if [ "$level" = "none" ]; then
        specrelay::out::err "invalid $role model configuration: provider '$provider' does not support explicit model selection; use model: provider-default (or omit the model key)"
        return 1
      fi
      if [ "$level" = "exact" ]; then
        local discovered
        if discovered="$(specrelay::capability::discovered_models "$provider")"; then
          local m
          while IFS= read -r m; do
            [ "$m" = "$value" ] && return 0
          done <<< "$discovered"
          specrelay::out::err "unknown $role model id '$value' for provider '$provider'"
          {
            echo "Provider model discovery lists:"
            while IFS= read -r m; do
              [ -n "$m" ] && echo "  $m"
            done <<< "$discovered"
            echo "Use the provider default:"
            echo "  model: provider-default"
            echo "Inspect model options with:"
            echo "  specrelay models $provider"
          } >&2
          return 1
        fi
        # Discovery FAILED: never misreport that as an invalid user model —
        # forward the id and say honestly that it could not be verified.
        specrelay::out::log "[$role] provider '$provider' model discovery failed; forwarding model id '$value' unverified (the provider validates availability)"
        return 0
      fi
      # aliases / structural levels: a structurally valid raw id is forwarded;
      # availability cannot be locally guaranteed, and SpecRelay says so
      # instead of pretending to know.
      specrelay::out::log "[$role] model id '$value' for provider '$provider' cannot be verified locally; it is forwarded exactly as configured and validated by the provider"
      return 0
      ;;
    *)
      specrelay::out::err "invalid $role model selection '$selection' for provider '$provider' (internal parse error)"
      return 1
      ;;
  esac
}

# specrelay::capability::resolved_display <provider> <selection>
# The human-readable RESOLVED value for diagnostics (doctor, models, task
# show). provider-default displays as "provider-managed default" — SpecRelay
# never fabricates an exact resolved model when the provider default remains
# unknown. Returns non-zero (with a clear placeholder) when the selection
# cannot be resolved (e.g. an unknown alias).
specrelay::capability::resolved_display() {
  local provider="$1" selection="$2" resolved
  if [ "$selection" = "provider-default" ]; then
    printf 'provider-managed default\n'
    return 0
  fi
  if resolved="$(specrelay::capability::resolve_selection "$provider" "$selection" 2>/dev/null)"; then
    printf '%s\n' "$resolved"
    return 0
  fi
  printf "(unresolvable: alias not declared by provider '%s')\n" "$provider"
  return 1
}

# specrelay::capability::validation_label <provider> <selection>
# The human-readable validation level shown by doctor / models for a
# configured selection. Never claims account availability unless the provider
# supports reliable non-billable discovery.
specrelay::capability::validation_label() {
  local provider="$1" selection="$2" level
  level="$(specrelay::capability::level "$provider")"
  case "$selection" in
    provider-default)
      printf 'structural (provider-managed default)\n'
      ;;
    alias:*)
      printf 'provider-declared alias\n'
      ;;
    *)
      if [ "$level" = "exact" ] && specrelay::capability::discovered_models "$provider" >/dev/null; then
        printf 'verified against provider model discovery\n'
      else
        printf 'structural (availability validated by the provider)\n'
      fi
      ;;
  esac
}
