#!/usr/bin/env bash
# rollback_test.sh — SDD 0085 explicit rollback path tests (spec sections 11,
# 31, 32, 33.7-33.8).
#
# Proves: (1) the rollback mechanism is explicit and not the silent default;
# (2) SPECRELAY_ENGINE=legacy and .ai/scripts/legacy/*.sh are equivalent
# entry points; (3) the rollback (legacy) engine CANNOT mutate a task owned
# by the SpecRelay engine (Case C, spec section 34) — proven against the
# REAL legacy scripts (not a re-implementation), inside an isolated temp
# fixture.
#   tools/specrelay/test/rollback_test.sh

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

# --- fixture: default (no override) resolves to specrelay, never legacy ---
proj0="$(specrelay_test::mktemp_specrelay_project)"
_install_shims_into "$proj0"
default_engine="$(cd "$proj0" && . .ai/scripts/internal/lib/specrelay-shim.sh && specrelay_shim::engine "$proj0")"
specrelay_test::assert_eq "default engine (no override, no config field) is specrelay" "specrelay" "$default_engine"

# --- rollback IS explicit: an unrecognized SPECRELAY_ENGINE value errors,
# never silently falls back --------------------------------------------------
bad_out="$(cd "$proj0" && SPECRELAY_ENGINE=bogus .ai/scripts/show-task.sh some-task 2>&1)"
bad_rc=$?
specrelay_test::assert_true "an unrecognized SPECRELAY_ENGINE value is a hard error, not a silent fallback" \
  "$([ "$bad_rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "the error names the invalid value" "$bad_out" "SPECRELAY_ENGINE must be"

# --- SPECRELAY_ENGINE=legacy and .ai/scripts/legacy/*.sh are equivalent ----
# entry points for a read-only command (show-task.sh), proven against a task
# created directly (no provider needed) ------------------------------------
proj1="$(specrelay_test::mktemp_specrelay_project)"
_install_shims_into "$proj1"
mkdir -p "$proj1/.ai-runs/tasks/0200-legacy-fixture"
cat > "$proj1/.ai-runs/tasks/0200-legacy-fixture/state.json" <<'JSON'
{
  "task_id": "0200-legacy-fixture",
  "state": "READY_FOR_HUMAN_REVIEW",
  "created_at": "2026-01-01T00:00:00Z",
  "base_commit": "deadbeef"
}
JSON
: > "$proj1/.ai-runs/tasks/0200-legacy-fixture/00-user-request.md"

out_env="$(cd "$proj1" && SPECRELAY_ENGINE=legacy .ai/scripts/show-task.sh 0200-legacy-fixture 2>&1)"
rc_env=$?
out_dir="$(cd "$proj1" && .ai/scripts/legacy/show-task.sh 0200-legacy-fixture 2>&1)"
rc_dir=$?
specrelay_test::assert_eq "SPECRELAY_ENGINE=legacy and .ai/scripts/legacy/*.sh give the same exit code" "$rc_dir" "$rc_env"
specrelay_test::assert_contains "SPECRELAY_ENGINE=legacy reaches the legacy show-task.sh implementation" "$out_env" "0200-legacy-fixture"
specrelay_test::assert_contains "the legacy/ directory copy gives the identical result" "$out_dir" "0200-legacy-fixture"
specrelay_test::assert_not_contains "the legacy rollback path never prints the SpecRelay engine banner" "$out_env" "Engine: specrelay"

# --- Case C: rollback (legacy) engine cannot mutate a SpecRelay-owned task -
proj2="$(specrelay_test::mktemp_specrelay_project)"
_install_shims_into "$proj2"
specrelay_owned_dir="$proj2/.ai-runs/tasks/0201-specrelay-owned"
mkdir -p "$specrelay_owned_dir"
cat > "$specrelay_owned_dir/state.json" <<'JSON'
{
  "task_id": "0201-specrelay-owned",
  "state": "READY_FOR_EXECUTOR",
  "created_at": "2026-01-01T00:00:00Z",
  "base_commit": "deadbeef",
  "requires_human_approval": true,
  "engine": "specrelay",
  "iteration": 1
}
JSON
echo "executor prompt" > "$specrelay_owned_dir/02-executor-prompt.md"

# approve-task.sh (legacy copy) on a DRAFT specrelay-owned task
draft_dir="$proj2/.ai-runs/tasks/0202-specrelay-owned-draft"
mkdir -p "$draft_dir"
cat > "$draft_dir/state.json" <<'JSON'
{
  "task_id": "0202-specrelay-owned-draft",
  "state": "DRAFT",
  "created_at": "2026-01-01T00:00:00Z",
  "base_commit": "deadbeef",
  "requires_human_approval": true,
  "engine": "specrelay",
  "iteration": 1
}
JSON

before_snapshot="$(cd "$proj2" && find .ai-runs -type f -exec cksum {} + | sort)"

# claim-task.sh is the legacy transition READY_FOR_EXECUTOR -> EXECUTOR_RUNNING
claim_out="$(cd "$proj2" && SPECRELAY_ENGINE=legacy .ai/scripts/internal/claim-task.sh 0201-specrelay-owned 2>&1)"
claim_rc=$?
specrelay_test::assert_true "legacy claim-task.sh refuses a SpecRelay-owned task" "$([ "$claim_rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "refusal names the SpecRelay ownership reason" "$claim_out" "owned by the SpecRelay engine"

approve_out="$(cd "$proj2" && .ai/scripts/legacy/approve-task.sh 0202-specrelay-owned-draft 2>&1)"
approve_rc=$?
specrelay_test::assert_true "legacy approve-task.sh (legacy/ copy) refuses a SpecRelay-owned task" "$([ "$approve_rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "refusal names the SpecRelay ownership reason (approve)" "$approve_out" "owned by the SpecRelay engine"

after_snapshot="$(cd "$proj2" && find .ai-runs -type f -exec cksum {} + | sort)"
specrelay_test::assert_eq "no file was mutated by the refused rollback-engine attempts" "$before_snapshot" "$after_snapshot"

# --- rollback cannot run concurrently with SpecRelay on the same task: the
# SpecRelay side (transitions.sh) independently refuses the same task too --
own_check="$(cd "$proj2" && tools/specrelay/bin/specrelay task requeue 0201-specrelay-owned 2>&1)"
own_check_rc=$?
specrelay_test::assert_true "SpecRelay itself also validates ownership (belt-and-braces, not just legacy's new guard)" \
  "$([ "$own_check_rc" -ne 0 ] && echo 0 || echo 1)"

specrelay_test::summary
exit $?
