#!/usr/bin/env bash
# context_adapters_test.sh — first-class context capability adapters
# (spec 0015). Deterministic; needs NO real provider and NO network — context
# behavior is exercised through the fake context adapter's env knobs and the
# fake executor/reviewer providers, whose invocation evidence PROVES what
# handoff actually reached each role.
#
# Covers the spec's Required Tests:
#   1. configuration (global/role-specific parsing, defaults, rejection);
#   2. discovery (contexts command: listing, capabilities, unknown adapter,
#      unavailable adapter honesty, copyable output);
#   3. validation timing (known-invalid context fails BEFORE
#      EXECUTOR_RUNNING / REVIEWER_RUNNING; the provider is never invoked);
#   4. optional policy (honest degradation: warning, durable degraded state,
#      provider still invoked, no success claim);
#   5. required policy (preflight/preparation/missing-artifact failures block;
#      provider never invoked — including a Claude-configured executor);
#   6. preparation, normalized handoff, executor/reviewer isolation;
#   7. durable state (capture, artifact metadata, old tasks readable,
#      no secrets);
#   8. resume (captured adapter survives config changes; reuse / reprepare /
#      stale / missing-artifact behavior is deterministic and explicit);
#   9. doctor and task show integration;
#  10. compatibility (adapter: none preserves current behavior).

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

# write_cfg <project> <context-yaml-block> [executor-provider] [reviewer-provider]
# A valid config with the given context block (verbatim; empty = no context
# section) and fake providers unless overridden.
write_cfg() {
  local proj="$1" context_block="$2" exec_provider="${3:-fake}" rev_provider="${4:-fake}"
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
# Prints the project path; creates the spec and commits the fixture.
mk_run_project() {
  local ctx="$1" slug="$2" exec_provider="${3:-fake}" rev_provider="${4:-fake}" proj
  proj="$(specrelay_test::mktemp_project)"
  write_cfg "$proj" "$ctx" "$exec_provider" "$rev_provider"
  printf '.specrelay-runs/\n' > "$proj/.gitignore"
  mkdir -p "$proj/docs/sdd/$slug"
  printf '# fixture spec\n' > "$proj/docs/sdd/$slug/spec.md"
  (cd "$proj" && git add -A && git commit -q -m "fixture")
  printf '%s\n' "$proj"
}

# ctx_state <task-dir> <role> <field> — one field from durable context_effective
ctx_state() {
  specrelay::state::get "$1/state.json" context_effective | \
    ROLE="$2" FIELD="$3" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
val = data[os.environ["ROLE"]][os.environ["FIELD"]]
print(json.dumps(val) if isinstance(val, bool) else val)
'
}

# =============================================================================
# 1 — configuration
# =============================================================================
p1="$(specrelay_test::mktemp_project)"

write_cfg "$p1" "context:
  adapter: fake
  required: true"
specrelay_test::assert_eq "1: global adapter parses" \
  "adapter=fake
required=true" "$(specrelay::config::role_context "$p1" executor)"

write_cfg "$p1" "context:
  adapter: none
  executor:
    adapter: fake
    required: true"
specrelay_test::assert_eq "1: executor override parses" \
  "adapter=fake
required=true" "$(specrelay::config::role_context "$p1" executor)"
specrelay_test::assert_eq "1: reviewer falls back to global adapter" \
  "adapter=none
required=false" "$(specrelay::config::role_context "$p1" reviewer)"

write_cfg "$p1" "context:
  adapter: fake
  required: true
  reviewer:
    adapter: none
    required: false"
specrelay_test::assert_eq "1: reviewer override parses" \
  "adapter=none
required=false" "$(specrelay::config::role_context "$p1" reviewer)"
specrelay_test::assert_eq "1: executor keeps the global values (role isolation)" \
  "adapter=fake
required=true" "$(specrelay::config::role_context "$p1" executor)"

write_cfg "$p1" ""
specrelay_test::assert_eq "1: missing configuration resolves to none" \
  "adapter=none
required=false" "$(specrelay::config::role_context "$p1" executor)"

write_cfg "$p1" "context:
  adapter: fake"
specrelay_test::assert_eq "1: required defaults safely to false" \
  "adapter=fake
required=false" "$(specrelay::config::role_context "$p1" executor)"

write_cfg "$p1" "context:
  adapter: \"\""
out1="$(specrelay::config::role_context "$p1" executor)"; rc1=$?
specrelay_test::assert_true "1: empty adapter name is rejected" \
  "$([ "$rc1" -ne 0 ] && echo 0 || echo 1)"

write_cfg "$p1" "context:
  adapter: [a, b]"
out1="$(specrelay::config::role_context "$p1" executor)"; rc1=$?
specrelay_test::assert_true "1: non-string adapter name is rejected" \
  "$([ "$rc1" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "1: non-string adapter error says string" \
  "$out1" "must be a string"

write_cfg "$p1" "context:
  adapter: fake
  required: banana"
out1="$(specrelay::config::role_context "$p1" executor)"; rc1=$?
specrelay_test::assert_true "1: malformed required value is rejected" \
  "$([ "$rc1" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "1: malformed required error says boolean" \
  "$out1" "boolean"

write_cfg "$p1" "context:
  adapter: fake
  retrieval_depth: 9"
out1="$(specrelay::config::role_context "$p1" executor)"; rc1=$?
specrelay_test::assert_true "1: unknown context keys are rejected" \
  "$([ "$rc1" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "1: unknown-key error names the key" \
  "$out1" "retrieval_depth"

write_cfg "$p1" "context:
  executor: not-a-mapping"
out1="$(specrelay::config::role_context "$p1" executor)"; rc1=$?
specrelay_test::assert_true "1: malformed role-specific configuration is rejected" \
  "$([ "$rc1" -ne 0 ] && echo 0 || echo 1)"

# unknown adapter rejected with actionable guidance (role, adapter, source,
# known adapters, inspection command)
write_cfg "$p1" "context:
  adapter: context-pluss"
err1="$(specrelay::workflow::assert_role_context_valid "$p1" no-such-task executor 2>&1)"; rc1=$?
specrelay_test::assert_true "1: unknown adapter is rejected" \
  "$([ "$rc1" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "1: unknown-adapter error names role and adapter" \
  "$err1" "invalid executor context adapter 'context-pluss'"
specrelay_test::assert_contains "1: unknown-adapter error lists known adapters" \
  "$err1" "Known adapters:"
specrelay_test::assert_contains "1: unknown-adapter error names the config source" \
  "$err1" ".specrelay/config.yml"
specrelay_test::assert_contains "1: unknown-adapter error points at the contexts command" \
  "$err1" "specrelay contexts"

# =============================================================================
# 2 — discovery: the contexts command
# =============================================================================
p2="$(specrelay_test::mktemp_project)"
write_cfg "$p2" "context:
  adapter: fake
  required: false"

list2="$(cd "$p2" && "$SPECRELAY_BIN" contexts 2>&1 </dev/null)"; rc2=$?
specrelay_test::assert_eq "2: contexts exits 0 (non-interactive, stdin closed)" "0" "$rc2"
specrelay_test::assert_contains "2: contexts lists none" "$list2" "none"
specrelay_test::assert_contains "2: contexts lists fake" "$list2" "fake"
specrelay_test::assert_contains "2: contexts lists contextplus" "$list2" "contextplus"
specrelay_test::assert_contains "2: contexts marks adapters built-in" "$list2" "built-in"
specrelay_test::assert_contains "2: contexts shows this project's configured adapters" \
  "$list2" "executor: adapter=fake required=false"
specrelay_test::assert_not_contains "2: contexts output contains no ANSI escapes" \
  "$list2" "$(printf '\033')"

none2="$(cd "$p2" && "$SPECRELAY_BIN" contexts none 2>&1)"
specrelay_test::assert_contains "2: contexts none shows the description" \
  "$none2" "No external context preparation."
specrelay_test::assert_contains "2: contexts none reports availability" "$none2" "available"
specrelay_test::assert_contains "2: contexts none reports preflight capability" \
  "$none2" "preflight:        yes"
specrelay_test::assert_contains "2: contexts none reports no prepare capability" \
  "$none2" "prepare:          no"
specrelay_test::assert_contains "2: contexts none reports no network requirement" \
  "$none2" "network required: no"
specrelay_test::assert_contains "2: contexts none shows a copyable configuration snippet" \
  "$none2" "adapter: none"

fake2="$(cd "$p2" && "$SPECRELAY_BIN" contexts fake 2>&1)"
specrelay_test::assert_contains "2: contexts fake reports prepare capability" \
  "$fake2" "prepare:          yes"
specrelay_test::assert_contains "2: contexts fake reports its capability level honestly" \
  "$fake2" "prepared"

unavail2="$(cd "$p2" && SPECRELAY_FAKE_CONTEXT_AVAILABLE=0 "$SPECRELAY_BIN" contexts fake 2>&1)"
specrelay_test::assert_contains "2: an unavailable adapter is reported unavailable" \
  "$unavail2" "unavailable"
specrelay_test::assert_contains "2: an unavailable adapter reports its reason" \
  "$unavail2" "Reason:"
specrelay_test::assert_contains "2: an unavailable adapter is explicitly not invoked" \
  "$unavail2" "This adapter was not invoked."
specrelay_test::assert_not_contains "2: an unavailable adapter is never reported usable" \
  "$unavail2" "prepare:          yes"

err2="$(cd "$p2" && "$SPECRELAY_BIN" contexts nope 2>&1)"; rc2=$?
specrelay_test::assert_true "2: unknown adapter exits non-zero" \
  "$([ "$rc2" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "2: unknown adapter produces guidance" \
  "$err2" "Known adapters:"

# a configured-but-unknown adapter is flagged in the listing
write_cfg "$p2" "context:
  adapter: mystery"
list2b="$(cd "$p2" && "$SPECRELAY_BIN" contexts 2>&1)"
specrelay_test::assert_contains "2: a configured unknown adapter is marked not usable" \
  "$list2b" "UNKNOWN adapter"

# =============================================================================
# 3 — validation timing
# =============================================================================
# 3a — unknown executor adapter fails before EXECUTOR_RUNNING; never invoked.
p3="$(mk_run_project "context:
  adapter: context-pluss" 0015-badctx)"
out3="$(cd "$p3" && "$SPECRELAY_BIN" run docs/sdd/0015-badctx/spec.md 2>&1)"; rc3=$?
task3="$p3/.specrelay-runs/tasks/0015-badctx"
specrelay_test::assert_true "3a: run with an unknown adapter exits non-zero" \
  "$([ "$rc3" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "3a: the error names the invalid executor adapter" \
  "$out3" "invalid executor context adapter 'context-pluss'"
specrelay_test::assert_eq "3a: the task never entered EXECUTOR_RUNNING" \
  "READY_FOR_EXECUTOR" "$(specrelay::state::get "$task3/state.json" state)"
specrelay_test::assert_true "3a: the executor provider was never invoked" \
  "$([ ! -f "$task3/fake-executor-invocation.txt" ] && echo 0 || echo 1)"

# 3b — required executor preflight failure fails before claim and provider.
p3b="$(mk_run_project "context:
  adapter: fake
  required: true" 0015-reqpre)"
out3b="$(cd "$p3b" && SPECRELAY_FAKE_CONTEXT_PREFLIGHT=fail \
  "$SPECRELAY_BIN" run docs/sdd/0015-reqpre/spec.md 2>&1)"; rc3b=$?
task3b="$p3b/.specrelay-runs/tasks/0015-reqpre"
specrelay_test::assert_true "3b: required preflight failure exits non-zero" \
  "$([ "$rc3b" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_eq "3b: the task never entered EXECUTOR_RUNNING" \
  "READY_FOR_EXECUTOR" "$(specrelay::state::get "$task3b/state.json" state)"
specrelay_test::assert_true "3b: the executor provider was never invoked" \
  "$([ ! -f "$task3b/fake-executor-invocation.txt" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "3b: the refusal is explicit" "$out3b" "refusing"

# 3c — invalid reviewer context fails before REVIEWER_RUNNING; never invoked.
p3c="$(mk_run_project "context:
  executor:
    adapter: none
  reviewer:
    adapter: bogus-reviewer-adapter" 0015-badrev)"
task3c="$p3c/.specrelay-runs/tasks/0015-badrevtask"
mkdir -p "$task3c"
cat > "$task3c/state.json" <<'JSON'
{
  "state": "READY_FOR_REVIEW",
  "iteration": 1,
  "engine": "specrelay"
}
JSON
out3c="$(cd "$p3c" && "$SPECRELAY_BIN" resume 0015-badrevtask 2>&1)"; rc3c=$?
specrelay_test::assert_true "3c: resume with an invalid reviewer adapter exits non-zero" \
  "$([ "$rc3c" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "3c: the error names the invalid reviewer adapter" \
  "$out3c" "invalid reviewer context adapter 'bogus-reviewer-adapter'"
specrelay_test::assert_eq "3c: the task never entered REVIEWER_RUNNING" \
  "READY_FOR_REVIEW" "$(specrelay::state::get "$task3c/state.json" state)"
specrelay_test::assert_true "3c: the reviewer provider was never invoked" \
  "$([ ! -f "$task3c/fake-reviewer-invocation.txt" ] && echo 0 || echo 1)"

# 3d — required reviewer preflight failure fails before REVIEWER_RUNNING.
p3d="$(mk_run_project "context:
  adapter: fake
  required: true" 0015-revpre)"
task3d="$p3d/.specrelay-runs/tasks/0015-revpretask"
mkdir -p "$task3d"
cat > "$task3d/state.json" <<'JSON'
{
  "state": "READY_FOR_REVIEW",
  "iteration": 1,
  "engine": "specrelay"
}
JSON
out3d="$(cd "$p3d" && SPECRELAY_FAKE_CONTEXT_PREFLIGHT=fail \
  "$SPECRELAY_BIN" resume 0015-revpretask 2>&1)"; rc3d=$?
specrelay_test::assert_true "3d: required reviewer preflight failure exits non-zero" \
  "$([ "$rc3d" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_eq "3d: the task never entered REVIEWER_RUNNING" \
  "READY_FOR_REVIEW" "$(specrelay::state::get "$task3d/state.json" state)"
specrelay_test::assert_true "3d: the reviewer provider was never invoked" \
  "$([ ! -f "$task3d/fake-reviewer-invocation.txt" ] && echo 0 || echo 1)"

# =============================================================================
# 4 — optional policy: honest degradation
# =============================================================================
p4="$(mk_run_project "context:
  adapter: fake
  required: false" 0015-optional)"
out4="$(cd "$p4" && SPECRELAY_FAKE_CONTEXT_PREFLIGHT=fail \
  "$SPECRELAY_BIN" run docs/sdd/0015-optional/spec.md 2>&1)"; rc4=$?
task4="$p4/.specrelay-runs/tasks/0015-optional"
specrelay_test::assert_eq "4: optional context failure still reaches READY_FOR_HUMAN_REVIEW" "0" "$rc4"
specrelay_test::assert_contains "4: degradation is logged honestly" \
  "$out4" "continuing without external context because required=false"
specrelay_test::assert_eq "4: durable state records the degraded executor result" \
  "degraded" "$(ctx_state "$task4" executor status)"
specrelay_test::assert_eq "4: durable state records the degraded reviewer result" \
  "degraded" "$(ctx_state "$task4" reviewer status)"
specrelay_test::assert_contains "4: the executor provider WAS invoked (degraded, not blocked)" \
  "$(cat "$task4/fake-executor-invocation.txt")" "role=executor"
specrelay_test::assert_contains "4: the degraded executor received NO context handoff" \
  "$(cat "$task4/fake-executor-invocation.txt")" "context=none"
specrelay_test::assert_not_contains "4: logs never claim context preparation succeeded" \
  "$out4" "prepared"
specrelay_test::assert_contains "4: context evidence records the degraded status" \
  "$(cat "$task4/14-executor-context.json")" "\"status\": \"degraded\""

# =============================================================================
# 5 — required policy: blocking
# =============================================================================
# 5a — required preparation failure blocks before claim/provider.
p5="$(mk_run_project "context:
  adapter: fake
  required: true" 0015-reqprep)"
out5="$(cd "$p5" && SPECRELAY_FAKE_CONTEXT_PREPARE=fail \
  "$SPECRELAY_BIN" run docs/sdd/0015-reqprep/spec.md 2>&1)"; rc5=$?
task5="$p5/.specrelay-runs/tasks/0015-reqprep"
specrelay_test::assert_true "5a: required preparation failure exits non-zero" \
  "$([ "$rc5" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_eq "5a: the task never entered EXECUTOR_RUNNING" \
  "READY_FOR_EXECUTOR" "$(specrelay::state::get "$task5/state.json" state)"
specrelay_test::assert_true "5a: the executor provider was never invoked" \
  "$([ ! -f "$task5/fake-executor-invocation.txt" ] && echo 0 || echo 1)"
specrelay_test::assert_eq "5a: durable state records the failed context" \
  "failed" "$(ctx_state "$task5" executor status)"

# 5b — a missing required artifact blocks.
p5b="$(mk_run_project "context:
  adapter: fake
  required: true" 0015-missing)"
out5b="$(cd "$p5b" && SPECRELAY_FAKE_CONTEXT_ARTIFACT=missing \
  "$SPECRELAY_BIN" run docs/sdd/0015-missing/spec.md 2>&1)"; rc5b=$?
task5b="$p5b/.specrelay-runs/tasks/0015-missing"
specrelay_test::assert_true "5b: missing required artifact exits non-zero" \
  "$([ "$rc5b" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "5b: the error names the missing artifact" \
  "$out5b" "artifact missing or unreadable"
specrelay_test::assert_true "5b: the executor provider was never invoked" \
  "$([ ! -f "$task5b/fake-executor-invocation.txt" ] && echo 0 || echo 1)"

# 5c — provider independence: a Claude-configured executor is never invoked
# when its required fake context fails (no live Claude needed or touched).
p5c="$(mk_run_project "context:
  adapter: fake
  required: true" 0015-claude claude manual)"
out5c="$(cd "$p5c" && SPECRELAY_FAKE_CONTEXT_PREFLIGHT=fail \
  "$SPECRELAY_BIN" run docs/sdd/0015-claude/spec.md 2>&1)"; rc5c=$?
specrelay_test::assert_true "5c: required context failure blocks a claude executor" \
  "$([ "$rc5c" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_not_contains "5c: the claude provider was never launched" \
  "$out5c" "running provider 'claude'"

# =============================================================================
# 6 — preparation, normalized handoff, executor/reviewer isolation
# =============================================================================
p6="$(mk_run_project "context:
  adapter: fake
  required: true" 0015-prep)"
out6="$(cd "$p6" && FAKE_SECRET_TOKEN=super-secret-value-xyz \
  "$SPECRELAY_BIN" run docs/sdd/0015-prep/spec.md 2>&1)"; rc6=$?
task6="$p6/.specrelay-runs/tasks/0015-prep"
specrelay_test::assert_eq "6: prepared-context run reaches READY_FOR_HUMAN_REVIEW" "0" "$rc6"
specrelay_test::assert_contains "6: the executor artifact was prepared role-specifically" \
  "$(cat "$task6/fake-context-executor.txt")" "role=executor"
specrelay_test::assert_contains "6: the reviewer artifact was prepared independently" \
  "$(cat "$task6/fake-context-reviewer.txt")" "role=reviewer"
exec_inv6="$(cat "$task6/fake-executor-invocation.txt")"
rev_inv6="$(cat "$task6/fake-reviewer-invocation.txt")"
specrelay_test::assert_contains "6: the normalized handoff reached the executor invocation" \
  "$exec_inv6" "context=file:.specrelay-runs/tasks/0015-prep/fake-context-executor.txt"
specrelay_test::assert_contains "6: the normalized handoff reached the reviewer invocation" \
  "$rev_inv6" "context=file:.specrelay-runs/tasks/0015-prep/fake-context-reviewer.txt"
specrelay_test::assert_not_contains "6: executor context never leaked into the reviewer" \
  "$rev_inv6" "fake-context-executor"
specrelay_test::assert_not_contains "6: reviewer context never leaked into the executor" \
  "$exec_inv6" "fake-context-reviewer"

# different executor and reviewer adapters in the same run
p6b="$(mk_run_project "context:
  executor:
    adapter: fake
    required: true
  reviewer:
    adapter: none" 0015-mixed)"
out6b="$(cd "$p6b" && "$SPECRELAY_BIN" run docs/sdd/0015-mixed/spec.md 2>&1)"; rc6b=$?
task6b="$p6b/.specrelay-runs/tasks/0015-mixed"
specrelay_test::assert_eq "6: mixed-adapter run reaches READY_FOR_HUMAN_REVIEW" "0" "$rc6b"
specrelay_test::assert_contains "6: the fake-adapter executor received its handoff" \
  "$(cat "$task6b/fake-executor-invocation.txt")" "context=file:"
specrelay_test::assert_contains "6: the none-adapter reviewer received no handoff" \
  "$(cat "$task6b/fake-reviewer-invocation.txt")" "context=none"

# =============================================================================
# 7 — durable state
# =============================================================================
specrelay_test::assert_eq "7: effective executor adapter is captured" \
  "fake" "$(ctx_state "$task6" executor adapter)"
specrelay_test::assert_eq "7: the executor required flag is captured" \
  "true" "$(ctx_state "$task6" executor required)"
specrelay_test::assert_eq "7: the executor preparation status is captured" \
  "prepared" "$(ctx_state "$task6" executor status)"
specrelay_test::assert_eq "7: the executor artifact kind is captured" \
  "file" "$(ctx_state "$task6" executor artifact_kind)"
specrelay_test::assert_eq "7: the executor artifact reference is project-relative" \
  ".specrelay-runs/tasks/0015-prep/fake-context-executor.txt" "$(ctx_state "$task6" executor artifact_reference)"
specrelay_test::assert_eq "7: the executor freshness report is captured" \
  "fresh" "$(ctx_state "$task6" executor freshness)"
specrelay_test::assert_eq "7: the reviewer preparation is captured distinctly" \
  ".specrelay-runs/tasks/0015-prep/fake-context-reviewer.txt" "$(ctx_state "$task6" reviewer artifact_reference)"
specrelay_test::assert_contains "7: executor context evidence file exists with metadata" \
  "$(cat "$task6/14-executor-context.json")" "\"role\": \"executor\""
specrelay_test::assert_contains "7: reviewer context evidence file is distinct" \
  "$(cat "$task6/17-reviewer-context.json")" "\"role\": \"reviewer\""
specrelay_test::assert_not_contains "7: no secrets in durable state" \
  "$(cat "$task6/state.json")" "super-secret-value-xyz"
specrelay_test::assert_not_contains "7: no secrets in context evidence" \
  "$(cat "$task6/14-executor-context.json" "$task6/17-reviewer-context.json")" "super-secret-value-xyz"

# old task state (no context metadata) remains readable and displayable
p7="$(specrelay_test::mktemp_project)"
write_cfg "$p7" ""
old_task="$p7/.specrelay-runs/tasks/0009-old"
mkdir -p "$old_task"
cat > "$old_task/state.json" <<'JSON'
{
  "state": "READY_FOR_HUMAN_REVIEW",
  "roles_effective": {
    "executor": {"provider": "fake", "model": "provider-default", "agent": "none"},
    "reviewer": {"provider": "fake", "model": "provider-default", "agent": "none"}
  }
}
JSON
show7="$(cd "$p7" && "$SPECRELAY_BIN" task show 0009-old 2>&1)"; rc7=$?
specrelay_test::assert_eq "7: an old task without context metadata displays without errors" "0" "$rc7"
specrelay_test::assert_contains "7: old task context status reports not recorded" \
  "$show7" "Executor context status: (not recorded"

# =============================================================================
# 8 — resume
# =============================================================================
# 8a — a task retains its captured adapter after the project config changes.
p8="$(mk_run_project "context:
  adapter: fake
  required: false" 0015-resume)"
task8="$p8/.specrelay-runs/tasks/0015-resume"
plan8="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")/rev.txt"
printf 'exit=1\n' > "$plan8"
(cd "$p8" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan8" \
  "$SPECRELAY_BIN" run docs/sdd/0015-resume/spec.md >/dev/null 2>&1)
specrelay_test::assert_eq "8a: round 1 captured the fake adapter" \
  "fake" "$(ctx_state "$task8" reviewer adapter)"
# the project now switches its context configuration to none...
write_cfg "$p8" "context:
  adapter: none"
out8="$(cd "$p8" && "$SPECRELAY_BIN" resume 0015-resume 2>&1)"; rc8=$?
specrelay_test::assert_eq "8a: resume reaches READY_FOR_HUMAN_REVIEW" "0" "$rc8"
specrelay_test::assert_contains "8a: the resumed reviewer still used the CAPTURED fake adapter" \
  "$(cat "$task8/fake-reviewer-invocation.txt")" "context=file:.specrelay-runs/tasks/0015-resume/fake-context-reviewer.txt"

# 8b — a reusable artifact is reused across rounds (executor round 2).
p8b="$(mk_run_project "context:
  adapter: fake
  required: true" 0015-reuse)"
plan8b="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")/rev.txt"
printf 'decision=request_changes\ndecision=accept\n' > "$plan8b"
out8b="$(cd "$p8b" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan8b" \
  "$SPECRELAY_BIN" run docs/sdd/0015-reuse/spec.md 2>&1)"; rc8b=$?
specrelay_test::assert_eq "8b: multi-round run reaches READY_FOR_HUMAN_REVIEW" "0" "$rc8b"
specrelay_test::assert_contains "8b: round 2 REUSED the prepared artifact (adapter permits)" \
  "$out8b" "reusing previously prepared artifact"

# 8c — the artifact is NOT reused when the adapter forbids reuse.
p8c="$(mk_run_project "context:
  adapter: fake
  required: true" 0015-noreuse)"
plan8c="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")/rev.txt"
printf 'decision=request_changes\ndecision=accept\n' > "$plan8c"
out8c="$(cd "$p8c" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan8c" SPECRELAY_FAKE_CONTEXT_REUSABLE=0 \
  "$SPECRELAY_BIN" run docs/sdd/0015-noreuse/spec.md 2>&1)"; rc8c=$?
specrelay_test::assert_eq "8c: no-reuse run still completes" "0" "$rc8c"
specrelay_test::assert_contains "8c: the adapter's reprepare decision is explicit" \
  "$out8c" "re-preparing"
specrelay_test::assert_not_contains "8c: nothing was silently reused" \
  "$out8c" "reusing previously prepared artifact"

# 8d — a missing artifact on resume triggers the documented reprepare.
p8d="$(mk_run_project "context:
  adapter: fake
  required: true" 0015-gone)"
task8d="$p8d/.specrelay-runs/tasks/0015-gone"
plan8d="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")/rev.txt"
printf 'exit=1\n' > "$plan8d"
(cd "$p8d" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan8d" \
  "$SPECRELAY_BIN" run docs/sdd/0015-gone/spec.md >/dev/null 2>&1)
rm -f "$task8d/fake-context-reviewer.txt"
out8d="$(cd "$p8d" && "$SPECRELAY_BIN" resume 0015-gone 2>&1)"; rc8d=$?
specrelay_test::assert_eq "8d: resume after artifact loss completes by re-preparing" "0" "$rc8d"
specrelay_test::assert_contains "8d: the missing artifact triggered an explicit reprepare" \
  "$out8d" "re-preparing"

# 8e — a stale artifact with mandatory freshness blocks a required role.
p8e="$(mk_run_project "context:
  adapter: fake
  required: true" 0015-stale)"
task8e="$p8e/.specrelay-runs/tasks/0015-stale"
plan8e="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")/rev.txt"
printf 'exit=1\n' > "$plan8e"
(cd "$p8e" && SPECRELAY_FAKE_REVIEWER_PLAN="$plan8e" \
  "$SPECRELAY_BIN" run docs/sdd/0015-stale/spec.md >/dev/null 2>&1)
out8e="$(cd "$p8e" && SPECRELAY_FAKE_CONTEXT_FRESHNESS=stale SPECRELAY_FAKE_CONTEXT_FRESHNESS_MANDATORY=1 \
  "$SPECRELAY_BIN" resume 0015-stale 2>&1)"; rc8e=$?
specrelay_test::assert_true "8e: a stale artifact blocks the required reviewer" \
  "$([ "$rc8e" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "8e: the staleness block is explicit" "$out8e" "stale"
# ...while WITHOUT mandatory freshness, stale context warns and continues.
out8e2="$(cd "$p8e" && SPECRELAY_FAKE_CONTEXT_FRESHNESS=stale \
  "$SPECRELAY_BIN" resume 0015-stale 2>&1)"; rc8e2=$?
specrelay_test::assert_eq "8e: stale context without a mandatory policy continues" "0" "$rc8e2"
specrelay_test::assert_contains "8e: the stale continuation is a warning, not silence" \
  "$out8e2" "STALE"

# =============================================================================
# 9 — doctor and task show
# =============================================================================
p9="$(specrelay_test::mktemp_project)"
mkdir -p "$p9/docs/sdd"
write_cfg "$p9" "context:
  adapter: fake
  required: false"
out9="$(cd "$p9" && SPECRELAY_PROVIDER_OPTIONAL=1 "$SPECRELAY_BIN" doctor 2>&1)"; rc9=$?
specrelay_test::assert_eq "9: doctor passes with an available optional adapter" "0" "$rc9"
specrelay_test::assert_contains "9: doctor reports the executor adapter honestly" \
  "$out9" "Executor context: adapter=fake required=false availability=available level=prepared"
specrelay_test::assert_contains "9: doctor reports the network requirement" \
  "$out9" "network=no"

out9b="$(cd "$p9" && SPECRELAY_PROVIDER_OPTIONAL=1 SPECRELAY_FAKE_CONTEXT_AVAILABLE=0 \
  "$SPECRELAY_BIN" doctor 2>&1)"; rc9b=$?
specrelay_test::assert_eq "9: an unavailable OPTIONAL adapter is an advisory warning" "0" "$rc9b"
specrelay_test::assert_contains "9: the optional unavailability is reported" \
  "$out9b" "availability=unavailable"

write_cfg "$p9" "context:
  adapter: fake
  required: true"
out9c="$(cd "$p9" && SPECRELAY_PROVIDER_OPTIONAL=1 SPECRELAY_FAKE_CONTEXT_AVAILABLE=0 \
  "$SPECRELAY_BIN" doctor 2>&1)"; rc9c=$?
specrelay_test::assert_true "9: an unavailable REQUIRED adapter fails doctor" \
  "$([ "$rc9c" -ne 0 ] && echo 0 || echo 1)"

write_cfg "$p9" "context:
  adapter: mystery"
out9d="$(cd "$p9" && SPECRELAY_PROVIDER_OPTIONAL=1 "$SPECRELAY_BIN" doctor 2>&1)"; rc9d=$?
specrelay_test::assert_true "9: an unknown configured adapter fails doctor" \
  "$([ "$rc9d" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "9: doctor names the unknown adapter" \
  "$out9d" "unknown adapter 'mystery'"

# task show uses the durable context metadata captured in section 6
show9="$(cd "$p6" && "$SPECRELAY_BIN" task show 0015-prep 2>&1)"
specrelay_test::assert_contains "9: task show reports the captured executor adapter" \
  "$show9" "Executor context adapter: fake"
specrelay_test::assert_contains "9: task show reports the captured executor required flag" \
  "$show9" "Executor context required: true"
specrelay_test::assert_contains "9: task show reports the executor context status" \
  "$show9" "Executor context status: prepared"
specrelay_test::assert_contains "9: task show reports the reviewer context distinctly" \
  "$show9" "Reviewer context status: prepared"
specrelay_test::assert_contains "9: task show reports the executor artifact" \
  "$show9" "Executor context artifact: file:.specrelay-runs/tasks/0015-prep/fake-context-executor.txt"

# =============================================================================
# 10 — compatibility: adapter 'none' preserves current behavior
# =============================================================================
p10="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$p10/docs/sdd/0015-none"
echo "# none spec" > "$p10/docs/sdd/0015-none/spec.md"
out10="$(cd "$p10" && "$SPECRELAY_BIN" run docs/sdd/0015-none/spec.md 2>&1)"; rc10=$?
task10="$p10/.specrelay-runs/tasks/0015-none"
specrelay_test::assert_eq "10: an adapter-none run reaches READY_FOR_HUMAN_REVIEW" "0" "$rc10"
specrelay_test::assert_contains "10: the none adapter announces no external context" \
  "$out10" "context: adapter 'none'; no external context requested"
specrelay_test::assert_contains "10: the executor received a none handoff" \
  "$(cat "$task10/fake-executor-invocation.txt")" "context=none"
specrelay_test::assert_true "10: no context evidence file implies external context" \
  "$([ ! -f "$task10/14-executor-context.json" ] && echo 0 || echo 1)"
specrelay_test::assert_eq "10: durable state records the none adapter honestly" \
  "none" "$(ctx_state "$task10" executor adapter)"

specrelay_test::summary
exit $?
