#!/usr/bin/env bash
# update.sh — update an installed SpecRelay from a local source (spec 0086,
# section 12).
#
# Truthful semantics only: during incubation the ONLY supported update source
# is a local SpecRelay source tree given with --from. There is no GitHub /
# release / package-manager update path yet, and this script does not pretend
# one exists.
#
#   update.sh --from /path/to/specrelay [--prefix DIR] [--allow-downgrade]
#
# The updater detects the installed and source versions, refuses an accidental
# downgrade unless --allow-downgrade is given, updates ONLY tool-owned files
# under <prefix>, and never touches any consumer project's .specrelay/ config
# (spec section 47).

set -uo pipefail

update::err() { printf 'update: %s\n' "$1" >&2; }

update::usage() {
  cat <<'USAGE'
Usage: update.sh --from DIR [--prefix DIR] [--allow-downgrade] [-h|--help]

  --from DIR          A local SpecRelay source tree to update FROM (required).
  --prefix DIR        The install prefix to update (default: $HOME/.local).
  --allow-downgrade   Permit installing an OLDER version than is installed.
  -h, --help          Show this help.

No network update source exists during incubation; --from is required.
USAGE
}

# update::_min <verA> <verB>  — prints the numerically-smaller dotted version.
update::_min() {
  printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1
}

main() {
  local from="" prefix="${HOME:-}/.local" allow_downgrade=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from) [ "$#" -ge 2 ] || { update::err "--from requires a value"; return 2; }
              from="$2"; shift 2 ;;
      --prefix) [ "$#" -ge 2 ] || { update::err "--prefix requires a value"; return 2; }
                prefix="$2"; shift 2 ;;
      --allow-downgrade) allow_downgrade=1; shift ;;
      -h|--help) update::usage; return 0 ;;
      *) update::err "unknown argument: $1"; update::usage >&2; return 2 ;;
    esac
  done

  if [ -z "$from" ]; then
    update::err "no update source given. Use: update.sh --from /path/to/specrelay"
    return 2
  fi
  if [ ! -f "$from/VERSION" ] || [ ! -f "$from/install/install.sh" ]; then
    update::err "source tree at '$from' is not a SpecRelay source (missing VERSION or install/install.sh)"
    return 1
  fi

  local share="$prefix/share/specrelay"
  if [ ! -f "$share/VERSION" ]; then
    update::err "no SpecRelay install found at $share. Run install.sh first (this command only UPDATES an existing install)."
    return 1
  fi

  local installed source_ver
  installed="$(tr -d '[:space:]' < "$share/VERSION")"
  source_ver="$(tr -d '[:space:]' < "$from/VERSION")"
  echo "Installed version: $installed"
  echo "Source version:    $source_ver"

  if [ "$installed" = "$source_ver" ]; then
    echo "Already at $installed; reinstalling from source to refresh files."
  else
    local smaller
    smaller="$(update::_min "$installed" "$source_ver")"
    if [ "$smaller" = "$source_ver" ] && [ "$allow_downgrade" -ne 1 ]; then
      update::err "refusing downgrade $installed -> $source_ver (pass --allow-downgrade to force)"
      return 1
    fi
  fi

  # Delegate the actual file replacement to the SOURCE's install.sh --force,
  # which only ever writes tool-owned files under <prefix> (spec section 12:
  # "update only tool-owned files"). Consumer project configs are untouched.
  # Invoke through `bash` rather than executing directly, so the update still
  # works if the source tree lost install.sh's exec bit (e.g. an archive or a
  # checkout on a filesystem that dropped it).
  bash "$from/install/install.sh" --prefix "$prefix" --force || return 1
  echo "Update complete: $installed -> $source_ver"
  return 0
}

main "$@"
