#!/usr/bin/env bash
# evidence.sh — durable git evidence capture (spec section 29).
#
# Reimplements the legacy capture-evidence.sh's intent-to-add/reset dance so
# untracked (new) files show up as full additions in the diff/stat, then are
# restored to untracked — never left staged. Writes the same artifact names
# as the legacy workflow (Artifact Compatibility Strategy: Option A — see
# docs/engine-parity.md) so a human comparing a SpecRelay task folder to a
# legacy one sees the same shape.

# specrelay::evidence::capture <project-root> <task-dir>
specrelay::evidence::capture() {
  local root="$1" task_dir="$2"
  local status_file="$task_dir/04-git-status.txt"
  local changed_file="$task_dir/05-changed-files.txt"
  local stat_file="$task_dir/05-git-diff-stat.txt"
  local patch_file="$task_dir/06-git-diff.patch"

  (
    cd "$root" || exit 1
    git status --short > "$status_file"

    local -a untracked=()
    while IFS= read -r f; do
      [ -n "$f" ] && untracked+=("$f")
    done < <(git ls-files --others --exclude-standard)

    if [ "${#untracked[@]}" -gt 0 ]; then
      git add --intent-to-add -- "${untracked[@]}"
    fi

    git diff --name-status > "$changed_file"
    git diff --stat > "$stat_file"
    git diff > "$patch_file"

    if [ "${#untracked[@]}" -gt 0 ]; then
      git reset -- "${untracked[@]}" > /dev/null
    fi
  )
}
