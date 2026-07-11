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

# specrelay::state::transition <state-file> <allowed-states-csv> <target-state> <set-json> [<clear-json>]
specrelay::state::transition() {
  specrelay::state::require_python || return 1
  python3 "$SPECRELAY_STATE_LIB_PY" transition "$@"
}
