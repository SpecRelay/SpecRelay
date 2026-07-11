#!/usr/bin/env bash
# ai_reviewer_agent_test.sh — doc/code consistency audit for the Claude reviewer
# sub-agent (spec 0008, section 11). Deterministic; needs no real Claude.
#
# Proves:
#   1. the standalone reviewer sub-agent TEMPLATE exists and is usable;
#   2. `specrelay doctor` clearly reports a MISSING ai-reviewer agent when the
#      reviewer provider is `claude-subagent` (a warning, not a silent pretend);
#   3. `specrelay doctor` reports the agent as configured when the file is
#      present in the consumer project;
#   4. `specrelay init` installs the agent template for a Claude reviewer, never
#      for the default `manual` reviewer, and never overwrites an existing file;
#   5. no ACTIVE standalone doc claims `.ai/` or `tools/specrelay` is a runtime
#      requirement (i.e. none invoke the incubation path `tools/specrelay/bin`);
#   6. provider docs are truthful that the agent file is NOT shipped, and
#      `provider: claude-subagent` stays backward compatible.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

SPECRELAY_BIN="$SPECRELAY_ROOT/bin/specrelay"
TEMPLATE="$SPECRELAY_ROOT/templates/claude/agents/ai-reviewer.md"

# --- helper: flip a freshly-initialized config's reviewer provider ----------
set_reviewer_subagent() {
  local cfg="$1/.specrelay/config.yml"
  # The template ships exactly one `provider: manual` line (the reviewer).
  sed -i.bak 's/provider: manual/provider: claude-subagent/' "$cfg" && rm -f "$cfg.bak"
}

# =============================================================================
# 1 — the standalone reviewer sub-agent template exists and is usable
# =============================================================================
specrelay_test::assert_true "1: templates/claude/agents/ai-reviewer.md exists and is non-empty" \
  "$([ -s "$TEMPLATE" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "1: template defines the ai-reviewer agent" \
  "$(cat "$TEMPLATE")" "name: ai-reviewer"
specrelay_test::assert_contains "1: template documents the ACCEPT decision marker" \
  "$(cat "$TEMPLATE")" "DECISION: ACCEPT"
specrelay_test::assert_contains "1: template documents the REQUEST_CHANGES decision marker" \
  "$(cat "$TEMPLATE")" "DECISION: REQUEST_CHANGES"

# =============================================================================
# 4 — init wiring: default (manual) reviewer must NOT create the agent file
# =============================================================================
proj="$(specrelay_test::mktemp_project)"
(cd "$proj" && "$SPECRELAY_BIN" init >/dev/null 2>&1)
specrelay_test::assert_true "4: init with default manual reviewer does NOT create the agent file" \
  "$([ ! -e "$proj/.claude/agents/ai-reviewer.md" ] && echo 0 || echo 1)"

# =============================================================================
# 2 — doctor warns clearly when claude-subagent is configured but agent missing
# =============================================================================
set_reviewer_subagent "$proj"
out_missing="$(cd "$proj" && SPECRELAY_PROVIDER_OPTIONAL=1 "$SPECRELAY_BIN" doctor 2>&1)"
specrelay_test::assert_contains "2: doctor names the reviewer sub-agent check" \
  "$out_missing" "Reviewer sub-agent"
specrelay_test::assert_contains "2: doctor clearly reports the missing ai-reviewer file" \
  "$out_missing" "no .claude/agents/ai-reviewer.md"
specrelay_test::assert_contains "2: doctor points to the template to enable it" \
  "$out_missing" "templates/claude/agents/ai-reviewer.md"

# =============================================================================
# 4b — re-running init on a claude-subagent project TOPS UP the agent file
# =============================================================================
init_top="$(cd "$proj" && "$SPECRELAY_BIN" init 2>&1)"
specrelay_test::assert_contains "4b: re-init reports creating the ai-reviewer agent" \
  "$init_top" "created: .claude/agents/ai-reviewer.md"
specrelay_test::assert_true "4b: re-init actually created the agent file" \
  "$([ -f "$proj/.claude/agents/ai-reviewer.md" ] && echo 0 || echo 1)"

# The installed agent file matches the shipped template (a real copy).
specrelay_test::assert_eq "4c: installed agent file matches the template byte-for-byte" \
  "$(cat "$TEMPLATE")" "$(cat "$proj/.claude/agents/ai-reviewer.md")"

# =============================================================================
# 3 — doctor reports the agent as configured once the file is present
# =============================================================================
out_present="$(cd "$proj" && SPECRELAY_PROVIDER_OPTIONAL=1 "$SPECRELAY_BIN" doctor 2>&1)"
specrelay_test::assert_contains "3: doctor reports the ai-reviewer sub-agent as configured" \
  "$out_present" "ai-reviewer configured"
specrelay_test::assert_not_contains "3: doctor no longer warns about a missing agent file" \
  "$out_present" "no .claude/agents/ai-reviewer.md"

# =============================================================================
# 4d — init never overwrites an existing agent file
# =============================================================================
printf 'CUSTOM USER AGENT\n' > "$proj/.claude/agents/ai-reviewer.md"
init_keep="$(cd "$proj" && "$SPECRELAY_BIN" init 2>&1)"
specrelay_test::assert_contains "4d: re-init keeps (does not overwrite) an existing agent file" \
  "$init_keep" "kept: .claude/agents/ai-reviewer.md"
specrelay_test::assert_eq "4d: the user's custom agent file is preserved verbatim" \
  "CUSTOM USER AGENT" "$(cat "$proj/.claude/agents/ai-reviewer.md")"

# =============================================================================
# 5 — no ACTIVE standalone doc claims the incubation path as a runtime command
# =============================================================================
for doc in installation.md providers.md configuration.md commands.md; do
  specrelay_test::assert_not_contains "5: docs/$doc does not invoke the incubation path tools/specrelay/bin/specrelay" \
    "$(cat "$SPECRELAY_ROOT/docs/$doc")" "tools/specrelay/bin/specrelay"
done
specrelay_test::assert_not_contains "5: README.md does not invoke the incubation path tools/specrelay/bin/specrelay" \
  "$(cat "$SPECRELAY_ROOT/README.md")" "tools/specrelay/bin/specrelay"

# =============================================================================
# 6 — provider docs are truthful (not shipped; legacy shorthand; backward-compat)
# =============================================================================
providers_doc="$(cat "$SPECRELAY_ROOT/docs/providers.md")"
specrelay_test::assert_contains "6: providers.md states the agent file is not shipped standalone" \
  "$providers_doc" "does not ship"
specrelay_test::assert_contains "6: providers.md points at the reviewer agent template path" \
  "$providers_doc" "templates/claude/agents/ai-reviewer.md"
specrelay_test::assert_contains "6: providers.md describes claude-subagent as legacy shorthand" \
  "$providers_doc" "legacy shorthand"
# Backward compatibility: claude-subagent is still an accepted reviewer value.
specrelay_test::assert_contains "6: claude-subagent remains an accepted reviewer provider" \
  "$providers_doc" "\`claude-subagent\`"

specrelay_test::summary
exit $?
