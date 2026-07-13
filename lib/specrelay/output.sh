#!/usr/bin/env bash
# output.sh — shared print helpers for the SpecRelay CLI, with OPTIONAL,
# terminal-only ANSI color.
#
# Color policy lives HERE for the shell side (the Python runtimes share
# lib/specrelay/py/color.py); no raw ANSI escapes are sprinkled through the rest
# of the engine. Every colorized engine/orchestrator line goes through one of
# the helpers below.
#
# Color mode is chosen by SPECRELAY_COLOR (auto|always|never), defaulting to
# auto; an unrecognized value is treated as auto. In auto mode color is emitted
# only when the target stream is a TTY and NO_COLOR is unset. NO_COLOR (present
# with any value, per https://no-color.org) disables color in auto/never but is
# overridden by SPECRELAY_COLOR=always. CI / non-TTY output therefore stays
# plain text by default — content is byte-for-byte identical to the uncolored
# form, so evidence, greps, and machine parsing are unaffected.

# Path to the shared Unicode card renderer (spec 0013). Resolved once at source
# time from this file's own location, mirroring state.sh's state_lib.py path.
SPECRELAY_RENDER_CARD_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/render_card.py"

# specrelay::color::mode -> echoes auto|always|never (unrecognized -> auto).
specrelay::color::mode() {
  local m
  m="$(printf '%s' "${SPECRELAY_COLOR:-auto}" | tr '[:upper:]' '[:lower:]')"
  case "$m" in
    auto|always|never) printf '%s' "$m" ;;
    *) printf 'auto' ;;
  esac
}

# specrelay::color::enabled <fd> -> return 0 when color should be emitted on the
# given file descriptor (default 1 = stdout; use 2 for stderr).
specrelay::color::enabled() {
  local fd="${1:-1}"
  case "$(specrelay::color::mode)" in
    always) return 0 ;;
    never)  return 1 ;;
  esac
  # auto: honor NO_COLOR (presence, any value), then require a TTY.
  [ -n "${NO_COLOR+x}" ] && return 1
  [ -t "$fd" ] && return 0
  return 1
}

# specrelay::color::seq <name> -> raw escape sequence for a named color.
specrelay::color::seq() {
  case "$1" in
    reset)   printf '\033[0m' ;;
    dim)     printf '\033[2m' ;;
    bold)    printf '\033[1m' ;;
    red)     printf '\033[31m' ;;
    green)   printf '\033[32m' ;;
    yellow)  printf '\033[33m' ;;
    blue)    printf '\033[34m' ;;
    magenta) printf '\033[35m' ;;
    cyan)    printf '\033[36m' ;;
  esac
}

# specrelay::out::err <message> — error line to stderr, red when stderr is a
# color-capable TTY.
specrelay::out::err() {
  if specrelay::color::enabled 2; then
    printf '%sspecrelay: %s%s\n' \
      "$(specrelay::color::seq red)" "$1" "$(specrelay::color::seq reset)" >&2
  else
    echo "specrelay: $1" >&2
  fi
}

# specrelay::out::section <heading> — a blank line then a section heading on
# stdout, bold when stdout is a color-capable TTY.
specrelay::out::section() {
  echo
  if specrelay::color::enabled 1; then
    printf '%s%s%s\n' \
      "$(specrelay::color::seq bold)" "$1" "$(specrelay::color::seq reset)"
  else
    echo "$1"
  fi
}

# specrelay::out::log <line> — an engine/orchestrator status line on stdout.
# When color is enabled: the leading "[tag]" is dimmed and the body is accented
# by the state keywords it mentions (green for progress toward completion,
# yellow for rework/warnings, red for refusals/failures). Plain otherwise, so
# the exact text is preserved for non-TTY consumers.
specrelay::out::log() {
  local line="$1"
  if ! specrelay::color::enabled 1; then
    printf '%s\n' "$line"
    return 0
  fi

  local body_color=""
  case "$line" in
    *"reached READY_FOR_HUMAN_REVIEW"*|*": accepted"*|*"submitted for review"*|*"approving task"*)
      body_color="$(specrelay::color::seq green)" ;;
    *"requeuing"*|*"changes requested"*|*"changes already requested"*|*WARNING*|*"proceeding"*)
      body_color="$(specrelay::color::seq yellow)" ;;
    *failed*|*refusing*|*"non-zero"*|*unexpected*|*BLOCKED*|*"no safe automated step"*)
      body_color="$(specrelay::color::seq red)" ;;
  esac

  local reset dim
  reset="$(specrelay::color::seq reset)"
  dim="$(specrelay::color::seq dim)"

  # Split a leading "[tag] " so the tag can be dimmed independently of the body.
  if [[ "$line" =~ ^(\[[^]]*\])\ (.*)$ ]]; then
    local tag="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[2]}"
    if [ -n "$body_color" ]; then
      printf '%s%s%s %s%s%s\n' "$dim" "$tag" "$reset" "$body_color" "$rest" "$reset"
    else
      printf '%s%s%s %s\n' "$dim" "$tag" "$reset" "$rest"
    fi
  elif [ -n "$body_color" ]; then
    printf '%s%s%s\n' "$body_color" "$line" "$reset"
  else
    printf '%s\n' "$line"
  fi
}

# --- stream-friendly cards (spec 0013) --------------------------------------
#
# The card helpers below add the spec 0013 visual hierarchy (major sections,
# transitions, role headers, result/summary cards) WITHOUT changing execution
# semantics. They are strictly APPEND-ONLY: they only ever write complete lines
# through render_card.py, never a cursor/redraw/clear sequence, so every card
# stays visible in scrollback and survives piping/redirection. Color (when
# enabled) accents only the box borders/title; the state, provider and result
# names are always present as plain text inside the card, so existing log
# parsers keep working and the hierarchy stays obvious with color disabled.

# specrelay::out::card <color> <title> [body...]
# Render a titled Unicode card. <color> is one of green|blue|magenta|yellow|
# red|none. Falls back to a plain (still append-only) block when python3 / the
# renderer is unavailable, so no card ever hides information.
specrelay::out::card() {
  local color="$1" title="$2"
  shift 2
  if command -v python3 >/dev/null 2>&1 && [ -f "$SPECRELAY_RENDER_CARD_PY" ]; then
    python3 "$SPECRELAY_RENDER_CARD_PY" card "$color" "$title" "$@"
    return 0
  fi
  echo "== $title =="
  local b
  for b in "$@"; do
    echo "  $b"
  done
}

# specrelay::out::transition_card <from-state> <to-state>
# Render the Level 2 transition card (source ─────▶ destination). The border
# color is derived from the DESTINATION state (green = a completed/human-review
# terminal, yellow = rework requested, red = blocked, blue = an in-flight
# running/handoff state); the state names themselves are always plain text.
specrelay::out::transition_card() {
  local from="$1" to="$2" color
  case "$to" in
    READY_FOR_HUMAN_REVIEW) color=green ;;
    CHANGES_REQUESTED)      color=yellow ;;
    BLOCKED)                color=red ;;
    *)                      color=blue ;;
  esac
  if command -v python3 >/dev/null 2>&1 && [ -f "$SPECRELAY_RENDER_CARD_PY" ]; then
    python3 "$SPECRELAY_RENDER_CARD_PY" transition "$color" "$from" "$to"
    return 0
  fi
  echo "== Transition: $from -> $to =="
}

# specrelay::out::format_duration <seconds>
# Human-friendly elapsed time for result cards ("3s", "1m 5s"). A non-integer
# value is printed unchanged (never guesses).
specrelay::out::format_duration() {
  local s="$1"
  case "$s" in
    ''|*[!0-9]*) printf '%s\n' "$s"; return 0 ;;
  esac
  if [ "$s" -lt 60 ]; then
    printf '%ds\n' "$s"
  else
    printf '%dm %ds\n' "$((s / 60))" "$((s % 60))"
  fi
}
