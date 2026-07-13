#!/usr/bin/env bash
# context/contextplus.sh — Context Plus capability adapter (spec section 25).
# Migrates the real current behavior of
# .ai/scripts/internal/context-plus-preflight.sh's Claude-family path: proves
# availability via `claude mcp list` (a real health check, not an assumption
# from .mcp.json's presence), then performs ONE bounded, scoped, real
# `semantic_code_search` retrieval call before returning success. No silent
# fallback: any failed step is a hard refusal.
#
# This is deliberately narrower than the legacy script (no Codex adapter, no
# --strict-mcp-config server-extraction helper) — SpecRelay's only currently
# configured provider needing this capability in this repository is Claude
# (see .specrelay/config.yml); a future provider gets its own adapter branch
# here, not a rewrite of this one. Recorded in docs/engine-parity.md.
#
# Env hooks (test-only; normal operation needs none of these):
#   SPECRELAY_CONTEXTPLUS_CLAUDE_BIN      claude-compatible binary (default: claude)
#   SPECRELAY_CONTEXTPLUS_SERVER_NAME     registered MCP server name (default: contextplus)
#   SPECRELAY_CONTEXTPLUS_MAX_BUDGET_USD  spend cap for the one bounded call (default: 0.50)

# --- capability contract (spec 0015) -----------------------------------------
#
# Honest capability reporting: this adapter can prove installation and perform
# a bounded retrieval during preflight, but it produces NO durable context
# artifact — so it reports the "preflight" capability level, never "indexed"
# or "prepared" (SpecRelay must not infer a higher level from branding).

specrelay::context::contextplus::describe() {
  printf 'Context Plus capability preflight (MCP health check + one bounded retrieval).\n'
}

# Availability is a LOCAL, non-billable check only (`contexts` and `doctor`
# must never spend): the configured Claude-compatible binary must exist on
# PATH. The deeper MCP registration/connection health check happens in the
# preflight at run time, where a real invocation is about to be paid for
# anyway.
specrelay::context::contextplus::availability() {
  local claude_bin
  claude_bin="${SPECRELAY_CONTEXTPLUS_CLAUDE_BIN:-claude}"
  if ! command -v "$claude_bin" >/dev/null 2>&1; then
    printf 'unavailable\n'
    printf 'required executable or configuration was not found\n'
    return 1
  fi
  printf 'available\n'
}

specrelay::context::contextplus::capability_level() {
  printf 'preflight\n'
}

specrelay::context::contextplus::capabilities() {
  printf 'preflight=yes\n'
  printf 'prepare=no\n'
  printf 'durable_artifact=no\n'
  printf 'role_isolation=yes\n'
  printf 'network=yes\n'
  printf 'freshness_check=no\n'
}

specrelay::context::contextplus::supported_roles() {
  printf 'executor reviewer\n'
}

specrelay::context::contextplus::validate_config() {
  return 0
}

specrelay::context::contextplus::preflight() {
  local role="$1" root="$2" task_id="$3" provider="$4" rc tmp_dir=""
  specrelay::context::contextplus::_run "$role" "$root" "$task_id" "$provider"
  rc=$?
  [ -n "${SPECRELAY_CONTEXTPLUS_TMP_DIR:-}" ] && rm -rf "$SPECRELAY_CONTEXTPLUS_TMP_DIR" 2>/dev/null
  unset SPECRELAY_CONTEXTPLUS_TMP_DIR
  return "$rc"
}

specrelay::context::contextplus::_run() {
  local role="$1" root="$2" task_id="$3" provider="$4"
  local claude_bin server max_budget purpose

  claude_bin="${SPECRELAY_CONTEXTPLUS_CLAUDE_BIN:-claude}"
  server="${SPECRELAY_CONTEXTPLUS_SERVER_NAME:-contextplus}"
  max_budget="${SPECRELAY_CONTEXTPLUS_MAX_BUDGET_USD:-0.50}"
  purpose="task-relevant repository context for task ${task_id:-<no task id>} ($role role)"

  echo "[$role] context-plus: checking (provider: $provider, server: $server)"

  if [ "$provider" = "manual" ] || [ "$provider" = "fake" ]; then
    echo "[$role] context-plus: not applicable (provider '$provider' runs no automated agent)"
    return 0
  fi

  if ! command -v "$claude_bin" >/dev/null 2>&1; then
    specrelay::out::err "[$role] context-plus: '$claude_bin' was not found on PATH"
    return 1
  fi

  local mcp_list_out mcp_list_rc
  mcp_list_out="$("$claude_bin" mcp list 2>&1)"
  mcp_list_rc=$?
  if [ "$mcp_list_rc" -ne 0 ] || [ -z "$mcp_list_out" ]; then
    specrelay::out::err "[$role] context-plus: '$claude_bin mcp list' failed or produced no output"
    return 1
  fi

  local server_line
  server_line="$(printf '%s\n' "$mcp_list_out" | grep -F "$server:" || true)"
  if [ -z "$server_line" ]; then
    specrelay::out::err "[$role] context-plus: '$server' is not registered (not found in '$claude_bin mcp list')"
    return 1
  fi
  if ! printf '%s' "$server_line" | grep -Eiq 'connected'; then
    specrelay::out::err "[$role] context-plus: '$server' is registered but not connected"
    return 1
  fi

  echo "[$role] context-plus: available"
  echo "[$role] context-plus: initialized"
  echo "[$role] context-plus: retrieving $purpose"

  local tmp_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-contextplus.XXXXXX")"
  SPECRELAY_CONTEXTPLUS_TMP_DIR="$tmp_dir"

  local mcp_config="$tmp_dir/mcp-config.json"
  if ! MCP_JSON="$root/.mcp.json" SERVER="$server" OUT="$mcp_config" python3 - <<'PY' 2>/dev/null
import json, os
src = os.environ["MCP_JSON"]
server = os.environ["SERVER"]
out = os.environ["OUT"]
with open(src, encoding="utf-8") as fh:
    data = json.load(fh)
servers = data.get("mcpServers", {})
if server not in servers:
    raise SystemExit(1)
with open(out, "w", encoding="utf-8") as fh:
    json.dump({"mcpServers": {server: servers[server]}}, fh)
PY
  then
    cp "$root/.mcp.json" "$mcp_config" 2>/dev/null || true
  fi

  local query="Call the '${server}' MCP server's semantic_code_search tool exactly once, with a query describing: $purpose. Do not call any other tool. After the tool call returns, reply with only the single line: CONTEXT_PLUS_OK."
  local retrieval_out="$tmp_dir/retrieval-stdout.jsonl" retrieval_rc

  "$claude_bin" --print \
    --strict-mcp-config --mcp-config "$mcp_config" \
    --allowedTools "mcp__${server}__semantic_code_search" \
    --permission-mode bypassPermissions \
    --max-budget-usd "$max_budget" \
    --output-format stream-json --verbose \
    "$query" > "$retrieval_out" 2> "$tmp_dir/retrieval-stderr.txt"
  retrieval_rc=$?

  if [ "$retrieval_rc" -ne 0 ]; then
    specrelay::out::err "[$role] context-plus: the meaningful-retrieval call exited non-zero ($retrieval_rc)"
    return 1
  fi
  if ! grep -Fq "mcp__${server}__semantic_code_search" "$retrieval_out"; then
    specrelay::out::err "[$role] context-plus: no evidence of a $server tool call in the retrieval response"
    return 1
  fi

  echo "[$role] context-plus: query completed"
  echo "[$role] context-plus: context loaded"
  return 0
}
