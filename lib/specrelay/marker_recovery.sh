#!/usr/bin/env bash
# marker_recovery.sh — narrow, single-attempt DECISION-marker-only recovery
# (spec 0019, "Smart Marker Recovery").
#
# Triggered ONLY when a reviewer provider exited successfully (rc=2 from
# specrelay::provider::reviewer_run — "ran fine, but no valid marker", never
# rc=1 "the process itself failed") AND the review artifacts strongly
# indicate the decision was already reached and only the final marker line
# is missing. It NEVER repeats the whole review, runs repository tools, or
# rewrites implementation files — it reads at most 3 already-written files
# and asks for exactly one line.

# specrelay::marker_recovery::eligible <task-dir>
# Prints the inferred decision (ACCEPT|REQUEST_CHANGES) on success (exit 0)
# when recovery is SAFE to attempt. Prints nothing and returns 1 when
# recovery is forbidden (spec 0019, "When Smart Recovery Is Forbidden"):
# missing/empty 09-consultant-review.md, an unclear/absent structured
# `Decision: ...` field in it, or (for REQUEST_CHANGES) a missing/empty
# 11-next-executor-prompt.md.
specrelay::marker_recovery::eligible() {
  local task_dir="$1" review
  review="$task_dir/09-consultant-review.md"

  if [ ! -s "$review" ]; then
    return 1
  fi

  # Preferred structured field (spec 0019, "Recovery Decision Extraction"):
  # a line "Decision: ACCEPT" or "Decision: REQUEST_CHANGES" inside the
  # review artifact itself. Vague sentiment ("looks good overall") is never
  # sufficient — only this exact structured field is honored.
  local field
  field="$(grep -E '^Decision:[[:space:]]*(ACCEPT|REQUEST_CHANGES)[[:space:]]*$' "$review" | tail -n1 | sed -E 's/^Decision:[[:space:]]*//; s/[[:space:]]*$//')"

  case "$field" in
    ACCEPT)
      if [ -s "$task_dir/10-business-summary.md" ]; then
        printf 'ACCEPT\n'
        return 0
      fi
      return 1
      ;;
    REQUEST_CHANGES)
      if [ -s "$task_dir/11-next-executor-prompt.md" ]; then
        printf 'REQUEST_CHANGES\n'
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# specrelay::marker_recovery::prompt <task-dir> <task-rel>
# Prints the path to a freshly written, NARROW corrective prompt file. It
# never contains the original review prompt, the spec, or the diff — only an
# instruction to read the already-written artifacts and emit one line.
specrelay::marker_recovery::prompt() {
  local task_dir="$1" task_rel="$2" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/specrelay-marker-recovery.XXXXXX")"
  {
    echo "Your review artifacts already exist, but the required final decision"
    echo "marker is missing."
    echo
    echo "Do not repeat the review."
    echo "Do not run tests."
    echo "Do not inspect the repository again."
    echo
    echo "Read only:"
    echo "  $task_rel/09-consultant-review.md"
    echo "  $task_rel/10-business-summary.md"
    echo "  $task_rel/11-next-executor-prompt.md (if present)"
    echo
    echo "Then output exactly one line, and nothing else:"
    echo "  DECISION: ACCEPT"
    echo "or:"
    echo "  DECISION: REQUEST_CHANGES"
  } > "$tmp"
  printf '%s\n' "$tmp"
}

# specrelay::marker_recovery::attempt <root> <task-dir> <task-id> <provider> <model> <agent>
# Runs the ONE corrective attempt (spec 0019, "Corrective Attempt Limits").
# Prints ACCEPT|REQUEST_CHANGES on success (exit 0); prints nothing and
# returns 1 on failure (task stays REVIEWER_RUNNING — no fallback repeat).
# Records the attempt (and its outcome) in the timeline regardless of
# result.
specrelay::marker_recovery::attempt() {
  local root="$1" task_dir="$2" task_id="$3" provider="$4" model="$5" agent="$6"
  local task_rel prompt_file decision rc

  task_rel="${task_dir#"$root"/}"
  prompt_file="$(specrelay::marker_recovery::prompt "$task_dir" "$task_rel")"

  specrelay::timeline::start "$task_dir" reviewer_marker_recovery reviewer
  if decision="$(specrelay::provider::reviewer_recover_marker "$provider" "$root" "$task_dir" "$prompt_file" "$model" "$agent")"; then
    rc=0
  else
    rc=$?
  fi
  rm -f "$prompt_file"

  decision="$(printf '%s\n' "$decision" | tail -n1 | tr -d '[:space:]')"

  if [ "$rc" -eq 0 ] && { [ "$decision" = "ACCEPT" ] || [ "$decision" = "REQUEST_CHANGES" ]; }; then
    specrelay::timeline::finish "$task_dir" reviewer_marker_recovery passed
    specrelay::timeline::marker_recovery_event "$task_dir" true success
    printf '%s\n' "$decision"
    return 0
  fi

  specrelay::timeline::finish "$task_dir" reviewer_marker_recovery failed
  specrelay::timeline::marker_recovery_event "$task_dir" true failed
  return 1
}
