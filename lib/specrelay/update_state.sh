#!/usr/bin/env bash
# update_state.sh — daily update-discovery cache and dismissal state (spec
# 0022, section 5 "Daily update discovery").
#
# State lives at <home>/update-state.json, i.e. under the INSTALLATION
# PREFIX, never in a consumer project repository. It is read/written ONLY in
# installed mode — source-local execution never touches this file (spec 1.1).
# Writes are atomic (temp file + rename).

SPECRELAY_UPDATE_STATE_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/update_state_lib.py"

# specrelay::update_state::path <home>
specrelay::update_state::path() {
  printf '%s/update-state.json\n' "$1"
}

# specrelay::update_state::read_field <home> <field> [default]
specrelay::update_state::read_field() {
  local home="$1" field="$2" default="${3:-}" out
  command -v python3 >/dev/null 2>&1 || { printf '%s\n' "$default"; return 0; }
  out="$(HOME_DIR="$home" FIELD="$field" python3 "$SPECRELAY_UPDATE_STATE_PY" read-field 2>/dev/null)" || out=""
  printf '%s\n' "${out:-$default}"
}

# specrelay::update_state::write <home> <last-checked-at> <last-available-version> \
#   <ignored-version> <last-check-status>
specrelay::update_state::write() {
  local home="$1" checked_at="$2" available="$3" ignored="$4" status="$5"
  command -v python3 >/dev/null 2>&1 || return 1
  HOME_DIR="$home" CHECKED_AT="$checked_at" AVAILABLE="$available" IGNORED="$ignored" STATUS="$status" \
    python3 "$SPECRELAY_UPDATE_STATE_PY" write
}

# specrelay::update_state::should_check <home> [now-epoch-seconds]
# Returns 0 (should check) when no state exists yet, the last check is
# unreadable, or 24h have elapsed since last_checked_at; returns 1 otherwise.
specrelay::update_state::should_check() {
  local home="$1" now="${2:-}"
  [ -n "$now" ] || now="$(date -u +%s)"
  local last_checked epoch
  last_checked="$(specrelay::update_state::read_field "$home" last_checked_at "")"
  [ -n "$last_checked" ] || return 0
  epoch="$(date -u -d "$last_checked" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_checked" +%s 2>/dev/null || true)"
  [ -n "$epoch" ] || return 0
  [ $((now - epoch)) -ge 86400 ]
}

# specrelay::update_state::set_ignored <home> <version>
# Records a rejected version WITHOUT disturbing the 24h cache fields.
specrelay::update_state::set_ignored() {
  local home="$1" version="$2" checked available status
  checked="$(specrelay::update_state::read_field "$home" last_checked_at "")"
  available="$(specrelay::update_state::read_field "$home" last_available_version "")"
  status="$(specrelay::update_state::read_field "$home" last_check_status "success")"
  specrelay::update_state::write "$home" "$checked" "$available" "$version" "$status"
}

# specrelay::update_state::reset <home>
# Clears cached check time and ignored/available versions (--reset-notifications).
specrelay::update_state::reset() {
  local home="$1" path
  path="$(specrelay::update_state::path "$home")"
  rm -f "$path" 2>/dev/null || true
  return 0
}
