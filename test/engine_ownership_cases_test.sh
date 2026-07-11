#!/usr/bin/env bash
# engine_ownership_cases_test.sh — SDD 0085 engine ownership tests, the four
# required cases from spec section 34:
#   A. a new SpecRelay task records engine=specrelay
#   B. SpecRelay refuses to resume/mutate an active legacy-owned task
#   C. the legacy rollback engine refuses to mutate an active SpecRelay-owned
#      task (this is the NEW behavior added by SDD 0085; case B already had
#      test coverage on the SpecRelay side via legacy_compat_test.sh)
#   D. a historical terminal task with no ownership metadata remains
#      read-only inspectable by SpecRelay
#   tools/specrelay/test/engine_ownership_cases_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

HOST_ROOT="$SPECRELAY_ROOT"
while [ -n "$HOST_ROOT" ] && [ ! -d "$HOST_ROOT/.git" ]; do
  parent="$(dirname "$HOST_ROOT")"
  [ "$parent" = "$HOST_ROOT" ] && HOST_ROOT="" && break
  HOST_ROOT="$parent"
done
specrelay_test::assert_true "host repository root was discovered" "$([ -n "$HOST_ROOT" ] && echo 0 || echo 1)"

AI_SCRIPTS="$HOST_ROOT/.ai/scripts"
_install_shims_into() {
  local fixture="$1"
  specrelay_test::safe_fixture_root_or_abort "$fixture" "$HOST_ROOT" || return 1
  mkdir -p "$fixture/.ai"
  cp -R "$AI_SCRIPTS" "$fixture/.ai/scripts"
  mkdir -p "$fixture/tools"
  cp -R "$HOST_ROOT/tools/specrelay" "$fixture/tools/specrelay"
  (cd "$fixture" && git add -A .ai tools && git commit -q -m "install shims + specrelay for fixture")
}

# --- Case A: a new SpecRelay task records engine=specrelay ------------------
projA="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$projA/docs/sdd/0300-case-a"
printf '# Fixture spec\n' > "$projA/docs/sdd/0300-case-a/spec.md"
(cd "$projA" && "$HOST_ROOT/tools/specrelay/bin/specrelay" task create docs/sdd/0300-case-a/spec.md >/dev/null 2>&1)
engine_a="$(grep -o '"engine": *"[a-z]*"' "$projA/.ai-runs/tasks/0300-case-a/state.json" 2>/dev/null)"
specrelay_test::assert_contains "Case A: a new SpecRelay task records engine=specrelay" "$engine_a" "specrelay"

# --- Case B: SpecRelay refuses to mutate an active legacy-owned task -------
projB="$(specrelay_test::mktemp_specrelay_project)"
legacy_dir="$projB/.ai-runs/tasks/0301-legacy-owned"
mkdir -p "$legacy_dir"
cat > "$legacy_dir/state.json" <<'JSON'
{
  "task_id": "0301-legacy-owned",
  "state": "READY_FOR_EXECUTOR",
  "created_at": "2026-01-01T00:00:00Z",
  "base_commit": "deadbeef"
}
JSON
echo "prompt" > "$legacy_dir/02-executor-prompt.md"
out_b="$(cd "$projB" && "$HOST_ROOT/tools/specrelay/bin/specrelay" task approve 0301-legacy-owned 2>&1)"
rc_b=$?
specrelay_test::assert_true "Case B: SpecRelay refuses to mutate an active legacy-owned task" "$([ "$rc_b" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "Case B: refusal names the ownership reason" "$out_b" "not owned by the SpecRelay engine"

# --- Case C: the legacy rollback engine refuses to mutate an active
# SpecRelay-owned task (proven against the REAL legacy scripts, per SDD 0085's
# new ownership guard) -------------------------------------------------------
projC="$(specrelay_test::mktemp_specrelay_project)"
_install_shims_into "$projC"
specrelay_dir="$projC/.ai-runs/tasks/0302-specrelay-owned"
mkdir -p "$specrelay_dir"
cat > "$specrelay_dir/state.json" <<'JSON'
{
  "task_id": "0302-specrelay-owned",
  "state": "READY_FOR_EXECUTOR",
  "created_at": "2026-01-01T00:00:00Z",
  "base_commit": "deadbeef",
  "requires_human_approval": true,
  "engine": "specrelay",
  "iteration": 1
}
JSON
echo "prompt" > "$specrelay_dir/02-executor-prompt.md"
out_c="$(cd "$projC" && SPECRELAY_ENGINE=legacy .ai/scripts/internal/claim-task.sh 0302-specrelay-owned 2>&1)"
rc_c=$?
specrelay_test::assert_true "Case C: the legacy rollback engine refuses to mutate an active SpecRelay-owned task" \
  "$([ "$rc_c" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "Case C: refusal names the SpecRelay ownership reason" "$out_c" "owned by the SpecRelay engine"
state_after_c="$(grep -o '"state": *"[A-Z_]*"' "$specrelay_dir/state.json")"
specrelay_test::assert_contains "Case C: task state was NOT mutated by the refused legacy attempt" "$state_after_c" "READY_FOR_EXECUTOR"

# --- Case D: a historical terminal task with no ownership metadata remains
# read-only inspectable ------------------------------------------------------
projD="$(specrelay_test::mktemp_specrelay_project)"
historical_dir="$projD/.ai-runs/tasks/0303-historical-no-engine"
mkdir -p "$historical_dir"
cat > "$historical_dir/state.json" <<'JSON'
{
  "task_id": "0303-historical-no-engine",
  "state": "READY_FOR_HUMAN_REVIEW",
  "created_at": "2025-06-01T00:00:00Z",
  "base_commit": "cafebabe",
  "reviewed_at": "2025-06-01T02:00:00Z",
  "review_result": "accepted"
}
JSON
: > "$historical_dir/00-user-request.md"
before_d="$(cd "$projD" && find .ai-runs -type f -exec cksum {} + | sort)"
show_d="$(cd "$projD" && "$HOST_ROOT/tools/specrelay/bin/specrelay" task show 0303-historical-no-engine 2>&1)"
rc_d=$?
after_d="$(cd "$projD" && find .ai-runs -type f -exec cksum {} + | sort)"
specrelay_test::assert_true "Case D: a historical no-engine terminal task is inspectable read-only" "$([ "$rc_d" -eq 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "Case D: task show reports the task id" "$show_d" "0303-historical-no-engine"
specrelay_test::assert_eq "Case D: read-only inspection never mutates the historical task" "$before_d" "$after_d"

specrelay_test::summary
exit $?
