#!/usr/bin/env bash
# contexts.sh — `specrelay contexts [adapter]` (spec 0015): context-adapter
# discovery and diagnostics.
#
# Output contract (spec 0015, "New CLI Command"): non-interactive, append-only,
# copyable, usable in CI and without color — plain stdout lines only, no ANSI
# escapes of its own (the copyable YAML snippet must survive a paste into
# .specrelay/config.yml). The command NEVER performs a billable AI-provider
# invocation and never runs an adapter's preflight or preparation — adapter
# availability is a read-only local check, and an unavailable adapter is
# reported honestly as not invoked (never as usable).

# specrelay::contexts::_yes_no <yes|no>
specrelay::contexts::_cap_line() {
  # left-pads the capability label to the spec's aligned output shape
  printf '  %-17s %s\n' "$1:" "$2"
}

# specrelay::contexts::_readiness_field <key=value blob> <field>
specrelay::contexts::_readiness_field() {
  printf '%s\n' "$1" | sed -n "s/^${2}=//p"
}

# specrelay::contexts::_compact_status <status>
# The precise, honest compact status word (spec 0018, "Context List Output")
# used in the `contexts` listing — never the ambiguous "available" unless the
# adapter is genuinely ready.
specrelay::contexts::_compact_status() {
  case "$1" in
    unavailable) printf 'not-installed\n' ;;
    installed) printf 'installed-not-registered\n' ;;
    registered) printf 'registered-not-connected\n' ;;
    disconnected) printf 'disconnected\n' ;;
    config-incomplete) printf 'config-incomplete\n' ;;
    ready) printf 'ready\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# specrelay::contexts::_render_readiness <key=value readiness blob>
# Renders the detailed runtime-readiness report (spec 0018, "Contexts Command
# Output"): installed/registered/connected always shown; the project/global
# config-source breakdown only once connection is proven (before that, a
# single "Config source: none" line — there is nothing more specific to say).
specrelay::contexts::_render_readiness() {
  local blob="$1" status installed registered connected project_config
  local global_detected selected retrieval_ready server reason

  status="$(specrelay::contexts::_readiness_field "$blob" status)"
  installed="$(specrelay::contexts::_readiness_field "$blob" installed)"
  registered="$(specrelay::contexts::_readiness_field "$blob" registered)"
  connected="$(specrelay::contexts::_readiness_field "$blob" connected)"
  project_config="$(specrelay::contexts::_readiness_field "$blob" project_config)"
  global_detected="$(specrelay::contexts::_readiness_field "$blob" global_detected)"
  selected="$(specrelay::contexts::_readiness_field "$blob" selected_source)"
  retrieval_ready="$(specrelay::contexts::_readiness_field "$blob" retrieval_ready)"
  server="$(specrelay::contexts::_readiness_field "$blob" server)"
  reason="$(specrelay::contexts::_readiness_field "$blob" reason)"

  echo "Runtime readiness:"
  printf '  %-16s %s\n' "Installed:" "$installed"
  printf '  %-16s %s\n' "Registered:" "$registered"
  printf '  %-16s %s\n' "Connected:" "$connected"
  if [ "$connected" = "yes" ]; then
    local project_label
    case "$project_config" in
      valid) project_label="valid" ;;
      missing) project_label="missing" ;;
      server-missing) project_label="missing (no entry for '$server')" ;;
      *) project_label="invalid" ;;
    esac
    printf '  %-16s %s\n' "Project config:" "$project_label"
    printf '  %-16s %s\n' "Global config:" "$([ "$global_detected" = "yes" ] && echo detected || echo none)"
    printf '  %-16s %s\n' "Selected source:" "$([ "$selected" = "project" ] && echo "project .mcp.json" || echo none)"
  else
    printf '  %-16s %s\n' "Config source:" "none"
  fi
  printf '  %-16s %s\n' "Retrieval ready:" "$retrieval_ready"
  echo "Status:"
  echo "  $status"
  echo "Reason:"
  echo "  ${reason:-no additional detail}"
  echo "Inspect Claude MCP registration with:"
  echo "  claude mcp list"
}

# specrelay::contexts::_adapter_detail <root> <adapter>
specrelay::contexts::_adapter_detail() {
  local root="$1" adapter="$2" avail_out avail reason readiness_out

  echo "Context adapter: $adapter"

  # Adapters with a richer structured readiness inspection (spec 0018) get a
  # detailed, honest report regardless of overall readiness — the whole point
  # is to show WHY Context+ is not ready, not just that it is not.
  if readiness_out="$(specrelay::context::runtime_readiness "$adapter" "$root" 2>/dev/null)"; then
    echo "Description:"
    echo "  $(specrelay::context::describe "$adapter")"
    specrelay::contexts::_render_readiness "$readiness_out"
    return 0
  fi

  avail_out="$(specrelay::context::availability "$adapter" "$root")"
  avail="$(printf '%s\n' "$avail_out" | sed -n '1p')"
  reason="$(printf '%s\n' "$avail_out" | sed -n '2p')"

  if [ "$avail" != "available" ]; then
    echo "Availability:"
    echo "  unavailable"
    echo "Reason:"
    echo "  ${reason:-adapter availability could not be verified}"
    echo "This adapter was not invoked."
    return 0
  fi

  echo "Description:"
  echo "  $(specrelay::context::describe "$adapter")"
  echo "Availability:"
  echo "  available"
  echo "Capability level:"
  echo "  $(specrelay::context::capability_level "$adapter")"
  echo "Capabilities:"
  specrelay::contexts::_cap_line "preflight" "$(specrelay::context::capability "$adapter" preflight)"
  specrelay::contexts::_cap_line "prepare" "$(specrelay::context::capability "$adapter" prepare)"
  specrelay::contexts::_cap_line "durable artifact" "$(specrelay::context::capability "$adapter" durable_artifact)"
  specrelay::contexts::_cap_line "role isolation" "$(specrelay::context::capability "$adapter" role_isolation)"
  specrelay::contexts::_cap_line "network required" "$(specrelay::context::capability "$adapter" network)"
  specrelay::contexts::_cap_line "freshness check" "$(specrelay::context::capability "$adapter" freshness_check)"
  echo "Supported roles:"
  echo "  $(specrelay::context::supported_roles "$adapter")"
  echo "Configuration:"
  echo "  context:"
  echo "    adapter: $adapter"
  echo "    required: false"
}

# specrelay::contexts::_role_line <root> <role>
specrelay::contexts::_role_line() {
  local root="$1" role="$2" parsed adapter required
  if ! parsed="$(specrelay::config::role_context "$root" "$role")"; then
    echo "  $role: INVALID context configuration ($parsed)"
    return 0
  fi
  adapter="$(printf '%s\n' "$parsed" | sed -n 's/^adapter=//p')"
  required="$(printf '%s\n' "$parsed" | sed -n 's/^required=//p')"
  if specrelay::context::known "$adapter"; then
    echo "  $role: adapter=$adapter required=$required"
  else
    echo "  $role: adapter=$adapter required=$required (UNKNOWN adapter — not usable)"
  fi
}

# specrelay::contexts::run <project-root> [adapter]
specrelay::contexts::run() {
  local root="$1" requested="${2:-}"

  if [ -n "$requested" ]; then
    if ! specrelay::context::known "$requested"; then
      specrelay::out::err "unknown context adapter '$requested'"
      {
        echo "Known adapters:"
        local a
        while IFS= read -r a; do
          [ -n "$a" ] && echo "  $a"
        done < <(specrelay::context::adapters)
        echo "Inspect adapters with:"
        echo "  bin/specrelay contexts"
        echo "Usage: specrelay contexts [adapter]"
      } >&2
      return 1
    fi
    specrelay::contexts::_adapter_detail "$root" "$requested"
    return 0
  fi

  # No adapter argument: discovery listing. Distinguishes built-in adapters,
  # each one's availability, and this project's configured adapters (a
  # configured-but-unknown adapter is explicitly reported as not usable —
  # appearing in configuration proves nothing).
  echo "Known context adapters (built-in to this SpecRelay version):"
  local adapter avail_out avail readiness_out status
  while IFS= read -r adapter; do
    [ -n "$adapter" ] || continue
    if readiness_out="$(specrelay::context::runtime_readiness "$adapter" "$root" 2>/dev/null)"; then
      status="$(specrelay::contexts::_readiness_field "$readiness_out" status)"
      printf '  %-13s built-in  %s\n' "$adapter" "$(specrelay::contexts::_compact_status "$status")"
      continue
    fi
    avail_out="$(specrelay::context::availability "$adapter" "$root")"
    avail="$(printf '%s\n' "$avail_out" | sed -n '1p')"
    printf '  %-13s built-in  %s\n' "$adapter" "$avail"
  done < <(specrelay::context::adapters)

  echo
  echo "Configured context adapters in this project:"
  specrelay::contexts::_role_line "$root" executor
  specrelay::contexts::_role_line "$root" reviewer

  echo
  echo "Inspect one adapter with:"
  echo "  bin/specrelay contexts <adapter>"
  return 0
}
