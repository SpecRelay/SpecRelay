#!/usr/bin/env bash
# state_test.sh — unit tests for state.sh / py/state_lib.py: state parsing,
# atomic init/transition, legacy-alias normalization, allowed vs forbidden
# transitions.
#   tools/specrelay/test/state_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/state.sh
. "$SPECRELAY_ROOT/lib/specrelay/state.sh"

proj="$(specrelay_test::mktemp_project)"
task_dir="$proj/.ai-runs/tasks/0001-fixture"
mkdir -p "$task_dir"
state_file="$(specrelay::state::path "$task_dir")"

# --- init --------------------------------------------------------------
specrelay::state::init "$state_file" '{"task_id": "0001-fixture", "state": "DRAFT", "iteration": 1}' >/dev/null
specrelay_test::assert_eq "init creates state.json" "0" "$([ -f "$state_file" ] && echo 0 || echo 1)"
specrelay_test::assert_eq "get reads a top-level field" "DRAFT" "$(specrelay::state::get "$state_file" "state")"
specrelay_test::assert_eq "get reads an integer field as its string form" "1" "$(specrelay::state::get "$state_file" "iteration")"
specrelay_test::assert_eq "get returns empty for a missing field" "" "$(specrelay::state::get "$state_file" "nope")"

specrelay::state::init "$state_file" '{"state": "DRAFT"}' >/tmp/specrelay-init-again.$$ 2>&1
rc=$?
specrelay_test::assert_true "init refuses to overwrite an existing state.json" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
rm -f /tmp/specrelay-init-again.$$

# --- normalize / canonical ----------------------------------------------
specrelay_test::assert_eq "normalize passes through a canonical state" "READY_FOR_REVIEW" "$(specrelay::state::normalize "READY_FOR_REVIEW")"
specrelay_test::assert_eq "normalize maps the legacy alias" "READY_FOR_REVIEW" "$(specrelay::state::normalize "READY_FOR_CODEX_REVIEW")"

legacy_dir="$proj/.ai-runs/tasks/0002-legacy"
mkdir -p "$legacy_dir"
legacy_state="$(specrelay::state::path "$legacy_dir")"
specrelay::state::init "$legacy_state" '{"task_id": "0002-legacy", "state": "READY_FOR_CODEX_REVIEW"}' >/dev/null
specrelay_test::assert_eq "canonical() normalizes a legacy alias read from disk" "READY_FOR_REVIEW" "$(specrelay::state::canonical "$legacy_state")"

# --- transition: allowed -------------------------------------------------
specrelay::state::transition "$state_file" "DRAFT,WAITING_FOR_HUMAN" "READY_FOR_EXECUTOR" '{"approved_at": "2026-01-01T00:00:00Z"}' >/dev/null
rc=$?
specrelay_test::assert_eq "transition from an allowed source state succeeds" "0" "$rc"
specrelay_test::assert_eq "transition writes the target state" "READY_FOR_EXECUTOR" "$(specrelay::state::get "$state_file" "state")"
specrelay_test::assert_eq "transition preserves other existing fields" "0001-fixture" "$(specrelay::state::get "$state_file" "task_id")"
specrelay_test::assert_eq "transition sets new fields" "2026-01-01T00:00:00Z" "$(specrelay::state::get "$state_file" "approved_at")"

# --- transition: forbidden -----------------------------------------------
specrelay::state::transition "$state_file" "DRAFT" "EXECUTOR_RUNNING" '{}' >/tmp/specrelay-forbidden.$$ 2>&1
rc=$?
specrelay_test::assert_true "transition from a disallowed source state is refused" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_eq "a refused transition does not change the state" "READY_FOR_EXECUTOR" "$(specrelay::state::get "$state_file" "state")"
rm -f /tmp/specrelay-forbidden.$$

# --- transition accepts a legacy-aliased current state -------------------
specrelay::state::transition "$legacy_state" "READY_FOR_REVIEW" "READY_FOR_HUMAN_REVIEW" '{"review_result": "accepted"}' >/dev/null
rc=$?
specrelay_test::assert_eq "transition allowed-list matches a legacy-aliased current state" "0" "$rc"

# --- invalid JSON is refused clearly --------------------------------------
bad_state_dir="$proj/.ai-runs/tasks/0003-bad"
mkdir -p "$bad_state_dir"
bad_state="$(specrelay::state::path "$bad_state_dir")"
printf 'not valid json' > "$bad_state"
specrelay::state::transition "$bad_state" "DRAFT" "READY_FOR_EXECUTOR" '{}' >/tmp/specrelay-badjson.$$ 2>&1
rc=$?
specrelay_test::assert_true "transition on invalid state.json fails clearly" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
rm -f /tmp/specrelay-badjson.$$

specrelay_test::summary
exit $?
