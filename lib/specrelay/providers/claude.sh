#!/usr/bin/env bash
# providers/claude.sh — real Claude Code CLI executor/reviewer adapter (spec
# section 22-23). Preserves the current repository's proven invocation
# surface (docs/current-workflow-contract.md, section 6-7): non-interactive
# `claude --print`, `--dangerously-skip-permissions` (required because
# `--print` cannot answer an interactive permission prompt), stdout/stderr
# captured to files, and — for the reviewer role — always a brand-new
# process (never `--continue`/`--resume` of the executor's session), which is
# what "isolation" actually means here (spec section 23).
#
# This adapter is intentionally simpler than the legacy run-executor.sh /
# run-reviewer.sh pair: it does not thread through live semantic event
# streaming (stream-json) or the `--agent` vs `--append-system-prompt`
# multi-tier flag detection. Those are real, valuable behaviors of the
# CURRENT engine but are not required for SpecRelay's lifecycle-parity goal
# in this task (spec section 4: "do not perform an unnecessary rewrite
# merely for architectural purity" cuts both ways — a real, working adapter
# now is preferred over a speculative full port). This is recorded as a known
# gap in docs/engine-parity.md, not hidden.

specrelay::provider::claude::_bin() {
  printf '%s\n' "${SPECRELAY_CLAUDE_BIN:-claude}"
}

specrelay::provider::claude::executor_run() {
  local root="$1" task_dir="$2" round="$3" prompt_file="$4" label="${5:-executor:claude}" bin prompt rc
  bin="$(specrelay::provider::claude::_bin)"

  if ! command -v "$bin" >/dev/null 2>&1; then
    specrelay::out::err "'$bin' was not found on PATH"
    return 1
  fi

  prompt="$(cat "$prompt_file")"
  # Stream live to the terminal (prefixed) AND capture the raw streams to the
  # evidence files. run_streamed returns claude's REAL exit code (spec 0003).
  specrelay::provider::run_streamed "$label" \
    "$task_dir/12-executor-stdout.txt" "$task_dir/13-executor-stderr.txt" "$root" -- \
    "$bin" --print --dangerously-skip-permissions "$prompt"
  rc=$?
  return "$rc"
}

# specrelay::provider::claude::reviewer_run — always a fresh, non-interactive
# `claude` invocation. Prefers `--agent ai-reviewer` when the installed CLI
# advertises `--agent` AND the repository defines that agent, exactly
# mirroring the legacy tiered-detection principle ("chosen by inspecting
# claude --help, never by guessing flags") without reimplementing every tier.
specrelay::provider::claude::reviewer_run() {
  local root="$1" task_dir="$2" round="$3" prompt_file="$4" label="${5:-reviewer:claude}" bin prompt rc out
  bin="$(specrelay::provider::claude::_bin)"

  if ! command -v "$bin" >/dev/null 2>&1; then
    specrelay::out::err "'$bin' was not found on PATH"
    return 1
  fi

  prompt="$(cat "$prompt_file")"
  local -a args=(--print --dangerously-skip-permissions)
  if [ -f "$root/.claude/agents/ai-reviewer.md" ] && "$bin" --help 2>&1 | grep -q -- '--agent'; then
    args=(--agent ai-reviewer --print --dangerously-skip-permissions)
  fi

  # Stream live to the terminal (fd 2, prefixed) AND capture raw streams to the
  # evidence files. Live output goes to fd 2 so this function's OWN stdout
  # stays reserved for the machine-readable decision below, which the lifecycle
  # reads via command substitution (spec 0003). run_streamed waits for the
  # readers, so 15-reviewer-stdout.txt is fully written before we grep it.
  specrelay::provider::run_streamed "$label" \
    "$task_dir/15-reviewer-stdout.txt" "$task_dir/16-reviewer-stderr.txt" "$root" -- \
    "$bin" "${args[@]}" "$prompt"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi

  out="$(cat "$task_dir/15-reviewer-stdout.txt")"
  if printf '%s\n' "$out" | grep -qE 'DECISION:[[:space:]]*ACCEPT[[:space:]]*$'; then
    echo "ACCEPT"
    return 0
  fi
  if printf '%s\n' "$out" | grep -qE 'DECISION:[[:space:]]*REQUEST_CHANGES[[:space:]]*$'; then
    echo "REQUEST_CHANGES"
    return 0
  fi

  specrelay::out::err "reviewer produced no explicit 'DECISION: ACCEPT|REQUEST_CHANGES' marker; refusing to infer a decision from prose"
  return 1
}
