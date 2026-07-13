#!/usr/bin/env bash
# models.sh — `specrelay models [provider]` (spec 0014): model-selection
# guidance for automated providers, BEFORE any configuration is edited or any
# task runs.
#
# Output contract (spec 0014, "Models Command Output"): stream-friendly,
# append-only, copyable, and usable without color — plain stdout lines only,
# never interactive, no ANSI escapes of its own (the copyable YAML snippets
# must survive a paste into .specrelay/config.yml). The command clearly
# distinguishes:
#   * SpecRelay-declared aliases (adapter-owned, provider-scoped)
#   * dynamically discovered provider models (only when the provider supports
#     reliable, non-billable discovery)
#   * this project's CONFIGURED model values (and their resolutions)
#   * values that cannot be verified locally (reported honestly, never faked)
# It performs NO billable or remote provider call.

# specrelay::models::_role_line <root> <role> <label>
# One "  <role>: ..." line describing a role's configured selection and its
# resolution. A malformed configured model is reported as such (with the
# parser's detail) — configuration guidance must never crash on a bad config.
specrelay::models::_role_line() {
  local root="$1" role="$2" provider selection resolved label
  provider="$(specrelay::workflow::role_raw_provider "$root" "$role")"
  if [ "$provider" = "manual" ]; then
    echo "  $role: manual (a human performs this role; model fields are ignored — no model selection is executed)"
    return 0
  fi
  if ! selection="$(specrelay::workflow::role_model_selection "$root" "$role" 2>/dev/null)"; then
    echo "  $role: INVALID model configuration ($(specrelay::config::role_model_selection "$root" "$role" 2>/dev/null || true))"
    return 0
  fi
  resolved="$(specrelay::capability::resolved_display "$provider" "$selection" || true)"
  label="$(specrelay::capability::validation_label "$provider" "$selection")"
  echo "  $role: configured=$selection resolved=$resolved (validation: $label)"
}

# specrelay::models::_provider_section <root> <configured-provider-name>
# The full guidance block for one provider, under its CONFIGURED name (a
# legacy shorthand that reuses another adapter says so explicitly).
specrelay::models::_provider_section() {
  local root="$1" provider="$2" normalized level status aliases a
  normalized="$(specrelay::capability::normalize_provider "$provider")"
  if [ "$normalized" != "$provider" ]; then
    echo "Provider: $provider (legacy shorthand; uses the '$normalized' adapter's capabilities)"
  else
    echo "Provider: $provider"
  fi

  level="$(specrelay::capability::level "$provider")"
  if [ "$level" = "none" ]; then
    echo "Explicit model selection: not supported by this provider."
    echo "Configuration forms:"
    echo "  Provider default (the only valid form):"
    echo "    model: provider-default"
    echo "An explicit alias or model ID configured for this provider fails before role execution."
    return 0
  fi

  echo "Configuration forms:"
  echo "  Provider default:"
  echo "    model: provider-default"
  echo "  Semantic alias:"
  echo "    model:"
  echo "      alias: <alias>"
  echo "  Exact provider model ID:"
  echo "    model:"
  echo "      id: <provider-model-id>"

  aliases="$(specrelay::capability::declared_aliases "$provider")"
  if [ -n "$aliases" ]; then
    echo "Supported aliases (SpecRelay-declared, provider-scoped):"
    while IFS= read -r a; do
      [ -n "$a" ] && echo "  $a"
    done <<< "$aliases"
  else
    echo "Supported aliases (SpecRelay-declared, provider-scoped):"
    echo "  (none declared for this provider)"
  fi

  status="$(specrelay::capability::discovery_status "$provider")"
  echo "Provider model discovery:"
  case "$status" in
    available*)
      echo "  available (source: ${status#available })"
      echo "Discovered models (from provider discovery):"
      local m
      while IFS= read -r m; do
        [ -n "$m" ] && echo "  $m"
      done < <(specrelay::capability::discovered_models "$provider" || true)
      ;;
    failed*)
      echo "  failed: ${status#failed }"
      echo "This is a provider discovery failure, not an invalid model configuration."
      echo "SpecRelay cannot currently enumerate this provider's models."
      echo "Use an exact model ID from the provider's own documentation or CLI."
      ;;
    *)
      echo "  unavailable"
      echo "SpecRelay cannot reliably enumerate every model available to this account."
      echo "Use an exact model ID from the provider's own documentation or CLI."
      ;;
  esac
}

# specrelay::models::run <project-root> [provider]
specrelay::models::run() {
  local root="$1" requested="${2:-}"

  if [ -n "$requested" ]; then
    if [ "$requested" = "manual" ]; then
      echo "Provider: manual"
      echo "A human performs this role directly; no automated provider is invoked,"
      echo "no model selection is executed, and configured model fields are ignored"
      echo "for manual roles."
      return 0
    fi
    if ! specrelay::capability::known "$requested"; then
      specrelay::out::err "unknown provider '$requested' for 'specrelay models'"
      {
        echo "Configured providers in this project:"
        echo "  executor: $(specrelay::workflow::role_raw_provider "$root" executor)"
        echo "  reviewer: $(specrelay::workflow::role_raw_provider "$root" reviewer)"
        echo "Supported automated providers:"
        local p
        while IFS= read -r p; do
          [ -n "$p" ] && echo "  $p"
        done < <(specrelay::capability::supported_providers)
        echo "Usage: specrelay models [provider]"
      } >&2
      return 1
    fi
    specrelay::models::_provider_section "$root" "$requested"
    echo
    echo "Configured models in this project (roles using any provider):"
    specrelay::models::_role_line "$root" executor
    specrelay::models::_role_line "$root" reviewer
    return 0
  fi

  # No provider argument: guidance for every configured automated provider.
  local exec_provider rev_provider
  exec_provider="$(specrelay::workflow::role_raw_provider "$root" executor)"
  rev_provider="$(specrelay::workflow::role_raw_provider "$root" reviewer)"

  echo "Model selection guidance (see also: specrelay models <provider>)"
  echo
  echo "Configured roles:"
  specrelay::models::_role_line "$root" executor
  specrelay::models::_role_line "$root" reviewer

  local shown="" p
  for p in "$exec_provider" "$rev_provider"; do
    [ "$p" = "manual" ] && continue
    case " $shown " in *" $p "*) continue ;; esac
    shown="$shown $p"
    echo
    if specrelay::capability::known "$p"; then
      specrelay::models::_provider_section "$root" "$p"
    else
      echo "Provider: $p"
      echo "  No capability adapter is available for this provider; SpecRelay cannot"
      echo "  offer model guidance for it (and the provider dispatch will reject it)."
    fi
  done
  return 0
}
