#!/usr/bin/env bash
# install_metadata.sh — installation metadata for installed SpecRelay
# distributions (spec 0022, section 2 "Installation metadata").
#
# The metadata file lives UNDER THE INSTALLATION PREFIX
# (<home>/install-metadata.json, i.e. <prefix>/share/specrelay/install-metadata.json)
# — never in a consumer repository. Writes are atomic (tmp file + rename on
# the same filesystem). No credentials or access tokens are ever written.

SPECRELAY_INSTALL_METADATA_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/install_metadata_lib.py"

# specrelay::install_metadata::path <home>
specrelay::install_metadata::path() {
  printf '%s/%s\n' "$1" "$SPECRELAY_INSTALL_METADATA_FILENAME"
}

# specrelay::install_metadata::write <home> <version> <commit> <executable-path> \
#   <resource-path> <update-source-type> <update-source-repo> <update-source-ref> \
#   [installed-at-iso8601]
# Atomically writes schema_version=1 metadata. installed-at defaults to now
# (UTC) when omitted; tests pass an explicit value for determinism.
specrelay::install_metadata::write() {
  local home="$1" version="$2" commit="$3" exe="$4" resources="$5" \
    src_type="$6" src_repo="$7" src_ref="$8" installed_at="${9:-}"
  [ -n "$installed_at" ] || installed_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  command -v python3 >/dev/null 2>&1 || { specrelay::out::err "python3 is required to write installation metadata"; return 1; }
  HOME_DIR="$home" VERSION="$version" COMMIT="$commit" EXE="$exe" RES="$resources" \
    SRC_TYPE="$src_type" SRC_REPO="$src_repo" SRC_REF="$src_ref" INSTALLED_AT="$installed_at" \
    python3 "$SPECRELAY_INSTALL_METADATA_PY" write
}

# specrelay::install_metadata::read_field <home> <field>
# Prints the field's value, or nothing if missing/malformed (never fatal).
specrelay::install_metadata::read_field() {
  local home="$1" field="$2"
  command -v python3 >/dev/null 2>&1 || return 1
  HOME_DIR="$home" FIELD="$field" python3 "$SPECRELAY_INSTALL_METADATA_PY" read-field 2>/dev/null
}

# specrelay::install_metadata::validate <home>
# Prints "ok" and returns 0 for valid metadata; prints a clear diagnostic to
# stderr and returns 1 for missing or malformed metadata.
specrelay::install_metadata::validate() {
  local home="$1" path
  path="$(specrelay::install_metadata::path "$home")"
  if [ ! -f "$path" ]; then
    specrelay::out::err "installation metadata not found at $path (this installed SpecRelay predates spec 0022, or was assembled by hand). Reinstall from an official source to regenerate it: see docs/updates.md#migration"
    return 1
  fi
  command -v python3 >/dev/null 2>&1 || { specrelay::out::err "python3 is required to validate installation metadata"; return 1; }
  local reason
  if reason="$(HOME_DIR="$home" python3 "$SPECRELAY_INSTALL_METADATA_PY" validate 2>&1)"; then
    printf 'ok\n'
    return 0
  fi
  specrelay::out::err "installation metadata at $path is malformed: $reason"
  return 1
}
