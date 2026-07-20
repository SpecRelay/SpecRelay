#!/usr/bin/env bash
# architecture.sh — thin CLI wrapper around the canonical architecture-version
# contract validator (spec 0031, sections 12-13). Like the release commands,
# this operates on THIS SpecRelay source checkout's own architecture/ layer and
# docs/specs/, never a consumer project's .specrelay/config.yml — so it refuses
# installed mode with the same source-local safety pattern.
#
# All validation logic lives in the single canonical Ruby validator
# (architecture_validate.rb); this wrapper only enforces the execution-mode
# guard and forwards arguments, so the CLI, the release preflight, and the tests
# all exercise exactly one parser with one set of rules (spec 12.1).

SPECRELAY_ARCHITECTURE_RB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/architecture_validate.rb"

# specrelay::architecture::_require_source_local <home>
specrelay::architecture::_require_source_local() {
  if ! specrelay::execution_mode::is_source_local "$1"; then
    specrelay::out::err "architecture commands validate THIS SpecRelay checkout's own architecture/ layer and are only meaningful in source-local mode (an installed SpecRelay has no architecture source to validate)."
    return 1
  fi
  return 0
}

# specrelay::architecture::validate <home> [--json]
# Runs the canonical validator against the source checkout. Read-only; exits
# non-zero if the contract is invalid.
specrelay::architecture::validate() {
  local home="$1"; shift
  specrelay::architecture::_require_source_local "$home" || return 1
  if ! command -v ruby >/dev/null 2>&1; then
    specrelay::out::err "ruby is required to validate the architecture contract but was not found on PATH"
    return 1
  fi
  ruby "$SPECRELAY_ARCHITECTURE_RB" --root "$home" "$@"
}

# specrelay::architecture::_release_preflight <home>
# Used by the release commands (spec 0031, section 13): the canonical validator
# must pass before a release is planned, prepared, verified, or tagged. Emits a
# clear, release-scoped diagnostic on failure and preserves the validator's
# non-zero exit. Deliberately quiet on success so it does not clutter release
# output when the contract is already valid.
specrelay::architecture::_release_preflight() {
  local home="$1" out rc
  # Reuse the same canonical validator the CLI command uses.
  out="$(specrelay::architecture::validate "$home" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    specrelay::out::err "release blocked: the architecture contract is invalid — fix it before releasing (run 'specrelay architecture validate'):"
    printf '%s\n' "$out" >&2
    return 1
  fi
  return 0
}
