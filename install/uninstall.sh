#!/usr/bin/env bash
# uninstall.sh — remove a user-level SpecRelay install (spec 0008, section 5).
#
# Reverses what install/install.sh created under a user prefix (default
# ~/.local):
#
#   <prefix>/bin/specrelay                 (the executable, copy OR --dev-link)
#   <prefix>/share/specrelay/              (lib, templates, VERSION, docs, ...)
#
# This uninstaller is deliberately conservative and NEVER:
#   - requires sudo, or writes/removes anything outside <prefix>;
#   - touches any consumer project's .specrelay/ configuration, task runs, or
#     specs — those are project-owned, not tool-owned (spec section 5, and
#     install.sh's section 47 boundary). Uninstalling the TOOL leaves every
#     consumer project exactly as it was.
#
# It only removes the two tool-owned locations above, and refuses to delete a
# <prefix>/share/specrelay that exists but is not a SpecRelay install.
#
#   uninstall.sh [--prefix DIR] [-h|--help]

set -uo pipefail

uninstall::err() { printf 'uninstall: %s\n' "$1" >&2; }

uninstall::usage() {
  cat <<'USAGE'
Usage: uninstall.sh [--prefix DIR] [-h|--help]

  --prefix DIR   Uninstall from DIR (default: $HOME/.local). Removes
                 DIR/bin/specrelay and DIR/share/specrelay/.
  -h, --help     Show this help.

No sudo is required or used. Nothing outside --prefix is modified, and no
consumer project's .specrelay/ configuration is ever touched.
USAGE
}

main() {
  local prefix="${HOME:-}/.local"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prefix) [ "$#" -ge 2 ] || { uninstall::err "--prefix requires a value"; return 2; }
                prefix="$2"; shift 2 ;;
      -h|--help) uninstall::usage; return 0 ;;
      *) uninstall::err "unknown argument: $1"; uninstall::usage >&2; return 2 ;;
    esac
  done

  if [ -z "$prefix" ]; then
    uninstall::err "empty --prefix; refusing (would be unsafe)"
    return 1
  fi
  if [ "$prefix" = "/" ]; then
    uninstall::err "refusing to uninstall from the filesystem root (/)"
    return 1
  fi

  local bin_target="$prefix/bin/specrelay"
  local share="$prefix/share/specrelay"
  local removed=0

  # Remove the tool-owned share dir, but only if it actually looks like a
  # SpecRelay install (has VERSION or lib/specrelay). This mirrors install.sh's
  # overwrite-safety guard so we never delete an unrelated directory.
  if [ -e "$share" ]; then
    if [ -f "$share/VERSION" ] || [ -d "$share/lib/specrelay" ]; then
      local version=""
      [ -f "$share/VERSION" ] && version="$(tr -d '[:space:]' < "$share/VERSION")"
      rm -rf "$share" || return 1
      echo "Removed resources: $share/${version:+ (was SpecRelay $version)}"
      removed=1
    else
      uninstall::err "refusing to remove $share: it exists but is not a SpecRelay install"
      return 1
    fi
  fi

  # Remove the executable (a copy OR a --dev-link symlink; removing a symlink
  # only removes the link, never the source tree it points at).
  if [ -e "$bin_target" ] || [ -L "$bin_target" ]; then
    rm -f "$bin_target" || return 1
    echo "Removed executable: $bin_target"
    removed=1
  fi

  if [ "$removed" -eq 0 ]; then
    echo "No SpecRelay install found under $prefix (nothing to remove)."
    return 0
  fi

  echo
  echo "SpecRelay was uninstalled from $prefix."
  echo "Consumer projects were NOT changed: their .specrelay/ config, task runs,"
  echo "and specs remain untouched. Remove those per-project by hand if you want"
  echo "to stop using SpecRelay in a given repository."
  return 0
}

main "$@"
