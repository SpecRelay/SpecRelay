#!/usr/bin/env bash
# schema_compat_test.sh — state.json schema/version compatibility (spec 0005,
# sections 4-6, 8). Proves:
#   * new tasks get an explicit integer schema_version equal to the engine's
#     current schema version;
#   * the compatibility guard allows a missing schema_version (historical task,
#     implicit v1) and any schema_version <= current;
#   * an unknown FUTURE schema_version is refused for a mutating resume/run with
#     a clear, actionable message, and only the documented override allows it;
#   * a non-integer schema_version is refused clearly;
#   * read-only inspection (task show) is NEVER blocked by the guard and
#     surfaces the recorded schema version.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
for f in output project config discovery state task lock auth git_guard evidence transitions workflow; do
  # shellcheck disable=SC1090
  . "$SPECRELAY_ROOT/lib/specrelay/$f.sh"
done

current="$(specrelay::state::current_schema_version)"
specrelay_test::assert_eq "current schema version is the expected integer (1)" "1" "$current"

# --- new tasks carry an explicit integer schema_version --------------------
proj="$(specrelay_test::mktemp_project_with_spec "0001-fixture")"
spec_rel="docs/sdd/0001-fixture/spec.md"
specrelay::transitions::create "$proj" "0001-fixture" "$spec_rel" "0" >/dev/null
task_dir="$(specrelay::task::dir "$proj" "0001-fixture")"
state_file="$(specrelay::state::path "$task_dir")"
specrelay_test::assert_eq "a new task records schema_version = current" \
  "$current" "$(specrelay::state::get "$state_file" "schema_version")"

# --- guard: missing schema_version (historical task) is allowed ------------
legacy_dir="$proj/scratch/legacy"
mkdir -p "$legacy_dir"
legacy_state="$(specrelay::state::path "$legacy_dir")"
specrelay::state::init "$legacy_state" '{"task_id": "legacy", "state": "READY_FOR_EXECUTOR"}' >/dev/null
specrelay::workflow::assert_schema_compat "$legacy_state" >/tmp/specrelay-schema-legacy.$$ 2>&1
rc=$?
specrelay_test::assert_eq "guard allows a task with no schema_version (implicit v1)" "0" "$rc"
rm -f /tmp/specrelay-schema-legacy.$$

# --- guard: schema_version <= current is allowed ---------------------------
cur_dir="$proj/scratch/current"
mkdir -p "$cur_dir"
cur_state="$(specrelay::state::path "$cur_dir")"
specrelay::state::init "$cur_state" "$(printf '{"task_id": "cur", "state": "READY_FOR_EXECUTOR", "schema_version": %s}' "$current")" >/dev/null
specrelay::workflow::assert_schema_compat "$cur_state" >/dev/null 2>&1
specrelay_test::assert_eq "guard allows a task at the current schema_version" "0" "$?"

# --- guard: unknown FUTURE schema_version is refused with a clear message ---
future_dir="$proj/scratch/future"
mkdir -p "$future_dir"
future_state="$(specrelay::state::path "$future_dir")"
specrelay::state::init "$future_state" '{"task_id": "future", "state": "READY_FOR_EXECUTOR", "schema_version": 999}' >/dev/null
out="$(specrelay::workflow::assert_schema_compat "$future_state" 2>&1)"
rc=$?
specrelay_test::assert_true "guard refuses an unknown future schema_version" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "future-schema refusal message is actionable" "$out" "incompatible state schema"
specrelay_test::assert_contains "future-schema refusal names the override" "$out" "SPECRELAY_ALLOW_SCHEMA_MISMATCH=1"

# --- guard: documented override allows the future schema deliberately ------
out="$(SPECRELAY_ALLOW_SCHEMA_MISMATCH=1 specrelay::workflow::assert_schema_compat "$future_state" 2>&1)"
rc=$?
specrelay_test::assert_eq "override allows a future-schema task deliberately" "0" "$rc"
specrelay_test::assert_contains "override logs that it was used" "$out" "SPECRELAY_ALLOW_SCHEMA_MISMATCH=1 was set"

# --- guard: a non-integer schema_version is refused clearly ----------------
bad_dir="$proj/scratch/bad"
mkdir -p "$bad_dir"
bad_state="$(specrelay::state::path "$bad_dir")"
specrelay::state::init "$bad_state" '{"task_id": "bad", "state": "READY_FOR_EXECUTOR", "schema_version": "not-a-number"}' >/dev/null
out="$(specrelay::workflow::assert_schema_compat "$bad_state" 2>&1)"
rc=$?
specrelay_test::assert_true "guard refuses a non-integer schema_version" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "non-integer refusal is clear" "$out" "unreadable schema_version"

# --- read-only inspection is NEVER blocked by the schema guard -------------
sr_proj="$(specrelay_test::mktemp_specrelay_project)"
show_dir="$sr_proj/.specrelay-runs/tasks/0050-future-schema"
mkdir -p "$show_dir"
cat > "$show_dir/state.json" <<'JSON'
{
  "task_id": "0050-future-schema",
  "state": "READY_FOR_HUMAN_REVIEW",
  "schema_version": 999,
  "engine": "specrelay",
  "created_at": "2026-01-01T00:00:00Z",
  "review_result": "accepted"
}
JSON
show_out="$(cd "$sr_proj" && "$SPECRELAY_BIN" task show 0050-future-schema 2>&1)"
rc=$?
specrelay_test::assert_eq "task show succeeds on a future-schema task (read-only never blocked)" "0" "$rc"
specrelay_test::assert_contains "task show surfaces the recorded schema version" "$show_out" "Schema version: 999"

specrelay_test::summary
exit $?
