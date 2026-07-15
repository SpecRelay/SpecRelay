#!/usr/bin/env bash
# guided_model_selection_test.sh — guided model selection & validation
# (spec 0014). Deterministic; needs NO real Claude or Codex — provider
# behavior is exercised through the fake provider's capability simulation
# knobs and a scripted fake `claude` binary that logs its argv.
#
# Covers the spec's Required Tests:
#   1. configuration parsing (three forms, legacy strings, invalid structured
#      forms, executor/reviewer isolation);
#   2. alias resolution (provider-scoped, deterministic, reaches invocation);
#   3. raw ids (byte-for-byte, never rewritten, never falsely rejected);
#   4. provider default (model argument omitted; the literal sentinel is
#      never forwarded to a real provider CLI);
#   5. the models command (guidance, honesty, discovery failure vs invalid
#      config, unknown provider);
#   6. validation timing (known-invalid selections fail BEFORE claim /
#      REVIEWER_RUNNING; the provider is never invoked);
#   7. durable state & resume (configured kind/value captured, resolved value
#      captured, old state readable, changed alias mappings never alter an
#      existing task);
#   8. doctor (configured vs resolved, validation level, provider-default
#      never misrepresented as an exact model, no billable invocation).

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
# shellcheck source=../lib/specrelay/workflow.sh
. "$SPECRELAY_ROOT/lib/specrelay/workflow.sh"
# shellcheck source=../lib/specrelay/models.sh
. "$SPECRELAY_ROOT/lib/specrelay/models.sh"

# write_cfg <project> <executor-model-yaml-lines> <reviewer-model-yaml-lines>
# A valid fake/fake config; the model blocks are injected verbatim (already
# indented to sit under the role mapping) so tests can supply any form.
write_cfg() {
  local proj="$1" exec_model="$2" rev_model="$3"
  mkdir -p "$proj/.specrelay"
  {
    echo "version: 1"
    echo "project:"
    echo "  name: Fixture"
    echo "specs:"
    echo "  root: docs/sdd"
    echo "tasks:"
    echo "  runs_root: .specrelay-runs/tasks"
    echo "  max_iterations: 3"
    echo "roles:"
    echo "  executor:"
    echo "    provider: fake"
    [ -n "$exec_model" ] && printf '%s\n' "$exec_model"
    echo "  reviewer:"
    echo "    provider: fake"
    [ -n "$rev_model" ] && printf '%s\n' "$rev_model"
    echo "context:"
    echo "  adapter: none"
    echo "  required: false"
    echo "validation:"
    echo "  full_test_command: \"echo ok\""
    echo "policy:"
    echo "  human_final_review_required: true"
  } > "$proj/.specrelay/config.yml"
}

# selection <project> <role> -> canonical selection string (or parse error text)
selection() {
  specrelay::config::role_model_selection "$1" "$2"
}

# =============================================================================
# 1 — configuration parsing
# =============================================================================
p1="$(specrelay_test::mktemp_project)"

write_cfg "$p1" "    model: provider-default" ""
specrelay_test::assert_eq "1: provider-default string remains valid" \
  "provider-default" "$(selection "$p1" executor)"

write_cfg "$p1" "    model: some-legacy-model-id" ""
specrelay_test::assert_eq "1: legacy raw string remains valid (means id)" \
  "id:some-legacy-model-id" "$(selection "$p1" executor)"

write_cfg "$p1" "    model:
      alias: swift" ""
specrelay_test::assert_eq "1: structured alias parses" \
  "alias:swift" "$(selection "$p1" executor)"

write_cfg "$p1" "    model:
      id: exact-model-7" ""
specrelay_test::assert_eq "1: structured raw ID parses" \
  "id:exact-model-7" "$(selection "$p1" executor)"

write_cfg "$p1" "    model:
      alias: swift
      id: exact-model-7" ""
out="$(selection "$p1" executor)"; rc=$?
specrelay_test::assert_true "1: alias plus ID is rejected" \
  "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "1: alias-plus-ID error explains exactly-one" \
  "$out" "exactly one of"

write_cfg "$p1" "    model:
      alias:" ""
out="$(selection "$p1" executor)"; rc=$?
specrelay_test::assert_true "1: empty alias is rejected" \
  "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

write_cfg "$p1" "    model:
      id: \"\"" ""
out="$(selection "$p1" executor)"; rc=$?
specrelay_test::assert_true "1: empty ID is rejected" \
  "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

write_cfg "$p1" "    model:
      unknown_key: value" ""
out="$(selection "$p1" executor)"; rc=$?
specrelay_test::assert_true "1: unknown model keys are rejected" \
  "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "1: unknown-key error names the key" \
  "$out" "unknown_key"

write_cfg "$p1" "    model: {}" ""
out="$(selection "$p1" executor)"; rc=$?
specrelay_test::assert_true "1: empty mapping is rejected" \
  "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

write_cfg "$p1" "    model:
      alias:
        nested: value" ""
out="$(selection "$p1" executor)"; rc=$?
specrelay_test::assert_true "1: nested alias value is rejected" \
  "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# executor and reviewer parse independently
write_cfg "$p1" "    model:
      alias: swift" "    model:
      id: reviewer-exact-1"
specrelay_test::assert_eq "1: executor selection is isolated" \
  "alias:swift" "$(selection "$p1" executor)"
specrelay_test::assert_eq "1: reviewer selection is isolated" \
  "id:reviewer-exact-1" "$(selection "$p1" reviewer)"

# the structured-form rejection carries actionable guidance (expected forms)
write_cfg "$p1" "    model: {}" ""
err1="$(specrelay::config::validate_role_model "$p1" executor 2>&1)"
specrelay_test::assert_contains "1: malformed error names the role" "$err1" "executor"
specrelay_test::assert_contains "1: malformed error names the config source" \
  "$err1" ".specrelay/config.yml"
specrelay_test::assert_contains "1: malformed error shows the provider-default form" \
  "$err1" "model: provider-default"
specrelay_test::assert_contains "1: malformed error shows the alias form" \
  "$err1" "alias: <alias>"
specrelay_test::assert_contains "1: malformed error shows the id form" \
  "$err1" "id: <provider-model-id>"

# =============================================================================
# 2 — alias resolution (provider-scoped, deterministic)
# =============================================================================
p2="$(specrelay_test::mktemp_project)"
write_cfg "$p2" "    model:
      alias: swift" ""

# known alias resolves for the correct provider (fake declares it)
r1="$(SPECRELAY_FAKE_CAPABILITY_LEVEL=aliases SPECRELAY_FAKE_DECLARED_ALIASES="swift=fake-model-swift steady" \
  specrelay::workflow::role_model "$p2" executor)"
specrelay_test::assert_eq "2: known alias resolves through the provider adapter" \
  "fake-model-swift" "$r1"

# alias resolution is deterministic (same inputs -> same resolution)
r2="$(SPECRELAY_FAKE_CAPABILITY_LEVEL=aliases SPECRELAY_FAKE_DECLARED_ALIASES="swift=fake-model-swift steady" \
  specrelay::workflow::role_model "$p2" executor)"
specrelay_test::assert_eq "2: alias resolution is deterministic" "$r1" "$r2"

# a bare declared alias resolves to itself (provider-recognized alias argument)
r3="$(SPECRELAY_FAKE_CAPABILITY_LEVEL=aliases SPECRELAY_FAKE_DECLARED_ALIASES="swift steady" \
  specrelay::workflow::role_model "$p2" executor)"
specrelay_test::assert_eq "2: bare declared alias resolves to the alias argument itself" \
  "swift" "$r3"

# unknown alias is rejected with an actionable error
err2="$(SPECRELAY_FAKE_CAPABILITY_LEVEL=aliases SPECRELAY_FAKE_DECLARED_ALIASES="steady" \
  specrelay::capability::validate_selection fake executor "alias:swift" 2>&1)"
rc2=$?
specrelay_test::assert_true "2: unknown alias is rejected" \
  "$([ "$rc2" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "2: unknown-alias error names role, alias, provider" \
  "$err2" "invalid executor model alias 'swift' for provider 'fake'"
specrelay_test::assert_contains "2: unknown-alias error lists supported aliases" \
  "$err2" "steady"
specrelay_test::assert_contains "2: unknown-alias error shows the provider-default form" \
  "$err2" "model: provider-default"
specrelay_test::assert_contains "2: unknown-alias error shows the exact-id form" \
  "$err2" "id: <exact-provider-model-id>"
specrelay_test::assert_contains "2: unknown-alias error points at the models command" \
  "$err2" "specrelay models fake"

# nearest-match suggestion when unambiguous
err2b="$(SPECRELAY_FAKE_CAPABILITY_LEVEL=aliases SPECRELAY_FAKE_DECLARED_ALIASES="swift steady" \
  specrelay::capability::validate_selection fake executor "alias:swiftt" 2>&1)"
specrelay_test::assert_contains "2: unambiguous typo gets a Did-you-mean suggestion" \
  "$err2b" "Did you mean: swift"

# a claude alias is NOT accepted for the fake provider (no cross-provider leak)
errx="$(SPECRELAY_FAKE_CAPABILITY_LEVEL=aliases SPECRELAY_FAKE_DECLARED_ALIASES="steady" \
  specrelay::capability::validate_selection fake executor "alias:opus" 2>&1)"
rcx=$?
specrelay_test::assert_true "2: claude's 'opus' alias is rejected for the fake provider" \
  "$([ "$rcx" -ne 0 ] && echo 0 || echo 1)"
# ...while the same alias IS valid for claude (provider-scoped, adapter-owned)
specrelay_test::assert_true "2: 'opus' is a declared claude alias" \
  "$(specrelay::capability::validate_selection claude executor "alias:opus" >/dev/null 2>&1; echo $?)"
specrelay_test::assert_eq "2: claude resolves 'opus' to the provider-recognized alias argument" \
  "opus" "$(specrelay::capability::resolve_alias claude opus)"
# ...and a fake alias is NOT accepted for claude
specrelay_test::assert_true "2: fake's alias is rejected for claude" \
  "$([ "$(SPECRELAY_FAKE_DECLARED_ALIASES="steady" \
      specrelay::capability::validate_selection claude executor "alias:steady" >/dev/null 2>&1; echo $?)" -ne 0 ] && echo 0 || echo 1)"

# =============================================================================
# 3 — raw IDs
# =============================================================================
p3="$(specrelay_test::mktemp_project)"
weird_id='Weird.id-42:with:colons_and.dots'
write_cfg "$p3" "    model:
      id: \"$weird_id\"" ""
specrelay_test::assert_eq "3: raw ID is preserved byte-for-byte (not rewritten/prefixed)" \
  "$weird_id" "$(specrelay::workflow::role_model "$p3" executor)"
# structural-only providers never falsely reject a valid-looking raw id
specrelay_test::assert_true "3: structural-only provider accepts an unknown raw ID" \
  "$(specrelay::capability::validate_selection fake executor "id:$weird_id" >/dev/null 2>&1; echo $?)"
# ...but reports honestly that it cannot verify it locally
note3="$(specrelay::capability::validate_selection fake executor "id:$weird_id" 2>&1)"
specrelay_test::assert_contains "3: unverifiable raw ID gets an honest advisory" \
  "$note3" "cannot be verified locally"

# exact discovery: a listed id passes, an unknown id is rejected locally
specrelay_test::assert_true "3: exact discovery accepts a listed ID" \
  "$(SPECRELAY_FAKE_CAPABILITY_LEVEL=exact SPECRELAY_FAKE_DISCOVERED_MODELS="m-one m-two" \
     specrelay::capability::validate_selection fake executor "id:m-two" >/dev/null 2>&1; echo $?)"
err3="$(SPECRELAY_FAKE_CAPABILITY_LEVEL=exact SPECRELAY_FAKE_DISCOVERED_MODELS="m-one m-two" \
  specrelay::capability::validate_selection fake executor "id:m-three" 2>&1)"
rc3=$?
specrelay_test::assert_true "3: exact discovery rejects an unknown ID locally" \
  "$([ "$rc3" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "3: unknown-ID error lists the discovered models" \
  "$err3" "m-one"
# discovery FAILURE is not misreported as an invalid user model
out3="$(SPECRELAY_FAKE_CAPABILITY_LEVEL=exact SPECRELAY_FAKE_DISCOVERED_MODELS="m-one" \
  SPECRELAY_FAKE_DISCOVERY_FAIL=1 \
  specrelay::capability::validate_selection fake executor "id:m-three" 2>&1)"
rc3b=$?
specrelay_test::assert_eq "3: discovery failure does NOT reject the configured ID" "0" "$rc3b"
specrelay_test::assert_contains "3: discovery failure is reported as a discovery problem" \
  "$out3" "discovery failed"

# a provider with NO explicit model support rejects any explicit selection
err3c="$(SPECRELAY_FAKE_CAPABILITY_LEVEL=none \
  specrelay::capability::validate_selection fake executor "id:whatever" 2>&1)"
rc3c=$?
specrelay_test::assert_true "3: no-explicit-model provider rejects an explicit ID" \
  "$([ "$rc3c" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "3: no-explicit-model error suggests provider-default" \
  "$err3c" "provider-default"
specrelay_test::assert_true "3: no-explicit-model provider still accepts provider-default" \
  "$(SPECRELAY_FAKE_CAPABILITY_LEVEL=none \
     specrelay::capability::validate_selection fake executor "provider-default" >/dev/null 2>&1; echo $?)"

# =============================================================================
# 4 — end-to-end forwarding through the FAKE provider (alias + id + default)
# =============================================================================
p4="$(specrelay_test::mktemp_specrelay_project)"
cat > "$p4/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: Fixture
specs:
  root: docs/sdd
tasks:
  runs_root: .specrelay-runs/tasks
  max_iterations: 3
roles:
  executor:
    provider: fake
    model:
      alias: swift
  reviewer:
    provider: fake
    model:
      id: reviewer-exact-9
context:
  adapter: none
  required: false
validation:
  full_test_command: "echo ok"
policy:
  human_final_review_required: true
YAML
(cd "$p4" && git add -A && git commit -q -m "alias/id config")
mkdir -p "$p4/docs/sdd/0014-forward"
echo "# forwarding spec" > "$p4/docs/sdd/0014-forward/spec.md"
out4="$(cd "$p4" && \
  SPECRELAY_FAKE_CAPABILITY_LEVEL=aliases \
  SPECRELAY_FAKE_DECLARED_ALIASES="swift=fake-model-swift" \
  "$SPECRELAY_BIN" run docs/sdd/0014-forward/spec.md 2>&1)"
rc4=$?
task4="$p4/.specrelay-runs/tasks/0014-forward"
specrelay_test::assert_eq "4: alias/id run reaches READY_FOR_HUMAN_REVIEW (exit 0)" "0" "$rc4"
specrelay_test::assert_contains "4: RESOLVED alias reached the executor invocation" \
  "$(cat "$task4/fake-executor-invocation.txt")" "model=fake-model-swift"
specrelay_test::assert_contains "4: raw ID reached the reviewer invocation byte-for-byte" \
  "$(cat "$task4/fake-reviewer-invocation.txt")" "model=reviewer-exact-9"
specrelay_test::assert_not_contains "4: the executor never received the reviewer's id (isolation)" \
  "$(cat "$task4/fake-executor-invocation.txt")" "reviewer-exact-9"
specrelay_test::assert_not_contains "4: the reviewer never received the executor's alias resolution (isolation)" \
  "$(cat "$task4/fake-reviewer-invocation.txt")" "fake-model-swift"
specrelay_test::assert_not_contains "4: the UNRESOLVED alias selection never reached the executor" \
  "$(cat "$task4/fake-executor-invocation.txt")" "alias:swift"

# durable state: resolved model AND configured kind/value are captured
roles4="$(specrelay::state::get "$task4/state.json" roles_effective)"
specrelay_test::assert_eq "4: state captures the executor's RESOLVED model" "fake-model-swift" \
  "$(printf '%s' "$roles4" | python3 -c 'import json,sys; print(json.load(sys.stdin)["executor"]["model"])')"
specrelay_test::assert_eq "4: state captures the executor's configured kind" "alias" \
  "$(printf '%s' "$roles4" | python3 -c 'import json,sys; print(json.load(sys.stdin)["executor"]["model_configured"]["kind"])')"
specrelay_test::assert_eq "4: state captures the executor's configured value" "swift" \
  "$(printf '%s' "$roles4" | python3 -c 'import json,sys; print(json.load(sys.stdin)["executor"]["model_configured"]["value"])')"
specrelay_test::assert_eq "4: state captures the reviewer's configured kind" "id" \
  "$(printf '%s' "$roles4" | python3 -c 'import json,sys; print(json.load(sys.stdin)["reviewer"]["model_configured"]["kind"])')"
specrelay_test::assert_eq "4: state captures the reviewer's configured value" "reviewer-exact-9" \
  "$(printf '%s' "$roles4" | python3 -c 'import json,sys; print(json.load(sys.stdin)["reviewer"]["model_configured"]["value"])')"

# task show displays durable configured + resolved model information
show4="$(cd "$p4" && "$SPECRELAY_BIN" task show 0014-forward 2>&1)"
specrelay_test::assert_contains "4: task show reports the resolved executor model" \
  "$show4" "Executor model: fake-model-swift"
specrelay_test::assert_contains "4: task show reports the configured executor selection" \
  "$show4" "Executor model configured: alias:swift"
specrelay_test::assert_contains "4: task show reports the configured reviewer selection" \
  "$show4" "Reviewer model configured: id:reviewer-exact-9"

# =============================================================================
# 5 — resume determinism: changed alias MAPPINGS never alter an existing task
# =============================================================================
p5="$(specrelay_test::mktemp_specrelay_project)"
cat > "$p5/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: Fixture
specs:
  root: docs/sdd
tasks:
  runs_root: .specrelay-runs/tasks
  max_iterations: 3
roles:
  executor:
    provider: fake
    model:
      alias: swift
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
(cd "$p5" && git add -A && git commit -q -m "alias config")
mkdir -p "$p5/docs/sdd/0014-resume"
echo "# resume spec" > "$p5/docs/sdd/0014-resume/spec.md"
task5="$p5/.specrelay-runs/tasks/0014-resume"

# Run 1: alias swift -> old-resolution; reviewer FAILS so the task stays open.
plan5="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")/rev.txt"
printf 'exit=1\n' > "$plan5"
(cd "$p5" && \
  SPECRELAY_FAKE_CAPABILITY_LEVEL=aliases \
  SPECRELAY_FAKE_DECLARED_ALIASES="swift=old-resolution" \
  SPECRELAY_FAKE_REVIEWER_PLAN="$plan5" \
  "$SPECRELAY_BIN" run docs/sdd/0014-resume/spec.md >/dev/null 2>&1)
specrelay_test::assert_contains "5: run 1 forwarded the OLD alias resolution" \
  "$(cat "$task5/fake-executor-invocation.txt")" "model=old-resolution"

# The ALIAS MAPPING now changes (adapter update simulated via env). Resume:
# reviewer requests changes then accepts, so the executor runs a second round
# AFTER the mapping changed — it must still use the captured OLD resolution.
plan5b="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")/rev.txt"
printf 'decision=request_changes\ndecision=accept\n' > "$plan5b"
out5="$(cd "$p5" && \
  SPECRELAY_FAKE_CAPABILITY_LEVEL=aliases \
  SPECRELAY_FAKE_DECLARED_ALIASES="swift=new-resolution" \
  SPECRELAY_FAKE_REVIEWER_PLAN="$plan5b" \
  "$SPECRELAY_BIN" resume 0014-resume 2>&1)"
rc5=$?
specrelay_test::assert_eq "5: resume reaches READY_FOR_HUMAN_REVIEW (exit 0)" "0" "$rc5"
specrelay_test::assert_contains "5: the resumed executor still uses the CAPTURED resolution" \
  "$(cat "$task5/fake-executor-invocation.txt")" "model=old-resolution"
specrelay_test::assert_not_contains "5: the resumed executor never re-resolved against the new mapping" \
  "$(cat "$task5/fake-executor-invocation.txt")" "new-resolution"
specrelay_test::assert_eq "5: durable state still records the captured resolution" "old-resolution" \
  "$(specrelay::state::get "$task5/state.json" roles_effective | python3 -c 'import json,sys; print(json.load(sys.stdin)["executor"]["model"])')"

# Old (pre-0014) state files — string model only, no model_configured — stay
# readable and displayable.
p5b="$(specrelay_test::mktemp_project)"
write_cfg "$p5b" "" ""
old_task_dir="$p5b/.specrelay-runs/tasks/0009-old"
mkdir -p "$old_task_dir"
cat > "$old_task_dir/state.json" <<'JSON'
{
  "state": "READY_FOR_HUMAN_REVIEW",
  "roles_effective": {
    "executor": {"provider": "fake", "model": "legacy-string-model", "agent": "none"},
    "reviewer": {"provider": "fake", "model": "provider-default", "agent": "none"}
  }
}
JSON
specrelay_test::assert_eq "5: old string-only capture still resolves on read" \
  "legacy-string-model" "$(specrelay::workflow::effective_role_model "$p5b" 0009-old executor)"
show5="$(cd "$p5b" && "$SPECRELAY_BIN" task show 0009-old 2>&1)"
specrelay_test::assert_contains "5: old task remains displayable by task show" \
  "$show5" "Executor model: legacy-string-model"
specrelay_test::assert_contains "5: old task reports structured metadata as not recorded" \
  "$show5" "not recorded"

# =============================================================================
# 6 — validation timing: known-invalid selections fail BEFORE running states
# =============================================================================
# 6a — invalid executor alias: rejected before claim; never EXECUTOR_RUNNING.
p6="$(specrelay_test::mktemp_specrelay_project)"
cat > "$p6/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: Fixture
specs:
  root: docs/sdd
tasks:
  runs_root: .specrelay-runs/tasks
  max_iterations: 3
roles:
  executor:
    provider: fake
    model:
      alias: no-such-alias
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
(cd "$p6" && git add -A && git commit -q -m "invalid alias config")
mkdir -p "$p6/docs/sdd/0014-badalias"
echo "# bad alias spec" > "$p6/docs/sdd/0014-badalias/spec.md"
out6="$(cd "$p6" && \
  SPECRELAY_FAKE_CAPABILITY_LEVEL=aliases SPECRELAY_FAKE_DECLARED_ALIASES="swift" \
  "$SPECRELAY_BIN" run docs/sdd/0014-badalias/spec.md 2>&1)"
rc6=$?
task6="$p6/.specrelay-runs/tasks/0014-badalias"
specrelay_test::assert_true "6a: run with an invalid alias exits non-zero" \
  "$([ "$rc6" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "6a: the error names the invalid alias, role, provider" \
  "$out6" "invalid executor model alias 'no-such-alias' for provider 'fake'"
specrelay_test::assert_eq "6a: the task never entered EXECUTOR_RUNNING" \
  "READY_FOR_EXECUTOR" "$(specrelay::state::get "$task6/state.json" state)"
specrelay_test::assert_true "6a: the provider was never invoked (no invocation evidence)" \
  "$([ ! -f "$task6/fake-executor-invocation.txt" ] && echo 0 || echo 1)"

# 6b — invalid reviewer alias on a task already READY_FOR_REVIEW (no captured
# roles): the reviewer is rejected before REVIEWER_RUNNING and never invoked.
p6b="$(specrelay_test::mktemp_specrelay_project)"
cat > "$p6b/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: Fixture
specs:
  root: docs/sdd
tasks:
  runs_root: .specrelay-runs/tasks
  max_iterations: 3
roles:
  executor:
    provider: fake
  reviewer:
    provider: fake
    model:
      alias: bogus-reviewer-alias
context:
  adapter: none
  required: false
validation:
  full_test_command: "echo ok"
policy:
  human_final_review_required: true
YAML
(cd "$p6b" && git add -A && git commit -q -m "invalid reviewer alias")
task6b="$p6b/.specrelay-runs/tasks/0014-badrev"
mkdir -p "$task6b"
cat > "$task6b/state.json" <<'JSON'
{
  "state": "READY_FOR_REVIEW",
  "iteration": 1,
  "engine": "specrelay"
}
JSON
out6b="$(cd "$p6b" && \
  SPECRELAY_FAKE_CAPABILITY_LEVEL=aliases SPECRELAY_FAKE_DECLARED_ALIASES="swift" \
  "$SPECRELAY_BIN" resume 0014-badrev 2>&1)"
rc6b=$?
specrelay_test::assert_true "6b: resume with an invalid reviewer alias exits non-zero" \
  "$([ "$rc6b" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "6b: the error names the invalid reviewer alias" \
  "$out6b" "invalid reviewer model alias 'bogus-reviewer-alias' for provider 'fake'"
specrelay_test::assert_eq "6b: the task never entered REVIEWER_RUNNING" \
  "READY_FOR_REVIEW" "$(specrelay::state::get "$task6b/state.json" state)"
specrelay_test::assert_true "6b: the reviewer provider was never invoked" \
  "$([ ! -f "$task6b/fake-reviewer-invocation.txt" ] && echo 0 || echo 1)"

# =============================================================================
# 7 — the models command
# =============================================================================
p7="$(specrelay_test::mktemp_project)"
mkdir -p "$p7/docs/sdd"
write_cfg "$p7" "    model:
      alias: swift" ""

models7="$(cd "$p7" && \
  SPECRELAY_FAKE_CAPABILITY_LEVEL=aliases SPECRELAY_FAKE_DECLARED_ALIASES="swift steady" \
  "$SPECRELAY_BIN" models 2>&1 </dev/null)"
rc7=$?
specrelay_test::assert_eq "7: models exits 0 (non-interactive, stdin closed)" "0" "$rc7"
specrelay_test::assert_contains "7: models displays the configured provider" \
  "$models7" "Provider: fake"
specrelay_test::assert_contains "7: models shows this project's configured executor selection" \
  "$models7" "executor: configured=alias:swift resolved=swift"
specrelay_test::assert_contains "7: models shows the provider-default form" \
  "$models7" "model: provider-default"
specrelay_test::assert_contains "7: models shows the alias form" \
  "$models7" "alias: <alias>"
specrelay_test::assert_contains "7: models shows the exact-id form" \
  "$models7" "id: <provider-model-id>"
specrelay_test::assert_contains "7: declared aliases are shown and marked SpecRelay-declared" \
  "$models7" "Supported aliases (SpecRelay-declared, provider-scoped):"
specrelay_test::assert_contains "7: models lists the declared alias" "$models7" "steady"
specrelay_test::assert_not_contains "7: models output contains no ANSI color escapes" \
  "$models7" "$(printf '\033')"

# discovery capability is reported honestly per level
models7a="$(cd "$p7" && SPECRELAY_FAKE_CAPABILITY_LEVEL=structural "$SPECRELAY_BIN" models fake 2>&1)"
specrelay_test::assert_contains "7: structural level reports discovery unavailable" \
  "$models7a" "unavailable"
specrelay_test::assert_contains "7: structural level says it cannot enumerate models" \
  "$models7a" "cannot reliably enumerate"

models7b="$(cd "$p7" && \
  SPECRELAY_FAKE_CAPABILITY_LEVEL=exact SPECRELAY_FAKE_DISCOVERED_MODELS="m-one m-two" \
  "$SPECRELAY_BIN" models fake 2>&1)"
specrelay_test::assert_contains "7: exact level reports discovery available" \
  "$models7b" "available (source:"
specrelay_test::assert_contains "7: exact level lists discovered models distinctly" \
  "$models7b" "Discovered models (from provider discovery):"
specrelay_test::assert_contains "7: exact level lists the discovered id" "$models7b" "m-two"

# discovery failure is distinguishable from invalid configuration
models7c="$(cd "$p7" && \
  SPECRELAY_FAKE_CAPABILITY_LEVEL=exact SPECRELAY_FAKE_DISCOVERY_FAIL=1 \
  "$SPECRELAY_BIN" models fake 2>&1)"
specrelay_test::assert_contains "7: discovery failure is reported as failed" \
  "$models7c" "failed:"
specrelay_test::assert_contains "7: discovery failure is explicitly NOT an invalid configuration" \
  "$models7c" "not an invalid model configuration"

# no-explicit-model level is honest
models7d="$(cd "$p7" && SPECRELAY_FAKE_CAPABILITY_LEVEL=none "$SPECRELAY_BIN" models fake 2>&1)"
specrelay_test::assert_contains "7: none level reports no explicit model support" \
  "$models7d" "not supported"

# unknown provider produces useful guidance
err7="$(cd "$p7" && "$SPECRELAY_BIN" models codex 2>&1)"
rc7e=$?
specrelay_test::assert_true "7: unknown provider exits non-zero" \
  "$([ "$rc7e" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "7: unknown provider error names the provider" \
  "$err7" "unknown provider 'codex'"
specrelay_test::assert_contains "7: unknown provider error lists configured providers" \
  "$err7" "Configured providers in this project:"
specrelay_test::assert_contains "7: unknown provider error lists supported providers" \
  "$err7" "claude-subagent"

# =============================================================================
# 8 — provider default and the claude CLI: REAL argv verification
# =============================================================================
# A scripted fake `claude` that advertises --model/--agent, logs its argv, and
# behaves as both roles (writes executor outputs / reviewer decision), so a
# full run proves what actually reaches the provider CLI: provider-default
# omits the model argument entirely (and the literal sentinel is never
# forwarded), a resolved alias arrives as `--model <alias>`, and a raw id
# arrives byte-for-byte.
FAKE_CLI_DIR="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-fakeclaude14.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$FAKE_CLI_DIR")
FAKE_CLI="$FAKE_CLI_DIR/claude"
cat > "$FAKE_CLI" <<'FAKE'
#!/usr/bin/env bash
set -u
for a in "$@"; do
  if [ "$a" = "--help" ]; then
    echo "Usage: claude"
    echo "  --print"
    echo "  --model <name>   the model to use"
    echo "  --agent <name>   run a named subagent"
    echo "  --dangerously-skip-permissions"
    exit 0
  fi
done
[ -n "${FAKE_CLAUDE_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_CLAUDE_ARGV_LOG"
if [ "${FAKE_CLAUDE_ROLE:-executor}" = "reviewer" ]; then
  printf 'review notes\n' > "$FAKE_TASK_DIR/09-consultant-review.md"
  printf 'summary\n' > "$FAKE_TASK_DIR/10-business-summary.md"
  echo "DECISION: ACCEPT"
else
  printf 'log\n' > "$FAKE_TASK_DIR/03-executor-log.md"
  printf 'tests ok\n' > "$FAKE_TASK_DIR/07-tests.txt"
  printf 'summary\n' > "$FAKE_TASK_DIR/08-executor-summary.md"
  echo "executor done"
fi
exit 0
FAKE
chmod +x "$FAKE_CLI"

# The same binary serves both roles; the reviewer invocation is detected via a
# wrapper that flips FAKE_CLAUDE_ROLE per role using SpecRelay's role-specific
# model env-override mechanism is NOT used here — instead we run two separate
# tasks, one per role focus, keeping each argv log unambiguous.

# 8a — executor: provider-default omits --model; alias resolves to --model opus
p8="$(specrelay_test::mktemp_project)"
mkdir -p "$p8/.specrelay" "$p8/docs/sdd/0014-argv"
cat > "$p8/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: Fixture
specs:
  root: docs/sdd
tasks:
  runs_root: .specrelay-runs/tasks
  max_iterations: 3
roles:
  executor:
    provider: claude
    model: provider-default
  reviewer:
    provider: claude
    model:
      alias: opus
context:
  adapter: none
  required: false
validation:
  full_test_command: "echo ok"
policy:
  human_final_review_required: true
YAML
printf '.specrelay-runs/\n' > "$p8/.gitignore"
echo "# argv spec" > "$p8/docs/sdd/0014-argv/spec.md"
(cd "$p8" && git add -A && git commit -q -m "argv fixture")
task8="$p8/.specrelay-runs/tasks/0014-argv"
argv_exec="$FAKE_CLI_DIR/exec-argv.log"
argv_rev="$FAKE_CLI_DIR/rev-argv.log"

# Wrap the fake CLI so each role logs to its own file and behaves per role.
EXEC_WRAP="$FAKE_CLI_DIR/claude-exec"
cat > "$EXEC_WRAP" <<WRAP
#!/usr/bin/env bash
if [ "\${SPECRELAY_FAKE_ROLE_HINT:-}" = "" ] && [ -f "$task8/03-executor-log.md" ]; then
  FAKE_CLAUDE_ROLE=reviewer FAKE_CLAUDE_ARGV_LOG="$argv_rev" FAKE_TASK_DIR="$task8" exec "$FAKE_CLI" "\$@"
fi
FAKE_CLAUDE_ROLE=executor FAKE_CLAUDE_ARGV_LOG="$argv_exec" FAKE_TASK_DIR="$task8" exec "$FAKE_CLI" "\$@"
WRAP
chmod +x "$EXEC_WRAP"

out8="$(cd "$p8" && \
  SPECRELAY_SEMANTIC_EVENTS=0 SPECRELAY_CLAUDE_BIN="$EXEC_WRAP" \
  "$SPECRELAY_BIN" run docs/sdd/0014-argv/spec.md 2>&1)"
rc8=$?
specrelay_test::assert_eq "8: claude argv run reaches READY_FOR_HUMAN_REVIEW (exit 0)" "0" "$rc8"
specrelay_test::assert_not_contains "8: provider-default passes NO --model to the executor CLI" \
  "$(cat "$argv_exec" 2>/dev/null)" "--model"
specrelay_test::assert_not_contains "8: the literal provider-default sentinel is never forwarded" \
  "$(cat "$argv_exec" 2>/dev/null)" "provider-default"
specrelay_test::assert_contains "8: the resolved alias reaches the reviewer CLI as --model opus" \
  "$(cat "$argv_rev" 2>/dev/null)" "--model opus"
specrelay_test::assert_not_contains "8: the alias selection is never forwarded unresolved" \
  "$(cat "$argv_rev" 2>/dev/null)" "alias:opus"

# 8b — raw id reaches the claude CLI byte-for-byte
p8b="$(specrelay_test::mktemp_project)"
mkdir -p "$p8b/.specrelay" "$p8b/docs/sdd/0014-argv-id"
cat > "$p8b/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: Fixture
specs:
  root: docs/sdd
tasks:
  runs_root: .specrelay-runs/tasks
  max_iterations: 3
roles:
  executor:
    provider: claude
    model:
      id: "custom.model-id:v42"
  reviewer:
    provider: manual
context:
  adapter: none
  required: false
validation:
  full_test_command: "echo ok"
policy:
  human_final_review_required: true
YAML
printf '.specrelay-runs/\n' > "$p8b/.gitignore"
echo "# raw id spec" > "$p8b/docs/sdd/0014-argv-id/spec.md"
(cd "$p8b" && git add -A && git commit -q -m "raw id fixture")
task8b="$p8b/.specrelay-runs/tasks/0014-argv-id"
argv8b="$FAKE_CLI_DIR/id-argv.log"
EXEC_WRAP_B="$FAKE_CLI_DIR/claude-id"
cat > "$EXEC_WRAP_B" <<WRAP
#!/usr/bin/env bash
FAKE_CLAUDE_ROLE=executor FAKE_CLAUDE_ARGV_LOG="$argv8b" FAKE_TASK_DIR="$task8b" exec "$FAKE_CLI" "\$@"
WRAP
chmod +x "$EXEC_WRAP_B"
(cd "$p8b" && \
  SPECRELAY_SEMANTIC_EVENTS=0 SPECRELAY_CLAUDE_BIN="$EXEC_WRAP_B" \
  "$SPECRELAY_BIN" run docs/sdd/0014-argv-id/spec.md >/dev/null 2>&1)
specrelay_test::assert_contains "8: the raw id reaches the claude CLI byte-for-byte" \
  "$(cat "$argv8b" 2>/dev/null)" "--model custom.model-id:v42"

# =============================================================================
# 9 — doctor
# =============================================================================
p9="$(specrelay_test::mktemp_project)"
mkdir -p "$p9/docs/sdd"
write_cfg "$p9" "    model:
      alias: swift" ""
out9="$(cd "$p9" && \
  SPECRELAY_PROVIDER_OPTIONAL=1 \
  SPECRELAY_FAKE_CAPABILITY_LEVEL=aliases SPECRELAY_FAKE_DECLARED_ALIASES="swift" \
  "$SPECRELAY_BIN" doctor 2>&1)"
specrelay_test::assert_contains "9: doctor shows the executor's configured selection" \
  "$out9" "configured=alias:swift"
specrelay_test::assert_contains "9: doctor shows the executor's resolved value" \
  "$out9" "resolved=swift"
specrelay_test::assert_contains "9: doctor shows the selection kind" \
  "$out9" "kind=alias"
specrelay_test::assert_contains "9: doctor shows the validation level" \
  "$out9" "validation=provider-declared alias"
specrelay_test::assert_contains "9: doctor shows the configuration source" \
  "$out9" ".specrelay/config.yml"
specrelay_test::assert_contains "9: doctor reports provider-default as provider-managed (not an exact model)" \
  "$out9" "resolved=provider-managed default"

# a known-invalid alias is a mandatory doctor failure
write_cfg "$p9" "    model:
      alias: no-such" ""
out9b="$(cd "$p9" && \
  SPECRELAY_PROVIDER_OPTIONAL=1 \
  SPECRELAY_FAKE_CAPABILITY_LEVEL=aliases SPECRELAY_FAKE_DECLARED_ALIASES="swift" \
  "$SPECRELAY_BIN" doctor 2>&1)"
rc9b=$?
specrelay_test::assert_true "9: doctor fails (non-zero) for a known-invalid alias" \
  "$([ "$rc9b" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "9: doctor marks the invalid selection KNOWN-INVALID" \
  "$out9b" "KNOWN-INVALID"

specrelay_test::summary
exit $?
