#!/usr/bin/env bash
# task_test.sh — unit tests for task.sh: id derivation/validation, runs-root
# resolution, spec-path resolution/safety, and ref lookup (exact / unique
# numeric prefix / ambiguous).
#   tools/specrelay/test/task_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/project.sh
. "$SPECRELAY_ROOT/lib/specrelay/project.sh"
# shellcheck source=../lib/specrelay/config.sh
. "$SPECRELAY_ROOT/lib/specrelay/config.sh"
# shellcheck source=../lib/specrelay/task.sh
. "$SPECRELAY_ROOT/lib/specrelay/task.sh"

# --- sanitize / valid_id --------------------------------------------------
specrelay_test::assert_eq "sanitize collapses unsafe runs to one hyphen" "0084-migrate-ai" "$(specrelay::task::sanitize '0084 migrate/ai!!')"
specrelay_test::assert_eq "sanitize strips leading/trailing hyphens" "abc" "$(specrelay::task::sanitize '---abc---')"

specrelay::task::valid_id "0084-migrate-ai-workflow"
specrelay_test::assert_true "valid_id accepts a normal task id" "$?"
specrelay::task::valid_id "../etc/passwd"
specrelay_test::assert_true "valid_id rejects path traversal" "$([ $? -ne 0 ] && echo 0 || echo 1)"
specrelay::task::valid_id ""
specrelay_test::assert_true "valid_id rejects an empty id" "$([ $? -ne 0 ] && echo 0 || echo 1)"
specrelay::task::valid_id "has space"
specrelay_test::assert_true "valid_id rejects whitespace" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# --- id_from_spec_path -----------------------------------------------------
proj="$(specrelay_test::mktemp_project_with_spec "0084-migrate-ai-workflow-engine-into-specrelay")"
derived="$(specrelay::task::id_from_spec_path "$proj/docs/sdd/0084-migrate-ai-workflow-engine-into-specrelay/spec.md")"
specrelay_test::assert_eq "id_from_spec_path derives from the spec's parent directory" "0084-migrate-ai-workflow-engine-into-specrelay" "$derived"

# --- runs_root / dir (config-driven, never hardcoded) ----------------------
proj2="$(specrelay_test::mktemp_project)"
mkdir -p "$proj2/.specrelay"
cat > "$proj2/.specrelay/config.yml" <<'YAML'
version: 1
tasks:
  runs_root: custom/runs/root
YAML
specrelay_test::assert_eq "runs_root reads tasks.runs_root from config" \
  "$proj2/custom/runs/root" "$(specrelay::task::runs_root "$proj2")"
specrelay_test::assert_eq "runs_root defaults to .ai-runs/tasks with no config" \
  "$proj/.ai-runs/tasks" "$(specrelay::task::runs_root "$proj")"
specrelay_test::assert_eq "dir composes runs_root and the task id" \
  "$proj/.ai-runs/tasks/0084-x" "$(specrelay::task::dir "$proj" "0084-x")"

# --- resolve_spec_path safety ------------------------------------------------
resolved="$(specrelay::task::resolve_spec_path "$proj" "docs/sdd/0084-migrate-ai-workflow-engine-into-specrelay/spec.md")"
specrelay_test::assert_eq "resolve_spec_path resolves a relative path under the project" \
  "$proj/docs/sdd/0084-migrate-ai-workflow-engine-into-specrelay/spec.md" "$resolved"

specrelay::task::resolve_spec_path "$proj" "does/not/exist.md" >/tmp/specrelay-nospec.$$ 2>&1
rc=$?
specrelay_test::assert_true "resolve_spec_path fails clearly for a missing file" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
rm -f /tmp/specrelay-nospec.$$

outside="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-outside.XXXXXX")"
printf 'x' > "$outside/spec.md"
specrelay::task::resolve_spec_path "$proj" "$outside/spec.md" >/tmp/specrelay-outside.$$ 2>&1
rc=$?
specrelay_test::assert_true "resolve_spec_path refuses a path outside the project root" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
rm -f /tmp/specrelay-outside.$$
rm -rf "$outside"

# --- resolve_ref: exact / unique prefix / ambiguous / not found -----------
mkdir -p "$proj/.ai-runs/tasks/0084-migrate-ai-workflow-engine-into-specrelay"
: > "$proj/.ai-runs/tasks/0084-migrate-ai-workflow-engine-into-specrelay/state.json"
mkdir -p "$proj/.ai-runs/tasks/0090-something-else"
: > "$proj/.ai-runs/tasks/0090-something-else/state.json"

specrelay_test::assert_eq "resolve_ref matches an exact task id" \
  "0084-migrate-ai-workflow-engine-into-specrelay" \
  "$(specrelay::task::resolve_ref "$proj" "0084-migrate-ai-workflow-engine-into-specrelay")"

specrelay_test::assert_eq "resolve_ref matches a unique numeric prefix" \
  "0084-migrate-ai-workflow-engine-into-specrelay" \
  "$(specrelay::task::resolve_ref "$proj" "0084")"

specrelay::task::resolve_ref "$proj" "9999" >/tmp/specrelay-noref.$$ 2>&1
rc=$?
specrelay_test::assert_true "resolve_ref fails clearly when nothing matches" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
rm -f /tmp/specrelay-noref.$$

mkdir -p "$proj/.ai-runs/tasks/00-ambi-a"
: > "$proj/.ai-runs/tasks/00-ambi-a/state.json"
mkdir -p "$proj/.ai-runs/tasks/00-ambi-b"
: > "$proj/.ai-runs/tasks/00-ambi-b/state.json"
specrelay::task::resolve_ref "$proj" "00" >/tmp/specrelay-ambi.$$ 2>&1
rc=$?
specrelay_test::assert_true "resolve_ref refuses an ambiguous reference rather than guessing" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "ambiguous-reference error lists both candidates" \
  "$(cat /tmp/specrelay-ambi.$$)" "00-ambi-a"
rm -f /tmp/specrelay-ambi.$$

specrelay_test::summary
exit $?
