#!/usr/bin/env bash
# archive.sh — relocate completed (terminal-state) tasks out of the active runs
# root into an archive directory, preserving every artifact.
#
# A "completed" task is one that has reached a terminal lifecycle state:
#   * READY_FOR_HUMAN_REVIEW — accepted by the reviewer, awaiting the final
#     human sign-off (the normal end of a successful run); always archivable.
#   * BLOCKED — a terminal failure the pipeline could not complete; archived
#     only on explicit opt-in (--include-blocked) so failures are not hidden
#     by accident.
#
# Archiving is a plain, reversible MOVE: the task's directory (state.json plus
# every numbered artifact and its iterations/ history) is moved verbatim under
# the archive root — which lives OUTSIDE the runs root — so `task list`/`status`
# no longer scan it, while nothing is deleted. To restore one, move its
# directory back under the runs root.
#
# Safety guarantees (never hide in-flight or foreign work):
#   * refuses a task a live process still owns (lock liveness live-local/
#     live-foreign) — an in-flight task is never archived out from under a run;
#   * refuses a task in any non-terminal state;
#   * refuses a task not owned by the SpecRelay engine (mutating relocation
#     respects the same ownership contract as every other mutating command);
#   * never overwrites an existing archived copy.

# specrelay::archive::root <project-root>
# Prints the absolute archive root. Configurable via `tasks.archive_root`; the
# generic default is `.specrelay-runs/archive` — deliberately a SIBLING of the
# runs root (`.specrelay-runs/tasks`) and OUTSIDE it, so archived tasks are
# never re-discovered by specrelay::task::list_ids.
specrelay::archive::root() {
  local root="$1" value=".specrelay-runs/archive"
  if specrelay::config::exists "$root"; then
    value="$(specrelay::config::get "$root" "tasks.archive_root" ".specrelay-runs/archive")"
  fi
  printf '%s/%s\n' "$root" "$value"
}

# specrelay::archive::is_archivable_state <state> <include-blocked 0|1>
# True when a task in <state> may be archived. READY_FOR_HUMAN_REVIEW always
# qualifies; BLOCKED qualifies only when include-blocked is 1.
specrelay::archive::is_archivable_state() {
  local state="$1" include_blocked="${2:-0}"
  case "$state" in
    READY_FOR_HUMAN_REVIEW) return 0 ;;
    BLOCKED) [ "$include_blocked" = "1" ] ;;
    *) return 1 ;;
  esac
}

# specrelay::archive::task <project-root> <task-id> <include-blocked 0|1> <dry-run 0|1>
# Archives ONE task after all safety checks. Prints a single outcome line to
# stdout on success (or, in dry-run, what it would do). Returns 0 when the task
# was archived (or would be), 1 on any refusal.
specrelay::archive::task() {
  local root="$1" task_id="$2" include_blocked="${3:-0}" dry_run="${4:-0}"
  local task_dir state_file state engine liveness archive_root dest lock_dir allowed

  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"

  if [ ! -f "$state_file" ]; then
    specrelay::out::err "archive: no such task '$task_id'"
    return 1
  fi

  # Ownership: a mutating relocation refuses a task another engine owns, exactly
  # as every other mutating command does (see transitions::_require_owned).
  engine="$(specrelay::state::get "$state_file" "engine" 2>/dev/null || true)"
  if [ "$engine" != "specrelay" ]; then
    specrelay::out::err "refusing to archive '$task_id': not owned by the SpecRelay engine (engine=${engine:-<legacy/unset>})"
    return 1
  fi

  state="$(specrelay::state::canonical "$state_file")"
  if ! specrelay::archive::is_archivable_state "$state" "$include_blocked"; then
    if [ "$state" = "BLOCKED" ]; then
      specrelay::out::err "refusing to archive '$task_id': BLOCKED tasks are archived only with --include-blocked"
    else
      allowed="READY_FOR_HUMAN_REVIEW"
      [ "$include_blocked" = "1" ] && allowed="READY_FOR_HUMAN_REVIEW or BLOCKED"
      specrelay::out::err "refusing to archive '$task_id': state is $state (only completed tasks — $allowed — can be archived)"
    fi
    return 1
  fi

  # Never archive a task a live process still owns.
  liveness="$(specrelay::lock::owner_liveness "$root" "$task_id")"
  case "$liveness" in
    live-local|live-foreign)
      specrelay::out::err "refusing to archive '$task_id': a live process still owns it ($(specrelay::lock::owner_description "$root" "$task_id"))"
      specrelay::out::err "wait for it to finish, or stop it, before archiving; nothing was changed"
      return 1
      ;;
  esac

  archive_root="$(specrelay::archive::root "$root")"
  dest="$archive_root/$task_id"
  if [ -e "$dest" ]; then
    specrelay::out::err "refusing to archive '$task_id': an archived copy already exists at $dest"
    return 1
  fi

  if [ "$dry_run" = "1" ]; then
    printf 'would archive %s (%s) -> %s\n' "$task_id" "$state" "$dest"
    return 0
  fi

  # Stamp provenance BEFORE moving: auditable, and it lets a later restore know
  # the original state. This is a metadata update, not a lifecycle transition
  # (the task keeps its terminal state).
  if ! specrelay::state::set "$state_file" \
      "$(printf '{"archived_at": "%s", "archived_from_state": "%s"}' \
        "$(specrelay::transitions::_now)" "$state")" >/dev/null 2>&1; then
    specrelay::out::err "archive: failed to stamp provenance on '$task_id'; nothing was moved"
    return 1
  fi

  # A stale (dead-owner) lock on a terminal task is meaningless — a live lock
  # was already refused above. Remove it so it does not linger.
  lock_dir="$(specrelay::lock::_dir "$root" "$task_id")"
  [ -d "$lock_dir" ] && rm -rf "$lock_dir"

  mkdir -p "$archive_root"
  if ! mv "$task_dir" "$dest"; then
    specrelay::out::err "archive: failed to move '$task_id' to $dest"
    return 1
  fi

  printf 'archived %s (%s) -> %s\n' "$task_id" "$state" "$dest"
  return 0
}
