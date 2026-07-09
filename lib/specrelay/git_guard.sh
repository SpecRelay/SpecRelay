#!/usr/bin/env bash
# git_guard.sh — dirty-working-tree baseline and task-owned-change tracking
# (spec sections 30-33). This is the fix for the legacy workflow's known,
# documented limitation (docs/current-workflow-contract.md, section 9): the
# legacy guard cannot distinguish a task's own still-uncommitted round-1 diff
# from a genuinely unrelated change, so the automated requeue retry path gets
# stuck. See docs/engine-parity.md for the full design writeup.
#
# Model:
#   - BASELINE (.git-baseline.txt, captured once at task creation, BEFORE any
#     task file is written): the working-tree paths that were already dirty
#     before this task existed. Never re-captured; it is a fact about the
#     moment the task was created.
#   - OWNED SNAPSHOT (.git-owned-snapshot.txt, captured after every
#     successful evidence capture): the working-tree paths that are the
#     task's OWN accumulated, legitimate changes so far (round 1 diff, round
#     2 diff, ...). This is what makes iteration 2 possible: it is the
#     working tree the PREVIOUS iteration intentionally left behind, so it
#     must never be misclassified as "unrelated."
#   - Before claiming any iteration, the guard computes the current
#     tree's changed paths and requires them to be a subset of
#     BASELINE ∪ OWNED SNAPSHOT. Anything outside that set is an unexpected
#     external change (Case 3) and blocks the claim, listing exact paths.
#   - If this is the FIRST iteration (no owned snapshot yet) and BASELINE
#     itself is non-empty (Case 2: pre-existing unrelated dirt), the claim is
#     also blocked UNLESS the task was explicitly created with
#     allow_pre_existing_dirty=true — an explicit, evidence-recorded policy
#     choice, never a silent default.
#   - Two path prefixes are ALWAYS treated as "related" (excluded from every
#     snapshot), mirroring the legacy guard's own allow-list
#     (docs/current-workflow-contract.md, section 9):
#       1. the configured task-runs root (e.g. .ai-runs/tasks/) — the
#          engine's own bookkeeping;
#       2. this task's recorded spec source's containing directory (e.g.
#          docs/sdd/<task-id>/) — an uncommitted spec file is the whole
#          reason the task exists, not an unrelated change. In this
#          repository the runs root is also gitignored, but neither
#          exclusion relies on that.

# specrelay::git_guard::_paths <project-root> [task-dir]
# Prints the sorted list of paths currently reported by `git status
# --porcelain`, one per line (for a rename "old -> new" both sides are
# listed, so a guard comparison is conservative rather than clever),
# EXCLUDING the task-runs root and (if a task-dir with a recorded
# spec_source is given) that spec's containing directory.
specrelay::git_guard::_paths() {
  local root="$1" task_dir="${2:-}" runs_root runs_root_rel extra_rel=""
  runs_root="$(specrelay::task::runs_root "$root")"
  runs_root_rel="${runs_root#"$root"/}"

  if [ -n "$task_dir" ]; then
    local state_file spec_source
    state_file="$(specrelay::state::path "$task_dir")"
    if [ -f "$state_file" ]; then
      spec_source="$(specrelay::state::get "$state_file" "spec_source" 2>/dev/null)"
      [ -n "$spec_source" ] && extra_rel="$(dirname "$spec_source")"
    fi
  fi

  (cd "$root" && git status --porcelain --untracked-files=all) | sed -E 's/^.. //' | sed -E 's/^"(.*)"$/\1/' \
    | awk '{ n=split($0, parts, " -> "); for (i=1;i<=n;i++) print parts[i] }' \
    | awk -v prefix="$runs_root_rel/" -v extra="${extra_rel:+$extra_rel/}" \
        '$0 != "" && index($0, prefix) != 1 && (extra == "" || index($0, extra) != 1)' \
    | sort -u
}

specrelay::git_guard::_baseline_file() {
  printf '%s/.git-baseline.txt\n' "$1"
}

specrelay::git_guard::_owned_file() {
  printf '%s/.git-owned-snapshot.txt\n' "$1"
}

# specrelay::git_guard::snapshot_now <project-root> [spec-rel-path]
# Prints the current guard-relevant path snapshot (for a caller that needs to
# capture it BEFORE the task's own state.json/directory exist — see
# transitions::create, which calls this before `mkdir` and writes the result
# with write_baseline after). Pass the about-to-be-recorded spec_source
# directly since state.json cannot be read yet at this point.
specrelay::git_guard::snapshot_now() {
  local root="$1" spec_rel="${2:-}" runs_root runs_root_rel extra_rel=""
  runs_root="$(specrelay::task::runs_root "$root")"
  runs_root_rel="${runs_root#"$root"/}"
  [ -n "$spec_rel" ] && extra_rel="$(dirname "$spec_rel")"

  (cd "$root" && git status --porcelain --untracked-files=all) | sed -E 's/^.. //' | sed -E 's/^"(.*)"$/\1/' \
    | awk '{ n=split($0, parts, " -> "); for (i=1;i<=n;i++) print parts[i] }' \
    | awk -v prefix="$runs_root_rel/" -v extra="${extra_rel:+$extra_rel/}" \
        '$0 != "" && index($0, prefix) != 1 && (extra == "" || index($0, extra) != 1)' \
    | sort -u
}

# specrelay::git_guard::write_baseline <task-dir> <snapshot-text>
# Writes a PRE-CAPTURED snapshot (see snapshot_now above) as the baseline. A
# no-op if a baseline already exists (the baseline is a fact about
# task-creation time, never refreshed).
specrelay::git_guard::write_baseline() {
  local task_dir="$1" snapshot="$2" file
  file="$(specrelay::git_guard::_baseline_file "$task_dir")"
  [ -f "$file" ] && return 0
  printf '%s\n' "$snapshot" | sed '/^$/d' > "$file"
}

# specrelay::git_guard::capture_baseline <project-root> <task-dir>
# Convenience form for a caller that does NOT need the spec-directory
# exclusion resolved ahead of time (e.g. a test capturing a baseline for a
# task directory created moments before via some other path). Prefer
# snapshot_now + write_baseline around task creation itself.
specrelay::git_guard::capture_baseline() {
  local root="$1" task_dir="$2" file
  file="$(specrelay::git_guard::_baseline_file "$task_dir")"
  [ -f "$file" ] && return 0
  specrelay::git_guard::_paths "$root" "$task_dir" > "$file"
}

# specrelay::git_guard::snapshot_owned <project-root> <task-dir>
# Records the current working-tree paths as "owned by this task" — call
# this AFTER a successful evidence capture (i.e. after an executor iteration
# that will be submitted for review), so the NEXT claim's guard check allows
# this iteration's accumulated diff to persist.
specrelay::git_guard::snapshot_owned() {
  local root="$1" task_dir="$2" file
  file="$(specrelay::git_guard::_owned_file "$task_dir")"
  specrelay::git_guard::_paths "$root" "$task_dir" > "$file"
}

# specrelay::git_guard::check <project-root> <task-dir>
# Prints nothing and returns 0 if the working tree is safe to claim against.
# Returns 1 with a clear listing on stderr otherwise.
specrelay::git_guard::check() {
  local root="$1" task_dir="$2"
  local baseline_file owned_file current_file allow_dirty
  baseline_file="$(specrelay::git_guard::_baseline_file "$task_dir")"
  owned_file="$(specrelay::git_guard::_owned_file "$task_dir")"

  # Defensive: a baseline should already exist (written at task creation
  # time); capture one now if it is somehow missing rather than fail.
  [ -f "$baseline_file" ] || specrelay::git_guard::capture_baseline "$root" "$task_dir"

  current_file="$(mktemp "${TMPDIR:-/tmp}/specrelay-guard.XXXXXX")"
  specrelay::git_guard::_paths "$root" "$task_dir" > "$current_file"

  local allowed_file
  allowed_file="$(mktemp "${TMPDIR:-/tmp}/specrelay-guard-allowed.XXXXXX")"
  if [ -f "$owned_file" ]; then
    cat "$baseline_file" "$owned_file" | sort -u > "$allowed_file"
  else
    sort -u "$baseline_file" > "$allowed_file"
  fi

  local unexpected
  unexpected="$(comm -23 "$current_file" "$allowed_file")"

  if [ -n "$unexpected" ]; then
    specrelay::out::err "refusing: unexpected working-tree changes outside this task's known baseline/owned paths:"
    printf '%s\n' "$unexpected" | sed 's/^/  - /' >&2
    rm -f "$current_file" "$allowed_file"
    return 1
  fi
  rm -f "$current_file" "$allowed_file"

  if [ ! -f "$owned_file" ]; then
    local state_file
    state_file="$(specrelay::state::path "$task_dir")"
    allow_dirty="$(specrelay::state::get "$state_file" "allow_pre_existing_dirty" 2>/dev/null)"
    if [ -s "$baseline_file" ] && [ "$allow_dirty" != "True" ] && [ "$allow_dirty" != "true" ]; then
      specrelay::out::err "refusing: the working tree already had unrelated pre-existing changes when this task was created:"
      sed 's/^/  - /' "$baseline_file" >&2
      specrelay::out::err "recreate the task with allow_pre_existing_dirty=true if this is intentional (spec section 30-32 policy)"
      return 1
    fi
  fi

  return 0
}
