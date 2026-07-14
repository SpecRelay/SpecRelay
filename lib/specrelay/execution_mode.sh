#!/usr/bin/env bash
# execution_mode.sh — source-local vs installed execution-mode contract
# (spec 0022, section 1 "Execution-mode contract").
#
# Detection is STRUCTURAL, not command-text based (spec 1.3): bin/specrelay
# already resolves SPECRELAY_HOME by following symlinks to a REAL directory
# before this file ever runs (see bin/specrelay's `_resolve_bin_dir`), and
# only two physical layouts are possible once that resolution has happened:
#
#   source-local layout:  <home>/bin/specrelay  and  <home>/lib/specrelay
#   installed layout:     <prefix>/bin/specrelay (a SIBLING of <home>, never
#                          inside it) and  <home>/lib/specrelay
#                          where <home> == <prefix>/share/specrelay
#
# So "does <home>/bin/specrelay exist" is a reliable, symlink-safe structural
# signal that requires no metadata file to be trustworthy: a repository
# checkout symlinked onto PATH from elsewhere still resolves SPECRELAY_HOME
# back to the repository root (which HAS bin/specrelay), so it is never
# misclassified as installed merely because of how it was invoked.
#
# Installation metadata (install_metadata.sh) is the DURABLE record an
# installer writes and is required for installed mode's rich detail
# (install-info, environment, update source) — its absence does not flip an
# installed layout back to source-local; it is reported as a migration
# diagnostic instead (spec section 12).

SPECRELAY_INSTALL_METADATA_FILENAME="install-metadata.json"

# specrelay::execution_mode::detect <specrelay-home>
# Prints "source-local" or "installed".
specrelay::execution_mode::detect() {
  local home="$1"
  if [ -f "$home/bin/specrelay" ]; then
    printf 'source-local\n'
  else
    printf 'installed\n'
  fi
}

specrelay::execution_mode::is_installed() {
  [ "$(specrelay::execution_mode::detect "$1")" = "installed" ]
}

specrelay::execution_mode::is_source_local() {
  [ "$(specrelay::execution_mode::detect "$1")" = "source-local" ]
}

# specrelay::execution_mode::resource_path <specrelay-home>
# The resources root reported to operators. For installed mode this IS
# SPECRELAY_HOME (<prefix>/share/specrelay); for source-local it is the
# repository checkout root, same value.
specrelay::execution_mode::resource_path() {
  printf '%s\n' "$1"
}

# specrelay::execution_mode::executable_path <specrelay-home>
# Best-effort path to the launcher that is actually on the caller's PATH for
# this mode. Source-local always has <home>/bin/specrelay. Installed mode's
# executable is a SIBLING of <home> (<home>/../../bin/specrelay when <home> is
# <prefix>/share/specrelay); installation metadata (when present) is a more
# precise source of truth and callers should prefer it when available.
specrelay::execution_mode::executable_path() {
  local home="$1"
  if [ -f "$home/bin/specrelay" ]; then
    printf '%s/bin/specrelay\n' "$home"
    return 0
  fi
  local candidate
  candidate="$(cd "$home/../../bin" 2>/dev/null && pwd)" || { printf '%s\n' "(unknown)"; return 0; }
  printf '%s/specrelay\n' "$candidate"
}
