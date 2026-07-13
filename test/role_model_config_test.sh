#!/usr/bin/env bash
# role_model_config_test.sh — explicit role model configuration (spec 0012).
#
# Deterministic; needs NO real Claude or Codex. Builds on the provider/model/
# agent resolution proven in provider_model_agent_test.sh (spec 0009) and adds
# the contract spec 0012 requires on top of it:
#   1. config parsing: executor/reviewer explicit models, different models per
#      role, missing -> provider-default;
#   2. validation: empty / whitespace-only / non-string / structurally invalid
#      model configuration is REJECTED before provider execution, with an error
#      naming the role and the config source;
#   3. effective task state: executor/reviewer models stored under
#      roles_effective; a no-model config stores provider-default;
#   4. provider forwarding via the FAKE provider's invocation evidence: the
#      configured model reaches the correct role, provider-default is forwarded
#      as-is to the fake (never as a literal remote model to a real CLI — proven
#      separately in provider_model_agent_test.sh for claude), and executor and
#      reviewer models stay isolated;
#   5. logging: executor/reviewer start output includes provider, model, agent;
#   6. doctor: shows both role models and distinguishes explicit from
#      provider-default;
#   7. resume: an existing task retains its captured models after project config
#      changes; the resumed executor and reviewer use the captured models.

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
# workflow.sh's model resolution goes through the provider capability layer
# (spec 0014), which dispatches to the provider adapters' capability functions.
# shellcheck source=../lib/specrelay/providers/provider.sh
. "$SPECRELAY_ROOT/lib/specrelay/providers/provider.sh"
# shellcheck source=../lib/specrelay/providers/fake.sh
. "$SPECRELAY_ROOT/lib/specrelay/providers/fake.sh"
# shellcheck source=../lib/specrelay/providers/claude.sh
. "$SPECRELAY_ROOT/lib/specrelay/providers/claude.sh"
# shellcheck source=../lib/specrelay/providers/capability.sh
. "$SPECRELAY_ROOT/lib/specrelay/providers/capability.sh"
# shellcheck source=../lib/specrelay/workflow.sh
. "$SPECRELAY_ROOT/lib/specrelay/workflow.sh"

# write_fake_config <project> <executor-model-line> <reviewer-model-line>
# Writes a valid .specrelay/config.yml with both roles on the deterministic
# `fake` provider, injecting the given raw model line(s) verbatim (so a test can
# supply a valid model, an invalid one, or nothing at all).
write_fake_config() {
  local proj="$1" exec_model_line="$2" rev_model_line="$3"
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
    echo "    provider: fake"
    [ -n "$exec_model_line" ] && echo "    $exec_model_line"
    echo "  reviewer:"
    echo "    provider: fake"
    [ -n "$rev_model_line" ] && echo "    $rev_model_line"
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
# 1 — config parsing: explicit models, different per role, missing -> default
# =============================================================================
proj1="$(specrelay_test::mktemp_project)"
write_fake_config "$proj1" "model: exec-model-1" "model: rev-model-1"
specrelay_test::assert_eq "1: executor explicit model is parsed" \
  "exec-model-1" "$(specrelay::workflow::role_model "$proj1" executor)"
specrelay_test::assert_eq "1: reviewer explicit model is parsed" \
  "rev-model-1" "$(specrelay::workflow::role_model "$proj1" reviewer)"
specrelay_test::assert_true "1: roles may use different models" \
  "$([ "$(specrelay::workflow::role_model "$proj1" executor)" != "$(specrelay::workflow::role_model "$proj1" reviewer)" ] && echo 0 || echo 1)"

proj1b="$(specrelay_test::mktemp_project)"
write_fake_config "$proj1b" "" ""
specrelay_test::assert_eq "1: missing executor model resolves to provider-default" \
  "provider-default" "$(specrelay::workflow::role_model "$proj1b" executor)"
specrelay_test::assert_eq "1: missing reviewer model resolves to provider-default" \
  "provider-default" "$(specrelay::workflow::role_model "$proj1b" reviewer)"

# =============================================================================
# 2 — validation: malformed model configuration is rejected before execution
# =============================================================================
# 2a — empty explicit model
proj2a="$(specrelay_test::mktemp_project)"
write_fake_config "$proj2a" "model: \"\"" ""
err2a="$(specrelay::config::validate_role_model "$proj2a" executor 2>&1)"
rc2a=$?
specrelay_test::assert_true "2a: empty explicit model is rejected (non-zero)" \
  "$([ "$rc2a" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "2a: empty-model error names the role" "$err2a" "role executor"
specrelay_test::assert_contains "2a: empty-model error names the config source" \
  "$err2a" ".specrelay/config.yml"

# 2b — whitespace-only explicit model
proj2b="$(specrelay_test::mktemp_project)"
write_fake_config "$proj2b" "" "model: \"   \""
err2b="$(specrelay::config::validate_role_model "$proj2b" reviewer 2>&1)"
rc2b=$?
specrelay_test::assert_true "2b: whitespace-only explicit model is rejected" \
  "$([ "$rc2b" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "2b: whitespace-model error names the role" \
  "$err2b" "role reviewer"

# 2c — non-string model (a YAML list)
proj2c="$(specrelay_test::mktemp_project)"
mkdir -p "$proj2c/.specrelay"
cat > "$proj2c/.specrelay/config.yml" <<'YAML'
version: 1
roles:
  executor:
    provider: fake
    model:
      - a
      - b
  reviewer:
    provider: fake
YAML
err2c="$(specrelay::config::validate_role_model "$proj2c" executor 2>&1)"
rc2c=$?
specrelay_test::assert_true "2c: non-string (list) model is rejected" \
  "$([ "$rc2c" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "2c: non-string error says it must be a string" \
  "$err2c" "must be a string"

# 2d — structurally invalid role configuration (role is not a mapping)
proj2d="$(specrelay_test::mktemp_project)"
mkdir -p "$proj2d/.specrelay"
cat > "$proj2d/.specrelay/config.yml" <<'YAML'
version: 1
roles:
  executor: fake
  reviewer:
    provider: fake
YAML
err2d="$(specrelay::config::validate_role_model "$proj2d" executor 2>&1)"
rc2d=$?
specrelay_test::assert_true "2d: structurally invalid role config is rejected" \
  "$([ "$rc2d" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "2d: structural error says it is not a mapping" \
  "$err2d" "not a mapping"

# 2e — a valid explicit model and a missing model both PASS validation
proj2e="$(specrelay_test::mktemp_project)"
write_fake_config "$proj2e" "model: some-valid-id" ""
specrelay_test::assert_true "2e: a valid explicit model passes validation" \
  "$([ "$(specrelay::config::validate_role_model "$proj2e" executor >/dev/null 2>&1; echo $?)" -eq 0 ] && echo 0 || echo 1)"
specrelay_test::assert_true "2e: a missing model passes validation" \
  "$([ "$(specrelay::config::validate_role_model "$proj2e" reviewer >/dev/null 2>&1; echo $?)" -eq 0 ] && echo 0 || echo 1)"

# 2f — malformed model fails the WHOLE run before any provider executes
proj2f="$(specrelay_test::mktemp_specrelay_project)"
cat > "$proj2f/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: Fixture
specs:
  root: docs/sdd
tasks:
  runs_root: .ai-runs/tasks
  max_iterations: 3
roles:
  executor:
    provider: fake
    model: "   "
  reviewer:
    provider: fake
context:
  adapter: none
  required: false
validation:
  full_test_command: "echo ok"
policy:
  human_final_review_required: true
YAML
(cd "$proj2f" && git add -A && git commit -q -m "malformed model config")
mkdir -p "$proj2f/docs/sdd/0012-bad-model"
echo "# bad model spec" > "$proj2f/docs/sdd/0012-bad-model/spec.md"
out2f="$(cd "$proj2f" && "$SPECRELAY_BIN" run docs/sdd/0012-bad-model/spec.md 2>&1)"
rc2f=$?
specrelay_test::assert_true "2f: run with a malformed model exits non-zero" \
  "$([ "$rc2f" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "2f: run reports the invalid model configuration" \
  "$out2f" "invalid model configuration"
specrelay_test::assert_true "2f: the fake executor never recorded an invocation" \
  "$([ ! -f "$proj2f/.ai-runs/tasks/0012-bad-model/fake-executor-invocation.txt" ] && echo 0 || echo 1)"

# =============================================================================
# 3 + 4 + 5 — effective state, forwarding evidence, logging (end-to-end fake)
# =============================================================================
proj3="$(specrelay_test::mktemp_specrelay_project)"
cat > "$proj3/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: Fixture
specs:
  root: docs/sdd
tasks:
  runs_root: .ai-runs/tasks
  max_iterations: 3
roles:
  executor:
    provider: fake
    model: executor-model-X
    agent: none
  reviewer:
    provider: fake
    model: reviewer-model-Y
    agent: none
context:
  adapter: none
  required: false
validation:
  full_test_command: "echo ok"
policy:
  human_final_review_required: true
YAML
(cd "$proj3" && git add -A && git commit -q -m "distinct-model config")
mkdir -p "$proj3/docs/sdd/0012-distinct"
echo "# distinct-model spec" > "$proj3/docs/sdd/0012-distinct/spec.md"
out3="$(cd "$proj3" && "$SPECRELAY_BIN" run docs/sdd/0012-distinct/spec.md 2>&1)"
rc3=$?
task3="$proj3/.ai-runs/tasks/0012-distinct"

specrelay_test::assert_eq "3: distinct-model run reaches READY_FOR_HUMAN_REVIEW (exit 0)" "0" "$rc3"

# 3 — effective task state under roles_effective
specrelay_test::assert_eq "3: state records executor model" "executor-model-X" \
  "$(specrelay::state::get "$task3/state.json" roles_effective | python3 -c 'import json,sys; print(json.load(sys.stdin)["executor"]["model"])')"
specrelay_test::assert_eq "3: state records reviewer model" "reviewer-model-Y" \
  "$(specrelay::state::get "$task3/state.json" roles_effective | python3 -c 'import json,sys; print(json.load(sys.stdin)["reviewer"]["model"])')"

# 4 — fake invocation evidence proves forwarding to the correct role...
specrelay_test::assert_contains "4: executor invocation evidence records executor-model-X" \
  "$(cat "$task3/fake-executor-invocation.txt")" "model=executor-model-X"
specrelay_test::assert_contains "4: executor invocation evidence records role=executor" \
  "$(cat "$task3/fake-executor-invocation.txt")" "role=executor"
specrelay_test::assert_contains "4: reviewer invocation evidence records reviewer-model-Y" \
  "$(cat "$task3/fake-reviewer-invocation.txt")" "model=reviewer-model-Y"
specrelay_test::assert_contains "4: reviewer invocation evidence records role=reviewer" \
  "$(cat "$task3/fake-reviewer-invocation.txt")" "role=reviewer"
# ...and isolation: neither role's model leaks into the other's invocation.
specrelay_test::assert_not_contains "4: reviewer model does NOT leak into executor invocation" \
  "$(cat "$task3/fake-executor-invocation.txt")" "reviewer-model-Y"
specrelay_test::assert_not_contains "4: executor model does NOT leak into reviewer invocation" \
  "$(cat "$task3/fake-reviewer-invocation.txt")" "executor-model-X"

# 5 — logging: executor and reviewer start output includes provider/model/agent
specrelay_test::assert_contains "5: executor start log includes provider, model, agent" \
  "$out3" "running provider 'fake' (round 1, model=executor-model-X agent=none)"
specrelay_test::assert_contains "5: reviewer start log includes provider, model, agent" \
  "$out3" "running provider 'fake' (round 1, model=reviewer-model-Y agent=none"

# provider-default forwards as-is to the fake (it is a real adapter, not a real
# CLI); the "never a literal remote model" contract for real CLIs is proven for
# the claude adapter in provider_model_agent_test.sh (5a).
proj3b="$(specrelay_test::mktemp_specrelay_project)"  # default fixture: no models
mkdir -p "$proj3b/docs/sdd/0012-default"
echo "# default-model spec" > "$proj3b/docs/sdd/0012-default/spec.md"
(cd "$proj3b" && "$SPECRELAY_BIN" run docs/sdd/0012-default/spec.md >/dev/null 2>&1)
task3b="$proj3b/.ai-runs/tasks/0012-default"
specrelay_test::assert_eq "3: no-model config stores executor model=provider-default" \
  "provider-default" "$(specrelay::state::get "$task3b/state.json" roles_effective | python3 -c 'import json,sys; print(json.load(sys.stdin)["executor"]["model"])')"
specrelay_test::assert_contains "4: provider-default is forwarded to the fake executor as-is" \
  "$(cat "$task3b/fake-executor-invocation.txt")" "model=provider-default"

# =============================================================================
# 6 — doctor shows both role models and distinguishes explicit vs default
# =============================================================================
proj6="$(specrelay_test::mktemp_project)"
mkdir -p "$proj6/docs/sdd"
write_fake_config "$proj6" "model: executor-model-X" ""
out6="$(cd "$proj6" && SPECRELAY_PROVIDER_OPTIONAL=1 "$SPECRELAY_BIN" doctor 2>&1)"
specrelay_test::assert_contains "6: doctor shows the executor effective model" \
  "$out6" "Executor role: provider=fake model=executor-model-X"
specrelay_test::assert_contains "6: doctor shows the reviewer effective model" \
  "$out6" "Reviewer role: provider=fake model=provider-default"
specrelay_test::assert_contains "6: doctor marks the explicit executor model as explicit" \
  "$out6" "Executor model source: explicit model 'executor-model-X'"
specrelay_test::assert_contains "6: doctor marks the provider-default reviewer model as delegated" \
  "$out6" "Reviewer model source: provider-default (delegated to the provider CLI"

# =============================================================================
# 7 — resume determinism: a captured task keeps its models after config change
# =============================================================================
# 7a — direct resolution: captured roles_effective is authoritative over config.
proj7="$(specrelay_test::mktemp_project)"
write_fake_config "$proj7" "model: model-A-exec" "model: model-A-rev"
task7_dir="$proj7/.ai-runs/tasks/0012-resume"
mkdir -p "$task7_dir"
cat > "$task7_dir/state.json" <<'JSON'
{
  "state": "READY_FOR_EXECUTOR",
  "roles_effective": {
    "executor": {"provider": "fake", "model": "model-A-exec", "agent": "none"},
    "reviewer": {"provider": "fake", "model": "model-A-rev", "agent": "none"}
  }
}
JSON
# The project configuration now changes to model B for both roles...
write_fake_config "$proj7" "model: model-B-exec" "model: model-B-rev"
specrelay_test::assert_eq "7a: live config resolution reflects the NEW model B (executor)" \
  "model-B-exec" "$(specrelay::workflow::role_model "$proj7" executor)"
specrelay_test::assert_eq "7a: captured effective model stays A (executor)" \
  "model-A-exec" "$(specrelay::workflow::effective_role_model "$proj7" 0012-resume executor)"
specrelay_test::assert_eq "7a: captured effective model stays A (reviewer)" \
  "model-A-rev" "$(specrelay::workflow::effective_role_model "$proj7" 0012-resume reviewer)"
# A now-malformed config must NOT retroactively fail a resume of a captured task.
write_fake_config "$proj7" "model: \"\"" ""
specrelay_test::assert_true "7a: captured task passes validation despite now-malformed config" \
  "$([ "$(specrelay::workflow::assert_role_model_valid "$proj7" 0012-resume executor >/dev/null 2>&1; echo $?)" -eq 0 ] && echo 0 || echo 1)"

# 7b — end-to-end: create with model A, fail the reviewer, change config to B,
# resume, and prove the resumed executor AND reviewer both use captured model A.
proj7b="$(specrelay_test::mktemp_specrelay_project)"
cat > "$proj7b/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: Fixture
specs:
  root: docs/sdd
tasks:
  runs_root: .ai-runs/tasks
  max_iterations: 3
roles:
  executor:
    provider: fake
    model: model-A-exec
  reviewer:
    provider: fake
    model: model-A-rev
context:
  adapter: none
  required: false
validation:
  full_test_command: "echo ok"
policy:
  human_final_review_required: true
YAML
(cd "$proj7b" && git add -A && git commit -q -m "resume model A config")
mkdir -p "$proj7b/docs/sdd/0012-resume-e2e"
echo "# resume spec" > "$proj7b/docs/sdd/0012-resume-e2e/spec.md"
task7b="$proj7b/.ai-runs/tasks/0012-resume-e2e"

# Run 1: executor succeeds (captures A), reviewer FAILS -> task REVIEWER_RUNNING.
plan7b_run1="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")/rev.txt"
printf 'exit=1\n' > "$plan7b_run1"
(cd "$proj7b" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan7b_run1" \
  "$SPECRELAY_BIN" run docs/sdd/0012-resume-e2e/spec.md >/dev/null 2>&1)
specrelay_test::assert_contains "7b: after a failed reviewer the task is REVIEWER_RUNNING" \
  "$(cat "$task7b/state.json")" "REVIEWER_RUNNING"
specrelay_test::assert_contains "7b: run 1 captured executor model A" \
  "$(cat "$task7b/fake-executor-invocation.txt")" "model=model-A-exec"

# Project configuration now changes to model B for both roles (committed so the
# working tree stays clean — a config edit is not part of the task's diff).
sed -i.bak 's/model-A-exec/model-B-exec/; s/model-A-rev/model-B-rev/' "$proj7b/.specrelay/config.yml"
rm -f "$proj7b/.specrelay/config.yml.bak"
(cd "$proj7b" && git add -A && git commit -q -m "change project config to model B")

# Resume: reviewer round 1 requests changes, executor round 2 runs, reviewer
# round 2 accepts — all AFTER the config changed to B. Every step must use A.
plan7b_resume="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")/rev.txt"
printf 'decision=request_changes\ndecision=accept\n' > "$plan7b_resume"
out7b="$(cd "$proj7b" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan7b_resume" \
  "$SPECRELAY_BIN" resume 0012-resume-e2e 2>&1)"
rc7b=$?
specrelay_test::assert_eq "7b: resume reaches READY_FOR_HUMAN_REVIEW (exit 0)" "0" "$rc7b"
# The resumed EXECUTOR ran round 2 (after config -> B) but used captured A.
specrelay_test::assert_contains "7b: resumed executor uses the captured executor model A" \
  "$(cat "$task7b/fake-executor-invocation.txt")" "model=model-A-exec"
specrelay_test::assert_not_contains "7b: resumed executor did NOT switch to config model B" \
  "$(cat "$task7b/fake-executor-invocation.txt")" "model-B-exec"
# The resumed REVIEWER used captured A too.
specrelay_test::assert_contains "7b: resumed reviewer uses the captured reviewer model A" \
  "$(cat "$task7b/fake-reviewer-invocation.txt")" "model=model-A-rev"
specrelay_test::assert_not_contains "7b: resumed reviewer did NOT switch to config model B" \
  "$(cat "$task7b/fake-reviewer-invocation.txt")" "model-B-rev"
# Durable state still records the captured models.
specrelay_test::assert_eq "7b: durable state still records executor model A" "model-A-exec" \
  "$(specrelay::state::get "$task7b/state.json" roles_effective | python3 -c 'import json,sys; print(json.load(sys.stdin)["executor"]["model"])')"
specrelay_test::assert_eq "7b: durable state still records reviewer model A" "model-A-rev" \
  "$(specrelay::state::get "$task7b/state.json" roles_effective | python3 -c 'import json,sys; print(json.load(sys.stdin)["reviewer"]["model"])')"

# 7c — task show surfaces the durable captured models, not the changed config.
show7c="$(cd "$proj7b" && "$SPECRELAY_BIN" task show 0012-resume-e2e 2>&1)"
specrelay_test::assert_contains "7c: task show reports the captured executor model" \
  "$show7c" "Executor model: model-A-exec"
specrelay_test::assert_contains "7c: task show reports the captured reviewer model" \
  "$show7c" "Reviewer model: model-A-rev"

specrelay_test::summary
exit $?
