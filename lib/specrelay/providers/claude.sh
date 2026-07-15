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

# --- provider capability (spec 0014) -----------------------------------------
#
# Provider-owned model-selection knowledge. The Claude CLI does not expose a
# reliable, non-billable, machine-readable list of the models available to the
# current account, so this adapter's practical capability level is
# "Declared Aliases Only": a small, adapter-owned set of provider-recognized
# semantic aliases can be validated locally, but SpecRelay never claims to
# enumerate all remote Claude models — an exact model id is forwarded as-is and
# ultimately validated by the provider. Nothing here performs any billable or
# remote call.

# Capability level: exact | aliases | structural | none (see providers/capability.sh).
specrelay::provider::claude::capability_level() {
  printf 'aliases\n'
}

specrelay::provider::claude::capability_supports_explicit_model() {
  return 0
}

# The adapter-declared, provider-scoped alias set (one per line). These are the
# semantic model aliases the Claude CLI itself recognizes as --model arguments;
# SpecRelay does not invent aliases beyond what the adapter declares here.
specrelay::provider::claude::capability_declared_aliases() {
  printf 'opus\nsonnet\n'
}

# specrelay::provider::claude::capability_resolve_alias <alias>
# Deterministic alias resolution: a declared alias resolves to itself — the
# provider-recognized alias ARGUMENT passed via --model (the CLI maps it to the
# latest concrete model). SpecRelay never fabricates an exact model id for it.
# Unknown aliases fail (non-zero, nothing printed).
specrelay::provider::claude::capability_resolve_alias() {
  local alias="$1" a
  while IFS= read -r a; do
    if [ "$a" = "$alias" ]; then
      printf '%s\n' "$alias"
      return 0
    fi
  done < <(specrelay::provider::claude::capability_declared_aliases)
  return 1
}

# Discovery status: "unavailable" — no reliable non-billable model list exists,
# and SpecRelay does not pretend otherwise (spec 0014, "No false certainty").
specrelay::provider::claude::capability_discovery_status() {
  printf 'unavailable\n'
}

specrelay::provider::claude::capability_discovered_models() {
  return 1
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

# specrelay::provider::claude::_model_supported <bin>
# True (exit 0) when the installed Claude CLI advertises a `--model` flag in its
# `--help` output. Model passing is help-driven (spec 0009): a model flag is
# NEVER guessed — it is passed only when help advertises it, and an explicit
# model configured against a CLI that does not advertise `--model` is a hard
# failure (the adapter refuses rather than silently dropping the model).
specrelay::provider::claude::_model_supported() {
  local bin="$1" help
  help="$("$bin" --help 2>&1)" || true
  printf '%s' "$help" | grep -Fq -- '--model'
}

# specrelay::provider::claude::_resolve_model_args <role> <bin> <model>
# Prints the model flag(s) to pass for an effective <model> (empty for
# `provider-default`), or fails (non-zero, with a clear error) when an explicit
# model is configured but the CLI cannot accept one. Callers MUST check the
# return code before using the printed value.
specrelay::provider::claude::_resolve_model_args() {
  local role="$1" bin="$2" model="$3"
  if [ -z "$model" ] || [ "$model" = "provider-default" ]; then
    return 0
  fi
  if specrelay::provider::claude::_model_supported "$bin"; then
    printf '%s\n' "--model $model"
    return 0
  fi
  specrelay::out::err "$role: model '$model' is configured but the Claude CLI ('$bin') does not advertise a --model flag; refusing to silently ignore the configured model"
  return 1
}

# specrelay::provider::claude::_context_fragment <context>
# The normalized context handoff (spec 0015) rendered as a provider-readable
# prompt fragment. The handoff is an opaque "<kind>:<reference>" string
# produced by the generic context step; this adapter never parses
# adapter-specific context formats — it only tells the agent where the
# prepared, role-specific context artifact lives. Prints nothing for "none".
specrelay::provider::claude::_context_fragment() {
  local context="$1"
  [ -n "$context" ] && [ "$context" != "none" ] || return 0
  printf '\n\n=== Prepared role context (SpecRelay context adapter handoff) ===\n'
  printf 'A role-specific context artifact was prepared for this run: %s\n' "$context"
  printf 'Consult it (relative to the repository root) before implementation.\n'
}

specrelay::provider::claude::executor_run() {
  local root="$1" task_dir="$2" round="$3" prompt_file="$4" label="${5:-executor:claude}" model="${6:-provider-default}" agent="${7:-none}" context="${8:-none}" invocation_id="${9:-1}" bin prompt stream_args model_args
  bin="$(specrelay::provider::claude::_bin)"

  if ! command -v "$bin" >/dev/null 2>&1; then
    specrelay::out::err "'$bin' was not found on PATH"
    return 1
  fi

  # Model negotiation (help-driven): fail clearly before launch if an explicit
  # model is configured but the CLI cannot accept one.
  if ! model_args="$(specrelay::provider::claude::_resolve_model_args "$label" "$bin" "$model")"; then
    return 1
  fi

  prompt="$(cat "$prompt_file")$(specrelay::provider::claude::_context_fragment "$context")"

  # Preferred: semantic live events (structured stream-json). The renderer
  # persists raw events to 19-executor-events.jsonl, shows human-readable live
  # lines, and extracts the final assistant text into 12-executor-stdout.txt.
  if specrelay::provider::claude::_semantic_enabled; then
    stream_args="$(specrelay::provider::claude::_stream_args "$bin")"
    if [ -n "$stream_args" ]; then
      # shellcheck disable=SC2086  # stream_args/model_args are controlled, word-split on purpose
      specrelay::provider::run_agent_events "$label" claude \
        "$task_dir/19-executor-events.jsonl" \
        "$task_dir/12-executor-stdout.txt" \
        "$task_dir/13-executor-stderr.txt" "$root" "$invocation_id" -- \
        "$bin" --print $stream_args $model_args --dangerously-skip-permissions "$prompt"
      return $?
    fi
  fi

  # Fallback: generic stdout/stderr streaming (spec 0003). run_streamed returns
  # claude's REAL exit code.
  # shellcheck disable=SC2086  # model_args is controlled, word-split on purpose
  specrelay::provider::run_streamed "$label" \
    "$task_dir/12-executor-stdout.txt" "$task_dir/13-executor-stderr.txt" "$root" -- \
    "$bin" --print $model_args --dangerously-skip-permissions "$prompt"
  return $?
}

# specrelay::provider::claude::reviewer_run — always a fresh, non-interactive
# `claude` invocation. Prefers `--agent ai-reviewer` when the installed CLI
# advertises `--agent` AND the repository defines that agent, exactly
# mirroring the legacy tiered-detection principle ("chosen by inspecting
# claude --help, never by guessing flags"). Uses the same semantic stream-json
# layer as the executor when available, else the generic fallback.
specrelay::provider::claude::reviewer_run() {
  local root="$1" task_dir="$2" round="$3" prompt_file="$4" label="${5:-reviewer:claude}" model="${6:-provider-default}" agent="${7:-}" context="${8:-none}" invocation_id="${9:-1}" bin prompt rc out stream_args model_args
  bin="$(specrelay::provider::claude::_bin)"

  if ! command -v "$bin" >/dev/null 2>&1; then
    specrelay::out::err "'$bin' was not found on PATH"
    return 1
  fi

  # Model negotiation (help-driven): fail clearly before launch if an explicit
  # model is configured but the CLI cannot accept one.
  if ! model_args="$(specrelay::provider::claude::_resolve_model_args "$label" "$bin" "$model")"; then
    return 1
  fi

  # The reviewer receives ITS OWN independently prepared context handoff (spec
  # 0015, role isolation) — never the executor's.
  prompt="$(cat "$prompt_file")$(specrelay::provider::claude::_context_fragment "$context")"

  # Reviewer subagent selection (help-driven; never guess flags). The effective
  # agent comes from the normalized role config (spec 0009). An empty value is
  # the legacy/direct-call default and preserves the original auto-detect
  # behavior ("prefer ai-reviewer when the project ships it and the CLI
  # advertises --agent"); "none" disables the sub-agent explicitly; any other
  # name selects that sub-agent when the CLI advertises --agent (and, for
  # ai-reviewer, when the project provides .claude/agents/ai-reviewer.md — the
  # 0008 fallback so a missing agent file never breaks the reviewer).
  local -a agent_args=()
  case "$agent" in
    ""|auto|ai-reviewer)
      if [ -f "$root/.claude/agents/ai-reviewer.md" ] && "$bin" --help 2>&1 | grep -q -- '--agent'; then
        agent_args=(--agent ai-reviewer)
      fi
      ;;
    none)
      : # explicitly no provider-specific sub-agent
      ;;
    *)
      if "$bin" --help 2>&1 | grep -q -- '--agent'; then
        agent_args=(--agent "$agent")
      fi
      ;;
  esac

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
    # shellcheck disable=SC2086  # stream_args/model_args are controlled, word-split on purpose
    specrelay::provider::run_agent_events "$label" claude \
      "$task_dir/20-reviewer-events.jsonl" \
      "$task_dir/15-reviewer-stdout.txt" \
      "$task_dir/16-reviewer-stderr.txt" "$root" "$invocation_id" -- \
      "$bin" ${agent_args[@]+"${agent_args[@]}"} --print $stream_args $model_args --dangerously-skip-permissions "$prompt"
    rc=$?
  else
    # Fallback: generic streaming (spec 0003). Live output goes to fd 2 so this
    # function's OWN stdout stays reserved for the decision below.
    # shellcheck disable=SC2086  # model_args is controlled, word-split on purpose
    specrelay::provider::run_streamed "$label" \
      "$task_dir/15-reviewer-stdout.txt" "$task_dir/16-reviewer-stderr.txt" "$root" -- \
      "$bin" ${agent_args[@]+"${agent_args[@]}"} --print $model_args --dangerously-skip-permissions "$prompt"
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
  # rendering (which is fd 2 only). specrelay::marker::parse (spec 0019, marker.sh)
  # enforces the full contract: exactly one marker, uppercase, on its own line,
  # and the final non-empty line — never inferred from prose.
  out="$(cat "$task_dir/15-reviewer-stdout.txt")"
  local decision
  if decision="$(specrelay::marker::parse "$out")"; then
    printf '%s\n' "$decision"
    return 0
  fi

  # A provider that exited 0 but produced no valid marker is NOT the same
  # failure as a crashed process (rc=1 above): it may still have written
  # complete review artifacts, which is exactly the case smart marker recovery
  # (spec 0019, marker_recovery.sh) exists to resolve without repeating the
  # whole review. rc=2 is that distinguishable signal; workflow.sh's reviewer
  # loop is the only caller that interprets it.
  specrelay::out::err "reviewer produced no valid 'DECISION: ACCEPT|REQUEST_CHANGES' marker; refusing to infer a decision from prose"
  return 2
}

# specrelay::provider::claude::reviewer_recover_marker <root> <task-dir>
#     <narrow-prompt-file> <label> <model> <agent>
# The ONE corrective, marker-only attempt (spec 0019, "Smart Marker
# Recovery"). Deliberately never passes `--dangerously-skip-permissions` and
# never selects the `--agent ai-reviewer` sub-agent (that sub-agent's whole
# purpose is the FULL review contract, not this narrow follow-up). Without
# that flag, `claude --print` has no interactive channel to grant permission
# for a tool call (see this file's own header: the flag exists ONLY because
# `--print` cannot answer an interactive permission prompt) — so any attempt
# to invoke a repository tool (Bash/Read/Edit/Write/...) is refused by the
# CLI itself, not merely discouraged by prompt text. This is the same
# documented mechanism already governing every other `--print` invocation in
# this adapter, reused here as the enforcement boundary rather than a new,
# unverified flag guess.
specrelay::provider::claude::reviewer_recover_marker() {
  local root="$1" task_dir="$2" prompt_file="$3" label="${4:-reviewer-recovery:claude}" model="${5:-provider-default}" agent="${6:-none}"
  local bin prompt rc out model_args
  bin="$(specrelay::provider::claude::_bin)"

  if ! command -v "$bin" >/dev/null 2>&1; then
    specrelay::out::err "'$bin' was not found on PATH"
    return 1
  fi
  if ! model_args="$(specrelay::provider::claude::_resolve_model_args "$label" "$bin" "$model")"; then
    return 1
  fi

  prompt="$(cat "$prompt_file")"

  # shellcheck disable=SC2086  # model_args is controlled, word-split on purpose
  specrelay::provider::run_streamed "$label" \
    "$task_dir/21-marker-recovery-stdout.txt" "$task_dir/21-marker-recovery-stderr.txt" "$root" -- \
    "$bin" --print $model_args "$prompt"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi

  out="$(cat "$task_dir/21-marker-recovery-stdout.txt")"
  local decision
  if decision="$(specrelay::marker::parse "$out")"; then
    printf '%s\n' "$decision"
    return 0
  fi
  specrelay::out::err "marker-recovery attempt produced no valid decision marker"
  return 1
}

# specrelay::provider::claude::coordinator_run <root> <task-dir> <prompt-file>
#     <raw-output-file> <label> <model> <agent>
# The Coordinator's ONE read-only invocation (spec 0025, section 18: "If the
# provider platform cannot enforce tool restrictions directly, the engine
# must enforce them by invoking the coordinator through a read-only adapter
# and accepting only the structured decision output"). Reuses EXACTLY the
# same enforcement mechanism as reviewer_recover_marker above: never passes
# `--dangerously-skip-permissions`, so `claude --print` has no interactive
# channel to grant a tool-call permission — any attempt at Bash/Read/Edit/
# Write/... is refused by the CLI itself, not merely discouraged by prompt
# text. Writes the model's raw final text verbatim to <raw-output-file> (the
# UNvalidated candidate decision); coordinator.sh's structured validator is
# solely responsible for deciding whether that text is a valid decision.
specrelay::provider::claude::coordinator_run() {
  local root="$1" task_dir="$2" prompt_file="$3" raw_output_file="$4" \
    label="${5:-coordinator:claude}" model="${6:-provider-default}" agent="${7:-none}"
  local bin prompt rc model_args
  bin="$(specrelay::provider::claude::_bin)"

  if ! command -v "$bin" >/dev/null 2>&1; then
    specrelay::out::err "'$bin' was not found on PATH"
    return 1
  fi
  if ! model_args="$(specrelay::provider::claude::_resolve_model_args "$label" "$bin" "$model")"; then
    return 1
  fi

  prompt="$(cat "$prompt_file")"

  # shellcheck disable=SC2086  # model_args is controlled, word-split on purpose
  specrelay::provider::run_streamed "$label" \
    "$raw_output_file" "$task_dir/25-coordinator-stderr.txt" "$root" -- \
    "$bin" --print $model_args "$prompt"
  rc=$?
  return "$rc"
}
