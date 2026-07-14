#!/usr/bin/env bash
# update.sh — explicit update commands for an INSTALLED SpecRelay (spec
# 0022, section 4 "Explicit update commands" + section 11 "Safety
# requirements"). Source-local execution refuses every subcommand here (spec
# 4.6, 1.1) — see specrelay::cli::cmd_update's guard.
#
# Staging model (11.1/11.2): a new payload is copied into
# <share>.staging-<pid>, verified there, then activated by an atomic rename
# swap (<share> -> <share>.old-<pid>, <share>.staging-<pid> -> <share>).
# The prior installation is only removed AFTER the new one is verified in
# place; any failure before that point leaves the ORIGINAL <share> completely
# untouched, and the swap step itself uses `mv` (atomic on the same
# filesystem), not a destructive rm-rf-then-copy.

# specrelay::update::_lock_dir <home>
specrelay::update::_lock_dir() {
  printf '%s/.update.lock\n' "$1"
}

# specrelay::update::_lock_acquire <home> — mkdir-based, same stale-lock
# reclaim strategy as lock.sh (same host + dead owning pid -> reclaimed).
specrelay::update::_lock_acquire() {
  local home="$1" lock_dir owner_file this_host
  lock_dir="$(specrelay::update::_lock_dir "$home")"
  owner_file="$lock_dir/owner"
  this_host="$(hostname 2>/dev/null || echo unknown-host)"

  if ! mkdir "$lock_dir" 2>/dev/null; then
    local owner_pid owner_host
    owner_pid="$(grep -m1 '^pid=' "$owner_file" 2>/dev/null | cut -d= -f2)"
    owner_host="$(grep -m1 '^host=' "$owner_file" 2>/dev/null | cut -d= -f2)"
    if [ "$owner_host" = "$this_host" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
      rm -rf "$lock_dir"
      mkdir "$lock_dir" 2>/dev/null || { specrelay::out::err "update: failed to reclaim a stale update lock (lost a race)"; return 1; }
    else
      specrelay::out::err "update: another update is already in progress (pid ${owner_pid:-unknown} on ${owner_host:-unknown host})"
      return 1
    fi
  fi
  { printf 'pid=%s\n' "$$"; printf 'host=%s\n' "$this_host"; } > "$owner_file"
  return 0
}

specrelay::update::_lock_release() {
  local home="$1" lock_dir
  lock_dir="$(specrelay::update::_lock_dir "$home")"
  rm -rf "$lock_dir" 2>/dev/null || true
}

# specrelay::update::_stage <source> <staging-dir>
# Copies a source checkout's tool-owned payload into a fresh staging
# directory. Never touches <source>.
specrelay::update::_stage() {
  local src="$1" staging="$2"
  rm -rf "$staging"
  mkdir -p "$staging" || return 1
  cp -R "$src/lib" "$staging/lib" || return 1
  cp -R "$src/templates" "$staging/templates" || return 1
  cp "$src/VERSION" "$staging/VERSION" || return 1
  [ -d "$src/docs" ] && cp -R "$src/docs" "$staging/docs"
  [ -f "$src/README.md" ] && cp "$src/README.md" "$staging/README.md"
  return 0
}

# specrelay::update::_verify_staged <staging-dir> <bin-target> <expected-version>
# Verifies the staged payload BEFORE activation: resources present, and a
# throwaway copy of the launcher actually runs against it and reports the
# expected version.
specrelay::update::_verify_staged() {
  local staging="$1" bin_target="$2" expected="$3" probe got
  [ -f "$staging/VERSION" ] && [ -d "$staging/lib/specrelay" ] || { specrelay::out::err "update: staged payload is incomplete"; return 1; }
  probe="$(mktemp "${TMPDIR:-/tmp}/specrelay-update-probe.XXXXXX")"
  cp "$bin_target" "$probe" && chmod +x "$probe"
  got="$(SPECRELAY_HOME="$staging" "$probe" version 2>/dev/null)"
  rm -f "$probe"
  [ "$got" = "specrelay $expected" ]
}

# specrelay::update::_activate <share> <staging-dir> <pid-tag>
# Atomic swap: rename current share aside, rename staging into place. Returns
# non-zero (leaving <share> exactly as it was) if the swap itself fails.
# On success, <share>.old-<tag> is left staged aside deliberately — it is the
# only copy of the prior installation, and perform's post-activation
# re-verification (11.2) must still be able to roll back to it. The caller is
# responsible for removing it once that re-verification passes.
specrelay::update::_activate() {
  local share="$1" staging="$2" tag="$3" old
  old="$share.old-$tag"
  if [ -e "$share" ]; then
    mv "$share" "$old" || return 1
  fi
  if ! mv "$staging" "$share"; then
    # Roll the previous install straight back into place.
    [ -e "$old" ] && mv "$old" "$share"
    return 1
  fi
  return 0
}

# specrelay::update::_rollback <share> <staging-dir> <pid-tag>
# Used when post-activation verification fails: restore the prior install.
specrelay::update::_rollback() {
  local share="$1" staging="$2" tag="$3" old activated
  old="$share.old-$tag"
  activated="$share.failed-$tag"
  [ -e "$share" ] && mv "$share" "$activated"
  [ -e "$old" ] && mv "$old" "$share"
  rm -rf "$activated" "$staging" 2>/dev/null || true
}

# specrelay::update::perform <home> <bin-target> <source-path> <expected-version> \
#   <expected-commit> [metadata-source-repo]
# Full stage -> verify -> activate -> re-verify -> (rollback on failure)
# sequence. Writes installation metadata only after activation succeeds.
# Never mutates <source-path>. <metadata-source-repo> is the DURABLE update
# source recorded in metadata (a real repository URL/path); it defaults to
# <source-path> but callers that staged from a throwaway clone of a
# configured official source should pass that source explicitly so metadata
# does not end up pointing at a deleted temp directory.
specrelay::update::perform() {
  local home="$1" bin_target="$2" source_path="$3" expected_version="$4" expected_commit="$5"
  local metadata_repo="${6:-$3}"
  local share tag staging
  share="$home"
  tag="$$"
  staging="$share.staging-$$"

  specrelay::update::_lock_acquire "$home" || return 1

  if ! specrelay::update::_stage "$source_path" "$staging"; then
    specrelay::out::err "update: failed to stage the new installation; the current installation is untouched"
    rm -rf "$staging"
    specrelay::update::_lock_release "$home"
    return 1
  fi

  if ! specrelay::update::_verify_staged "$staging" "$bin_target" "$expected_version"; then
    specrelay::out::err "update: staged installation failed verification; the current installation is untouched"
    rm -rf "$staging"
    specrelay::update::_lock_release "$home"
    return 1
  fi

  if ! specrelay::update::_activate "$share" "$staging" "$tag"; then
    specrelay::out::err "update: activation failed; the prior installation has been restored"
    specrelay::update::_lock_release "$home"
    return 1
  fi

  # Post-activation re-verification (11.2): the SAME check, now against the
  # live path. A failure here rolls back automatically. Only after this
  # passes is the prior installation (still staged aside at
  # <share>.old-<tag> by _activate) safe to discard.
  if ! specrelay::update::_verify_staged "$share" "$bin_target" "$expected_version"; then
    specrelay::out::err "update: post-activation verification failed; rolling back to the prior installation"
    specrelay::update::_rollback "$share" "" "$tag"
    specrelay::update::_lock_release "$home"
    return 1
  fi

  rm -rf "$share.old-$tag"

  specrelay::install_metadata::write "$share" "$expected_version" "$expected_commit" \
    "$bin_target" "$share" "official-git" "$metadata_repo" "main" || true

  specrelay::update::_lock_release "$home"
  printf 'Installed version: specrelay %s\n' "$expected_version"
  printf 'Installed commit:  %s\n' "$expected_commit"
  return 0
}
