#!/usr/bin/env bash
# cli_workflow_test.sh — CLI-level coverage for the task lifecycle
# subcommands (spec sections 14-16, 65): task create/show/status/list/
# approve/requeue/accept/request-changes/block/authorize-submit, ambiguous
# task lookup, and an unsupported provider configuration.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

proj="$(specrelay_test::mktemp_specrelay_project)"
# This file exercises the MANUAL reviewer CLI subcommands (task accept /
# request-changes). Under the automated-reviewer continuation contract (spec
# 0010) `resume` with an automated reviewer would run the reviewer too and
# reach READY_FOR_HUMAN_REVIEW; to deterministically rest a task at
# READY_FOR_REVIEW for a human decision the reviewer provider must be the
# explicit `manual` opt-out. Reconfigure this fixture accordingly (executor
# stays the deterministic `fake` provider).
cat > "$proj/.specrelay/config.yml" <<'YAML'
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
    provider: manual
context:
  adapter: none
  required: false
validation:
  full_test_command: "echo ok"
policy:
  human_final_review_required: true
YAML
mkdir -p "$proj/docs/sdd/0001-cli-fixture"
echo "# CLI fixture spec" > "$proj/docs/sdd/0001-cli-fixture/spec.md"
(cd "$proj" && git add -A && git commit -q -m "commit spec")

# --- task create: does not approve or run ------------------------------------
create_out="$(cd "$proj" && "$SPECRELAY_BIN" task create docs/sdd/0001-cli-fixture/spec.md 2>&1)"
rc=$?
specrelay_test::assert_eq "task create exits 0" "0" "$rc"
specrelay_test::assert_contains "task create reports DRAFT, not approved" "$create_out" "created in DRAFT"

status_out="$(cd "$proj" && "$SPECRELAY_BIN" task status 0001-cli-fixture 2>&1)"
specrelay_test::assert_contains "task create leaves the task in DRAFT" "$status_out" "DRAFT"

create_again="$(cd "$proj" && "$SPECRELAY_BIN" task create docs/sdd/0001-cli-fixture/spec.md 2>&1)"
rc=$?
specrelay_test::assert_true "task create refuses to recreate an existing task" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# --- task approve -------------------------------------------------------------
(cd "$proj" && "$SPECRELAY_BIN" task approve 0001-cli-fixture >/dev/null)
rc=$?
specrelay_test::assert_eq "task approve succeeds from DRAFT" "0" "$rc"
status_out="$(cd "$proj" && "$SPECRELAY_BIN" task status 0001-cli-fixture 2>&1)"
specrelay_test::assert_contains "task approve transitions to READY_FOR_EXECUTOR" "$status_out" "READY_FOR_EXECUTOR"

# --- task show ---------------------------------------------------------------
show_out="$(cd "$proj" && "$SPECRELAY_BIN" task show 0001-cli-fixture 2>&1)"
specrelay_test::assert_contains "task show prints the task id" "$show_out" "0001-cli-fixture"
specrelay_test::assert_contains "task show prints the state" "$show_out" "READY_FOR_EXECUTOR"
specrelay_test::assert_contains "task show prints the executor provider" "$show_out" "Executor provider: fake"
specrelay_test::assert_contains "task show prints the task runtime path" "$show_out" ".specrelay-runs/tasks/0001-cli-fixture"

# --- run one executor round via resume, then reviewer round via CLI ---------
(cd "$proj" && "$SPECRELAY_BIN" resume 0001-cli-fixture >/dev/null 2>&1)
status_out="$(cd "$proj" && "$SPECRELAY_BIN" task status 0001-cli-fixture 2>&1)"
specrelay_test::assert_contains "resume runs the executor and reaches READY_FOR_REVIEW" "$status_out" "READY_FOR_REVIEW"

# --- task request-changes (manual reviewer path) ----------------------------
task_dir="$proj/.specrelay-runs/tasks/0001-cli-fixture"
printf 'manual reviewer notes\n' > "$task_dir/09-consultant-review.md"
printf 'manual next prompt\n' > "$task_dir/11-next-executor-prompt.md"
(cd "$proj" && "$SPECRELAY_BIN" task request-changes 0001-cli-fixture "please fix X" >/dev/null)
rc=$?
specrelay_test::assert_eq "task request-changes succeeds with 09/11 written" "0" "$rc"
status_out="$(cd "$proj" && "$SPECRELAY_BIN" task status 0001-cli-fixture 2>&1)"
specrelay_test::assert_contains "task request-changes transitions to CHANGES_REQUESTED" "$status_out" "CHANGES_REQUESTED"

# --- task requeue --------------------------------------------------------------
(cd "$proj" && "$SPECRELAY_BIN" task requeue 0001-cli-fixture >/dev/null)
rc=$?
specrelay_test::assert_eq "task requeue succeeds from CHANGES_REQUESTED" "0" "$rc"
status_out="$(cd "$proj" && "$SPECRELAY_BIN" task status 0001-cli-fixture 2>&1)"
specrelay_test::assert_contains "task requeue transitions back to READY_FOR_EXECUTOR" "$status_out" "READY_FOR_EXECUTOR"

# --- round 2, then task accept (manual reviewer path) -----------------------
(cd "$proj" && "$SPECRELAY_BIN" resume 0001-cli-fixture >/dev/null 2>&1)
printf 'manual reviewer notes round 2\n' > "$task_dir/09-consultant-review.md"
printf 'manual business summary\n' > "$task_dir/10-business-summary.md"
(cd "$proj" && "$SPECRELAY_BIN" task accept 0001-cli-fixture >/dev/null)
rc=$?
specrelay_test::assert_eq "task accept succeeds with 09/10 written" "0" "$rc"
status_out="$(cd "$proj" && "$SPECRELAY_BIN" task status 0001-cli-fixture 2>&1)"
specrelay_test::assert_contains "task accept transitions to READY_FOR_HUMAN_REVIEW" "$status_out" "READY_FOR_HUMAN_REVIEW"

# --- task block ----------------------------------------------------------------
mkdir -p "$proj/docs/sdd/0002-block-fixture"
echo "# block fixture" > "$proj/docs/sdd/0002-block-fixture/spec.md"
(cd "$proj" && git add -A && git commit -q -m "spec2")
(cd "$proj" && "$SPECRELAY_BIN" task create docs/sdd/0002-block-fixture/spec.md >/dev/null)
(cd "$proj" && "$SPECRELAY_BIN" task approve 0002-block-fixture >/dev/null)
task_dir2="$proj/.specrelay-runs/tasks/0002-block-fixture"
python3 - "$task_dir2/state.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["state"] = "EXECUTOR_RUNNING"
json.dump(d, open(p, "w"), indent=2)
PY
(cd "$proj" && "$SPECRELAY_BIN" task block 0002-block-fixture "manual intervention needed" >/dev/null)
rc=$?
specrelay_test::assert_eq "task block succeeds from EXECUTOR_RUNNING" "0" "$rc"
status_out="$(cd "$proj" && "$SPECRELAY_BIN" task status 0002-block-fixture 2>&1)"
specrelay_test::assert_contains "task block transitions to BLOCKED" "$status_out" "BLOCKED"

# --- task authorize-submit (manual-recovery entry point) --------------------
mkdir -p "$proj/docs/sdd/0003-authsubmit"
echo "# authsubmit fixture" > "$proj/docs/sdd/0003-authsubmit/spec.md"
(cd "$proj" && git add -A && git commit -q -m "spec3")
(cd "$proj" && "$SPECRELAY_BIN" task create docs/sdd/0003-authsubmit/spec.md >/dev/null)
(cd "$proj" && "$SPECRELAY_BIN" task approve 0003-authsubmit >/dev/null)
(cd "$proj" && "$SPECRELAY_BIN" resume 0003-authsubmit >/dev/null 2>&1)
# resume already submits automatically via the orchestrator; force the task
# back to EXECUTOR_RUNNING with required outputs present to test the manual
# authorize-submit path directly.
task_dir3="$proj/.specrelay-runs/tasks/0003-authsubmit"
python3 - "$task_dir3/state.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["state"] = "EXECUTOR_RUNNING"
json.dump(d, open(p, "w"), indent=2)
PY
authsubmit_out="$(cd "$proj" && "$SPECRELAY_BIN" task authorize-submit 0003-authsubmit 2>&1)"
rc=$?
specrelay_test::assert_eq "task authorize-submit succeeds with required outputs present" "0" "$rc"
status_out="$(cd "$proj" && "$SPECRELAY_BIN" task status 0003-authsubmit 2>&1)"
specrelay_test::assert_contains "task authorize-submit transitions to READY_FOR_REVIEW" "$status_out" "READY_FOR_REVIEW"

# --- ambiguous / unknown task reference via CLI -----------------------------
mkdir -p "$proj/.specrelay-runs/tasks/00aa-one" "$proj/.specrelay-runs/tasks/00aa-two"
: > "$proj/.specrelay-runs/tasks/00aa-one/state.json"
: > "$proj/.specrelay-runs/tasks/00aa-two/state.json"
ambi_out="$(cd "$proj" && "$SPECRELAY_BIN" show 00aa 2>&1)"
rc=$?
specrelay_test::assert_true "show with an ambiguous ref exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "show with an ambiguous ref lists candidates" "$ambi_out" "ambiguous"

# --- unsupported provider configuration -------------------------------------
bad_provider_proj="$(specrelay_test::mktemp_project)"
mkdir -p "$bad_provider_proj/.specrelay"
cat > "$bad_provider_proj/.specrelay/config.yml" <<'YAML'
version: 1
specs:
  root: docs/sdd
tasks:
  runs_root: .specrelay-runs/tasks
roles:
  executor:
    provider: not-a-real-provider
  reviewer:
    provider: fake
context:
  adapter: none
  required: false
YAML
mkdir -p "$bad_provider_proj/docs/sdd/0001-bad-provider"
echo "# bad provider spec" > "$bad_provider_proj/docs/sdd/0001-bad-provider/spec.md"
(cd "$bad_provider_proj" && git add -A && git commit -q -m init)

bad_out="$(cd "$bad_provider_proj" && "$SPECRELAY_BIN" run docs/sdd/0001-bad-provider/spec.md 2>&1)"
rc=$?
specrelay_test::assert_true "run with an unsupported executor provider exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "run with an unsupported provider names it clearly" "$bad_out" "unsupported executor provider"

specrelay_test::summary
exit $?
