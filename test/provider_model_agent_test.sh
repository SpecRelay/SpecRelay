#!/usr/bin/env bash
# provider_model_agent_test.sh — provider / model / agent selection (spec 0009).
#
# Deterministic; needs NO real Claude. Proves:
#   1. config defaults: missing model -> provider-default, missing agent -> none
#   2. legacy normalization: reviewer `claude-subagent` -> provider=claude,
#      agent=ai-reviewer (model provider-default)
#   3. env precedence: SPECRELAY_REVIEWER_MODEL / SPECRELAY_REVIEWER_AGENT
#      override the configured values
#   4. doctor reports the effective provider/model/agent, warns for a missing
#      ai-reviewer agent, and reports it configured when present
#   5. Claude invocation model passing: provider-default passes no model flag;
#      an explicit model passes the flag when the (fake) CLI advertises --model;
#      an explicit model FAILS CLEARLY when the CLI does not advertise it
#   6. runtime evidence: state.json records the effective (normalized)
#      provider/model/agent for both roles
#   7. backward compatibility: an existing `claude-subagent` reviewer config
#      still runs end-to-end (normalized to the claude reviewer + ai-reviewer)

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
# shellcheck source=../lib/specrelay/providers/claude.sh
. "$SPECRELAY_ROOT/lib/specrelay/providers/claude.sh"
# shellcheck source=../lib/specrelay/workflow.sh
. "$SPECRELAY_ROOT/lib/specrelay/workflow.sh"

# write_config <project> <reviewer-block-yaml> [executor-block-yaml]
# Writes a minimal, valid .specrelay/config.yml with the given role blocks.
write_config() {
  local proj="$1" reviewer="$2" executor="${3:-  executor:
    provider: claude}"
  mkdir -p "$proj/.specrelay"
  {
    echo "version: 1"
    echo "project:"
    echo "  name: Fixture"
    echo "specs:"
    echo "  root: specs"
    echo "tasks:"
    echo "  runs_root: .specrelay-runs/tasks"
    echo "  max_iterations: 3"
    echo "roles:"
    printf '%s\n' "$executor"
    printf '%s\n' "$reviewer"
    echo "context:"
    echo "  adapter: none"
    echo "  required: false"
    echo "validation:"
    echo "  full_test_command: \"echo ok\""
    echo "policy:"
    echo "  human_final_review_required: true"
  } > "$proj/.specrelay/config.yml"
}

# =============================================================================
# 1 — config defaults: missing model -> provider-default, missing agent -> none
# =============================================================================
proj1="$(specrelay_test::mktemp_project)"
write_config "$proj1" "  reviewer:
    provider: claude"

specrelay_test::assert_eq "1: missing executor model defaults to provider-default" \
  "provider-default" "$(specrelay::workflow::role_model "$proj1" executor)"
specrelay_test::assert_eq "1: missing executor agent defaults to none" \
  "none" "$(specrelay::workflow::role_agent "$proj1" executor)"
specrelay_test::assert_eq "1: missing reviewer model defaults to provider-default" \
  "provider-default" "$(specrelay::workflow::role_model "$proj1" reviewer)"
specrelay_test::assert_eq "1: plain claude reviewer agent defaults to none" \
  "none" "$(specrelay::workflow::role_agent "$proj1" reviewer)"
specrelay_test::assert_eq "1: reviewer provider passes through as claude" \
  "claude" "$(specrelay::workflow::role_provider "$proj1" reviewer)"

# =============================================================================
# 2 — legacy normalization: reviewer `claude-subagent`
# =============================================================================
proj2="$(specrelay_test::mktemp_project)"
write_config "$proj2" "  reviewer:
    provider: claude-subagent"

specrelay_test::assert_eq "2: claude-subagent normalizes provider to claude" \
  "claude" "$(specrelay::workflow::role_provider "$proj2" reviewer)"
specrelay_test::assert_eq "2: claude-subagent normalizes agent to ai-reviewer" \
  "ai-reviewer" "$(specrelay::workflow::role_agent "$proj2" reviewer)"
specrelay_test::assert_eq "2: claude-subagent model is provider-default" \
  "provider-default" "$(specrelay::workflow::role_model "$proj2" reviewer)"
specrelay_test::assert_eq "2: raw provider is still the configured claude-subagent" \
  "claude-subagent" "$(specrelay::workflow::role_raw_provider "$proj2" reviewer)"
# An explicitly configured model on a claude-subagent reviewer is honored.
proj2b="$(specrelay_test::mktemp_project)"
write_config "$proj2b" "  reviewer:
    provider: claude-subagent
    model: claude-sonnet-4"
specrelay_test::assert_eq "2: configured model on claude-subagent is honored" \
  "claude-sonnet-4" "$(specrelay::workflow::role_model "$proj2b" reviewer)"

# =============================================================================
# 3 — env precedence: SPECRELAY_REVIEWER_MODEL / SPECRELAY_REVIEWER_AGENT
# =============================================================================
proj3="$(specrelay_test::mktemp_project)"
write_config "$proj3" "  reviewer:
    provider: claude
    model: config-model
    agent: config-agent"

specrelay_test::assert_eq "3: config model is used when no env override" \
  "config-model" "$(specrelay::workflow::role_model "$proj3" reviewer)"
specrelay_test::assert_eq "3: SPECRELAY_REVIEWER_MODEL overrides config model" \
  "env-model" "$(SPECRELAY_REVIEWER_MODEL=env-model specrelay::workflow::role_model "$proj3" reviewer)"
specrelay_test::assert_eq "3: SPECRELAY_REVIEWER_AGENT overrides config agent" \
  "env-agent" "$(SPECRELAY_REVIEWER_AGENT=env-agent specrelay::workflow::role_agent "$proj3" reviewer)"
specrelay_test::assert_eq "3: executor env override is independent of reviewer" \
  "exec-model" "$(SPECRELAY_EXECUTOR_MODEL=exec-model specrelay::workflow::role_model "$proj3" executor)"
# An empty env override is treated as unset (falls through to config).
specrelay_test::assert_eq "3: empty env override falls through to config" \
  "config-model" "$(SPECRELAY_REVIEWER_MODEL= specrelay::workflow::role_model "$proj3" reviewer)"

# =============================================================================
# 4 — doctor reports effective provider/model/agent + ai-reviewer status
# =============================================================================
# A bogus SPECRELAY_CLAUDE_BIN makes the run deterministic regardless of whether
# a real Claude is installed on the developer's machine: the provider-availability
# and model-support checks then see an absent CLI (advisory under
# SPECRELAY_PROVIDER_OPTIONAL=1), while the effective-role lines still print.
NO_CLAUDE="$proj1/no-such-claude-binary"

proj4="$(specrelay_test::mktemp_project)"
mkdir -p "$proj4/specs"
write_config "$proj4" "  reviewer:
    provider: claude
    model: claude-sonnet-4
    agent: ai-reviewer" "  executor:
    provider: claude
    model: provider-default
    agent: none"
out4="$(cd "$proj4" && SPECRELAY_PROVIDER_OPTIONAL=1 SPECRELAY_CLAUDE_BIN="$NO_CLAUDE" "$SPECRELAY_BIN" doctor 2>&1)"
specrelay_test::assert_contains "4: doctor reports the effective Executor role line" \
  "$out4" "Executor role: provider=claude model=provider-default agent=none"
specrelay_test::assert_contains "4: doctor reports the effective Reviewer role line" \
  "$out4" "Reviewer role: provider=claude model=claude-sonnet-4 agent=ai-reviewer"

# 4b — claude-subagent reviewer, agent missing -> clear warning
proj4b="$(specrelay_test::mktemp_project)"
mkdir -p "$proj4b/specs"
write_config "$proj4b" "  reviewer:
    provider: claude-subagent"
out4b="$(cd "$proj4b" && SPECRELAY_PROVIDER_OPTIONAL=1 SPECRELAY_CLAUDE_BIN="$NO_CLAUDE" "$SPECRELAY_BIN" doctor 2>&1)"
specrelay_test::assert_contains "4b: doctor normalizes claude-subagent in the role line" \
  "$out4b" "Reviewer role: provider=claude model=provider-default agent=ai-reviewer"
specrelay_test::assert_contains "4b: doctor warns about the missing ai-reviewer agent file" \
  "$out4b" "no .claude/agents/ai-reviewer.md"
specrelay_test::assert_contains "4b: doctor points at the template for remediation" \
  "$out4b" "templates/claude/agents/ai-reviewer.md"

# 4c — ai-reviewer agent present -> reported configured
mkdir -p "$proj4b/.claude/agents"
printf '# ai-reviewer\n' > "$proj4b/.claude/agents/ai-reviewer.md"
out4c="$(cd "$proj4b" && SPECRELAY_PROVIDER_OPTIONAL=1 SPECRELAY_CLAUDE_BIN="$NO_CLAUDE" "$SPECRELAY_BIN" doctor 2>&1)"
specrelay_test::assert_contains "4c: doctor reports the ai-reviewer agent configured when present" \
  "$out4c" "ai-reviewer configured"
specrelay_test::assert_not_contains "4c: doctor no longer warns once the agent file is present" \
  "$out4c" "no .claude/agents/ai-reviewer.md"

# 4d — an explicit model with a CLI that lacks --model is reported clearly
FAKE_NOMODEL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-nomodel.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$FAKE_NOMODEL_DIR")
FAKE_NOMODEL="$FAKE_NOMODEL_DIR/claude"
cat > "$FAKE_NOMODEL" <<'FAKE'
#!/usr/bin/env bash
set -u
for a in "$@"; do
  if [ "$a" = "--help" ]; then
    echo "Usage: claude"
    echo "  --print"
    echo "  --dangerously-skip-permissions"
    exit 0
  fi
done
exit 0
FAKE
chmod +x "$FAKE_NOMODEL"
proj4d="$(specrelay_test::mktemp_project)"
mkdir -p "$proj4d/specs"
write_config "$proj4d" "  reviewer:
    provider: manual" "  executor:
    provider: claude
    model: claude-sonnet-4"
out4d="$(cd "$proj4d" && SPECRELAY_PROVIDER_OPTIONAL=1 SPECRELAY_CLAUDE_BIN="$FAKE_NOMODEL" "$SPECRELAY_BIN" doctor 2>&1)"
specrelay_test::assert_contains "4d: doctor reports an explicit model the CLI cannot accept" \
  "$out4d" "does not advertise a --model flag"

# =============================================================================
# 5 — Claude invocation model passing (fake claude, generic path)
# =============================================================================
FAKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-fakeclaude5.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$FAKE_DIR")
FAKE_CLAUDE="$FAKE_DIR/claude"
cat > "$FAKE_CLAUDE" <<'FAKE'
#!/usr/bin/env bash
# Fake Claude for model-flag tests. Knobs:
#   FAKE_CLAUDE_ADVERTISE_MODEL  1 => --help advertises --model (default 0)
#   FAKE_CLAUDE_ARGV_LOG         file to append real-run argv to
set -u
for a in "$@"; do
  if [ "$a" = "--help" ]; then
    echo "Usage: claude"
    echo "  --print"
    echo "  --dangerously-skip-permissions"
    if [ "${FAKE_CLAUDE_ADVERTISE_MODEL:-0}" = "1" ]; then
      echo "  --model <name>   the model to use"
    fi
    exit 0
  fi
done
[ -n "${FAKE_CLAUDE_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_CLAUDE_ARGV_LOG"
echo "plain claude stdout"
exit 0
FAKE
chmod +x "$FAKE_CLAUDE"

new_task5() {
  local proj task
  proj="$(specrelay_test::mktemp_project)"
  task="$proj/task"
  mkdir -p "$task"
  printf 'Implement.\n' > "$task/02-prompt.md"
  printf '%s\t%s\n' "$proj" "$task"
}

# 5a — provider-default passes NO model flag (generic path, semantic disabled)
IFS=$'\t' read -r p5a t5a < <(new_task5)
SPECRELAY_SEMANTIC_EVENTS=0 \
SPECRELAY_CLAUDE_BIN="$FAKE_CLAUDE" \
FAKE_CLAUDE_ADVERTISE_MODEL=1 \
FAKE_CLAUDE_ARGV_LOG="$t5a/argv.log" \
  specrelay::provider::claude::executor_run "$p5a" "$t5a" 1 "$t5a/02-prompt.md" "executor:claude" "provider-default" "none" 2>/dev/null
rc5a=$?
specrelay_test::assert_eq "5a: provider-default executor run exits 0" "0" "$rc5a"
specrelay_test::assert_not_contains "5a: provider-default passes NO --model flag" \
  "$(cat "$t5a/argv.log")" "--model"

# 5b — explicit model passes the flag when the CLI advertises --model
IFS=$'\t' read -r p5b t5b < <(new_task5)
SPECRELAY_SEMANTIC_EVENTS=0 \
SPECRELAY_CLAUDE_BIN="$FAKE_CLAUDE" \
FAKE_CLAUDE_ADVERTISE_MODEL=1 \
FAKE_CLAUDE_ARGV_LOG="$t5b/argv.log" \
  specrelay::provider::claude::executor_run "$p5b" "$t5b" 1 "$t5b/02-prompt.md" "executor:claude" "claude-opus-4" "none" 2>/dev/null
rc5b=$?
specrelay_test::assert_eq "5b: explicit-model executor run exits 0" "0" "$rc5b"
specrelay_test::assert_contains "5b: explicit model passes the --model flag" \
  "$(cat "$t5b/argv.log")" "--model claude-opus-4"

# 5c — explicit model FAILS CLEARLY when the CLI does not advertise --model
IFS=$'\t' read -r p5c t5c < <(new_task5)
err5c="$(SPECRELAY_SEMANTIC_EVENTS=0 \
  SPECRELAY_CLAUDE_BIN="$FAKE_CLAUDE" \
  FAKE_CLAUDE_ADVERTISE_MODEL=0 \
  FAKE_CLAUDE_ARGV_LOG="$t5c/argv.log" \
  specrelay::provider::claude::executor_run "$p5c" "$t5c" 1 "$t5c/02-prompt.md" "executor:claude" "claude-opus-4" "none" 2>&1)"
rc5c=$?
specrelay_test::assert_true "5c: explicit model with unsupported CLI fails (non-zero)" \
  "$([ "$rc5c" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "5c: the failure message is clear about --model" \
  "$err5c" "does not advertise a --model flag"
specrelay_test::assert_true "5c: the provider was never launched (no argv logged)" \
  "$([ ! -s "$t5c/argv.log" ] && echo 0 || echo 1)"

# =============================================================================
# 7 (+6) — backward compatibility: a claude-subagent reviewer config runs
#   end-to-end, and state.json records the effective NORMALIZED role metadata.
# =============================================================================
# A fake `claude` that behaves like a reviewer agent: writes 09/10 and prints
# the explicit ACCEPT decision, advertises --agent (so the normalized
# ai-reviewer sub-agent is selected), and logs its argv.
FAKE_REV_DIR="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-fakerev.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$FAKE_REV_DIR")
FAKE_REV="$FAKE_REV_DIR/claude"
cat > "$FAKE_REV" <<'FAKE'
#!/usr/bin/env bash
set -u
for a in "$@"; do
  if [ "$a" = "--help" ]; then
    echo "Usage: claude"
    echo "  --print"
    echo "  --dangerously-skip-permissions"
    echo "  --agent <name>   run a named subagent"
    exit 0
  fi
done
[ -n "${FAKE_CLAUDE_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_CLAUDE_ARGV_LOG"
printf 'Fake claude reviewer review.\n' > "$FAKE_REVIEW_TASK_DIR/09-consultant-review.md"
printf 'Fake claude reviewer business summary.\n' > "$FAKE_REVIEW_TASK_DIR/10-business-summary.md"
echo "DECISION: ACCEPT"
exit 0
FAKE
chmod +x "$FAKE_REV"

proj7="$(specrelay_test::mktemp_project)"
write_config "$proj7" "  reviewer:
    provider: claude-subagent" "  executor:
    provider: fake"
printf '.specrelay-runs/\n' > "$proj7/.gitignore"
mkdir -p "$proj7/.claude/agents"
printf '# ai-reviewer\n' > "$proj7/.claude/agents/ai-reviewer.md"
mkdir -p "$proj7/specs/0009-compat"
printf '# Compat spec\n' > "$proj7/specs/0009-compat/spec.md"
(cd "$proj7" && git add -A && git commit -q -m "compat fixture")

task_dir7="$proj7/.specrelay-runs/tasks/0009-compat"
argv7="$FAKE_REV_DIR/argv7.log"
out7="$(cd "$proj7" && \
  SPECRELAY_SEMANTIC_EVENTS=0 \
  SPECRELAY_CLAUDE_BIN="$FAKE_REV" \
  FAKE_REVIEW_TASK_DIR="$task_dir7" \
  FAKE_CLAUDE_ARGV_LOG="$argv7" \
  "$SPECRELAY_BIN" run specs/0009-compat/spec.md 2>&1)"
rc7=$?

specrelay_test::assert_eq "7: claude-subagent config runs end-to-end (exit 0)" "0" "$rc7"
specrelay_test::assert_contains "7: reaches READY_FOR_HUMAN_REVIEW" "$out7" "READY_FOR_HUMAN_REVIEW"
specrelay_test::assert_contains "7: the reviewer was invoked with --agent ai-reviewer (normalized)" \
  "$(cat "$argv7" 2>/dev/null)" "--agent ai-reviewer"

state7="$(cat "$task_dir7/state.json" 2>/dev/null)"
specrelay_test::assert_contains "6: state.json records a roles_effective block" \
  "$state7" "roles_effective"
specrelay_test::assert_eq "6: state records executor provider=fake" \
  "fake" "$(specrelay::state::get "$task_dir7/state.json" roles_effective | python3 -c 'import json,sys; print(json.load(sys.stdin)["executor"]["provider"])')"
specrelay_test::assert_eq "6: state records executor model=provider-default" \
  "provider-default" "$(specrelay::state::get "$task_dir7/state.json" roles_effective | python3 -c 'import json,sys; print(json.load(sys.stdin)["executor"]["model"])')"
specrelay_test::assert_eq "6: state records executor agent=none" \
  "none" "$(specrelay::state::get "$task_dir7/state.json" roles_effective | python3 -c 'import json,sys; print(json.load(sys.stdin)["executor"]["agent"])')"
specrelay_test::assert_eq "6: state records reviewer provider NORMALIZED to claude" \
  "claude" "$(specrelay::state::get "$task_dir7/state.json" roles_effective | python3 -c 'import json,sys; print(json.load(sys.stdin)["reviewer"]["provider"])')"
specrelay_test::assert_eq "6: state records reviewer agent=ai-reviewer (from claude-subagent)" \
  "ai-reviewer" "$(specrelay::state::get "$task_dir7/state.json" roles_effective | python3 -c 'import json,sys; print(json.load(sys.stdin)["reviewer"]["agent"])')"
specrelay_test::assert_eq "6: state records reviewer model=provider-default" \
  "provider-default" "$(specrelay::state::get "$task_dir7/state.json" roles_effective | python3 -c 'import json,sys; print(json.load(sys.stdin)["reviewer"]["model"])')"

specrelay_test::summary
exit $?
