#!/usr/bin/env bash
# dogfood_orchestration_test.sh — SDD 0085B, section 4 + test 8.6: dogfood
# orchestration does NOT launch untracked background nested tasks. The safe
# model (M1: foreground, synchronous, operator-driven) is documented, the
# prohibited pattern is forbidden, and the fresh scenarios are SpecRelay-native
# with non-colliding task ids.
#   tools/specrelay/test/dogfood_orchestration_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

HOST_ROOT="$SPECRELAY_ROOT"
while [ -n "$HOST_ROOT" ] && [ ! -d "$HOST_ROOT/.git" ]; do
  parent="$(dirname "$HOST_ROOT")"
  [ "$parent" = "$HOST_ROOT" ] && HOST_ROOT="" && break
  HOST_ROOT="$parent"
done
specrelay_test::assert_true "host repository root was discovered" "$([ -n "$HOST_ROOT" ] && echo 0 || echo 1)"

DOC="$HOST_ROOT/tools/specrelay/docs/dogfood-orchestration.md"

# --- 8.6: the orchestration model is documented -----------------------------
specrelay_test::assert_true "8.6: dogfood-orchestration.md exists" "$([ -f "$DOC" ] && echo 0 || echo 1)"
doc="$(cat "$DOC")"
specrelay_test::assert_contains "8.6: documents the prohibited background pattern" "$doc" "prohibited pattern"
specrelay_test::assert_contains "8.6: forbids fire-and-forget background launch" "$doc" "fire-and-forget"
specrelay_test::assert_contains "8.6: adopts foreground/synchronous model M1" "$doc" "synchronously in the foreground"
specrelay_test::assert_contains "8.6: forbids fake-provider evidence" "$doc" "be presented as satisfying a real-provider"

# --- 8.6: the ENGINE ORCHESTRATOR itself never fire-and-forgets a run/provider
# workflow.sh composes executor/reviewer synchronously; it must not launch a
# nested `specrelay run`, an executor, or a reviewer as a detached background
# job (no trailing '&', nohup, or disown on those launches).
wf="$(cat "$HOST_ROOT/tools/specrelay/lib/specrelay/workflow.sh")"
bad_bg="$(printf '%s\n' "$wf" | grep -nE '(specrelay_run|specrelay run|executor_iteration|reviewer_iteration|provider::run)[^&]*&[[:space:]]*$' || true)"
specrelay_test::assert_eq "8.6: workflow.sh never launches a run/provider as a background job" "" "$bad_bg"
nohup_hits="$(printf '%s\n' "$wf" | grep -nE 'nohup|disown' || true)"
specrelay_test::assert_eq "8.6: workflow.sh uses no nohup/disown detachment" "" "$nohup_hits"

# --- 8.6: fresh scenarios are SpecRelay-native and use non-colliding ids -----
for id in 9201a-scenario-a-troubleshooting-doc 9202b-scenario-b-operator-recovery-doc; do
  spec="$HOST_ROOT/docs/sdd/$id/spec.md"
  specrelay_test::assert_true "8.6: scenario spec exists ($id)" "$([ -f "$spec" ] && echo 0 || echo 1)"
done
# The fresh ids must NOT reuse the bare historical 9101/9102 ids (section 5.3).
specrelay_test::assert_true "8.6: fresh ids do not reuse the bare 9101 residue id" "$([ ! -d "$HOST_ROOT/docs/sdd/9101-scenario-a-troubleshooting-doc" ] && echo 0 || echo 1)"

# --- 8.6: a real SpecRelay-created scenario task is genuinely tracked --------
# Prove the safe path produces a tracked task (task id + state.json with
# engine=specrelay + a lock), rather than an untracked fire-and-forget child.
proj="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj/docs/sdd/9201a-scenario-a-troubleshooting-doc"
printf '# Fixture scenario spec\n' > "$proj/docs/sdd/9201a-scenario-a-troubleshooting-doc/spec.md"
(cd "$proj" && "$SPECRELAY_ROOT/bin/specrelay" task create docs/sdd/9201a-scenario-a-troubleshooting-doc/spec.md >/dev/null 2>&1)
tracked_state="$proj/.ai-runs/tasks/9201a-scenario-a-troubleshooting-doc/state.json"
specrelay_test::assert_true "8.6: a launched scenario task has a tracked state.json" "$([ -f "$tracked_state" ] && echo 0 || echo 1)"
engine_field="$(grep -o '"engine": *"[a-z]*"' "$tracked_state" 2>/dev/null || true)"
specrelay_test::assert_contains "8.6: the tracked scenario task is engine-owned by specrelay" "$engine_field" "specrelay"

specrelay_test::summary
exit $?
