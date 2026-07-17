#!/usr/bin/env bash
# executor_finalization_test.sh — spec 0029, "Engine-Owned Executor
# Finalization and Supervised Verification", section 32.1 required tests
# (the subset exercisable deterministically with the fake provider).
#
# Covers (spec 0029, section 32.1 naming):
#   A  missing 03-executor-log.md -> engine generates an honest log with
#      provenance zones.
#   B  missing 07-tests.txt -> engine runs/reads actual verification and
#      generates it.
#   C  provider exits 0 with a REAL, long-lived process-group survivor still
#      alive -> no submit; the survivor is terminated by process group;
#      PROVIDER_EXITED_WITH_PENDING_WORK; survivor count recorded.
#   F  required verification FAILS -> no submit; VERIFICATION_FAILED.
#   G  required verification BLOCKED (a spec-0026 multi-service dependency
#      chain: a required check FAILS and a required dependent check is
#      cascaded to BLOCKED_BY_DEPENDENCY) -> no submit; VERIFICATION_BLOCKED;
#      the blocked prerequisite is reported.
#   H  missing 08-executor-summary.md -> the sandboxed finalizer runs and
#      produces a candidate; the engine adopts only the validated summary.
#   I  a finalizer that tries to edit source -> the sandbox + post-call diff
#      check reject it; no repository change is ever adopted.
#   J  a finalizer that fails -> recoverable, explicit FINALIZATION_FAILED.
#   V  the full standalone suite (this project's own `echo ok` legacy
#      command, exercised through the real spec-0026 engine) runs once at
#      its authoritative placement and is recorded honestly.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

specrelay_test::run() {
  local proj="$1" spec="$2"
  shift 2
  (cd "$proj" && "$SPECRELAY_BIN" run "$spec" "$@")
}

# =============================================================================
# Scenario A — missing 03-executor-log.md is engine-generated with provenance
# zones (Engine-Observed Facts / Reported by the AI / Unavailable).
# =============================================================================
proj_a="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_a/docs/sdd/0001-fin-a"
echo "# fin a spec" > "$proj_a/docs/sdd/0001-fin-a/spec.md"
plan_a="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-fin-plan.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$plan_a")
printf 'missing_artifact=03-executor-log.md\n' > "$plan_a/exec-plan.txt"
out_a="$(SPECRELAY_FAKE_EXECUTOR_PLAN="$plan_a/exec-plan.txt" \
  specrelay_test::run "$proj_a" "docs/sdd/0001-fin-a/spec.md" 2>&1)"
specrelay_test::assert_eq "A: run exits 0" "0" "$?"
specrelay_test::assert_contains "A: reaches READY_FOR_HUMAN_REVIEW" "$out_a" "READY_FOR_HUMAN_REVIEW"
task_dir_a="$proj_a/.specrelay-runs/tasks/0001-fin-a"
log_a="$(cat "$task_dir_a/03-executor-log.md" 2>/dev/null)"
specrelay_test::assert_contains "A: engine-generated log has the Engine-Observed Facts zone" \
  "$log_a" "## Engine-Observed Facts"
specrelay_test::assert_contains "A: engine-generated log has the Reported-by-the-AI zone" \
  "$log_a" "## Reported by the AI (unverified)"
specrelay_test::assert_contains "A: finalization record shows engine-generated log provenance" \
  "$(cat "$task_dir_a/30-executor-finalization.json" 2>/dev/null)" '"log": "engine-generated"'

# =============================================================================
# Scenario B — missing 07-tests.txt: the engine runs the configured legacy
# full-suite check (`echo ok`, this fixture's `validation.full_test_command`)
# and generates 07-tests.txt from the real 27-verification-summary.json.
# =============================================================================
proj_b="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_b/docs/sdd/0002-fin-b"
echo "# fin b spec" > "$proj_b/docs/sdd/0002-fin-b/spec.md"
plan_b="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-fin-plan.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$plan_b")
printf 'missing_artifact=07-tests.txt\n' > "$plan_b/exec-plan.txt"
out_b="$(SPECRELAY_FAKE_EXECUTOR_PLAN="$plan_b/exec-plan.txt" \
  specrelay_test::run "$proj_b" "docs/sdd/0002-fin-b/spec.md" 2>&1)"
specrelay_test::assert_eq "B: run exits 0" "0" "$?"
task_dir_b="$proj_b/.specrelay-runs/tasks/0002-fin-b"
specrelay_test::assert_true "B: 27-verification-summary.json was actually written" \
  "$([ -s "$task_dir_b/27-verification-summary.json" ] && echo 0 || echo 1)"
tests_b="$(cat "$task_dir_b/07-tests.txt" 2>/dev/null)"
specrelay_test::assert_contains "B: 07-tests.txt reports the real engine-owned verification status" \
  "$tests_b" "Engine-owned verification overall status:"
specrelay_test::assert_contains "B: finalization record shows engine-generated tests provenance" \
  "$(cat "$task_dir_b/30-executor-finalization.json" 2>/dev/null)" '"tests": "engine-generated"'

# =============================================================================
# Scenario C — the flagship spec 0029 failure class (AC-09): the provider
# exits 0 while a REAL, long-lived child it spawned is still alive in its
# process group (a required verification job it illicitly backgrounded). The
# round must NOT submit, the survivor must be terminated by process group
# (TERM -> grace -> KILL), and the outcome/survivor count must be recorded.
# =============================================================================
proj_c="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_c/docs/sdd/0008-fin-c"
echo "# fin c spec" > "$proj_c/docs/sdd/0008-fin-c/spec.md"
plan_c="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-fin-plan.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$plan_c")
printf 'survivor=1\n' > "$plan_c/exec-plan.txt"
out_c="$(SPECRELAY_FAKE_EXECUTOR_PLAN="$plan_c/exec-plan.txt" \
  SPECRELAY_FAKE_SURVIVOR_SLEEP=8171 \
  specrelay_test::run "$proj_c" "docs/sdd/0008-fin-c/spec.md" 2>&1)"
rc_c=$?
specrelay_test::assert_true "C: run exits non-zero (no submit)" "$([ "$rc_c" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "C: names PROVIDER_EXITED_WITH_PENDING_WORK" "$out_c" "PROVIDER_EXITED_WITH_PENDING_WORK"
specrelay_test::assert_contains "C: reports the survivor was terminated by process group" "$out_c" "terminated by group"
task_dir_c="$proj_c/.specrelay-runs/tasks/0008-fin-c"
specrelay_test::assert_contains "C: task remains EXECUTOR_RUNNING (recoverable, not submitted)" \
  "$(cat "$task_dir_c/state.json")" "EXECUTOR_RUNNING"
fin_c="$(cat "$task_dir_c/30-executor-finalization.json" 2>/dev/null)"
specrelay_test::assert_contains "C: finalization outcome is PROVIDER_EXITED_WITH_PENDING_WORK" \
  "$fin_c" '"outcome": "PROVIDER_EXITED_WITH_PENDING_WORK"'
specrelay_test::assert_contains "C: survivor count is recorded (1 terminated child)" \
  "$fin_c" '"surviving_children_terminated": 1'
specrelay_test::assert_true "C: the real OS survivor process was actually terminated, not merely reported" \
  "$(pgrep -f "sleep 8171" >/dev/null 2>&1 && echo 1 || echo 0)"

# =============================================================================
# Scenario AE — portable supervision fallback (spec 0029, section 22.1,
# AC-12): with process-group primitives UNAVAILABLE (simulated via the
# SPECRELAY_PROC_SUPERVISOR_PY test seam), required verification still runs
# SYNCHRONOUSLY and the round still completes; survivor detection is honestly
# reported `not_verifiable` (never fabricated as a clean "0"); this is the
# honest degraded-FOREGROUND fallback, not `executor_finalization.mode:
# degraded-legacy` (which stays "enabled" and unreported as DEGRADED).
# =============================================================================
proj_ae="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_ae/docs/sdd/0013-fin-ae"
echo "# fin ae spec" > "$proj_ae/docs/sdd/0013-fin-ae/spec.md"
out_ae="$(SPECRELAY_PROC_SUPERVISOR_PY="$SPECRELAY_ROOT/test/fixtures/proc-supervisor-unavailable-stub.py" \
  specrelay_test::run "$proj_ae" "docs/sdd/0013-fin-ae/spec.md" 2>&1)"
rc_ae=$?
specrelay_test::assert_eq "AE: run exits 0 (fallback never blocks a genuinely complete round)" "0" "$rc_ae"
specrelay_test::assert_contains "AE: reaches READY_FOR_HUMAN_REVIEW" "$out_ae" "READY_FOR_HUMAN_REVIEW"
task_dir_ae="$proj_ae/.specrelay-runs/tasks/0013-fin-ae"
specrelay_test::assert_true "AE: required verification still actually ran (27-verification-summary.json written)" \
  "$([ -s "$task_dir_ae/27-verification-summary.json" ] && echo 0 || echo 1)"
fin_ae="$(cat "$task_dir_ae/30-executor-finalization.json" 2>/dev/null)"
specrelay_test::assert_contains "AE: supervision honestly reported as the degraded-foreground fallback (spec 0029 §22, survivors not verifiable)" \
  "$fin_ae" '"supervision": "degraded-foreground"'
specrelay_test::assert_contains "AE: mode remains enabled (this is the foreground fallback, not degraded-legacy)" \
  "$fin_ae" '"mode": "enabled"'
specrelay_test::assert_not_contains "AE: not reported as DEGRADED" "$out_ae" "DEGRADED"

# =============================================================================
# Scenario F — required verification FAILS -> no submit, VERIFICATION_FAILED,
# task remains EXECUTOR_RUNNING.
# =============================================================================
proj_f="$(specrelay_test::mktemp_specrelay_project)"
sed -i.bak 's/full_test_command: "echo ok"/full_test_command: "false"/' "$proj_f/.specrelay/config.yml"
rm -f "$proj_f/.specrelay/config.yml.bak"
mkdir -p "$proj_f/docs/sdd/0003-fin-f"
echo "# fin f spec" > "$proj_f/docs/sdd/0003-fin-f/spec.md"
(cd "$proj_f" && git add -A && git commit -q -m "configure a failing full-suite command")
out_f="$(specrelay_test::run "$proj_f" "docs/sdd/0003-fin-f/spec.md" 2>&1)"
rc_f=$?
specrelay_test::assert_true "F: run exits non-zero" "$([ "$rc_f" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "F: names VERIFICATION_FAILED" "$out_f" "VERIFICATION_FAILED"
task_dir_f="$proj_f/.specrelay-runs/tasks/0003-fin-f"
specrelay_test::assert_contains "F: task remains EXECUTOR_RUNNING" \
  "$(cat "$task_dir_f/state.json")" "EXECUTOR_RUNNING"
specrelay_test::assert_contains "F: finalization outcome recorded as VERIFICATION_FAILED" \
  "$(cat "$task_dir_f/30-executor-finalization.json" 2>/dev/null)" '"outcome": "VERIFICATION_FAILED"'

# =============================================================================
# Scenario G — required verification BLOCKED (spec 0026 multi-service
# dependency chain): a required check FAILS and a required dependent check
# cascades to BLOCKED_BY_DEPENDENCY -> overall BLOCKED -> no submit,
# VERIFICATION_BLOCKED, with the blocked prerequisite reported.
# =============================================================================
FIXTURE_G="$SPECRELAY_ROOT/test/fixtures/verification-fixture.sh"
proj_g="$(specrelay_test::mktemp_specrelay_project)"
cat > "$proj_g/.specrelay/config.yml" <<YAML
version: 1
project:
  name: Fixture Project
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
context:
  adapter: none
  required: false
verification:
  defaults:
    level: full
  services:
    - name: backend
      checks:
        - name: unit
          command: "$FIXTURE_G --exit 1"
          required: true
          levels: [full]
        - name: integration
          command: "$FIXTURE_G --exit 0"
          required: true
          levels: [full]
          depends_on: [backend.unit]
policy:
  human_final_review_required: true
YAML
mkdir -p "$proj_g/docs/sdd/0012-fin-g"
echo "# fin g spec" > "$proj_g/docs/sdd/0012-fin-g/spec.md"
(cd "$proj_g" && git add -A && git commit -q -m "configure a BLOCKED-prerequisite verification chain")
out_g="$(specrelay_test::run "$proj_g" "docs/sdd/0012-fin-g/spec.md" 2>&1)"
rc_g=$?
specrelay_test::assert_true "G: run exits non-zero (no submit)" "$([ "$rc_g" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "G: names VERIFICATION_BLOCKED" "$out_g" "VERIFICATION_BLOCKED"
task_dir_g="$proj_g/.specrelay-runs/tasks/0012-fin-g"
specrelay_test::assert_contains "G: task remains EXECUTOR_RUNNING" \
  "$(cat "$task_dir_g/state.json")" "EXECUTOR_RUNNING"
specrelay_test::assert_contains "G: finalization outcome recorded as VERIFICATION_BLOCKED" \
  "$(cat "$task_dir_g/30-executor-finalization.json" 2>/dev/null)" '"outcome": "VERIFICATION_BLOCKED"'
verif_summary_g="$(cat "$task_dir_g/27-verification-summary.json" 2>/dev/null)"
specrelay_test::assert_contains "G: overall verification status is BLOCKED" \
  "$verif_summary_g" '"overall_status": "BLOCKED"'
specrelay_test::assert_contains "G: the failed prerequisite (backend.unit) is reported" \
  "$verif_summary_g" '"identity": "backend.unit"'
specrelay_test::assert_contains "G: the cascaded-blocked dependent (backend.integration) is reported" \
  "$verif_summary_g" '"identity": "backend.integration"'
specrelay_test::assert_contains "G: the dependent is explicitly recorded BLOCKED_BY_DEPENDENCY" \
  "$verif_summary_g" '"status": "BLOCKED_BY_DEPENDENCY"'
blocked_by_g="$(printf '%s' "$verif_summary_g" | python3 -c '
import json, sys
d = json.load(sys.stdin)
chk = next(c for c in d["checks"] if c["identity"] == "backend.integration")
print(",".join(chk["blocked_by"]))
' 2>/dev/null)"
specrelay_test::assert_eq "G: the dependent names its blocking prerequisite" "backend.unit" "$blocked_by_g"

# =============================================================================
# Scenario H — missing 08-executor-summary.md: the sandboxed finalizer runs
# and produces a candidate; the engine adopts only the validated summary.
# =============================================================================
proj_h="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_h/docs/sdd/0004-fin-h"
echo "# fin h spec" > "$proj_h/docs/sdd/0004-fin-h/spec.md"
plan_h="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-fin-plan.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$plan_h")
printf 'missing_artifact=08-executor-summary.md\n' > "$plan_h/exec-plan.txt"
out_h="$(SPECRELAY_FAKE_EXECUTOR_PLAN="$plan_h/exec-plan.txt" \
  specrelay_test::run "$proj_h" "docs/sdd/0004-fin-h/spec.md" 2>&1)"
specrelay_test::assert_eq "H: run exits 0" "0" "$?"
task_dir_h="$proj_h/.specrelay-runs/tasks/0004-fin-h"
summary_h="$(cat "$task_dir_h/08-executor-summary.md" 2>/dev/null)"
specrelay_test::assert_contains "H: adopted summary came from the finalizer" "$summary_h" "Fake finalizer candidate summary"
specrelay_test::assert_contains "H: adopted summary has the engine-appended verification appendix" \
  "$summary_h" "## Engine-Observed Verification"
specrelay_test::assert_contains "H: finalization record shows finalizer summary provenance" \
  "$(cat "$task_dir_h/30-executor-finalization.json" 2>/dev/null)" '"summary": "finalizer"'

# =============================================================================
# Scenario I — a finalizer that tries to edit source: the sandbox + post-call
# diff check reject it; no repository change is ever adopted; the round is
# recoverable (FINALIZATION_FAILED), not silently accepted.
# =============================================================================
proj_i="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_i/docs/sdd/0005-fin-i"
echo "# fin i spec" > "$proj_i/docs/sdd/0005-fin-i/spec.md"
plan_i="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-fin-plan.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$plan_i")
printf 'missing_artifact=08-executor-summary.md\n' > "$plan_i/exec-plan.txt"
out_i="$(SPECRELAY_FAKE_EXECUTOR_PLAN="$plan_i/exec-plan.txt" \
  SPECRELAY_FAKE_FINALIZER_SCENARIO=finalizer_edits_source \
  SPECRELAY_FAKE_FINALIZER_REPO_ROOT="$proj_i" \
  specrelay_test::run "$proj_i" "docs/sdd/0005-fin-i/spec.md" 2>&1)"
rc_i=$?
specrelay_test::assert_true "I: run exits non-zero" "$([ "$rc_i" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "I: names FINALIZATION_FAILED" "$out_i" "FINALIZATION_FAILED"
specrelay_test::assert_true "I: the rogue repo-root file was never adopted into the task's own tree" \
  "$([ ! -f "$proj_i/.specrelay-runs/tasks/0005-fin-i/specrelay-fake-finalizer-rogue.txt" ] && echo 0 || echo 1)"
task_dir_i="$proj_i/.specrelay-runs/tasks/0005-fin-i"
specrelay_test::assert_contains "I: task remains EXECUTOR_RUNNING (recoverable)" \
  "$(cat "$task_dir_i/state.json")" "EXECUTOR_RUNNING"
rm -f "$proj_i/specrelay-fake-finalizer-rogue.txt"

# =============================================================================
# Scenario J — a finalizer that fails outright: recoverable, explicit
# FINALIZATION_FAILED, no fabricated success.
# =============================================================================
proj_j="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_j/docs/sdd/0006-fin-j"
echo "# fin j spec" > "$proj_j/docs/sdd/0006-fin-j/spec.md"
plan_j="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-fin-plan.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$plan_j")
printf 'missing_artifact=08-executor-summary.md\n' > "$plan_j/exec-plan.txt"
out_j="$(SPECRELAY_FAKE_EXECUTOR_PLAN="$plan_j/exec-plan.txt" \
  SPECRELAY_FAKE_FINALIZER_SCENARIO=finalizer_fails \
  specrelay_test::run "$proj_j" "docs/sdd/0006-fin-j/spec.md" 2>&1)"
rc_j=$?
specrelay_test::assert_true "J: run exits non-zero" "$([ "$rc_j" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "J: names FINALIZATION_FAILED" "$out_j" "FINALIZATION_FAILED"
task_dir_j="$proj_j/.specrelay-runs/tasks/0006-fin-j"
specrelay_test::assert_contains "J: task remains EXECUTOR_RUNNING (recoverable)" \
  "$(cat "$task_dir_j/state.json")" "EXECUTOR_RUNNING"

# =============================================================================
# Scenario V — the full standalone suite (this project's own configured
# legacy full_test_command) runs exactly once, at its authoritative
# placement (executor), and is recorded honestly (never claimed "passed"
# unless actually observed PASSED at level=full).
# =============================================================================
proj_v="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_v/docs/sdd/0007-fin-v"
echo "# fin v spec" > "$proj_v/docs/sdd/0007-fin-v/spec.md"
out_v="$(specrelay_test::run "$proj_v" "docs/sdd/0007-fin-v/spec.md" 2>&1)"
specrelay_test::assert_eq "V: run exits 0" "0" "$?"
task_dir_v="$proj_v/.specrelay-runs/tasks/0007-fin-v"
specrelay_test::assert_contains "V: the plan recorded the executor placement" \
  "$(cat "$task_dir_v/26-verification-plan.json" 2>/dev/null)" '"phase": "executor"'
specrelay_test::assert_contains "V: overall status PASSED was actually observed" \
  "$(cat "$task_dir_v/27-verification-summary.json" 2>/dev/null)" '"overall_status": "PASSED"'

echo
specrelay_test::summary
