#!/usr/bin/env bash
# install.sh — user-level installer for SpecRelay (spec 0086, sections 10-11).
#
# Copy-based, no-sudo installation into a user prefix (default: ~/.local):
#
#   <prefix>/bin/specrelay                 (the executable)
#   <prefix>/share/specrelay/{lib,templates,VERSION,docs,README.md}
#
# The executable discovers its own resources relative to its location
# (bin/specrelay -> ../share/specrelay/lib), so no path is baked in and the
# install is relocatable. A --dev-link mode symlinks the executable back to
# this source tree for development instead of copying.
#
# This installer NEVER: requires sudo, writes outside <prefix>, or touches any
# consumer project's .specrelay/ configuration (tool install and project init
# are separate concerns — spec section 47).

set -uo pipefail

install::err() { printf 'install: %s\n' "$1" >&2; }

install::usage() {
  cat <<'USAGE'
Usage: install.sh [--prefix DIR] [--dev-link] [--force] [-h|--help]

  --prefix DIR   Install under DIR (default: $HOME/.local). Creates
                 DIR/bin/specrelay and DIR/share/specrelay/.
  --dev-link     Symlink DIR/bin/specrelay to this source tree instead of
                 copying (for development). Optional; copy is the default.
  --force        Reinstall even if the same version is already installed.
  -h, --help     Show this help.

No sudo is required or used. Nothing outside --prefix is modified.
USAGE
}

# Resolve this script's real directory, then the SpecRelay source root (its
# parent), following symlinks.
install::src_root() {
  local src="${BASH_SOURCE[0]}" dir
  while [ -h "$src" ]; do
    dir="$(cd "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  cd "$(dirname "$src")/.." && pwd
}

main() {
  local prefix="${HOME:-}/.local" dev_link=0 force=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prefix) [ "$#" -ge 2 ] || { install::err "--prefix requires a value"; return 2; }
                prefix="$2"; shift 2 ;;
      --dev-link) dev_link=1; shift ;;
      --force) force=1; shift ;;
      -h|--help) install::usage; return 0 ;;
      *) install::err "unknown argument: $1"; install::usage >&2; return 2 ;;
    esac
  done

  if [ -z "$prefix" ]; then
    install::err "empty --prefix; refusing (would be unsafe)"
    return 1
  fi
  if [ "$prefix" = "/" ]; then
    install::err "refusing to install into the filesystem root (/)"
    return 1
  fi

  local src
  src="$(install::src_root)"
  if [ ! -f "$src/bin/specrelay" ] || [ ! -d "$src/lib/specrelay" ]; then
    install::err "source tree looks incomplete under $src (missing bin/specrelay or lib/specrelay)"
    return 1
  fi
  local version
  version="$(tr -d '[:space:]' < "$src/VERSION")"

  # Create prefix dirs (mkdir -p is safe/idempotent and never touches files).
  mkdir -p "$prefix/bin" "$prefix/share" || return 1
  local share="$prefix/share/specrelay"
  local bin_target="$prefix/bin/specrelay"

  if [ "$dev_link" -eq 1 ]; then
    # Development symlink mode: point the executable back at this source tree.
    ln -sf "$src/bin/specrelay" "$bin_target" || return 1
    echo "Linked $bin_target -> $src/bin/specrelay (dev mode)"
  else
    # Copy-based mode. Refuse to clobber a non-SpecRelay directory living at
    # the share target (overwrite safety, spec section 64).
    if [ -e "$share" ] && [ ! -e "$share/VERSION" ] && [ ! -d "$share/lib/specrelay" ]; then
      install::err "refusing to overwrite $share: it exists but is not a SpecRelay install"
      return 1
    fi
    local existing=""
    [ -f "$share/VERSION" ] && existing="$(tr -d '[:space:]' < "$share/VERSION")"
    if [ -n "$existing" ] && [ "$existing" = "$version" ] && [ "$force" -ne 1 ]; then
      echo "SpecRelay $version is already installed at $share (use --force to reinstall)."
    fi
    # Replace only the tool-owned share dir, so a re-install never leaves stale
    # files behind (idempotency, spec section 45).
    rm -rf "$share"
    mkdir -p "$share" || return 1
    cp -R "$src/lib" "$share/lib" || return 1
    cp -R "$src/templates" "$share/templates" || return 1
    cp "$src/VERSION" "$share/VERSION" || return 1
    [ -d "$src/docs" ] && cp -R "$src/docs" "$share/docs"
    [ -f "$src/README.md" ] && cp "$src/README.md" "$share/README.md"
    cp "$src/bin/specrelay" "$bin_target" || return 1
    chmod +x "$bin_target" || return 1

    # Installation metadata (spec 0022, section 2): durable, atomic, lives
    # under the install prefix only — never in a consumer repository, never
    # containing credentials. Best-effort commit/remote detection: a
    # non-git source tree (e.g. a release tarball) still installs, just with
    # an honestly empty commit/repository.
    local commit="" remote=""
    if command -v git >/dev/null 2>&1 && git -C "$src" rev-parse HEAD >/dev/null 2>&1; then
      commit="$(git -C "$src" rev-parse HEAD)"
      remote="$(git -C "$src" remote get-url origin 2>/dev/null || true)"
    fi
    [ -n "$remote" ] || remote="$src"
    if command -v python3 >/dev/null 2>&1; then
      HOME_DIR="$share" VERSION="$version" COMMIT="$commit" EXE="$bin_target" RES="$share" \
        SRC_TYPE="official-git" SRC_REPO="$remote" SRC_REF="main" \
        INSTALLED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        python3 "$src/lib/specrelay/py/install_metadata_lib.py" write \
        || install::err "warning: could not write installation metadata (continuing; 'install-info' will report it as missing)"
    fi

    echo "Installed SpecRelay $version:"
    echo "  executable: $bin_target"
    echo "  resources:  $share/"
  fi

  # Print the version through the freshly installed executable as proof.
  echo -n "Installed version: "
  "$bin_target" version || { install::err "installed executable failed to run"; return 1; }

  # PATH guidance (spec section 10, item 9).
  case ":${PATH:-}:" in
    *":$prefix/bin:"*)
      echo "$prefix/bin is already on your PATH."
      ;;
    *)
      echo
      echo "NOTE: $prefix/bin is not on your PATH. Add it, e.g.:"
      echo "  export PATH=\"$prefix/bin:\$PATH\""
      ;;
  esac
  return 0
}

main "$@"
