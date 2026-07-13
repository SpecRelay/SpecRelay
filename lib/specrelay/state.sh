#!/usr/bin/env bash
# state.sh — thin bash wrapper around py/state_lib.py (SpecRelay's own,
# independent task-state module — see that file's docstring for why this is
# not a re-use of .ai/scripts/internal/lib/ai_state.py).
#
# Every function below shells out to state_lib.py with plain positional
# arguments (never interpolated into a python source string), so untrusted
# task ids / field values cannot inject code.

SPECRELAY_STATE_LIB_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/state_lib.py"

specrelay::state::require_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    specrelay::out::err "python3 is required but was not found on PATH."
    return 1
  fi
}

# specrelay::state::path <task-dir>
specrelay::state::path() {
  printf '%s/state.json\n' "$1"
}

# specrelay::state::current_schema_version
# Prints the state.json schema version this engine writes for NEW tasks. The
# single source of truth is state_lib.py's CURRENT_SCHEMA_VERSION; callers must
# not hardcode the number.
specrelay::state::current_schema_version() {
  specrelay::state::require_python || return 1
  python3 "$SPECRELAY_STATE_LIB_PY" schema-version
}

# specrelay::state::get <state-file> <field>
specrelay::state::get() {
  specrelay::state::require_python || return 1
  python3 "$SPECRELAY_STATE_LIB_PY" get "$1" "$2"
}

# specrelay::state::normalize <raw-state>
specrelay::state::normalize() {
  case "$1" in
    READY_FOR_CODEX_REVIEW) printf '%s\n' "READY_FOR_REVIEW" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# specrelay::state::canonical <state-file>
# Prints the CANONICAL current state (normalizing a legacy alias), or nothing
# if the file is missing/invalid.
specrelay::state::canonical() {
  local file="$1" raw
  [ -f "$file" ] || return 0
  raw="$(specrelay::state::get "$file" "state")" || return 0
  specrelay::state::normalize "$raw"
}

# specrelay::state::init <state-file> <fields-json>
specrelay::state::init() {
  specrelay::state::require_python || return 1
  python3 "$SPECRELAY_STATE_LIB_PY" init "$1" "$2"
}

# specrelay::state::set <state-file> <set-json>
# Merges fields into an EXISTING state.json with NO transition/state
# validation — a metadata update, not a lifecycle transition.
specrelay::state::set() {
  specrelay::state::require_python || return 1
  python3 "$SPECRELAY_STATE_LIB_PY" set "$1" "$2"
}

# specrelay::state::_csv_contains <csv> <value>
# True when <value> is one of the comma-separated entries in <csv>.
specrelay::state::_csv_contains() {
  local csv="$1" value="$2" item
  local IFS=,
  for item in $csv; do
    [ "$item" = "$value" ] && return 0
  done
  return 1
}

# specrelay::state::transition <state-file> <allowed-states-csv> <target-state> <set-json> [<clear-json>]
#
# Presentation (spec 0013): when the current state is actually an allowed source
# state, a Level 2 transition card is emitted just before the transition. The
# card is the enhanced VISUAL for a lifecycle transition; the authoritative
# machine-parseable "Transitioned: <from> -> <to>" line still comes from
# state_lib.py below (unchanged), so existing log parsers keep working. A
# refused transition (source state not allowed) prints no card, so a card never
# implies a transition that did not happen.
specrelay::state::transition() {
  specrelay::state::require_python || return 1
  local file="$1" allowed_csv="$2" target="$3" from
  from="$(specrelay::state::canonical "$file")"
  if [ -n "$from" ] && specrelay::state::_csv_contains "$allowed_csv" "$from"; then
    specrelay::out::transition_card "$from" "$target"
  fi
  python3 "$SPECRELAY_STATE_LIB_PY" transition "$@"
}
