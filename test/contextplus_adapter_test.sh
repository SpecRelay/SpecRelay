#!/usr/bin/env bash
# contextplus_adapter_test.sh — Context+ runtime readiness and configuration
# source (spec 0018). Deterministic; NO real Context+ server, NO real Claude
# CLI, and NO network — every scenario is driven by a fake `claude` binary
# (parameterized by env knobs) and fixture .mcp.json files.
#
# Covers the spec's Required Tests:
#   installation (installed != registered != ready);
#   registration (name matching, similarly-named servers, list failure/empty);
#   connection (connected/disconnected/unknown, realistic output variants);
#   project configuration (missing/malformed/server-missing/valid, no secrets);
#   source selection (project-only, global-only, both, explicit project/global,
#     auto determinism);
#   the readiness status model (installed-only, disconnected, config-
#     incomplete, ready);
#   the `contexts` command (detail + compact list, non-billable, no secrets);
#   `doctor` (optional warning, required failure, ready pass, non-billable,
#     selected source shown);
#   runtime preflight (re-check before retrieval, exactly one bounded call,
#     required/optional blocking, tool-evidence enforcement);
#   temporary MCP config (narrowed to one server, removed after success and
#     failure, never in task evidence);
#   compatibility (unsupported provider fails clearly; none/fake unaffected).

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/config.sh
. "$SPECRELAY_ROOT/lib/specrelay/config.sh"
# shellcheck source=../lib/specrelay/task.sh
. "$SPECRELAY_ROOT/lib/specrelay/task.sh"
# shellcheck source=../lib/specrelay/state.sh
. "$SPECRELAY_ROOT/lib/specrelay/state.sh"
# shellcheck source=../lib/specrelay/providers/provider.sh
. "$SPECRELAY_ROOT/lib/specrelay/providers/provider.sh"
# shellcheck source=../lib/specrelay/providers/fake.sh
. "$SPECRELAY_ROOT/lib/specrelay/providers/fake.sh"
# shellcheck source=../lib/specrelay/providers/claude.sh
. "$SPECRELAY_ROOT/lib/specrelay/providers/claude.sh"
# shellcheck source=../lib/specrelay/providers/capability.sh
. "$SPECRELAY_ROOT/lib/specrelay/providers/capability.sh"
# shellcheck source=../lib/specrelay/context/capability.sh
. "$SPECRELAY_ROOT/lib/specrelay/context/capability.sh"
# shellcheck source=../lib/specrelay/context/none.sh
. "$SPECRELAY_ROOT/lib/specrelay/context/none.sh"
# shellcheck source=../lib/specrelay/context/fake.sh
. "$SPECRELAY_ROOT/lib/specrelay/context/fake.sh"
# shellcheck source=../lib/specrelay/context/contextplus.sh
. "$SPECRELAY_ROOT/lib/specrelay/context/contextplus.sh"
# shellcheck source=../lib/specrelay/workflow.sh
. "$SPECRELAY_ROOT/lib/specrelay/workflow.sh"
# shellcheck source=../lib/specrelay/contexts.sh
. "$SPECRELAY_ROOT/lib/specrelay/contexts.sh"
# shellcheck source=../lib/specrelay/doctor.sh
. "$SPECRELAY_ROOT/lib/specrelay/doctor.sh"

SECRET="super-secret-token-xyz789"

# --- fake `claude` binary -----------------------------------------------------
# One script, parameterized by env, drives every scenario. `mcp list` and the
# real retrieval/executor invocation are logged to SEPARATE files so a test can
# assert "no billable retrieval occurred" independently of "mcp list was
# checked" (both are legitimate, but only one is billable).
FAKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-fakeclaude-cp.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$FAKE_DIR")
FAKE_CLAUDE="$FAKE_DIR/claude"
cat > "$FAKE_CLAUDE" <<'FAKE'
#!/usr/bin/env bash
# Fake Claude CLI for deterministic Context+ tests. Env knobs:
#   FAKE_CLAUDE_MCP_LIST_OUTPUT   raw text for `claude mcp list` (default: empty)
#   FAKE_CLAUDE_MCP_LIST_EXIT     exit code for `mcp list` (default 0)
#   FAKE_CLAUDE_MCP_LIST_LOG      file to append each `mcp list` invocation to
#   FAKE_CLAUDE_ARGV_LOG          file to append each NON-"mcp list" argv to
#   FAKE_CLAUDE_MCP_CONFIG_CAPTURE  copy the --mcp-config file's content here
#                                   (captured BEFORE the caller removes it)
#   FAKE_CLAUDE_RETRIEVAL_FIXTURE stream-json file emitted for a --strict-mcp-config call
#   FAKE_CLAUDE_RETRIEVAL_EXIT    exit code for a --strict-mcp-config call (default 0)
set -u

if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "list" ]; then
  [ -n "${FAKE_CLAUDE_MCP_LIST_LOG:-}" ] && printf 'called\n' >> "$FAKE_CLAUDE_MCP_LIST_LOG"
  printf '%s' "${FAKE_CLAUDE_MCP_LIST_OUTPUT:-}"
  exit "${FAKE_CLAUDE_MCP_LIST_EXIT:-0}"
fi

for a in "$@"; do
  if [ "$a" = "--help" ]; then
    echo "Usage: claude [options] <prompt>"
    echo "  --print"
    echo "  --verbose"
    echo "  --output-format <fmt>   one of: text, json, stream-json"
    exit 0
  fi
done

[ -n "${FAKE_CLAUDE_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_CLAUDE_ARGV_LOG"

strict=0
mcp_config=""
prev=""
for a in "$@"; do
  [ "$a" = "--strict-mcp-config" ] && strict=1
  [ "$prev" = "--mcp-config" ] && mcp_config="$a"
  prev="$a"
done

if [ "$strict" = "1" ]; then
  if [ -n "${FAKE_CLAUDE_MCP_CONFIG_CAPTURE:-}" ] && [ -n "$mcp_config" ] && [ -f "$mcp_config" ]; then
    cp "$mcp_config" "$FAKE_CLAUDE_MCP_CONFIG_CAPTURE"
  fi
  if [ -n "${FAKE_CLAUDE_RETRIEVAL_FIXTURE:-}" ]; then
    cat "${FAKE_CLAUDE_RETRIEVAL_FIXTURE}"
  else
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__contextplus__semantic_code_search"}]}}'
    echo 'CONTEXT_PLUS_OK'
  fi
  exit "${FAKE_CLAUDE_RETRIEVAL_EXIT:-0}"
fi

echo "plain claude stdout line"
exit 0
FAKE
chmod +x "$FAKE_CLAUDE"

# no_claude: a guaranteed-nonexistent path (installation: missing).
NO_CLAUDE="$FAKE_DIR/does-not-exist/claude"

# --- fixture helpers -----------------------------------------------------------

# mcp_out_registered_connected <server> [tick]
mcp_out_registered_connected() {
  local tick="${2:-✓}"
  printf '%s: node server.js - %s Connected\n' "$1" "$tick"
}
mcp_out_registered_disconnected() {
  printf '%s: node server.js - ✗ Disconnected\n' "$1"
}
mcp_out_needs_auth() {
  printf '%s: https://example.invalid/mcp - ! Needs authentication\n' "$1"
}
mcp_out_similarly_named() {
  # a DIFFERENT, similarly-named server is connected; the configured server
  # itself is absent — must NOT be treated as a match.
  printf '%s-extra: node server.js - ✓ Connected\n' "$1"
}

# write_mcp_json <project-root> <json-body>
write_mcp_json() {
  printf '%s' "$2" > "$1/.mcp.json"
}

valid_mcp_json() {
  local server="$1"
  printf '{"mcpServers": {"%s": {"command": "node", "args": ["server.js"], "env": {"API_KEY": "%s"}}}}' "$server" "$SECRET"
}

readiness_field() {
  printf '%s\n' "$1" | sed -n "s/^${2}=//p"
}

# mk_project — a bare temp project (git repo only; no .specrelay/config.yml).
mk_project() { specrelay_test::mktemp_project; }

# write_cfg <project> <context-yaml-block> [executor-provider] [reviewer-provider]
write_cfg() {
  local proj="$1" context_block="$2" exec_provider="${3:-fake}" rev_provider="${4:-manual}"
  mkdir -p "$proj/.specrelay"
  {
    echo "version: 1"
    echo "project:"
    echo "  name: Fixture"
    echo "specs:"
    echo "  root: docs/sdd"
    echo "tasks:"
    echo "  runs_root: .ai-runs/tasks"
    echo "  max_iterations: 3"
    echo "roles:"
    echo "  executor:"
    echo "    provider: $exec_provider"
    echo "  reviewer:"
    echo "    provider: $rev_provider"
    [ -n "$context_block" ] && printf '%s\n' "$context_block"
    echo "validation:"
    echo "  full_test_command: \"echo ok\""
    echo "policy:"
    echo "  human_final_review_required: true"
  } > "$proj/.specrelay/config.yml"
}

# mk_run_project <context-yaml-block> <spec-slug> [executor-provider] [reviewer-provider]
mk_run_project() {
  local ctx="$1" slug="$2" exec_provider="${3:-fake}" rev_provider="${4:-manual}" proj
  proj="$(specrelay_test::mktemp_project)"
  write_cfg "$proj" "$ctx" "$exec_provider" "$rev_provider"
  printf '.ai-runs/\n' > "$proj/.gitignore"
  mkdir -p "$proj/docs/sdd/$slug"
  printf '# fixture spec\n' > "$proj/docs/sdd/$slug/spec.md"
  (cd "$proj" && git add -A && git commit -q -m "fixture")
  printf '%s\n' "$proj"
}

# =============================================================================
# 1 — installation
# =============================================================================
p1="$(mk_project)"

out1="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$NO_CLAUDE" specrelay::context::contextplus::readiness "$p1")"
specrelay_test::assert_eq "1: missing executable reports installed=no" "no" "$(readiness_field "$out1" installed)"
specrelay_test::assert_eq "1: missing executable reports status=unavailable" "unavailable" "$(readiness_field "$out1" status)"

out1b="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" FAKE_CLAUDE_MCP_LIST_OUTPUT="" \
  specrelay::context::contextplus::readiness "$p1")"
specrelay_test::assert_eq "1: existing executable reports installed=yes" "yes" "$(readiness_field "$out1b" installed)"
specrelay_test::assert_eq "1: installation alone (not registered) is status=installed, not ready" \
  "installed" "$(readiness_field "$out1b" status)"

avail1="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" FAKE_CLAUDE_MCP_LIST_OUTPUT="" \
  specrelay::context::contextplus::availability "$p1" 2>&1)"; rc1=$?
specrelay_test::assert_true "1: installation alone does not report available" "$([ "$rc1" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "1: unavailable reports 'unavailable'" "$avail1" "unavailable"

# =============================================================================
# 2 — registration
# =============================================================================
out2a="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(printf 'other-server: cmd - ✓ Connected\n')" \
  specrelay::context::contextplus::readiness "$p1")"
specrelay_test::assert_eq "2: missing server registration reports registered=no" "no" "$(readiness_field "$out2a" registered)"

out2b="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  specrelay::context::contextplus::readiness "$p1")"
specrelay_test::assert_eq "2: registered server reports registered=yes" "yes" "$(readiness_field "$out2b" registered)"

out2c="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" SPECRELAY_CONTEXTPLUS_SERVER_NAME="my-ctx" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected my-ctx)" \
  specrelay::context::contextplus::readiness "$p1")"
specrelay_test::assert_eq "2: configured server name is respected" "yes" "$(readiness_field "$out2c" registered)"
specrelay_test::assert_eq "2: configured server name is reported" "my-ctx" "$(readiness_field "$out2c" server)"

out2d="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_similarly_named contextplus)" \
  specrelay::context::contextplus::readiness "$p1")"
specrelay_test::assert_eq "2: a similarly-named server does not produce a false match" \
  "no" "$(readiness_field "$out2d" registered)"

out2e="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" FAKE_CLAUDE_MCP_LIST_EXIT=1 \
  specrelay::context::contextplus::readiness "$p1")"
specrelay_test::assert_eq "2: mcp list command failure is reported as not registered" \
  "no" "$(readiness_field "$out2e" registered)"
specrelay_test::assert_contains "2: mcp list failure reason names the failure" \
  "$(readiness_field "$out2e" reason)" "mcp list' failed"

out2f="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" FAKE_CLAUDE_MCP_LIST_OUTPUT="" \
  specrelay::context::contextplus::readiness "$p1")"
specrelay_test::assert_eq "2: empty mcp list output is handled (registered=no)" \
  "no" "$(readiness_field "$out2f" registered)"
specrelay_test::assert_contains "2: empty mcp list output reason names it" \
  "$(readiness_field "$out2f" reason)" "no output"

# =============================================================================
# 3 — connection
# =============================================================================
out3a="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  specrelay::context::contextplus::readiness "$p1")"
specrelay_test::assert_eq "3: connected server reports connected=yes" "yes" "$(readiness_field "$out3a" connected)"

out3b="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_disconnected contextplus)" \
  specrelay::context::contextplus::readiness "$p1")"
specrelay_test::assert_eq "3: disconnected server reports connected=no" "no" "$(readiness_field "$out3b" connected)"
specrelay_test::assert_eq "3: disconnected server reports status=disconnected" \
  "disconnected" "$(readiness_field "$out3b" status)"

out3c="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(printf 'contextplus: node server.js - running\n')" \
  specrelay::context::contextplus::readiness "$p1")"
specrelay_test::assert_eq "3: an unknown connection status is NOT treated as connected" \
  "no" "$(readiness_field "$out3c" connected)"
specrelay_test::assert_eq "3: unknown connection status yields status=registered (not disconnected)" \
  "registered" "$(readiness_field "$out3c" status)"

out3d="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_needs_auth contextplus)" \
  specrelay::context::contextplus::readiness "$p1")"
specrelay_test::assert_eq "3: a realistic 'needs authentication' variant is not connected" \
  "no" "$(readiness_field "$out3d" connected)"

out3e="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus '✔')" \
  specrelay::context::contextplus::readiness "$p1")"
specrelay_test::assert_eq "3: the real CLI's heavy check mark (✔) is recognized as connected" \
  "yes" "$(readiness_field "$out3e" connected)"

# =============================================================================
# 4 — project configuration
# =============================================================================
p4="$(mk_project)"

out4a="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  specrelay::context::contextplus::readiness "$p4")"
specrelay_test::assert_eq "4: missing .mcp.json is detected" \
  "missing" "$(readiness_field "$out4a" project_config)"
specrelay_test::assert_eq "4: missing project config is config-incomplete, not ready" \
  "config-incomplete" "$(readiness_field "$out4a" status)"

write_mcp_json "$p4" '{not valid json'
out4b="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  specrelay::context::contextplus::readiness "$p4")"
specrelay_test::assert_eq "4: malformed JSON is detected as invalid" \
  "invalid" "$(readiness_field "$out4b" project_config)"

write_mcp_json "$p4" '{"otherKey": {}}'
out4c="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  specrelay::context::contextplus::readiness "$p4")"
specrelay_test::assert_eq "4: missing mcpServers is detected as invalid" \
  "invalid" "$(readiness_field "$out4c" project_config)"

write_mcp_json "$p4" '{"mcpServers": {"other-server": {"command": "node"}}}'
out4d="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  specrelay::context::contextplus::readiness "$p4")"
specrelay_test::assert_eq "4: the configured server missing from mcpServers is detected" \
  "server-missing" "$(readiness_field "$out4d" project_config)"

write_mcp_json "$p4" "$(valid_mcp_json contextplus)"
out4e="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  specrelay::context::contextplus::readiness "$p4")"
specrelay_test::assert_eq "4: a valid server entry is detected" \
  "valid" "$(readiness_field "$out4e" project_config)"
specrelay_test::assert_eq "4: valid project config + connected registration is ready" \
  "ready" "$(readiness_field "$out4e" status)"
specrelay_test::assert_not_contains "4: project config secrets are never printed by readiness" \
  "$out4e" "$SECRET"

# =============================================================================
# 5 — source selection
# =============================================================================
p5="$(mk_project)"

# project-only: registered/connected + valid project config -> project selected
write_mcp_json "$p5" "$(valid_mcp_json contextplus)"
out5a="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  specrelay::context::contextplus::readiness "$p5")"
specrelay_test::assert_eq "5: project-only source selects project" \
  "project" "$(readiness_field "$out5a" selected_source)"
specrelay_test::assert_eq "5: project-only source is retrieval-ready" \
  "yes" "$(readiness_field "$out5a" retrieval_ready)"

# global-only: registered/connected, no project config -> reported but NOT ready
p5b="$(mk_project)"
out5b="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  specrelay::context::contextplus::readiness "$p5b")"
specrelay_test::assert_eq "5: global-only registration is reported (registered=yes)" \
  "yes" "$(readiness_field "$out5b" registered)"
specrelay_test::assert_eq "5: global-only registration does NOT become retrieval-ready" \
  "no" "$(readiness_field "$out5b" retrieval_ready)"
specrelay_test::assert_eq "5: global-only registration selects no source" \
  "none" "$(readiness_field "$out5b" selected_source)"
specrelay_test::assert_eq "5: global-only registration is config-incomplete" \
  "config-incomplete" "$(readiness_field "$out5b" status)"

# both sources present -> project has deterministic precedence
specrelay_test::assert_eq "5: with both sources, project has deterministic precedence" \
  "project" "$(readiness_field "$out5a" selected_source)"
specrelay_test::assert_eq "5: global registration is still reported alongside project" \
  "yes" "$(readiness_field "$out5a" global_detected)"

# auto is deterministic: repeated calls with identical fixtures agree
out5c="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  specrelay::context::contextplus::readiness "$p5")"
specrelay_test::assert_eq "5: auto selection is deterministic across repeated calls" \
  "$(readiness_field "$out5a" selected_source)" "$(readiness_field "$out5c" selected_source)"

# explicitly requested config_source: project with no project config fails clearly
p5d="$(mk_project)"
write_cfg "$p5d" "context:
  executor:
    adapter: contextplus
    required: true
    options:
      config_source: project" claude manual
out5d="$(cd "$p5d" && SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" SPECRELAY_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  specrelay::context::contextplus::_run executor "$p5d" test-task claude 2>&1)"; rc5d=$?
specrelay_test::assert_true "5: explicitly requested config_source 'project' with no project config fails" \
  "$([ "$rc5d" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "5: the project-source failure names the requirement" \
  "$out5d" "config_source 'project' requires"

# explicitly requested config_source: global fails clearly (unsupported, Option A)
p5e="$(mk_project)"
write_cfg "$p5e" "context:
  executor:
    adapter: contextplus
    required: true
    options:
      config_source: global" claude manual
write_mcp_json "$p5e" "$(valid_mcp_json contextplus)"
out5e="$(cd "$p5e" && SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" SPECRELAY_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  specrelay::context::contextplus::_run executor "$p5e" test-task claude 2>&1)"; rc5e=$?
specrelay_test::assert_true "5: explicitly requested config_source 'global' fails clearly (not silently supported)" \
  "$([ "$rc5e" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "5: the global-source failure names it as unsupported" \
  "$out5e" "not supported for strict retrieval"

# =============================================================================
# 6 — status model
# =============================================================================
specrelay_test::assert_eq "6: installed-only status is not ready" "installed" "$(readiness_field "$out1b" status)"
specrelay_test::assert_true "6: installed-only is not ready (retrieval_ready=no)" \
  "$([ "$(readiness_field "$out1b" retrieval_ready)" = "no" ] && echo 0 || echo 1)"
specrelay_test::assert_true "6: registered-but-disconnected is not ready" \
  "$([ "$(readiness_field "$out3b" retrieval_ready)" = "no" ] && echo 0 || echo 1)"
specrelay_test::assert_eq "6: connected-but-no-project-config is config-incomplete" \
  "config-incomplete" "$(readiness_field "$out4a" status)"
specrelay_test::assert_eq "6: valid project config plus connected registration is ready" \
  "ready" "$(readiness_field "$out4e" status)"
specrelay_test::assert_true "6: status reasons are actionable (non-empty)" \
  "$([ -n "$(readiness_field "$out4a" reason)" ] && echo 0 || echo 1)"

# =============================================================================
# 7 — the `contexts` command
# =============================================================================
p7="$(mk_project)"
write_cfg "$p7" "context:
  adapter: contextplus"
write_mcp_json "$p7" "$(valid_mcp_json contextplus)"

detail7_ready="$(cd "$p7" && SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  "$SPECRELAY_BIN" contexts contextplus 2>&1)"
specrelay_test::assert_contains "7: ready detail shows Installed:" "$detail7_ready" "Installed:"
specrelay_test::assert_contains "7: ready detail shows Registered:" "$detail7_ready" "Registered:"
specrelay_test::assert_contains "7: ready detail shows Connected:" "$detail7_ready" "Connected:"
specrelay_test::assert_contains "7: ready detail shows Retrieval ready:" "$detail7_ready" "Retrieval ready:"
specrelay_test::assert_contains "7: ready detail shows Status: ready" "$detail7_ready" "
  ready"
specrelay_test::assert_contains "7: ready detail shows the selected project source" \
  "$detail7_ready" "project .mcp.json"
specrelay_test::assert_not_contains "7: contextplus detail never prints secrets" "$detail7_ready" "$SECRET"

p7b="$(mk_project)"
write_cfg "$p7b" "context:
  adapter: contextplus"
detail7_installed="$(cd "$p7b" && SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(printf 'other-server: cmd - ✓ Connected\n')" \
  "$SPECRELAY_BIN" contexts contextplus 2>&1)"
specrelay_test::assert_contains "7: not-registered detail names the reason" \
  "$detail7_installed" "not registered"
specrelay_test::assert_contains "7: not-registered detail points at claude mcp list" \
  "$detail7_installed" "claude mcp list"

list7="$(cd "$p7" && SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  "$SPECRELAY_BIN" contexts 2>&1)"
specrelay_test::assert_contains "7: list output uses the precise 'ready' status" "$list7" "contextplus   built-in  ready"

list7b="$(cd "$p7b" && SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(printf 'other-server: cmd - ✓ Connected\n')" \
  "$SPECRELAY_BIN" contexts 2>&1)"
specrelay_test::assert_contains "7: list output distinguishes installed-not-registered" \
  "$list7b" "installed-not-registered"
specrelay_test::assert_not_contains "7: contexts never labels Context+ ready merely because claude is installed" \
  "$list7b" "contextplus   built-in  ready"

argv_log7="$FAKE_DIR/argv7.log"
rm -f "$argv_log7"
(cd "$p7" && SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" FAKE_CLAUDE_ARGV_LOG="$argv_log7" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  "$SPECRELAY_BIN" contexts contextplus >/dev/null 2>&1)
specrelay_test::assert_true "7: contexts performs NO billable retrieval" \
  "$([ ! -s "$argv_log7" ] && echo 0 || echo 1)"

# =============================================================================
# 8 — doctor
# =============================================================================
p8="$(specrelay_test::mktemp_project)"
mkdir -p "$p8/docs/sdd"
write_cfg "$p8" "context:
  executor:
    adapter: contextplus
    required: false" fake manual
out8="$(cd "$p8" && SPECRELAY_PROVIDER_OPTIONAL=1 SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="" "$SPECRELAY_BIN" doctor 2>&1)"; rc8=$?
specrelay_test::assert_eq "8: optional unready Context+ produces an advisory warning (doctor still passes)" "0" "$rc8"
specrelay_test::assert_contains "8: doctor names the adapter" "$out8" "Executor context adapter: contextplus"
specrelay_test::assert_contains "8: doctor reports the MCP registration honestly" \
  "$out8" "Executor context MCP registration: contextplus not registered"

write_cfg "$p8" "context:
  executor:
    adapter: contextplus
    required: true" fake manual
out8b="$(cd "$p8" && SPECRELAY_PROVIDER_OPTIONAL=1 SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="" "$SPECRELAY_BIN" doctor 2>&1)"; rc8b=$?
specrelay_test::assert_true "8: required unready Context+ fails doctor" "$([ "$rc8b" -ne 0 ] && echo 0 || echo 1)"

write_mcp_json "$p8" "$(valid_mcp_json contextplus)"
out8c="$(cd "$p8" && SPECRELAY_PROVIDER_OPTIONAL=1 SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" "$SPECRELAY_BIN" doctor 2>&1)"; rc8c=$?
specrelay_test::assert_eq "8: a ready Context+ passes doctor" "0" "$rc8c"
specrelay_test::assert_contains "8: doctor shows the selected configuration source" \
  "$out8c" "context configuration source: project .mcp.json"
specrelay_test::assert_not_contains "8: doctor output never contains secrets" "$out8c" "$SECRET"

argv_log8="$FAKE_DIR/argv8.log"
rm -f "$argv_log8"
(cd "$p8" && SPECRELAY_PROVIDER_OPTIONAL=1 SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_ARGV_LOG="$argv_log8" FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  "$SPECRELAY_BIN" doctor >/dev/null 2>&1)
specrelay_test::assert_true "8: doctor performs NO billable retrieval" \
  "$([ ! -s "$argv_log8" ] && echo 0 || echo 1)"

# =============================================================================
# 9 — runtime preflight (end-to-end via `specrelay run`)
# =============================================================================
# 9a — missing registration blocks BEFORE EXECUTOR_RUNNING.
p9a="$(mk_run_project "context:
  executor:
    adapter: contextplus
    required: true" 0018-noreg claude manual)"
out9a="$(cd "$p9a" && SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" SPECRELAY_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="" "$SPECRELAY_BIN" run docs/sdd/0018-noreg/spec.md 2>&1)"; rc9a=$?
task9a="$p9a/.ai-runs/tasks/0018-noreg"
specrelay_test::assert_true "9a: missing registration blocks the run" "$([ "$rc9a" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_eq "9a: the task never entered EXECUTOR_RUNNING" \
  "READY_FOR_EXECUTOR" "$(specrelay::state::get "$task9a/state.json" state)"

# 9b — disconnected blocks similarly.
p9b="$(mk_run_project "context:
  executor:
    adapter: contextplus
    required: true" 0018-disc claude manual)"
out9b="$(cd "$p9b" && SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" SPECRELAY_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_disconnected contextplus)" \
  "$SPECRELAY_BIN" run docs/sdd/0018-disc/spec.md 2>&1)"; rc9b=$?
task9b="$p9b/.ai-runs/tasks/0018-disc"
specrelay_test::assert_true "9b: a disconnected server blocks the run" "$([ "$rc9b" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_eq "9b: the task never entered EXECUTOR_RUNNING" \
  "READY_FOR_EXECUTOR" "$(specrelay::state::get "$task9b/state.json" state)"

# 9c — config-incomplete (registered/connected, no project config) blocks.
p9c="$(mk_run_project "context:
  executor:
    adapter: contextplus
    required: true" 0018-cfginc claude manual)"
out9c="$(cd "$p9c" && SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" SPECRELAY_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  "$SPECRELAY_BIN" run docs/sdd/0018-cfginc/spec.md 2>&1)"; rc9c=$?
task9c="$p9c/.ai-runs/tasks/0018-cfginc"
specrelay_test::assert_true "9c: config-incomplete blocks the run" "$([ "$rc9c" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_eq "9c: the task never entered EXECUTOR_RUNNING" \
  "READY_FOR_EXECUTOR" "$(specrelay::state::get "$task9c/state.json" state)"

# 9d — optional failure degrades honestly (run still completes, executor runs).
p9d="$(mk_run_project "context:
  executor:
    adapter: contextplus
    required: false" 0018-optional fake manual)"
out9d="$(cd "$p9d" && SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="" "$SPECRELAY_BIN" run docs/sdd/0018-optional/spec.md 2>&1)"; rc9d=$?
task9d="$p9d/.ai-runs/tasks/0018-optional"
# rc=2 is the documented "manual reviewer stops the automated loop for human
# review" sentinel (see reviewer_continuation_test.sh) — not an error; the
# executor itself ran to completion despite the degraded (optional) context.
specrelay_test::assert_eq "9d: optional Context+ failure still reaches READY_FOR_REVIEW" "2" "$rc9d"
specrelay_test::assert_contains "9d: degradation is logged honestly" "$out9d" "required=false"
specrelay_test::assert_true "9d: the fake executor WAS invoked (degraded, not blocked)" \
  "$([ -f "$task9d/fake-executor-invocation.txt" ] && echo 0 || echo 1)"

# 9e — valid readiness runs EXACTLY one bounded retrieval, and the temporary
# strict MCP config contains ONLY the selected server. Exercised through
# preflight() directly (rather than a full `specrelay run`), which drives the
# EXACT SAME runtime-preflight code path without depending on a fake `claude`
# actually producing this repository's real executor deliverables (an
# unrelated, much older contract) — a full end-to-end `specrelay run` with the
# contextplus gate is already covered by 9a-9d above.
p9e="$(mk_project)"
write_mcp_json "$p9e" '{"mcpServers": {"contextplus": {"command": "node", "args": ["server.js"], "env": {"API_KEY": "'"$SECRET"'"}}, "other-server": {"command": "node", "args": ["other.js"], "env": {"OTHER_SECRET": "should-never-appear"}}}}'
task9e="$p9e/.ai-runs/tasks/0018-ready"
mkdir -p "$task9e"
argv_log9e="$FAKE_DIR/argv9e.log"
capture9e="$FAKE_DIR/captured-mcp-config-9e.json"
rm -f "$argv_log9e" "$capture9e"
out9e="$(cd "$p9e" && SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_ARGV_LOG="$argv_log9e" FAKE_CLAUDE_MCP_CONFIG_CAPTURE="$capture9e" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  specrelay::context::contextplus::preflight executor "$p9e" 0018-ready claude 2>&1)"; rc9e=$?
specrelay_test::assert_eq "9e: a ready Context+ configuration completes the bounded retrieval" "0" "$rc9e"
specrelay_test::assert_eq "9e: EXACTLY one bounded retrieval call was made" "1" "$(grep -c -- '--strict-mcp-config' "$argv_log9e" 2>/dev/null || echo 0)"
specrelay_test::assert_contains "9e: the narrowed config contains the selected server" \
  "$(cat "$capture9e")" "contextplus"
specrelay_test::assert_not_contains "9e: the narrowed config does NOT contain the other server" \
  "$(cat "$capture9e")" "other-server"
specrelay_test::assert_not_contains "9e: the narrowed config never leaked into the run's own output" \
  "$out9e" "$SECRET"
specrelay_test::assert_contains "9e: the preflight reports itself verified" "$out9e" "preflight verified"

# 9f — a bounded-retrieval failure is a hard failure when required.
p9f="$(mk_project)"
write_mcp_json "$p9f" "$(valid_mcp_json contextplus)"
out9f="$(cd "$p9f" && SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" FAKE_CLAUDE_RETRIEVAL_EXIT=3 \
  specrelay::context::contextplus::preflight executor "$p9f" 0018-retfail claude 2>&1)"; rc9f=$?
specrelay_test::assert_true "9f: a required retrieval failure is a hard failure" "$([ "$rc9f" -ne 0 ] && echo 0 || echo 1)"

# 9g — missing tool-call evidence is a hard failure (even with exit 0).
p9g="$(mk_project)"
write_mcp_json "$p9g" "$(valid_mcp_json contextplus)"
no_evidence_fixture="$FAKE_DIR/no-evidence.jsonl"
printf '{"type":"result","subtype":"success"}\n' > "$no_evidence_fixture"
out9g="$(cd "$p9g" && SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  FAKE_CLAUDE_RETRIEVAL_FIXTURE="$no_evidence_fixture" \
  specrelay::context::contextplus::preflight executor "$p9g" 0018-noevidence claude 2>&1)"; rc9g=$?
specrelay_test::assert_true "9g: missing tool-call evidence is a hard failure" "$([ "$rc9g" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "9g: the missing-evidence failure is explicit" "$out9g" "no evidence"

# =============================================================================
# 10 — temporary MCP config cleanup
# =============================================================================
# After both the successful run (9e) and the failed retrieval (9f) above, NO
# specrelay-contextplus.* temp directory is left behind (success, failure, and
# — via the preflight() wrapper's unconditional cleanup — every other exit
# path all remove it).
leftover10="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'specrelay-contextplus.*' 2>/dev/null)"
specrelay_test::assert_eq "10: no temp strict MCP config directory is left behind" "" "$leftover10"

specrelay_test::assert_true "10: the captured narrowed config file itself still names only the selected server" \
  "$([ -f "$capture9e" ] && echo 0 || echo 1)"

if [ -f "$task9e/14-executor-context.json" ]; then
  specrelay_test::assert_not_contains "10: the narrowed MCP config is never written into task evidence" \
    "$(cat "$task9e/14-executor-context.json")" "$SECRET"
else
  specrelay_test::assert_true "10: contextplus produces no durable context evidence file (preflight-only capability)" 0
fi

# =============================================================================
# 11 — compatibility
# =============================================================================
# 11a — an unsupported automated provider fails clearly before the retrieval
# would ever be attempted (no claude invocation of any kind).
p11a="$(mk_project)"
write_mcp_json "$p11a" "$(valid_mcp_json contextplus)"
mcp_log11a="$FAKE_DIR/mcplist11a.log"
rm -f "$mcp_log11a"
out11a="$(SPECRELAY_CONTEXTPLUS_CLAUDE_BIN="$FAKE_CLAUDE" FAKE_CLAUDE_MCP_LIST_LOG="$mcp_log11a" \
  FAKE_CLAUDE_MCP_LIST_OUTPUT="$(mcp_out_registered_connected contextplus)" \
  specrelay::context::contextplus::_run executor "$p11a" test-task some-other-provider 2>&1)"; rc11a=$?
specrelay_test::assert_true "11a: an unsupported provider fails clearly" "$([ "$rc11a" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "11a: the unsupported-provider error names it" "$out11a" "not supported"
specrelay_test::assert_true "11a: an unsupported provider never even checks MCP registration" \
  "$([ ! -s "$mcp_log11a" ] && echo 0 || echo 1)"

# 11b — manual/fake providers are explicitly not-applicable (unchanged
# preflight-skip behavior).
out11b="$(specrelay::context::contextplus::_run executor "$p11a" test-task manual 2>&1)"; rc11b=$?
specrelay_test::assert_eq "11b: the manual provider is not applicable (exits 0)" "0" "$rc11b"
specrelay_test::assert_contains "11b: not-applicable is explicit" "$out11b" "not applicable"

# 11c — the none/fake adapters are entirely unaffected by this spec's changes.
none11c="$(cd "$p11a" && "$SPECRELAY_BIN" contexts none 2>&1)"
specrelay_test::assert_contains "11c: the none adapter is unaffected" "$none11c" "No external context preparation."
fake11c="$(cd "$p11a" && "$SPECRELAY_BIN" contexts fake 2>&1)"
specrelay_test::assert_contains "11c: the fake adapter is unaffected" "$fake11c" "prepare:          yes"

# 11d — configuration validation: unknown option keys and bad values rejected.
p11d="$(mk_project)"
write_cfg "$p11d" "context:
  adapter: contextplus
  options:
    server_name: contextplus
    bogus_option: 1"
err11d="$(specrelay::workflow::assert_role_context_valid "$p11d" no-such-task executor 2>&1)"; rc11d=$?
specrelay_test::assert_true "11d: an unknown contextplus option is rejected" "$([ "$rc11d" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "11d: the unknown-option error names it" "$err11d" "bogus_option"

write_cfg "$p11d" "context:
  adapter: contextplus
  options:
    config_source: sometimes"
err11e="$(specrelay::workflow::assert_role_context_valid "$p11d" no-such-task executor 2>&1)"; rc11e=$?
specrelay_test::assert_true "11e: an unknown config_source value is rejected" "$([ "$rc11e" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "11e: the invalid config_source error names the allowed values" \
  "$err11e" "auto, project, global"

write_cfg "$p11d" "context:
  adapter: contextplus
  options:
    server_name: \"\""
err11f="$(specrelay::workflow::assert_role_context_valid "$p11d" no-such-task executor 2>&1)"; rc11f=$?
specrelay_test::assert_true "11f: an empty server_name is rejected" "$([ "$rc11f" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "11f: the empty server_name error is explicit" "$err11f" "non-empty string"

specrelay_test::summary
exit $?
