#!/usr/bin/env bash
# context/none.sh — the "no external context" adapter, implemented through the
# SAME capability contract as every other adapter (spec 0015, "None Adapter"):
# it is a real adapter, not a special case scattered through workflow code.
#
# Behavior: always available, no network, no preparation, no artifact,
# freshness not-applicable, valid for both roles. This preserves the pre-0015
# `context.adapter: none` semantics exactly (a no-op, always-succeeds
# preflight).

specrelay::context::none::describe() {
  printf 'No external context preparation.\n'
}

specrelay::context::none::availability() {
  printf 'available\n'
}

specrelay::context::none::capability_level() {
  printf 'none\n'
}

specrelay::context::none::capabilities() {
  printf 'preflight=yes\n'
  printf 'prepare=no\n'
  printf 'durable_artifact=no\n'
  printf 'role_isolation=yes\n'
  printf 'network=no\n'
  printf 'freshness_check=no\n'
}

specrelay::context::none::supported_roles() {
  printf 'executor reviewer coordinator\n'
}

specrelay::context::none::validate_config() {
  # The none adapter recognizes no adapter-specific configuration keys, and
  # the structural context-section validation (config.sh) already rejects
  # unknown keys — nothing further to check.
  return 0
}

specrelay::context::none::preflight() {
  local role="$1"
  echo "[$role] context: adapter 'none'; no external context requested"
  return 0
}
