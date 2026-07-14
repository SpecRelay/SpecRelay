#!/usr/bin/env bash
# update_discovery.sh — read-only newest-release discovery (spec 0022,
# sections 4.1, 6 "Update source and version discovery").
#
# Authority order (section 6):
#   1. official versioned Git tags (the update_source recorded in
#      installation metadata);
#   2. an explicit operator-provided --from source (read directly, no tag
#      requirement — the operator is vouching for it);
#   3. no fallback beyond that: an official source with no tags yet simply
#      reports "no release found" rather than treating a moving branch tip
#      as a released version.
#
# Never runs `git pull`, never resets or mutates the repository it queries,
# never treats an unversioned branch tip as a "released" version.

SPECRELAY_SEMVER_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/semver_lib.py"

specrelay::semver::valid() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 "$SPECRELAY_SEMVER_PY" validate "$1" >/dev/null 2>&1
}

# specrelay::semver::gt <a> <b> — true when a > b (both must be valid).
specrelay::semver::gt() {
  local rc
  rc="$(python3 "$SPECRELAY_SEMVER_PY" compare "$1" "$2" 2>/dev/null)" || return 1
  [ "$rc" = "1" ]
}

# specrelay::update_discovery::from_tags <repository> [ref-glob]
# Prints "<version> <commit>" for the highest vX.Y.Z tag from a Git
# repository (local path or remote URL) via `git ls-remote --tags` —
# read-only, no clone/checkout/pull. Prints nothing and returns 1 on any
# failure (network, missing git, no matching tags): callers must treat that
# as a non-blocking discovery failure, never a hang.
specrelay::update_discovery::from_tags() {
  local repository="$1" out best="" best_sha="" tag ver sha
  command -v git >/dev/null 2>&1 || return 1
  [ -n "$repository" ] || return 1
  if command -v timeout >/dev/null 2>&1; then
    out="$(timeout 10 git ls-remote --tags "$repository" 'v[0-9]*' 2>/dev/null)" || return 1
  else
    out="$(git ls-remote --tags "$repository" 'v[0-9]*' 2>/dev/null)" || return 1
  fi
  [ -n "$out" ] || return 1
  while IFS= read -r line; do
    sha="${line%%$'\t'*}"
    tag="${line##*refs/tags/}"
    tag="${tag%\^\{\}}"
    ver="${tag#v}"
    specrelay::semver::valid "$ver" || continue
    if [ -z "$best" ] || specrelay::semver::gt "$ver" "$best"; then
      best="$ver"
      best_sha="$sha"
    fi
  done <<< "$out"
  [ -n "$best" ] || return 1
  printf '%s %s\n' "$best" "$best_sha"
}

# specrelay::update_discovery::from_path <source-path>
# Reads VERSION + the current commit directly from an explicit --from source
# checkout. Prints "<version> <commit>" or returns 1 if the path is not a
# structurally valid SpecRelay source checkout.
specrelay::update_discovery::from_path() {
  local src="$1" version commit
  [ -f "$src/VERSION" ] && [ -f "$src/bin/specrelay" ] && [ -d "$src/lib/specrelay" ] || return 1
  version="$(tr -d '[:space:]' < "$src/VERSION")"
  specrelay::semver::valid "$version" || return 1
  commit="$(git -C "$src" rev-parse HEAD 2>/dev/null || true)"
  printf '%s %s\n' "$version" "${commit:-unknown}"
}

# specrelay::update_discovery::is_dirty <source-path>
specrelay::update_discovery::is_dirty() {
  local src="$1"
  command -v git >/dev/null 2>&1 || return 1
  [ -n "$(git -C "$src" status --porcelain 2>/dev/null)" ]
}
