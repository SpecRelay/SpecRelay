#!/usr/bin/env bash
# marker.sh — the mandatory Reviewer DECISION marker contract (spec 0019,
# "Mandatory Decision Marker").
#
# A single, shared parser so every caller (providers/claude.sh's real
# reviewer, marker_recovery.sh's corrective attempt, and tests) agrees on
# EXACTLY what counts as a valid final decision marker: it must appear
# exactly once, in uppercase, on its own line, and be the final non-empty
# line of the reviewer's output. Prose ("I accept this implementation.") is
# never inferred as a decision.

# specrelay::marker::parse <reviewer-output>
# Prints ACCEPT or REQUEST_CHANGES on success (exit 0). Prints nothing and
# returns 1 when no valid marker is present (missing, lowercase, duplicated,
# conflicting, or not the final non-empty line).
specrelay::marker::parse() {
  local text="$1"
  local last_nonempty
  last_nonempty="$(printf '%s\n' "$text" | awk 'NF{last=$0} END{print last}')"

  local accept_count request_count
  accept_count="$(printf '%s\n' "$text" | grep -cE '^DECISION:[[:space:]]*ACCEPT[[:space:]]*$' || true)"
  request_count="$(printf '%s\n' "$text" | grep -cE '^DECISION:[[:space:]]*REQUEST_CHANGES[[:space:]]*$' || true)"

  # Duplicate (same marker more than once) or conflicting (both markers
  # present) output is never a valid decision.
  if [ "$((accept_count + request_count))" -eq 0 ]; then
    return 1
  fi
  if [ "$accept_count" -gt 1 ] || [ "$request_count" -gt 1 ]; then
    return 1
  fi
  if [ "$accept_count" -eq 1 ] && [ "$request_count" -eq 1 ]; then
    return 1
  fi

  # The marker must be the FINAL non-empty line — not merely present anywhere.
  case "$last_nonempty" in
    'DECISION: ACCEPT')
      [ "$accept_count" -eq 1 ] || return 1
      printf 'ACCEPT\n'
      return 0
      ;;
    'DECISION: REQUEST_CHANGES')
      [ "$request_count" -eq 1 ] || return 1
      printf 'REQUEST_CHANGES\n'
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# specrelay::marker::artifacts_consistent <task-dir> <decision>
# Validates the artifact/marker consistency contract (spec 0019, "Decision
# Consistency") BEFORE a transition is applied:
#   ACCEPT          requires 09-consultant-review.md and 10-business-summary.md
#                   non-empty, and NO required-changes prompt.
#   REQUEST_CHANGES requires 09-consultant-review.md and
#                   11-next-executor-prompt.md non-empty.
# Prints nothing; returns 0 when consistent, 1 with a clear reason on stderr
# otherwise. A conflicting artifact/marker combination must fail clearly
# rather than silently proceed.
specrelay::marker::artifacts_consistent() {
  local task_dir="$1" decision="$2"

  if [ ! -s "$task_dir/09-consultant-review.md" ]; then
    specrelay::out::err "decision '$decision' is inconsistent with artifacts: 09-consultant-review.md is missing or empty"
    return 1
  fi

  case "$decision" in
    ACCEPT)
      if [ ! -s "$task_dir/10-business-summary.md" ]; then
        specrelay::out::err "decision ACCEPT is inconsistent with artifacts: 10-business-summary.md is missing or empty"
        return 1
      fi
      ;;
    REQUEST_CHANGES)
      if [ ! -s "$task_dir/11-next-executor-prompt.md" ]; then
        specrelay::out::err "decision REQUEST_CHANGES is inconsistent with artifacts: 11-next-executor-prompt.md is missing or empty"
        return 1
      fi
      ;;
    *)
      specrelay::out::err "unrecognized decision '$decision'"
      return 1
      ;;
  esac

  # Reviewer completion gate, input-coverage clause (spec 0023, section
  # 21.3: "reviewer input coverage is missing" must fail completion). Only
  # applies to tasks that actually have a bundle manifest — legacy tasks
  # predating spec 0023 never have one, and are unaffected.
  if [ -f "$task_dir/01-input-manifest.json" ]; then
    if ! grep -Eqi '^#+[[:space:]]*Input Coverage' "$task_dir/09-consultant-review.md" 2>/dev/null; then
      specrelay::out::err "decision '$decision' is inconsistent with artifacts: 09-consultant-review.md does not record an Input Coverage section (spec 0023, section 21.3)"
      return 1
    fi
  fi
  return 0
}
