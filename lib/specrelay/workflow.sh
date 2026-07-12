#!/usr/bin/env bash
# workflow.sh — the SpecRelay orchestrator (spec sections 13, 39).
#
# This is the ONLY code that composes transitions + providers + context
# adapters + locking into the full lifecycle. It owns the runner-owned
# submit transition (mint -> submit -> cleanup) and the "specrelay run"
# iteration loop, mirroring the legacy run-executor.sh / run-reviewer.sh /
# run-workflow.sh / run-ai-loop.sh composition (see
# docs/current-workflow-contract.md) as SpecRelay's own engine code.

# --- project-policy accessors (never hardcoded — always read from config) --

specrelay::workflow::executor_provider() {
  specrelay::config::get "$1" "roles.executor.provider" "claude"
}

specrelay::workflow::reviewer_provider() {
  specrelay::config::get "$1" "roles.reviewer.provider" "manual"
}

# --- normalized role config: provider / model / agent (spec 0009) ----------
#
# Spec 0009 separates three concerns that used to be conflated in a single
# "provider" string:
#   provider = which adapter/CLI runs the role
#   model    = which model id the provider should use (opaque string), or the
#              sentinel "provider-default" (pass no explicit model flag)
#   agent    = which provider-specific agent/profile/subagent to use, or "none"
#
# The accessors below compute the EFFECTIVE, NORMALIZED value for a role,
# honoring this precedence (spec "Environment overrides"):
#   1. role-specific env override
#   2. .specrelay/config.yml
#   3. normalized legacy provider behavior (e.g. reviewer `claude-subagent`)
#   4. provider default
# They are the single source of truth for doctor reporting, runtime evidence
# metadata, and what the provider dispatch actually passes to the adapter.

# specrelay::workflow::_role_env <role> <MODEL|AGENT>
# Prints the role-specific env override variable NAME for a role/kind (empty
# for an unknown role, so a caller never dereferences a bogus name).
specrelay::workflow::_role_env() {
  local role="$1" kind="$2"
  case "$role" in
    executor) printf 'SPECRELAY_EXECUTOR_%s\n' "$kind" ;;
    reviewer) printf 'SPECRELAY_REVIEWER_%s\n' "$kind" ;;
    *) printf '\n' ;;
  esac
}

# specrelay::workflow::role_raw_provider <root> <role>
# The provider EXACTLY as configured (may be the legacy `claude-subagent`),
# used both for the default computation below and for the provider dispatch's
# own case arms (which still accept `claude-subagent` for backward compat).
specrelay::workflow::role_raw_provider() {
  local root="$1" role="$2"
  case "$role" in
    executor) specrelay::config::get "$root" "roles.executor.provider" "claude" ;;
    reviewer) specrelay::config::get "$root" "roles.reviewer.provider" "manual" ;;
  esac
}

# specrelay::workflow::role_provider <root> <role>
# The NORMALIZED provider: the legacy `claude-subagent` shorthand collapses to
# the real provider `claude` (its sub-agent selection is expressed via `agent`
# below), everything else passes through unchanged.
specrelay::workflow::role_provider() {
  local raw
  raw="$(specrelay::workflow::role_raw_provider "$1" "$2")"
  case "$raw" in
    claude-subagent) printf 'claude\n' ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

# specrelay::workflow::role_model <root> <role>
# Effective model: role-specific env override, else configured model, else the
# `provider-default` sentinel. The model is an opaque string — SpecRelay never
# validates it against real vendor model names.
specrelay::workflow::role_model() {
  local root="$1" role="$2" env_name env_val cfg
  env_name="$(specrelay::workflow::_role_env "$role" MODEL)"
  if [ -n "$env_name" ]; then
    env_val="${!env_name:-}"
    if [ -n "$env_val" ]; then
      printf '%s\n' "$env_val"
      return 0
    fi
  fi
  cfg="$(specrelay::config::get "$root" "roles.$role.model" "")"
  if [ -n "$cfg" ]; then
    printf '%s\n' "$cfg"
    return 0
  fi
  printf 'provider-default\n'
}

# specrelay::workflow::role_agent <root> <role>
# Effective agent: role-specific env override, else configured agent, else the
# normalized-legacy default (reviewer + legacy `claude-subagent` -> ai-reviewer),
# else `none`.
specrelay::workflow::role_agent() {
  local root="$1" role="$2" env_name env_val cfg raw
  env_name="$(specrelay::workflow::_role_env "$role" AGENT)"
  if [ -n "$env_name" ]; then
    env_val="${!env_name:-}"
    if [ -n "$env_val" ]; then
      printf '%s\n' "$env_val"
      return 0
    fi
  fi
  cfg="$(specrelay::config::get "$root" "roles.$role.agent" "")"
  if [ -n "$cfg" ]; then
    printf '%s\n' "$cfg"
    return 0
  fi
  raw="$(specrelay::workflow::role_raw_provider "$root" "$role")"
  if [ "$role" = "reviewer" ] && [ "$raw" = "claude-subagent" ]; then
    printf 'ai-reviewer\n'
    return 0
  fi
  printf 'none\n'
}

# specrelay::workflow::record_effective_roles <root> <task-id>
# Persists the effective, NORMALIZED role metadata (provider/model/agent for
# both roles) into the task's state.json under "roles_effective" (spec 0009,
# "Runtime evidence"). Based strictly on the normalized effective config above,
# never the raw legacy config. Idempotent metadata update (not a lifecycle
# transition), so re-running a round refreshes it. A missing state.json is a
# no-op (nothing to annotate yet).
specrelay::workflow::record_effective_roles() {
  local root="$1" task_id="$2" state_file
  state_file="$(specrelay::state::path "$(specrelay::task::dir "$root" "$task_id")")"
  [ -f "$state_file" ] || return 0

  local set_json
  set_json="$(
    EP="$(specrelay::workflow::role_provider "$root" executor)" \
    EM="$(specrelay::workflow::role_model "$root" executor)" \
    EA="$(specrelay::workflow::role_agent "$root" executor)" \
    RP="$(specrelay::workflow::role_provider "$root" reviewer)" \
    RM="$(specrelay::workflow::role_model "$root" reviewer)" \
    RA="$(specrelay::workflow::role_agent "$root" reviewer)" \
    python3 -c '
import json, os
print(json.dumps({"roles_effective": {
    "executor": {"provider": os.environ["EP"], "model": os.environ["EM"], "agent": os.environ["EA"]},
    "reviewer": {"provider": os.environ["RP"], "model": os.environ["RM"], "agent": os.environ["RA"]},
}}))
')"
  specrelay::state::set "$state_file" "$set_json" >/dev/null
}

specrelay::workflow::context_adapter() {
  specrelay::config::get "$1" "context.adapter" "none"
}

specrelay::workflow::context_required() {
  specrelay::config::get "$1" "context.required" "false"
}

specrelay::workflow::max_iterations() {
  specrelay::config::get "$1" "tasks.max_iterations" "3"
}

specrelay::workflow::_truthy() {
  case "$1" in
    1|true|True|TRUE|yes) return 0 ;;
    *) return 1 ;;
  esac
}

# --- reviewer prompt reconstruction (isolation — spec section 23) ----------

# specrelay::workflow::build_reviewer_prompt <project-root> <task-id>
# Prints the path to a freshly written, temporary prompt file reconstructed
# from the spec/task/evidence files — NEVER from any executor conversation
# state (there is none to reuse: the reviewer provider is always a brand new
# process, see providers/claude.sh).
specrelay::workflow::build_reviewer_prompt() {
  local root="$1" task_id="$2" task_dir task_rel tmp
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  task_rel="${task_dir#"$root"/}"
  tmp="$(mktemp "${TMPDIR:-/tmp}/specrelay-reviewer-prompt.XXXXXX")"
  {
    echo "You are an INDEPENDENT reviewer for SpecRelay task '$task_id'."
    echo "You are a fresh context: you are NOT a continuation of the executor's session."
    echo "Verify the executor's evidence against the real working tree, not just its narrative."
    echo "Decide exactly one of ACCEPT or REQUEST_CHANGES."
    echo
    echo "Before you answer, write your review to $task_rel/09-consultant-review.md"
    echo "(your findings, in your own words)."
    echo "If you decide ACCEPT, also write $task_rel/10-business-summary.md (a short"
    echo "plain-language summary of what changed, for a non-technical reader)."
    echo "If you decide REQUEST_CHANGES, also write"
    echo "$task_rel/11-next-executor-prompt.md (the next executor prompt, explaining"
    echo "exactly what must change)."
    echo "End your reply with exactly one line, verbatim: 'DECISION: ACCEPT' or 'DECISION: REQUEST_CHANGES'."
    echo
    echo "=== User request (00-user-request.md) ==="
    cat "$task_dir/00-user-request.md" 2>/dev/null
    echo
    echo "=== Executor prompt (02-executor-prompt.md) ==="
    cat "$task_dir/02-executor-prompt.md" 2>/dev/null
    echo
    echo "=== Executor log (03-executor-log.md) ==="
    cat "$task_dir/03-executor-log.md" 2>/dev/null
    echo
    echo "=== Tests (07-tests.txt) ==="
    cat "$task_dir/07-tests.txt" 2>/dev/null
    echo
    echo "=== Executor summary (08-executor-summary.md) ==="
    cat "$task_dir/08-executor-summary.md" 2>/dev/null
    echo
    echo "=== Changed files (05-changed-files.txt) ==="
    cat "$task_dir/05-changed-files.txt" 2>/dev/null
    echo
    echo "=== Diff stat (05-git-diff-stat.txt) ==="
    cat "$task_dir/05-git-diff-stat.txt" 2>/dev/null
    echo
    echo "Also independently inspect the real working tree (git status --short, git diff) under $root before deciding."
  } > "$tmp"
  printf '%s\n' "$tmp"
}

# --- task seeding from a spec (real, non-fake executor content) ------------

# specrelay::workflow::seed_task_from_spec <project-root> <task-id> <spec-abs-path>
# Fills 00/01/02 from the spec, in the numbered-prompt format this
# repository's own protocol requires (see CLAUDE.md: every implementation
# prompt starts with "Prompt #N — Title"), and always appends the
# ownership-contract footer.
specrelay::workflow::seed_task_from_spec() {
  local root="$1" task_id="$2" spec_abs="$3" task_dir spec_rel task_rel
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  spec_rel="${spec_abs#"$root"/}"
  task_rel="${task_dir#"$root"/}"

  {
    echo "# User Request — SpecRelay Task $task_id"
    echo
    echo "Spec source: $spec_rel"
    echo
    cat "$spec_abs"
  } > "$task_dir/00-user-request.md"

  {
    echo "# Consultant Analysis — SpecRelay Task $task_id"
    echo
    echo "Auto-generated by 'specrelay run'. The spec file on disk ($spec_rel) is the"
    echo "single source of truth; this file only records that fact."
  } > "$task_dir/01-consultant-analysis.md"

  {
    echo "Prompt #1 — Implement Spec Task $task_id"
    echo
    echo "Implement exactly what $spec_rel requires. Do not add, remove, or"
    echo "reinterpret requirements. If the spec is unclear or contradictory,"
    echo "stop and report a blocking issue instead of guessing."
    echo
    echo "Write these files in $task_rel/ (the task's runtime evidence folder,"
    echo "NOT the spec's own directory):"
    echo "  - $task_rel/03-executor-log.md"
    echo "  - $task_rel/07-tests.txt"
    echo "  - $task_rel/08-executor-summary.md"
    echo
    echo "=== Spec ($spec_rel) ==="
    cat "$spec_abs"
    echo
    cat "$SPECRELAY_CONTRACT_FOOTER"
  } > "$task_dir/02-executor-prompt.md"
}

# --- one executor round -----------------------------------------------------

# specrelay::workflow::executor_iteration <project-root> <task-id>
# Requires the task to already be READY_FOR_EXECUTOR. Runs the full
# claim -> guard -> context preflight -> provider -> evidence -> submit
# sequence (spec section 6's contract, migrated).
specrelay::workflow::executor_iteration() {
  local root="$1" task_id="$2" task_dir state_file current
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"

  current="$(specrelay::state::canonical "$state_file")"
  if [ "$current" != "READY_FOR_EXECUTOR" ]; then
    specrelay::out::err "cannot run executor iteration: task '$task_id' is not READY_FOR_EXECUTOR (current: $current)"
    return 1
  fi

  specrelay::out::log "[executor] task '$task_id': checking working-tree guard"
  if ! specrelay::git_guard::check "$root" "$task_dir"; then
    return 1
  fi

  local provider model agent context_adapter context_required
  provider="$(specrelay::workflow::executor_provider "$root")"
  model="$(specrelay::workflow::role_model "$root" executor)"
  agent="$(specrelay::workflow::role_agent "$root" executor)"
  context_adapter="$(specrelay::workflow::context_adapter "$root")"
  context_required="$(specrelay::workflow::context_required "$root")"

  specrelay::out::log "[executor] task '$task_id': context-capability preflight (adapter: $context_adapter)"
  if ! specrelay::context::preflight "$context_adapter" "executor" "$root" "$task_id" "$provider"; then
    if specrelay::workflow::_truthy "$context_required"; then
      specrelay::out::err "[executor] context-capability preflight failed; refusing to claim/launch the executor"
      return 1
    fi
    specrelay::out::log "[executor] context-capability preflight failed but is not required by policy; proceeding"
  fi

  specrelay::out::log "[executor] task '$task_id': claiming"
  if ! specrelay::transitions::claim "$root" "$task_id"; then
    return 1
  fi

  # Record effective (normalized) role metadata into durable state (spec 0009,
  # "Runtime evidence"): provider/model/agent for both roles.
  specrelay::workflow::record_effective_roles "$root" "$task_id"

  local round rc
  round="$(specrelay::state::get "$state_file" "iteration" 2>/dev/null || true)"
  [ -n "$round" ] || round=1

  specrelay::out::log "[executor] task '$task_id': running provider '$provider' (round $round, model=$model agent=$agent)"
  if specrelay::provider::executor_run "$provider" "$root" "$task_dir" "$round" "$task_dir/02-executor-prompt.md" "$model" "$agent"; then
    rc=0
  else
    rc=$?
  fi

  specrelay::out::log "[executor] task '$task_id': capturing evidence"
  specrelay::evidence::capture "$root" "$task_dir"

  if [ "$rc" -ne 0 ]; then
    specrelay::out::err "[executor] task '$task_id': provider exited non-zero ($rc); not submitted for review"
    return 1
  fi

  local f missing=0
  for f in 03-executor-log.md 07-tests.txt 08-executor-summary.md; do
    if [ ! -s "$task_dir/$f" ]; then
      specrelay::out::err "[executor] task '$task_id': required output '$f' missing/empty; not submitted for review"
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    return 1
  fi

  # Snapshot task-owned working-tree paths BEFORE submitting, so the NEXT
  # claim's guard allows this round's accumulated diff to persist into the
  # next iteration (spec sections 31-33 — the rework-loop fix).
  specrelay::git_guard::snapshot_owned "$root" "$task_dir"

  local token rc2
  token="$(specrelay::auth::mint "$root" "$task_id")"
  if specrelay::transitions::submit "$root" "$task_id" "$token"; then
    rc2=0
  else
    rc2=$?
  fi
  specrelay::auth::cleanup "$root" "$task_id"
  if [ "$rc2" -ne 0 ]; then
    return 1
  fi

  specrelay::out::log "[executor] task '$task_id': submitted for review (READY_FOR_REVIEW)"
  return 0
}

# --- one reviewer round ------------------------------------------------------

# specrelay::workflow::reviewer_iteration <project-root> <task-id>
# Requires the task to be READY_FOR_REVIEW or (resuming an interrupted
# automated review — spec 0011) REVIEWER_RUNNING. Returns 0 on a decision
# (accept or request-changes, either is "success" for the loop), 1 on a
# provider failure (no decision — the task stays REVIEWER_RUNNING once the
# review has started, so a later resume continues from there), 2 when the
# configured reviewer provider is 'manual' (no automated decision is possible;
# state unchanged at READY_FOR_REVIEW, a human must run 'specrelay task
# accept|request-changes').
#
# For an AUTOMATED reviewer the state machine is (spec 0011):
#   READY_FOR_REVIEW -> REVIEWER_RUNNING -> READY_FOR_HUMAN_REVIEW | CHANGES_REQUESTED
# The transition into REVIEWER_RUNNING happens BEFORE the reviewer executes, so
# review-in-progress is observable and an interrupted review is recoverable by
# resume (it never rolls back to READY_FOR_REVIEW).
specrelay::workflow::reviewer_iteration() {
  local root="$1" task_id="$2" task_dir state_file current
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"

  current="$(specrelay::state::canonical "$state_file")"
  case "$current" in
    READY_FOR_REVIEW|REVIEWER_RUNNING) : ;;
    *)
      specrelay::out::err "cannot run reviewer iteration: task '$task_id' is not READY_FOR_REVIEW or REVIEWER_RUNNING (current: $current)"
      return 1
      ;;
  esac

  local provider context_adapter context_required
  provider="$(specrelay::workflow::reviewer_provider "$root")"

  if [ "$provider" = "manual" ]; then
    specrelay::out::log "[reviewer] task '$task_id': reviewer provider is 'manual'; a human must decide (specrelay task accept|request-changes). State unchanged."
    return 2
  fi

  context_adapter="$(specrelay::workflow::context_adapter "$root")"
  context_required="$(specrelay::workflow::context_required "$root")"

  specrelay::out::log "[reviewer] task '$task_id': independent context-capability preflight (adapter: $context_adapter)"
  if ! specrelay::context::preflight "$context_adapter" "reviewer" "$root" "$task_id" "$provider"; then
    if specrelay::workflow::_truthy "$context_required"; then
      specrelay::out::err "[reviewer] context-capability preflight failed; refusing to launch the reviewer"
      return 1
    fi
    specrelay::out::log "[reviewer] context-capability preflight failed but is not required by policy; proceeding"
  fi

  # Enter REVIEWER_RUNNING before executing the reviewer (spec 0011). Only when
  # the task is still READY_FOR_REVIEW: when resuming an interrupted review the
  # task is already REVIEWER_RUNNING and must NOT be transitioned again. A
  # preflight refusal above returns early, so it never marks a review "running"
  # that was never launched (that is not a reviewer crash — no state change).
  if [ "$current" = "READY_FOR_REVIEW" ]; then
    specrelay::out::log "[reviewer] task '$task_id': entering REVIEWER_RUNNING (automated review in progress)"
    if ! specrelay::transitions::start_review "$root" "$task_id" "$provider"; then
      specrelay::out::err "[reviewer] task '$task_id': could not enter REVIEWER_RUNNING; task stays READY_FOR_REVIEW"
      return 1
    fi
  else
    specrelay::out::log "[reviewer] task '$task_id': resuming an interrupted review from REVIEWER_RUNNING"
  fi

  local round prompt_file decision rc model agent
  model="$(specrelay::workflow::role_model "$root" reviewer)"
  agent="$(specrelay::workflow::role_agent "$root" reviewer)"
  round="$(specrelay::state::get "$state_file" "iteration" 2>/dev/null || true)"
  [ -n "$round" ] || round=1
  prompt_file="$(specrelay::workflow::build_reviewer_prompt "$root" "$task_id")"

  specrelay::out::log "[reviewer] task '$task_id': running provider '$provider' (round $round, model=$model agent=$agent, isolated context)"
  if decision="$(specrelay::provider::reviewer_run "$provider" "$root" "$task_dir" "$round" "$prompt_file" "$model" "$agent")"; then
    rc=0
  else
    rc=$?
  fi
  rm -f "$prompt_file"

  if [ "$rc" -ne 0 ]; then
    specrelay::out::err "[reviewer] task '$task_id': provider exited non-zero or produced no clear decision; task stays REVIEWER_RUNNING for recovery/resume (spec 0011: no rollback)"
    return 1
  fi

  decision="$(printf '%s\n' "$decision" | tail -n1 | tr -d '[:space:]')"

  # Re-read the canonical state AFTER the reviewer provider ran. A real
  # reviewer agent runs under `claude --print --dangerously-skip-permissions`
  # and CAN itself enact the accept/request-changes transition (neither is
  # runner-owned), so by the time control returns here the task may already be
  # in the decision's target state. Own the transition state-aware: apply it
  # only when the task is still REVIEWER_RUNNING, and otherwise stop cleanly
  # instead of attempting a second, invalid transition out of an already-final
  # state (spec 0004). This does NOT weaken any guard — transitions.sh still
  # refuses genuinely invalid transitions; the runner simply stops making the
  # redundant call that produced the confusing "Refusing to transition task in
  # state 'READY_FOR_HUMAN_REVIEW'" warning.
  current="$(specrelay::state::canonical "$state_file")"
  case "$decision" in
    ACCEPT)
      case "$current" in
        REVIEWER_RUNNING)
          specrelay::transitions::accept "$root" "$task_id" "$provider" || return 1
          specrelay::out::log "[reviewer] task '$task_id': accepted -> READY_FOR_HUMAN_REVIEW"
          ;;
        READY_FOR_HUMAN_REVIEW)
          specrelay::out::log "[reviewer] task '$task_id': already accepted -> READY_FOR_HUMAN_REVIEW (reviewer enacted the transition; runner stops cleanly)"
          ;;
        *)
          specrelay::out::err "[reviewer] task '$task_id': reviewer decided ACCEPT but task is in unexpected state '$current'; refusing to transition"
          return 1
          ;;
      esac
      ;;
    REQUEST_CHANGES)
      case "$current" in
        REVIEWER_RUNNING)
          local reason
          reason="$(head -c 500 "$task_dir/09-consultant-review.md" 2>/dev/null)"
          [ -n "$reason" ] || reason="changes requested"
          specrelay::transitions::request_changes "$root" "$task_id" "$reason" "$provider" || return 1
          specrelay::out::log "[reviewer] task '$task_id': changes requested -> CHANGES_REQUESTED"
          ;;
        CHANGES_REQUESTED)
          specrelay::out::log "[reviewer] task '$task_id': changes already requested -> CHANGES_REQUESTED (reviewer enacted the transition; runner stops cleanly)"
          ;;
        *)
          specrelay::out::err "[reviewer] task '$task_id': reviewer decided REQUEST_CHANGES but task is in unexpected state '$current'; refusing to transition"
          return 1
          ;;
      esac
      ;;
    *)
      specrelay::out::err "[reviewer] task '$task_id': unrecognized decision '$decision'; refusing to transition"
      return 1
      ;;
  esac
  return 0
}

# --- the shared executor<->reviewer automation loop (spec 0010) -------------

# specrelay::workflow::drive <project-root> <task-id>
# The single automation loop shared by BOTH `specrelay run <spec>` and
# `specrelay resume <task>`. Given a task whose state.json already exists, it
# repeatedly dispatches the one safe next step for the current state until a
# terminal or explicit-stop state is reached. This is what makes automated
# reviewer continuation work (spec 0010): after the executor submits and the
# task becomes READY_FOR_REVIEW, the SAME invocation runs the reviewer instead
# of leaving the operator to start it by hand.
#
# It NEVER stops silently at READY_FOR_REVIEW. `READY_FOR_REVIEW` is an internal
# handoff state for automated review; the loop only rests there when the
# effective reviewer provider is 'manual' (an explicit opt-out) or the automated
# reviewer fails/is unavailable — and in both cases it logs an explicit reason
# (spec 0010, section 4). The normal successful path continues through the
# reviewer to `READY_FOR_HUMAN_REVIEW` in the same invocation.
#
# Exit codes (spec section 54):
#   0  reached READY_FOR_HUMAN_REVIEW
#   1  usage/config/lookup error (or the internal safety limit — an engine bug)
#   2  reviewer provider is 'manual' — automated loop stops; human action required
#   3  task is BLOCKED
#   4  provider (executor or reviewer) failure — task remains READY_FOR_REVIEW
#   5  maximum iterations reached without acceptance
specrelay::workflow::drive() {
  local root="$1" task_id="$2" task_dir state_file
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"

  local max_iter safety_limit safety_count current rc
  max_iter="$(specrelay::workflow::max_iterations "$root")"
  case "$max_iter" in ''|*[!0-9]*) max_iter=3 ;; esac
  safety_limit=$((max_iter * 2 + 6))
  safety_count=0
  rc=0

  while :; do
    safety_count=$((safety_count + 1))
    if [ "$safety_count" -gt "$safety_limit" ]; then
      specrelay::out::err "[specrelay] internal safety limit reached without a terminal state; stopping (this indicates an engine bug, not a normal outcome)"
      rc=1
      break
    fi

    current="$(specrelay::state::canonical "$state_file")"
    case "$current" in
      READY_FOR_HUMAN_REVIEW)
        specrelay::out::log "[specrelay] task '$task_id' reached READY_FOR_HUMAN_REVIEW."
        rc=0
        break
        ;;
      BLOCKED)
        specrelay::out::err "[specrelay] task '$task_id' is BLOCKED."
        rc=3
        break
        ;;
      READY_FOR_EXECUTOR)
        local iteration
        iteration="$(specrelay::state::get "$state_file" "iteration" 2>/dev/null || true)"
        [ -n "$iteration" ] || iteration=1
        if [ "$iteration" -gt "$max_iter" ] 2>/dev/null; then
          specrelay::out::err "[specrelay] task '$task_id' reached the maximum of $max_iter iteration(s) without acceptance."
          rc=5
          break
        fi
        if ! specrelay::workflow::executor_iteration "$root" "$task_id"; then
          rc=4
          break
        fi
        ;;
      CHANGES_REQUESTED)
        specrelay::out::log "[specrelay] requeuing task '$task_id' for its next iteration"
        if ! specrelay::transitions::requeue "$root" "$task_id"; then
          rc=1
          break
        fi
        ;;
      READY_FOR_REVIEW|REVIEWER_RUNNING)
        # Both the initial handoff (READY_FOR_REVIEW) and an interrupted
        # automated review (REVIEWER_RUNNING — spec 0011) are driven by the same
        # reviewer iteration: it enters REVIEWER_RUNNING when needed, executes
        # the reviewer, and transitions to the decision state. Resuming a task
        # left in REVIEWER_RUNNING continues the review from there (no rollback).
        specrelay::workflow::reviewer_iteration "$root" "$task_id"
        rc=$?
        case "$rc" in
          0) rc=0 ;;
          2)
            specrelay::out::log "[reviewer] reviewer provider is 'manual'; stopping at READY_FOR_REVIEW for human review. Run 'specrelay task accept' or 'specrelay task request-changes' when ready."
            break
            ;;
          *)
            local failed_state
            failed_state="$(specrelay::state::canonical "$state_file")"
            specrelay::out::err "[reviewer] automated reviewer failed; task remains ${failed_state:-READY_FOR_REVIEW} for recovery/resume."
            rc=4
            break
            ;;
        esac
        ;;
      *)
        specrelay::out::err "[specrelay] task '$task_id' has state '$current' with no safe automated step."
        rc=1
        break
        ;;
    esac
  done

  return "$rc"
}

# specrelay::workflow::assert_engine_compat <state-file>
# Resume/version safety (SDD 0087, sections 30/32/33). Compares the engine
# version recorded in a task's state.json with the engine version now trying
# to act on it, and refuses an UNSAFE cross-version action rather than
# silently resuming old task state with an incompatible engine.
#
# Compatibility policy (see docs/versioning.md):
#   * No recorded engine_version (historical task) -> allowed (nothing to
#     compare against).
#   * Same MAJOR version -> compatible (minor/patch are backward compatible).
#   * Different MAJOR version -> UNSAFE; refuse.
#   * A task recorded with a NEWER engine than the one running now -> UNSAFE
#     (a downgraded engine cannot safely resume newer task state); refuse.
# An explicit, per-invocation override (SPECRELAY_ALLOW_ENGINE_MISMATCH=1)
# exists for deliberate human recovery; it is never the default and always
# logs that it was used.
specrelay::workflow::assert_engine_compat() {
  local state_file="$1" task_ev cur_ev
  [ -f "$state_file" ] || return 0
  task_ev="$(specrelay::state::get "$state_file" "engine_version" 2>/dev/null || true)"
  if [ -z "$task_ev" ] || [ "$task_ev" = "null" ]; then
    return 0
  fi
  cur_ev=""
  if [ -n "${SPECRELAY_HOME:-}" ] && [ -f "$SPECRELAY_HOME/VERSION" ]; then
    cur_ev="$(tr -d '[:space:]' < "$SPECRELAY_HOME/VERSION")"
  fi
  [ -n "$cur_ev" ] || return 0
  [ "$task_ev" = "$cur_ev" ] && return 0

  local task_major cur_major smaller unsafe=0 reason=""
  task_major="${task_ev%%.*}"
  cur_major="${cur_ev%%.*}"
  if [ "$task_major" != "$cur_major" ]; then
    unsafe=1; reason="different major version"
  else
    smaller="$(printf '%s\n%s\n' "$task_ev" "$cur_ev" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)"
    if [ "$smaller" = "$cur_ev" ]; then
      unsafe=1; reason="task was created by a NEWER engine ($task_ev) than the one running now ($cur_ev)"
    fi
  fi

  if [ "$unsafe" -eq 1 ]; then
    if [ "${SPECRELAY_ALLOW_ENGINE_MISMATCH:-}" = "1" ]; then
      specrelay::out::err "[specrelay] WARNING: resuming across incompatible engine versions ($reason) because SPECRELAY_ALLOW_ENGINE_MISMATCH=1 was set."
      return 0
    fi
    specrelay::out::err "[specrelay] refusing to resume task: incompatible engine version ($reason)."
    specrelay::out::err "  task engine_version: $task_ev"
    specrelay::out::err "  running engine:      $cur_ev"
    specrelay::out::err "  Install the matching engine version, or set SPECRELAY_ALLOW_ENGINE_MISMATCH=1 to override deliberately."
    return 1
  fi
  return 0
}

# specrelay::workflow::assert_schema_compat <state-file>
# state.json schema compatibility guard (spec 0005, section 4). Complements the
# engine-version guard above: it compares the SCHEMA version recorded in a
# task's state.json with the schema version this engine writes for new tasks,
# and refuses to mutate a task written by an UNKNOWN FUTURE schema rather than
# silently resuming state it may not fully understand.
#
# Compatibility policy (see docs/versioning.md):
#   * No recorded schema_version (historical task) -> allowed (implicit v1).
#   * schema_version <= current -> allowed (schema is additive within a major
#     engine version; older/current shapes still read).
#   * schema_version > current  -> UNSAFE (written by a newer engine's schema);
#     refuse the mutating action.
# The per-invocation override SPECRELAY_ALLOW_SCHEMA_MISMATCH=1 exists for
# deliberate human recovery; it is never the default and always logs its use.
# Read-only inspection (show/status/list) never calls this — only mutating
# resume/run.
specrelay::workflow::assert_schema_compat() {
  local state_file="$1" task_sv cur_sv
  [ -f "$state_file" ] || return 0
  task_sv="$(specrelay::state::get "$state_file" "schema_version" 2>/dev/null || true)"
  if [ -z "$task_sv" ] || [ "$task_sv" = "null" ]; then
    return 0
  fi
  # A non-integer schema_version is unreadable metadata, not a safe resume.
  case "$task_sv" in
    ''|*[!0-9]*)
      specrelay::out::err "[specrelay] refusing to resume task: unreadable schema_version '$task_sv' in state.json."
      specrelay::out::err "  Inspect it read-only with 'specrelay task show', then recover deliberately."
      return 1
      ;;
  esac
  cur_sv="$(specrelay::state::current_schema_version 2>/dev/null || true)"
  [ -n "$cur_sv" ] || return 0
  if [ "$task_sv" -le "$cur_sv" ]; then
    return 0
  fi

  if [ "${SPECRELAY_ALLOW_SCHEMA_MISMATCH:-}" = "1" ]; then
    specrelay::out::err "[specrelay] WARNING: resuming a task written by a newer state schema (task schema_version=$task_sv, this engine writes $cur_sv) because SPECRELAY_ALLOW_SCHEMA_MISMATCH=1 was set."
    return 0
  fi
  specrelay::out::err "[specrelay] refusing to resume task: incompatible state schema (task was written by a newer engine)."
  specrelay::out::err "  task schema_version: $task_sv"
  specrelay::out::err "  this engine writes:  $cur_sv"
  specrelay::out::err "  Install a newer SpecRelay engine, or set SPECRELAY_ALLOW_SCHEMA_MISMATCH=1 to override deliberately."
  return 1
}

# --- resume (spec section 39) -----------------------------------------------

# specrelay::workflow::resume <project-root> <task-id>
# Resumes an existing task from its persisted state and drives the shared
# executor<->reviewer automation loop (specrelay::workflow::drive) to the next
# terminal or explicit-stop state — it never blindly restarts a task from the
# beginning. Because it uses the same loop as `specrelay run`, resuming an
# automated-reviewer task continues from READY_FOR_REVIEW into reviewer
# execution in the SAME invocation and reaches READY_FOR_HUMAN_REVIEW without a
# second manual `resume` (spec 0010). It shares `run`'s exit-code contract.
specrelay::workflow::resume() {
  local root="$1" task_id="$2" task_dir
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  if [ ! -d "$task_dir" ]; then
    specrelay::out::err "task not found: $task_dir"
    return 1
  fi
  if ! specrelay::workflow::assert_engine_compat "$(specrelay::state::path "$task_dir")"; then
    return 1
  fi
  if ! specrelay::workflow::assert_schema_compat "$(specrelay::state::path "$task_dir")"; then
    return 1
  fi
  if ! specrelay::lock::acquire "$root" "$task_id"; then
    return 1
  fi
  specrelay::workflow::drive "$root" "$task_id"
  local rc=$?
  specrelay::lock::release "$root" "$task_id"
  return "$rc"
}

# --- full lifecycle: `specrelay run <spec>` ---------------------------------
#
# Exit codes (spec section 54):
#   0  reached READY_FOR_HUMAN_REVIEW
#   1  usage/config/lookup error
#   2  a reviewer provider is 'manual' — automated loop stops; human action required
#   3  task is BLOCKED
#   4  provider (executor or reviewer) failure
#   5  maximum iterations reached without acceptance

# specrelay::workflow::run <project-root> <spec-arg> [task-id-override] [allow-dirty(0|1)]
specrelay::workflow::run() {
  local root="$1" spec_arg="$2" task_id_override="${3:-}" allow_dirty="${4:-0}"
  local spec_abs spec_rel task_id task_dir

  spec_abs="$(specrelay::task::resolve_spec_path "$root" "$spec_arg")" || return 1
  spec_rel="${spec_abs#"$root"/}"

  if [ -n "$task_id_override" ]; then
    task_id="$task_id_override"
  else
    task_id="$(specrelay::task::id_from_spec_path "$spec_abs")"
  fi
  if ! specrelay::task::valid_id "$task_id"; then
    specrelay::out::err "could not derive a safe task id from spec path: $spec_arg"
    return 1
  fi

  task_dir="$(specrelay::task::dir "$root" "$task_id")"

  if ! specrelay::lock::acquire "$root" "$task_id"; then
    return 1
  fi

  if [ ! -d "$task_dir" ]; then
    specrelay::out::log "[specrelay] creating task '$task_id' from spec: $spec_rel"
    if ! specrelay::transitions::create "$root" "$task_id" "$spec_rel" "$allow_dirty"; then
      specrelay::lock::release "$root" "$task_id"
      return 1
    fi
    specrelay::workflow::seed_task_from_spec "$root" "$task_id" "$spec_abs"
  else
    specrelay::out::log "[specrelay] resuming existing task '$task_id'"
    if ! specrelay::workflow::assert_engine_compat "$(specrelay::state::path "$task_dir")"; then
      specrelay::lock::release "$root" "$task_id"
      return 1
    fi
    if ! specrelay::workflow::assert_schema_compat "$(specrelay::state::path "$task_dir")"; then
      specrelay::lock::release "$root" "$task_id"
      return 1
    fi
  fi

  local state_file current
  state_file="$(specrelay::state::path "$task_dir")"

  # --allow-dirty-baseline is an explicit, per-invocation human override; it
  # applies even when resuming an already-created task (the human is
  # providing it right now, not only at the moment of creation).
  if [ "$allow_dirty" = "1" ]; then
    specrelay::state::set "$state_file" '{"allow_pre_existing_dirty": true}' >/dev/null
  fi

  current="$(specrelay::state::canonical "$state_file")"

  case "$current" in
    DRAFT|WAITING_FOR_HUMAN)
      specrelay::out::log "[specrelay] approving task '$task_id' (this 'specrelay run' invocation IS the human approval — see docs/engine-parity.md, 'Approval semantics')"
      if ! specrelay::transitions::approve "$root" "$task_id"; then
        specrelay::lock::release "$root" "$task_id"
        return 1
      fi
      ;;
  esac

  # Drive the shared executor<->reviewer automation loop to a terminal or
  # explicit-stop state. This is the SAME loop `specrelay resume` uses, so both
  # commands continue automated reviewer execution identically (spec 0010).
  local rc
  specrelay::workflow::drive "$root" "$task_id"
  rc=$?

  specrelay::lock::release "$root" "$task_id"
  return "$rc"
}
