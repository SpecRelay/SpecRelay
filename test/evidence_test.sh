#!/usr/bin/env bash
# evidence_test.sh — unit tests for evidence.sh: git status/diff/stat/patch
# capture, including untracked (new) files showing up as full additions
# (spec section 29) and the intent-to-add/reset dance never leaving files
# staged afterward.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/evidence.sh
. "$SPECRELAY_ROOT/lib/specrelay/evidence.sh"

proj="$(specrelay_test::mktemp_project)"
task_dir="$proj/.specrelay-runs/tasks/0001-fixture"
mkdir -p "$task_dir"

# Gitignore the task-runs root, matching this repository's real .gitignore
# (.specrelay-runs/) — otherwise the task folder's OWN evidence files would show up
# as "changes" in the very evidence they are capturing (a fixture artifact,
# not a real production concern).
printf '.specrelay-runs/\n' > "$proj/.gitignore"

# Baseline commit so there is a tracked file to modify.
echo "line one" > "$proj/tracked.txt"
(cd "$proj" && git add .gitignore tracked.txt && git commit -q -m "seed tracked file")

# Produce a representative change set: modify a tracked file, add a new file.
echo "line two" >> "$proj/tracked.txt"
echo "brand new content" > "$proj/new-file.txt"

specrelay::evidence::capture "$proj" "$task_dir"

specrelay_test::assert_contains "04-git-status.txt lists the modified tracked file" \
  "$(cat "$task_dir/04-git-status.txt")" "tracked.txt"
specrelay_test::assert_contains "04-git-status.txt lists the new untracked file" \
  "$(cat "$task_dir/04-git-status.txt")" "new-file.txt"

specrelay_test::assert_contains "05-changed-files.txt lists the modified tracked file" \
  "$(cat "$task_dir/05-changed-files.txt")" "tracked.txt"

specrelay_test::assert_contains "06-git-diff.patch includes the tracked file's diff" \
  "$(cat "$task_dir/06-git-diff.patch")" "line two"
specrelay_test::assert_contains "06-git-diff.patch shows the new file as a full addition" \
  "$(cat "$task_dir/06-git-diff.patch")" "brand new content"

specrelay_test::assert_contains "05-git-diff-stat.txt is non-empty" \
  "$(cat "$task_dir/05-git-diff-stat.txt")" "tracked.txt"

# The intent-to-add/reset dance must never leave anything staged afterward.
staged="$(cd "$proj" && git diff --cached --name-only)"
specrelay_test::assert_eq "no files remain staged after evidence capture" "" "$staged"

new_file_status="$(cd "$proj" && git status --porcelain -- new-file.txt)"
specrelay_test::assert_contains "the new file is restored to untracked (??) after capture" \
  "$new_file_status" "?? new-file.txt"

# --- clean tree: evidence files exist but are empty -------------------------
clean_proj="$(specrelay_test::mktemp_project)"
clean_task_dir="$clean_proj/.specrelay-runs/tasks/0002-clean"
mkdir -p "$clean_task_dir"
printf '.specrelay-runs/\n' > "$clean_proj/.gitignore"
echo "content" > "$clean_proj/committed.txt"
(cd "$clean_proj" && git add .gitignore committed.txt && git commit -q -m "seed")

specrelay::evidence::capture "$clean_proj" "$clean_task_dir"
for f in 04-git-status.txt 05-changed-files.txt 05-git-diff-stat.txt 06-git-diff.patch; do
  specrelay_test::assert_eq "on a clean tree, $f exists but is empty" \
    "0" "$([ -f "$clean_task_dir/$f" ] && [ ! -s "$clean_task_dir/$f" ] && echo 0 || echo 1)"
done

specrelay_test::summary
exit $?
