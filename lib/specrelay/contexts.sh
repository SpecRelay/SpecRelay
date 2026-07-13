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

# specrelay::contexts::_adapter_detail <root> <adapter>
specrelay::contexts::_adapter_detail() {
  local root="$1" adapter="$2" avail_out avail reason

  echo "Context adapter: $adapter"

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
  local adapter avail_out avail
  while IFS= read -r adapter; do
    [ -n "$adapter" ] || continue
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
