#!/usr/bin/env bash
# context/contextplus.sh — Context Plus capability adapter (spec 0015, spec
# 0018 "Runtime Readiness and Configuration Source").
#
# Spec 0018 replaces the old single ambiguous "available" signal (which meant
# only "the claude executable is on PATH") with explicit, distinct readiness
# concepts that must never collapse into one status:
#
#   installed    the configured Claude-compatible executable exists
#   registered   the configured MCP server name appears in `claude mcp list`
#   connected    that MCP server is reported connected (not merely registered)
#   config source  which .mcp.json / registration can produce a valid
#                   --strict-mcp-config for the actual retrieval
#   retrieval ready  installed + registered + connected + a usable config
#                    source are ALL true (safe to attempt bounded retrieval)
#   verified     a real bounded retrieval succeeded (established ONLY by the
#                runtime preflight below, never by `contexts` or `doctor`)
#
# Chosen scope (spec 0018, "Recommended Initial Scope" / "Strict MCP
# Configuration", Option A): only a valid PROJECT-LOCAL .mcp.json entry can
# satisfy retrieval readiness. `claude mcp list` may confirm registration and
# connection health (which may reflect project- or user-scoped registration —
# the CLI's human-readable list does not reliably distinguish the two, so both
# are reported under the "global" registration signal, distinct from the
# on-disk project .mcp.json check), but a registration with no valid project
# .mcp.json entry is reported honestly as config-incomplete, never as ready.
# No global-config export/reconstruction is attempted — that would risk
# fabricating a usable config the CLI never actually promised (spec 0018,
# "Reviewer Rejection Conditions").
#
# Env hooks (test-only; normal operation needs none of these):
#   SPECRELAY_CONTEXTPLUS_CLAUDE_BIN      claude-compatible binary (default: claude)
#   SPECRELAY_CONTEXTPLUS_SERVER_NAME     registered MCP server name (default: contextplus)
#   SPECRELAY_CONTEXTPLUS_MAX_BUDGET_USD  spend cap for the one bounded call (default: 0.50)
#
# Role-specific configuration (spec 0018, "Configuration Validation"):
#   context:
#     executor:
#       adapter: contextplus
#       options:
#         server_name: contextplus   # non-empty string, default: contextplus
#         config_source: auto        # auto | project | global, default: auto
# "global" is accepted syntactically but never becomes retrieval-ready (Option
# A) — requesting it explicitly fails clearly rather than silently degrading
# to "auto". An env override (SPECRELAY_CONTEXTPLUS_SERVER_NAME) always wins
# over a configured server_name, for test determinism.

# --- capability contract (spec 0015) -----------------------------------------
#
# Honest capability reporting: this adapter can prove installation and perform
# a bounded retrieval during preflight, but it produces NO durable context
# artifact — so it reports the "preflight" capability level, never "indexed"
# or "prepared" (SpecRelay must not infer a higher level from branding).

specrelay::context::contextplus::describe() {
  printf 'Context Plus MCP preflight with one bounded semantic retrieval.\n'
}

specrelay::context::contextplus::_claude_bin() {
  printf '%s\n' "${SPECRELAY_CONTEXTPLUS_CLAUDE_BIN:-claude}"
}

specrelay::context::contextplus::_default_server_name() {
  printf '%s\n' "${SPECRELAY_CONTEXTPLUS_SERVER_NAME:-contextplus}"
}

# specrelay::context::contextplus::_option <root> <role> <key>
# One resolved contextplus option value for a role (empty string if unset).
# Only reached after config.sh has already validated the options mapping's
# SHAPE; malformed JSON here degrades to empty rather than erroring again.
specrelay::context::contextplus::_option() {
  local root="$1" role="$2" key="$3" opts_json
  opts_json="$(specrelay::config::role_context_options "$root" "$role" 2>/dev/null || printf '{}\n')"
  printf '%s' "$opts_json" | KEY="$key" python3 -c '
import json, os, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
val = data.get(os.environ["KEY"])
print(val if isinstance(val, str) else "")
' 2>/dev/null
}

# specrelay::context::contextplus::_server_name_for_role <root> <role>
# Precedence: env override (test-only) -> configured options.server_name ->
# built-in default. Used ONLY where a role is known (preflight); generic,
# role-less inspection (contexts/doctor/availability) uses the env/default
# pair via _default_server_name.
specrelay::context::contextplus::_server_name_for_role() {
  local root="$1" role="$2" cfg
  if [ -n "${SPECRELAY_CONTEXTPLUS_SERVER_NAME:-}" ]; then
    printf '%s\n' "$SPECRELAY_CONTEXTPLUS_SERVER_NAME"
    return 0
  fi
  cfg="$(specrelay::context::contextplus::_option "$root" "$role" server_name)"
  [ -n "$cfg" ] && printf '%s\n' "$cfg" || printf 'contextplus\n'
}

# specrelay::context::contextplus::_config_source_for_role <root> <role>
# Prints auto|project|global (default auto). Config-shape validation
# (validate_config) already rejected anything else before a role can run.
specrelay::context::contextplus::_config_source_for_role() {
  local root="$1" role="$2" cfg
  cfg="$(specrelay::context::contextplus::_option "$root" "$role" config_source)"
  case "$cfg" in
    auto|project|global) printf '%s\n' "$cfg" ;;
    *) printf 'auto\n' ;;
  esac
}

# specrelay::context::contextplus::_mcp_list_status <claude-bin> <server> <root>
# Runs `claude mcp list` (a local, non-mutating, non-billable health check —
# it does not invoke any tool) FROM the project root (so project-scoped
# .mcp.json registrations are visible regardless of the caller's cwd) and
# reports the given server's registration/connection status as key=value
# lines:
#   registered=yes|no
#   connected=yes|no|unknown   ("unknown" MUST NOT be treated as connected)
#   error=none|list-failed|list-empty
# Matching is line-anchored on the server name up to the FIRST colon, so a
# similarly-named server (e.g. "contextplus-extra" or "my-contextplus") never
# produces a false match (spec 0018, Required Tests: "Registration").
specrelay::context::contextplus::_mcp_list_status() {
  local claude_bin="$1" server="$2" root="$3" out rc
  out="$(cd "$root" && "$claude_bin" mcp list 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'registered=no\nconnected=unknown\nerror=list-failed\n'
    return 0
  fi
  if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
    printf 'registered=no\nconnected=unknown\nerror=list-empty\n'
    return 0
  fi
  printf '%s\n' "$out" | SERVER="$server" python3 -c '
import os, re, sys

server = os.environ["SERVER"]
found = False
connected = "unknown"
for raw_line in sys.stdin:
    line = raw_line.strip()
    if not line or ":" not in line:
        continue
    name, rest = line.split(":", 1)
    if name.strip() != server:
        continue
    found = True
    negative_symbols = ("✗", "✘")
    positive_symbols = ("✓", "✔")
    if (
        re.search(r"(?i)(disconnected|failed|error|needs authentication|unauthenticated)", rest)
        or any(sym in rest for sym in negative_symbols)
    ):
        connected = "no"
    elif re.search(r"(?i)\bconnected\b", rest) or any(sym in rest for sym in positive_symbols):
        connected = "yes"
    break

reported_connected = connected if found else "unknown"
print("registered=yes" if found else "registered=no")
print("connected=" + reported_connected)
print("error=none")
'
}

# specrelay::context::contextplus::_project_config_status <root> <server>
# Inspects <root>/.mcp.json ONLY (never prints its contents — no secrets):
#   missing         the file does not exist
#   invalid         not valid JSON, or has no usable "mcpServers" mapping
#   server-missing  valid mcpServers mapping, but no entry for <server>
#   valid           a structurally usable entry for <server> exists
specrelay::context::contextplus::_project_config_status() {
  local root="$1" server="$2" path="$root/.mcp.json"
  [ -f "$path" ] || { printf 'missing\n'; return 0; }
  SERVER="$server" python3 - "$path" <<'PY'
import json, os, sys

path = sys.argv[1]
server = os.environ["SERVER"]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print("invalid")
    sys.exit(0)

if not isinstance(data, dict) or not isinstance(data.get("mcpServers"), dict):
    print("invalid")
    sys.exit(0)

servers = data["mcpServers"]
if server not in servers:
    print("server-missing")
    sys.exit(0)

entry = servers[server]
if not isinstance(entry, dict) or not entry:
    print("invalid")
    sys.exit(0)

print("valid")
PY
}

# specrelay::context::contextplus::readiness <root> [server-name-override]
# The structured readiness inspection (spec 0018, "Readiness Inspection API").
# Prints key=value lines (status, installed, registered, connected,
# project_config, global_detected, selected_source, retrieval_ready, server,
# reason) and ALWAYS exits 0 — this is a report, not a pass/fail gate; callers
# (availability, contexts, doctor, preflight's re-check) each apply their own
# policy on top of "status". NEVER performs a billable retrieval and NEVER
# mutates anything. reason is always a single line and never contains secret
# values (only server/config-source/field names and connection status).
specrelay::context::contextplus::readiness() {
  local root="$1" server_override="${2:-}"
  local claude_bin server

  claude_bin="$(specrelay::context::contextplus::_claude_bin)"
  if [ -n "$server_override" ]; then
    server="$server_override"
  else
    server="$(specrelay::context::contextplus::_default_server_name)"
  fi

  if ! command -v "$claude_bin" >/dev/null 2>&1; then
    printf 'status=unavailable\n'
    printf 'installed=no\nregistered=no\nconnected=no\n'
    printf 'project_config=not-checked\nglobal_detected=no\nselected_source=none\nretrieval_ready=no\n'
    printf 'server=%s\nbin=%s\n' "$server" "$claude_bin"
    printf "reason=Claude-compatible executable '%s' was not found on PATH.\n" "$claude_bin"
    return 0
  fi

  local mcp_out reg conn err
  mcp_out="$(specrelay::context::contextplus::_mcp_list_status "$claude_bin" "$server" "$root")"
  reg="$(printf '%s\n' "$mcp_out" | sed -n 's/^registered=//p')"
  conn="$(printf '%s\n' "$mcp_out" | sed -n 's/^connected=//p')"
  err="$(printf '%s\n' "$mcp_out" | sed -n 's/^error=//p')"

  if [ "$reg" != "yes" ]; then
    printf 'status=installed\n'
    printf 'installed=yes\nregistered=no\nconnected=no\n'
    printf 'project_config=not-checked\nglobal_detected=no\nselected_source=none\nretrieval_ready=no\n'
    printf 'server=%s\nbin=%s\n' "$server" "$claude_bin"
    case "$err" in
      list-failed)
        printf "reason='%s mcp list' failed; registration cannot be determined.\n" "$claude_bin" ;;
      list-empty)
        printf "reason='%s mcp list' produced no output; registration cannot be determined.\n" "$claude_bin" ;;
      *)
        printf "reason=Context+ MCP server '%s' is not registered.\n" "$server" ;;
    esac
    return 0
  fi

  if [ "$conn" = "unknown" ]; then
    printf 'status=registered\n'
    printf 'installed=yes\nregistered=yes\nconnected=no\n'
    printf 'project_config=not-checked\nglobal_detected=yes\nselected_source=none\nretrieval_ready=no\n'
    printf 'server=%s\nbin=%s\n' "$server" "$claude_bin"
    printf "reason=Context+ MCP server '%s' is registered, but its connection status could not be verified.\n" "$server"
    return 0
  fi

  if [ "$conn" = "no" ]; then
    printf 'status=disconnected\n'
    printf 'installed=yes\nregistered=yes\nconnected=no\n'
    printf 'project_config=not-checked\nglobal_detected=yes\nselected_source=none\nretrieval_ready=no\n'
    printf 'server=%s\nbin=%s\n' "$server" "$claude_bin"
    printf "reason=Context+ MCP server '%s' is registered but reported disconnected.\n" "$server"
    return 0
  fi

  # registered=yes, connected=yes: the only remaining gate is a usable
  # project-local strict MCP config (Option A).
  local pc
  pc="$(specrelay::context::contextplus::_project_config_status "$root" "$server")"

  if [ "$pc" = "valid" ]; then
    printf 'status=ready\n'
    printf 'installed=yes\nregistered=yes\nconnected=yes\n'
    printf 'project_config=valid\nglobal_detected=yes\nselected_source=project\nretrieval_ready=yes\n'
    printf 'server=%s\nbin=%s\n' "$server" "$claude_bin"
    printf 'reason=Registration, connection, and a valid project .mcp.json entry are all present.\n'
    return 0
  fi

  printf 'status=config-incomplete\n'
  printf 'installed=yes\nregistered=yes\nconnected=yes\n'
  printf 'project_config=%s\n' "$pc"
  printf 'global_detected=yes\nselected_source=none\nretrieval_ready=no\n'
  printf 'server=%s\nbin=%s\n' "$server" "$claude_bin"
  case "$pc" in
    missing)
      printf "reason=Global registration is visible, but no project-local .mcp.json exists; SpecRelay cannot construct a safe strict MCP config from global registration alone. Add a project-local .mcp.json entry for '%s'.\n" "$server" ;;
    server-missing)
      printf "reason=project .mcp.json exists but has no entry for '%s'.\n" "$server" ;;
    *)
      printf 'reason=project .mcp.json exists but is not valid JSON or has no usable mcpServers mapping.\n' ;;
  esac
}

# Availability (spec 0018, "Availability Contract"): no longer "the claude
# executable exists" — it now means the adapter is ready enough to attempt its
# promised bounded retrieval, i.e. status=ready (installed + registered +
# connected + a usable project config source). Read-only and non-billable —
# safe for `contexts`, `doctor`, and the pre-preflight check in workflow.sh.
specrelay::context::contextplus::availability() {
  local root="$1" out status reason
  out="$(specrelay::context::contextplus::readiness "$root")"
  status="$(printf '%s\n' "$out" | sed -n 's/^status=//p')"
  reason="$(printf '%s\n' "$out" | sed -n 's/^reason=//p')"
  if [ "$status" = "ready" ]; then
    printf 'available\n'
    return 0
  fi
  printf 'unavailable\n'
  printf '%s\n' "${reason:-Context+ is not ready ($status).}"
  return 1
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

# specrelay::context::contextplus::validate_config <root> <role>
# Adapter-specific option validation (spec 0018, "Configuration Validation").
# config.sh has already confirmed "options" (if present) is a mapping; this
# validates its CONTENTS: only server_name/config_source are recognized,
# server_name must be a non-empty string, and config_source must be one of
# auto/project/global. Unknown keys and invalid values are rejected clearly.
specrelay::context::contextplus::validate_config() {
  local root="$1" role="$2" opts_json result
  opts_json="$(specrelay::config::role_context_options "$root" "$role" 2>/dev/null || printf '{}\n')"
  result="$(printf '%s' "$opts_json" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("error=contextplus options must be valid JSON")
    sys.exit(0)

if not isinstance(data, dict):
    print("error=contextplus options must be a mapping")
    sys.exit(0)

allowed = {"server_name", "config_source"}
unknown = sorted(set(data.keys()) - allowed)
if unknown:
    print("error=unknown contextplus option(s) " + ", ".join(repr(k) for k in unknown) + "; recognized keys: server_name, config_source")
    sys.exit(0)

server_name = data.get("server_name")
if server_name is not None and (not isinstance(server_name, str) or server_name.strip() == ""):
    print("error=contextplus option server_name must be a non-empty string")
    sys.exit(0)

config_source = data.get("config_source")
if config_source is not None and config_source not in ("auto", "project", "global"):
    print("error=contextplus option config_source must be one of auto, project, global (got " + repr(config_source) + ")")
    sys.exit(0)

print("ok")
')"
  if [ "$result" != "ok" ]; then
    specrelay::out::err "invalid contextplus configuration for $role role: ${result#error=}"
    return 1
  fi
  return 0
}

specrelay::context::contextplus::preflight() {
  local role="$1" root="$2" task_id="$3" provider="$4" rc
  specrelay::context::contextplus::_run "$role" "$root" "$task_id" "$provider"
  rc=$?
  if [ -n "${SPECRELAY_CONTEXTPLUS_TMP_DIR:-}" ]; then
    rm -rf "$SPECRELAY_CONTEXTPLUS_TMP_DIR" 2>/dev/null
    trap - INT TERM 2>/dev/null
  fi
  unset SPECRELAY_CONTEXTPLUS_TMP_DIR
  return "$rc"
}

# specrelay::context::contextplus::_run <role> <root> <task-id> <provider>
# Runtime preflight (spec 0018, "Runtime Preflight"): re-checks readiness
# immediately before the bounded retrieval (protects against a server going
# disconnected, a config being removed, or the binary disappearing between
# `contexts`/`doctor` inspection and this actual run), then performs the SAME
# bounded, scoped, real `semantic_code_search` retrieval call as before — no
# weakening of those protections (one call, one allowed tool, budget cap,
# machine-readable stream output, hard failure on missing tool evidence or a
# non-zero provider exit).
specrelay::context::contextplus::_run() {
  local role="$1" root="$2" task_id="$3" provider="$4"
  local claude_bin server config_source_pref max_budget purpose

  purpose="task-relevant repository context for task ${task_id:-<no task id>} ($role role)"

  echo "[$role] context-plus: checking (provider: $provider)"

  # Provider compatibility (spec 0018, "Provider Compatibility"): manual and
  # fake run no automated agent, so Context+ is not applicable to them. Any
  # OTHER provider must be a supported Claude-family automated provider — an
  # unsupported provider must fail clearly BEFORE the role's running-state
  # transition, never silently routed through Claude.
  case "$provider" in
    manual|fake)
      echo "[$role] context-plus: not applicable (provider '$provider' runs no automated agent)"
      return 0
      ;;
    claude|claude-subagent)
      : ;;
    *)
      specrelay::out::err "[$role] context-plus: provider '$provider' is not supported by the contextplus adapter (supported: claude, claude-subagent)"
      return 1
      ;;
  esac

  claude_bin="$(specrelay::context::contextplus::_claude_bin)"
  server="$(specrelay::context::contextplus::_server_name_for_role "$root" "$role")"
  config_source_pref="$(specrelay::context::contextplus::_config_source_for_role "$root" "$role")"
  max_budget="${SPECRELAY_CONTEXTPLUS_MAX_BUDGET_USD:-0.50}"

  if [ "$config_source_pref" = "global" ]; then
    specrelay::out::err "[$role] context-plus: config_source 'global' is not supported for strict retrieval (no safe global-config export exists); configure a project-local .mcp.json entry for '$server' or use config_source: auto/project"
    return 1
  fi

  local readiness_out status reason
  readiness_out="$(specrelay::context::contextplus::readiness "$root" "$server")"
  status="$(printf '%s\n' "$readiness_out" | sed -n 's/^status=//p')"
  reason="$(printf '%s\n' "$readiness_out" | sed -n 's/^reason=//p')"

  if [ "$status" != "ready" ]; then
    if [ "$config_source_pref" = "project" ]; then
      specrelay::out::err "[$role] context-plus: config_source 'project' requires a valid project .mcp.json entry for '$server'; ${reason:-not ready}"
    else
      specrelay::out::err "[$role] context-plus: not ready (status=$status): ${reason:-reason unknown}"
    fi
    return 1
  fi

  echo "[$role] context-plus: ready (server: $server, config source: project .mcp.json)"
  echo "[$role] context-plus: retrieving $purpose"

  local tmp_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-contextplus.XXXXXX")"
  chmod 700 "$tmp_dir" 2>/dev/null || true
  SPECRELAY_CONTEXTPLUS_TMP_DIR="$tmp_dir"
  # Best-effort cleanup on interrupt (spec 0018, "Temporary MCP Config" — never
  # leave the narrowed config behind on failure OR interrupt); the normal exit
  # path is still cleaned up by preflight() above regardless of this trap.
  trap 'rm -rf "$tmp_dir" 2>/dev/null' INT TERM

  # Build a STRICT MCP config containing ONLY the selected server (never the
  # whole project .mcp.json — that would leak every other configured server's
  # command/args/env to the retrieval invocation). Readiness already proved
  # this server has a structurally usable project entry, so extraction here
  # must succeed; a failure is treated as a hard refusal rather than falling
  # back to copying the whole file.
  local mcp_config="$tmp_dir/mcp-config.json"
  if ! MCP_JSON="$root/.mcp.json" SERVER="$server" OUT="$mcp_config" python3 - <<'PY'
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
    specrelay::out::err "[$role] context-plus: failed to construct a narrowed strict MCP config for '$server'"
    return 1
  fi
  chmod 600 "$mcp_config" 2>/dev/null || true

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
    specrelay::out::err "[$role] context-plus: the bounded retrieval call exited non-zero ($retrieval_rc)"
    return 1
  fi
  if ! grep -Fq "mcp__${server}__semantic_code_search" "$retrieval_out"; then
    specrelay::out::err "[$role] context-plus: no evidence of a $server tool call in the retrieval response"
    return 1
  fi

  echo "[$role] context-plus: query completed"
  echo "[$role] context-plus: preflight verified"
  return 0
}
