#!/usr/bin/env bash
# providers/claude.sh — real Claude Code CLI executor/reviewer adapter.
#
# Preserves the current repository's proven invocation surface
# (docs/current-workflow-contract.md, section 6-7): non-interactive
# `claude --print`, `--dangerously-skip-permissions` (required because
# `--print` cannot answer an interactive permission prompt), stdout/stderr
# captured to files, and — for the reviewer role — always a brand-new
# process (never `--continue`/`--resume` of the executor's session), which is
# what "isolation" actually means here.
#
# Two live-output layers exist, chosen per run (spec 0006):
#   * SEMANTIC live events (preferred when available): Claude runs with the
#     structured stream-json output mode its own --help advertises
#     (`--verbose --output-format stream-json`), the raw JSONL events are
#     persisted to 19-executor-events.jsonl / 20-reviewer-events.jsonl, the
#     standalone renderer (py/render_agent_events.py) shows concise
#     human-readable activity lines live ([executor:claude] reading: …,
#     command: …), and the final assistant text is extracted into the numbered
#     stdout capture file so the workflow (and the reviewer DECISION grep) keep
#     working. Raw JSON is never the normal terminal UX and private reasoning is
#     never rendered.
#   * GENERIC live output (fallback, spec 0003): when semantic mode is
#     unavailable — python3/renderer missing, the installed CLI does not
#     advertise stream-json, or SPECRELAY_SEMANTIC_EVENTS=0 — the run falls back
#     to specrelay::provider::run_streamed, which streams/persists the provider's
#     plain stdout/stderr exactly as before. Semantic events are NEVER faked.
# In both layers the provider's REAL exit code is preserved.
#
# Fallback is PRE-LAUNCH ONLY: the mode is chosen from `claude --help` before
# the process starts. Once a semantic `claude` process has launched, its exit
# code is authoritative — a non-zero semantic run is reported as a provider
# failure and is NOT automatically retried as a generic run (an automatic retry
# could duplicate provider side effects or rerun a partially completed agent
# task). A renderer failure is separate and non-fatal: it may warn but never
# masks the provider exit code (see specrelay::provider::run_agent_events).

specrelay::provider::claude::_bin() {
  printf '%s\n' "${SPECRELAY_CLAUDE_BIN:-claude}"
}

# specrelay::provider::claude::_semantic_enabled
# Whether the semantic layer may be considered for this run: not explicitly
# disabled, and the renderer/python3 are available. Provider flag capability is
# checked separately (help-driven) by _stream_args.
specrelay::provider::claude::_semantic_enabled() {
  [ "${SPECRELAY_SEMANTIC_EVENTS:-1}" != "0" ] || return 1
  specrelay::provider::render_events_available
}

# specrelay::provider::claude::_stream_args <bin>
# Prints the stream-json flags to use IF the installed CLI advertises them
# (help-driven; flags are NEVER guessed), else prints nothing. `--verbose` is
# required by the CLI for stream-json with --print and is added only when the
# help text advertises it.
specrelay::provider::claude::_stream_args() {
  local bin="$1" help
  help="$("$bin" --help 2>&1)" || true
  if printf '%s' "$help" | grep -Fq -- '--output-format' \
     && printf '%s' "$help" | grep -Fq 'stream-json'; then
    if printf '%s' "$help" | grep -Fq -- '--verbose'; then
      printf '%s\n' '--verbose --output-format stream-json'
    else
      printf '%s\n' '--output-format stream-json'
    fi
  fi
}

specrelay::provider::claude::executor_run() {
  local root="$1" task_dir="$2" round="$3" prompt_file="$4" label="${5:-executor:claude}" bin prompt stream_args
  bin="$(specrelay::provider::claude::_bin)"

  if ! command -v "$bin" >/dev/null 2>&1; then
    specrelay::out::err "'$bin' was not found on PATH"
    return 1
  fi

  prompt="$(cat "$prompt_file")"

  # Preferred: semantic live events (structured stream-json). The renderer
  # persists raw events to 19-executor-events.jsonl, shows human-readable live
  # lines, and extracts the final assistant text into 12-executor-stdout.txt.
  if specrelay::provider::claude::_semantic_enabled; then
    stream_args="$(specrelay::provider::claude::_stream_args "$bin")"
    if [ -n "$stream_args" ]; then
      # shellcheck disable=SC2086  # stream_args is controlled, word-split on purpose
      specrelay::provider::run_agent_events "$label" claude \
        "$task_dir/19-executor-events.jsonl" \
        "$task_dir/12-executor-stdout.txt" \
        "$task_dir/13-executor-stderr.txt" "$root" -- \
        "$bin" --print $stream_args --dangerously-skip-permissions "$prompt"
      return $?
    fi
  fi

  # Fallback: generic stdout/stderr streaming (spec 0003). run_streamed returns
  # claude's REAL exit code.
  specrelay::provider::run_streamed "$label" \
    "$task_dir/12-executor-stdout.txt" "$task_dir/13-executor-stderr.txt" "$root" -- \
    "$bin" --print --dangerously-skip-permissions "$prompt"
  return $?
}

# specrelay::provider::claude::reviewer_run — always a fresh, non-interactive
# `claude` invocation. Prefers `--agent ai-reviewer` when the installed CLI
# advertises `--agent` AND the repository defines that agent, exactly
# mirroring the legacy tiered-detection principle ("chosen by inspecting
# claude --help, never by guessing flags"). Uses the same semantic stream-json
# layer as the executor when available, else the generic fallback.
specrelay::provider::claude::reviewer_run() {
  local root="$1" task_dir="$2" round="$3" prompt_file="$4" label="${5:-reviewer:claude}" bin prompt rc out stream_args
  bin="$(specrelay::provider::claude::_bin)"

  if ! command -v "$bin" >/dev/null 2>&1; then
    specrelay::out::err "'$bin' was not found on PATH"
    return 1
  fi

  prompt="$(cat "$prompt_file")"

  # Reviewer subagent selection (help-driven; never guess flags), preserved.
  local -a agent_args=()
  if [ -f "$root/.claude/agents/ai-reviewer.md" ] && "$bin" --help 2>&1 | grep -q -- '--agent'; then
    agent_args=(--agent ai-reviewer)
  fi

  # Preferred: semantic live events. The final assistant text is extracted into
  # 15-reviewer-stdout.txt (so the DECISION grep below still works), raw events
  # go to 20-reviewer-events.jsonl, and rendered lines + stderr go to fd 2 only —
  # this function's own stdout (the decision channel) stays clean.
  local semantic=0
  if specrelay::provider::claude::_semantic_enabled; then
    stream_args="$(specrelay::provider::claude::_stream_args "$bin")"
    [ -n "$stream_args" ] && semantic=1
  fi

  if [ "$semantic" -eq 1 ]; then
    # shellcheck disable=SC2086  # stream_args is controlled, word-split on purpose
    specrelay::provider::run_agent_events "$label" claude \
      "$task_dir/20-reviewer-events.jsonl" \
      "$task_dir/15-reviewer-stdout.txt" \
      "$task_dir/16-reviewer-stderr.txt" "$root" -- \
      "$bin" ${agent_args[@]+"${agent_args[@]}"} --print $stream_args --dangerously-skip-permissions "$prompt"
    rc=$?
  else
    # Fallback: generic streaming (spec 0003). Live output goes to fd 2 so this
    # function's OWN stdout stays reserved for the decision below.
    specrelay::provider::run_streamed "$label" \
      "$task_dir/15-reviewer-stdout.txt" "$task_dir/16-reviewer-stderr.txt" "$root" -- \
      "$bin" ${agent_args[@]+"${agent_args[@]}"} --print --dangerously-skip-permissions "$prompt"
    rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi

  # Decision extraction reads the numbered stdout capture (fully written before
  # we get here: run_streamed waits for its readers, and run_agent_events writes
  # the extracted final text at EOF and waits for the stderr reader). In both
  # modes 15-reviewer-stdout.txt holds human-readable text — raw JSON is never
  # written there — so the explicit DECISION marker stays parseable. The
  # decision travels on THIS function's own stdout, never polluted by the live
  # rendering (which is fd 2 only).
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
