#!/usr/bin/env bash
# transitions.sh — SpecRelay task lifecycle transitions.
#
# Every function here validates the CURRENT state before writing anything
# (via state.sh -> py/state_lib.py's atomic transition), refuses cleanly on a
# disallowed source state, and never touches a task it does not own (see
# specrelay::transitions::_require_owned below — spec section 50,
# "Cross-engine mutation safety").

SPECRELAY_CONTRACT_FOOTER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/templates/prompts/executor-ownership-contract.md"

specrelay::transitions::_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# specrelay::transitions::_archive_round <task-dir> <round>
# Copies every currently-present round artifact (the executor's prompt/log/
# tests/summary/stdout/stderr, evidence snapshots, and the reviewer's
# review/business-summary/next-prompt/stdout/stderr) into
# <task-dir>/iterations/round-<N>/, WITHOUT removing or renaming the live
# numbered files (Artifact Compatibility Strategy Option A is unaffected).
# This is what makes multi-round history genuinely reconstructable (spec
# section 36) instead of relying on later rounds simply overwriting earlier
# ones the way the legacy workflow's numbered files do (see
# docs/current-workflow-contract.md, section 8, "18-iteration-summary.md's
# timeline is a best-effort reconstruction, not an authoritative log").
# Idempotent: safe to call more than once for the same round (overwrites that
# round's own archive, never a DIFFERENT round's).
specrelay::transitions::_archive_round() {
  local task_dir="$1" round="$2" archive_dir f
  archive_dir="$task_dir/iterations/round-$round"
  mkdir -p "$archive_dir"
  for f in 02-executor-prompt.md 03-executor-log.md 07-tests.txt 08-executor-summary.md \
    04-git-status.txt 05-changed-files.txt 05-git-diff-stat.txt 06-git-diff.patch \
    12-executor-stdout.txt 13-executor-stderr.txt \
    09-consultant-review.md 10-business-summary.md 11-next-executor-prompt.md \
    15-reviewer-stdout.txt 16-reviewer-stderr.txt; do
    [ -f "$task_dir/$f" ] && cp -p "$task_dir/$f" "$archive_dir/$f"
  done
}

# specrelay::transitions::_require_owned <task-dir>
# Refuses to mutate a task created by a DIFFERENT engine (e.g. the legacy
# .ai/ workflow). A task's "engine" field is set to "specrelay" at creation
# time by this engine; its absence means a pre-existing / other-engine task.
# Read-only inspection commands (show/status/list) do NOT call this — only
# mutating transitions do.
specrelay::transitions::_require_owned() {
  local task_dir="$1" state_file engine
  state_file="$(specrelay::state::path "$task_dir")"
  engine="$(specrelay::state::get "$state_file" "engine" 2>/dev/null || true)"
  if [ "$engine" != "specrelay" ]; then
    specrelay::out::err "refusing to mutate task: not owned by the SpecRelay engine (engine=${engine:-<legacy/unset>})"
    specrelay::out::err "this task was created by another engine; use its own tooling to mutate it, or 'specrelay task show' to inspect it read-only"
    return 1
  fi
  return 0
}

# specrelay::transitions::create <project-root> <task-id> [spec-path-rel] [allow-pre-existing-dirty(0|1)]
# Creates a NEW task directory + state.json in DRAFT. Refuses if the task
# directory already exists (never silently overwrites — spec section 12).
specrelay::transitions::create() {
  local root="$1" task_id="$2" spec_rel="${3:-}" allow_dirty="${4:-0}" task_dir state_file base_commit fields
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"

  if [ -e "$task_dir" ]; then
    specrelay::out::err "task already exists: $task_dir"
    return 1
  fi

  # Capture the guard baseline snapshot BEFORE the task's own directory
  # exists, so the task's own newly-created files are never misread as
  # "pre-existing unrelated dirt" (git_guard.sh already excludes the whole
  # runs-root from every snapshot, but capturing before creation is the more
  # fundamentally correct ordering regardless).
  local baseline_snapshot
  baseline_snapshot="$(specrelay::git_guard::snapshot_now "$root" "$spec_rel")"

  mkdir -p "$task_dir"
  base_commit="$(cd "$root" && git rev-parse HEAD 2>/dev/null || echo "")"

  SPEC_REL="$spec_rel" TASK_ID="$task_id" BASE_COMMIT="$base_commit" CREATED_AT="$(specrelay::transitions::_now)" ALLOW_DIRTY="$allow_dirty" \
  python3 -c '
import json, os
fields = {
    "task_id": os.environ["TASK_ID"],
    "state": "DRAFT",
    "created_at": os.environ["CREATED_AT"],
    "base_commit": os.environ["BASE_COMMIT"],
    "requires_human_approval": True,
    "engine": "specrelay",
    "iteration": 1,
    "allow_pre_existing_dirty": os.environ.get("ALLOW_DIRTY") == "1",
}
if os.environ.get("SPEC_REL"):
    fields["spec_source"] = os.environ["SPEC_REL"]
print(json.dumps(fields))
' > "$task_dir/.init-fields.json"

  specrelay::state::init "$state_file" "$(cat "$task_dir/.init-fields.json")"
  rm -f "$task_dir/.init-fields.json"

  : > "$task_dir/00-user-request.md"
  : > "$task_dir/01-consultant-analysis.md"
  : > "$task_dir/02-executor-prompt.md"

  specrelay::git_guard::write_baseline "$task_dir" "$baseline_snapshot"

  echo "Created task: $task_dir"
}

# specrelay::transitions::approve <project-root> <task-id>
# DRAFT|WAITING_FOR_HUMAN -> READY_FOR_EXECUTOR. This is the human-approval
# gate (spec section 45/`.ai/protocol.md` Safety Rules). `specrelay run`
# treats the human's own explicit invocation of that command as this
# approval (documented in docs/engine-parity.md); `specrelay task approve`
# is the explicit, decoupled equivalent of the legacy `approve-task.sh`.
specrelay::transitions::approve() {
  local root="$1" task_id="$2" task_dir state_file
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"
  specrelay::transitions::_require_owned "$task_dir" || return 1

  specrelay::state::transition "$state_file" "DRAFT,WAITING_FOR_HUMAN" "READY_FOR_EXECUTOR" \
    "$(printf '{"approved_at": "%s", "approved_by": "human"}' "$(specrelay::transitions::_now)")"
}

# specrelay::transitions::claim <project-root> <task-id>
# READY_FOR_EXECUTOR -> EXECUTOR_RUNNING. Requires a non-empty executor prompt.
specrelay::transitions::claim() {
  local root="$1" task_id="$2" task_dir state_file prompt_file
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"
  prompt_file="$task_dir/02-executor-prompt.md"
  specrelay::transitions::_require_owned "$task_dir" || return 1

  if [ ! -s "$prompt_file" ]; then
    specrelay::out::err "refusing to claim '$task_id': 02-executor-prompt.md is missing or empty"
    return 1
  fi

  specrelay::state::transition "$state_file" "READY_FOR_EXECUTOR" "EXECUTOR_RUNNING" \
    "$(printf '{"claimed_at": "%s", "claimed_by": "specrelay-runner"}' "$(specrelay::transitions::_now)")"
}

# specrelay::transitions::submit <project-root> <task-id> <token>
# EXECUTOR_RUNNING -> READY_FOR_REVIEW. Runner-owned only: requires a valid,
# single-use authorization token (see auth.sh). Requires the required
# executor outputs (non-empty) and evidence files (must exist) first.
specrelay::transitions::submit() {
  local root="$1" task_id="$2" token="${3:-}" task_dir state_file f
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"
  specrelay::transitions::_require_owned "$task_dir" || return 1

  if ! specrelay::auth::consume "$root" "$task_id" "$token"; then
    specrelay::out::err "refusing: submit-for-review is runner-owned; no valid transition authorization is present"
    specrelay::out::err "use the orchestrator (specrelay run/resume), not a direct submit call"
    return 1
  fi

  for f in 03-executor-log.md 07-tests.txt 08-executor-summary.md; do
    if [ ! -s "$task_dir/$f" ]; then
      specrelay::out::err "refusing to submit '$task_id': required output '$f' is missing or empty"
      return 1
    fi
  done
  for f in 04-git-status.txt 05-changed-files.txt 05-git-diff-stat.txt 06-git-diff.patch; do
    if [ ! -f "$task_dir/$f" ]; then
      specrelay::out::err "refusing to submit '$task_id': required evidence file '$f' does not exist"
      return 1
    fi
  done

  specrelay::state::transition "$state_file" "EXECUTOR_RUNNING" "READY_FOR_REVIEW" \
    "$(printf '{"submitted_for_review_at": "%s", "submitted_for_review_by": "specrelay-runner"}' "$(specrelay::transitions::_now)")"
}

# specrelay::transitions::accept <project-root> <task-id> [reviewer-provider]
# READY_FOR_REVIEW -> READY_FOR_HUMAN_REVIEW. Requires 09/10 non-empty.
specrelay::transitions::accept() {
  local root="$1" task_id="$2" reviewer_provider="${3:-}" task_dir state_file f
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"
  specrelay::transitions::_require_owned "$task_dir" || return 1

  for f in 09-consultant-review.md 10-business-summary.md; do
    if [ ! -s "$task_dir/$f" ]; then
      specrelay::out::err "refusing to accept '$task_id': required file '$f' is missing or empty"
      return 1
    fi
  done

  local current_round
  current_round="$(specrelay::state::get "$state_file" "iteration" 2>/dev/null)"
  [ -n "$current_round" ] || current_round=1
  specrelay::transitions::_archive_round "$task_dir" "$current_round"

  local set_json
  set_json="$(REVIEWED_AT="$(specrelay::transitions::_now)" REVIEWER_PROVIDER="$reviewer_provider" python3 -c '
import json, os
d = {"reviewed_at": os.environ["REVIEWED_AT"], "reviewed_by": "reviewer-agent", "review_result": "accepted"}
if os.environ.get("REVIEWER_PROVIDER"):
    d["reviewer_provider"] = os.environ["REVIEWER_PROVIDER"]
print(json.dumps(d))
')"

  specrelay::state::transition "$state_file" "READY_FOR_REVIEW" "READY_FOR_HUMAN_REVIEW" "$set_json"
}

# specrelay::transitions::request_changes <project-root> <task-id> <reason> [reviewer-provider]
# READY_FOR_REVIEW -> CHANGES_REQUESTED. Requires 09/11 non-empty.
specrelay::transitions::request_changes() {
  local root="$1" task_id="$2" reason="${3:?reason required}" reviewer_provider="${4:-}" task_dir state_file f
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"
  specrelay::transitions::_require_owned "$task_dir" || return 1

  for f in 09-consultant-review.md 11-next-executor-prompt.md; do
    if [ ! -s "$task_dir/$f" ]; then
      specrelay::out::err "refusing to request changes on '$task_id': required file '$f' is missing or empty"
      return 1
    fi
  done

  local set_json
  set_json="$(CHANGES_AT="$(specrelay::transitions::_now)" REASON="$reason" REVIEWER_PROVIDER="$reviewer_provider" python3 -c '
import json, os
d = {
    "changes_requested_at": os.environ["CHANGES_AT"],
    "changes_requested_by": "reviewer-agent",
    "changes_requested_reason": os.environ["REASON"],
}
if os.environ.get("REVIEWER_PROVIDER"):
    d["reviewer_provider"] = os.environ["REVIEWER_PROVIDER"]
print(json.dumps(d))
')"

  specrelay::state::transition "$state_file" "READY_FOR_REVIEW" "CHANGES_REQUESTED" "$set_json"
}

# specrelay::transitions::requeue <project-root> <task-id>
# CHANGES_REQUESTED -> READY_FOR_EXECUTOR. Backs up 02-executor-prompt.md
# (non-destructively, timestamped), promotes 11-next-executor-prompt.md to
# 02-executor-prompt.md, always re-appends the ownership-contract footer, and
# increments the iteration counter (this IS the "next iteration" boundary —
# see docs/engine-parity.md's rework-loop design).
specrelay::transitions::requeue() {
  local root="$1" task_id="$2" task_dir state_file current_prompt next_prompt stamp backup n iteration next_iteration
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"
  current_prompt="$task_dir/02-executor-prompt.md"
  next_prompt="$task_dir/11-next-executor-prompt.md"
  specrelay::transitions::_require_owned "$task_dir" || return 1

  if [ ! -s "$next_prompt" ]; then
    specrelay::out::err "refusing to requeue '$task_id': '11-next-executor-prompt.md' is missing or empty"
    return 1
  fi

  # Validate state BEFORE touching any file (state.json is the source of
  # truth for whether this requeue is even allowed).
  local current
  current="$(specrelay::state::canonical "$state_file")"
  if [ "$current" != "CHANGES_REQUESTED" ]; then
    specrelay::out::err "refusing to requeue task in state '$current'; requeue is allowed only from CHANGES_REQUESTED"
    return 1
  fi

  local current_round
  current_round="$(specrelay::state::get "$state_file" "iteration" 2>/dev/null)"
  [ -n "$current_round" ] || current_round=1
  specrelay::transitions::_archive_round "$task_dir" "$current_round"

  stamp="$(specrelay::transitions::_now | tr -d ':-')"
  backup="$task_dir/02-executor-prompt.before-requeue-$stamp.md"
  n=1
  while [ -e "$backup" ]; do
    backup="$task_dir/02-executor-prompt.before-requeue-$stamp-$n.md"
    n=$((n + 1))
  done

  if [ -f "$current_prompt" ]; then
    cp -p "$current_prompt" "$backup"
  fi

  cp -p "$next_prompt" "$current_prompt"
  printf '\n\n' >> "$current_prompt"
  cat "$SPECRELAY_CONTRACT_FOOTER" >> "$current_prompt"

  iteration="$(specrelay::state::get "$state_file" "iteration" 2>/dev/null || echo 0)"
  [ -n "$iteration" ] || iteration=0
  next_iteration=$((iteration + 1))

  specrelay::state::transition "$state_file" "CHANGES_REQUESTED" "READY_FOR_EXECUTOR" \
    "$(printf '{"requeued_at": "%s", "requeued_by": "specrelay-orchestrator", "iteration": %d}' "$(specrelay::transitions::_now)" "$next_iteration")" \
    '["claimed_at", "claimed_by"]'
}

# specrelay::transitions::block <project-root> <task-id> <reason>
# EXECUTOR_RUNNING -> BLOCKED.
specrelay::transitions::block() {
  local root="$1" task_id="$2" reason="${3:?reason required}" task_dir state_file
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"
  specrelay::transitions::_require_owned "$task_dir" || return 1

  local set_json
  set_json="$(BLOCKED_AT="$(specrelay::transitions::_now)" REASON="$reason" python3 -c '
import json, os
print(json.dumps({"blocked_at": os.environ["BLOCKED_AT"], "blocked_by": "specrelay-orchestrator", "blocked_reason": os.environ["REASON"]}))
')"
  specrelay::state::transition "$state_file" "EXECUTOR_RUNNING" "BLOCKED" "$set_json"
}
