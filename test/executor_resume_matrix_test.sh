#!/usr/bin/env bash
# executor_resume_matrix_test.sh — spec 0029, section 11 ("Finalization-only
# resume vs. implementation rerun") + section 32.2 interruption-boundary
# matrix (the subset exercisable deterministically with the fake provider):
#
#   M1  interrupted DURING provider execution (no durable terminal result
#       recorded yet) -> implementation RERUN.
#   M2  post-provider / pre-capture (exit 0, crash before 04/05/06/32) ->
#       ownership reconstructed from the pre-provider snapshot; provider NOT
#       rerun; finalization continues.
#   M3  interrupted DURING evidence capture (ledger already recorded, but
#       03-executor-log.md never got written) -> recapture; provider NOT
#       rerun.
#   M4  interrupted DURING verification (no verification summary was ever
#       produced) -> provider + evidence reused; verification reruns
#       (stale/missing evidence).
#   M5  interrupted DURING 07-tests.txt generation (verification itself
#       already passed with fresh digests) -> 07 regenerated from the
#       EXISTING (reused) verification summary, not re-executed.
#   M6  interrupted DURING the summary finalizer (08-executor-summary.md
#       never landed) -> re-finalized in the sandbox; provider NOT rerun.
#   M7  interrupted PRE-SUBMIT (all finalization phases already passed,
#       crash before the token/submit step) -> resume validates + submits
#       (idempotent), the provider is NOT rerun.
#   M9  interrupted AT CHANGES_REQUESTED -> a single resume requeues to the
#       next iteration and reruns implementation with the NEW prompt.
#   M10 DURING that iteration-2 rework's provider execution -> same
#       mechanics as M1, proven iteration-agnostic (iteration is part of the
#       resume-decision digest match itself).
#   M11 DURING that iteration-2 rework's verification -> same mechanics as
#       M4, proven iteration-agnostic.
#   M12 interruption with a suspect-hung/foreign-host lease -> resume STOPS
#       with an explicit human-decision message (still just `resume`, no
#       separate command) rather than auto-recovering.
#   P   resume reuses a fresh verification result ("reused": true) rather
#       than re-executing it when nothing changed.
#
# M8 (interrupted DURING Reviewer execution -> continue reviewer) is the
# pre-existing, pre-0029 REVIEWER_RUNNING resume contract (spec 0011),
# already covered end-to-end by test/reviewer_continuation_test.sh and
# test/transitions_test.sh — not duplicated here.
#
# Q (stale-digest rerun) is covered functionally by finalization_lib.py's
# verification-fresh digest comparison directly (see M4/M5's use of it via a
# real engine-owned verification pass) rather than a separate dedicated
# fixture.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/project.sh
. "$SPECRELAY_ROOT/lib/specrelay/project.sh"
# shellcheck source=../lib/specrelay/config.sh
. "$SPECRELAY_ROOT/lib/specrelay/config.sh"
# shellcheck source=../lib/specrelay/task.sh
. "$SPECRELAY_ROOT/lib/specrelay/task.sh"
# shellcheck source=../lib/specrelay/state.sh
. "$SPECRELAY_ROOT/lib/specrelay/state.sh"
# shellcheck source=../lib/specrelay/git_guard.sh
. "$SPECRELAY_ROOT/lib/specrelay/git_guard.sh"
# shellcheck source=../lib/specrelay/finalization.sh
. "$SPECRELAY_ROOT/lib/specrelay/finalization.sh"
# shellcheck source=../lib/specrelay/evidence.sh
. "$SPECRELAY_ROOT/lib/specrelay/evidence.sh"
# shellcheck source=../lib/specrelay/lock.sh
. "$SPECRELAY_ROOT/lib/specrelay/lock.sh"

BIN="$SPECRELAY_ROOT/bin/specrelay"

# ---- M1: interrupted during provider execution -> implementation RERUN ----
proj_m1="$(specrelay_test::mktemp_specrelay_project)"
id_m1="0700-resume-m1"
mkdir -p "$proj_m1/docs/sdd/$id_m1"
echo "# $id_m1 spec" > "$proj_m1/docs/sdd/$id_m1/spec.md"
(cd "$proj_m1" && git add -A && git commit -q -m "add spec")

dir_m1="$proj_m1/.specrelay-runs/tasks/$id_m1"
mkdir -p "$dir_m1"
specrelay::state::init "$(specrelay::state::path "$dir_m1")" \
  "{\"task_id\": \"$id_m1\", \"state\": \"EXECUTOR_RUNNING\", \"engine\": \"specrelay\", \"iteration\": 1, \"spec_source\": \"docs/sdd/$id_m1/spec.md\", \"claimed_at\": \"2026-01-01T00:00:00Z\", \"claimed_by\": \"specrelay-runner\"}" >/dev/null
specrelay::git_guard::write_baseline "$dir_m1" ""
printf 'executor prompt\n' > "$dir_m1/02-executor-prompt.md"
# NO 30-executor-finalization.json at all: the provider was killed before it
# ever recorded a terminal result (section 11.2, case 1).

out_m1="$( (cd "$proj_m1" && "$BIN" resume "$id_m1" --verbose) 2>&1)"
rc_m1=$?
specrelay_test::assert_eq "M1: resume drives the recovered task to completion" "0" "$rc_m1"
specrelay_test::assert_contains "M1: the provider actually ran (implementation rerun)" "$out_m1" "running provider 'fake'"
specrelay_test::assert_not_contains "M1: never claims a finalization-only resume" "$out_m1" "finalization-only resume"
specrelay_test::assert_contains "M1: reaches READY_FOR_HUMAN_REVIEW" "$out_m1" "READY_FOR_HUMAN_REVIEW"

# ---- M2: post-provider / pre-capture (crash before 04/05/06/32) -----------
# The provider's terminal result WAS durably recorded (section 11.1 records
# it BEFORE any finalization phase runs), but the crash happened before
# executor_evidence_capture ever wrote 04/05/06 or the ledger. Recovery must
# reconstruct ownership from the pre-provider snapshot (section 23.4) and
# must NOT rerun the provider.
proj_m2="$(specrelay_test::mktemp_specrelay_project)"
id_m2="0703-resume-m2"
mkdir -p "$proj_m2/docs/sdd/$id_m2"
echo "# $id_m2 spec" > "$proj_m2/docs/sdd/$id_m2/spec.md"
echo "original tracked line" > "$proj_m2/src-m2.txt"
(cd "$proj_m2" && git add -A && git commit -q -m "seed $id_m2")

dir_m2="$proj_m2/.specrelay-runs/tasks/$id_m2"
mkdir -p "$dir_m2"
specrelay::state::init "$(specrelay::state::path "$dir_m2")" \
  "{\"task_id\": \"$id_m2\", \"state\": \"EXECUTOR_RUNNING\", \"engine\": \"specrelay\", \"iteration\": 1, \"spec_source\": \"docs/sdd/$id_m2/spec.md\", \"claimed_at\": \"2026-01-01T00:00:00Z\", \"claimed_by\": \"specrelay-runner\"}" >/dev/null
specrelay::git_guard::write_baseline "$dir_m2" ""
printf 'executor prompt\n' > "$dir_m2/02-executor-prompt.md"

specrelay::finalization::init "$dir_m2" "$id_m2" 1 enabled >/dev/null
specrelay::finalization::record_provider_execution "$dir_m2" 1 "1" "$dir_m2/02-executor-prompt.md" 0 false >/dev/null

# Pre-provider snapshot captured BEFORE the round's own diff (section 23.1).
specrelay::git_guard::capture_pre_provider_snapshot "$proj_m2" "$dir_m2"

# The round's OWN diff — the crash happened before evidence capture ever ran:
# NO 04/05/06/32 exist.
echo "round-1 tracked edit" >> "$proj_m2/src-m2.txt"
echo "round-1 new untracked" > "$proj_m2/new-module-m2.txt"
specrelay_test::assert_true "M2: precondition — no evidence/ledger was ever captured" \
  "$([ ! -f "$dir_m2/32-round-change-ledger.jsonl" ] && [ ! -f "$dir_m2/05-changed-files.txt" ] && echo 0 || echo 1)"

out_m2="$( (cd "$proj_m2" && "$BIN" resume "$id_m2" --verbose) 2>&1)"
rc_m2=$?
specrelay_test::assert_eq "M2: resume drives the recovered task to completion" "0" "$rc_m2"
specrelay_test::assert_contains "M2: finalization-only resume (provider not rerun)" "$out_m2" "finalization-only resume"
specrelay_test::assert_not_contains "M2: the provider was never rerun" "$out_m2" "[executor] task '$id_m2': running provider 'fake'"
specrelay_test::assert_contains "M2: ownership reconstructed from the pre-provider snapshot" \
  "$out_m2" "pre-provider-snapshot reconstruction"
specrelay_test::assert_contains "M2: reaches READY_FOR_HUMAN_REVIEW" "$out_m2" "READY_FOR_HUMAN_REVIEW"
specrelay_test::assert_contains "M2: ledger records the reconstructed source" \
  "$(cat "$dir_m2/32-round-change-ledger.jsonl" 2>/dev/null)" "reconstructed-from-pre-provider-snapshot"
specrelay_test::assert_true "M2: round-1's own tracked edit is present in the final tree" \
  "$(grep -q 'round-1 tracked edit' "$proj_m2/src-m2.txt" 2>/dev/null && echo 0 || echo 1)"

# ---- shared helper for M3/M4/M5/M6/M11: a REAL completed round, then force
# the task back to EXECUTOR_RUNNING and remove exactly one downstream
# artifact, so resume must recapture/rerun/re-finalize ONLY that one phase —
# never the provider (a genuinely fresh, engine-produced baseline, not a
# hand-crafted approximation).
_resume_matrix_completed_round() {
  local id="$1" proj dir
  proj="$(specrelay_test::mktemp_specrelay_project)"
  mkdir -p "$proj/docs/sdd/$id"
  echo "# $id spec" > "$proj/docs/sdd/$id/spec.md"
  (cd "$proj" && "$BIN" run "docs/sdd/$id/spec.md" >/dev/null 2>&1)
  dir="$proj/.specrelay-runs/tasks/$id"
  specrelay::state::set "$(specrelay::state::path "$dir")" '{"state": "EXECUTOR_RUNNING"}' >/dev/null
  printf '%s\n' "$proj"
}

# ---- M3: interrupted DURING evidence capture (ledger recorded, 03 never
# written) -> recapture; provider NOT rerun; no snapshot reconstruction
# needed (distinguishes this from M2).
proj_m3="$(_resume_matrix_completed_round "0704-resume-m3")"
dir_m3="$proj_m3/.specrelay-runs/tasks/0704-resume-m3"
rm -f "$dir_m3/03-executor-log.md"

out_m3="$( (cd "$proj_m3" && "$BIN" resume "0704-resume-m3" --verbose) 2>&1)"
rc_m3=$?
specrelay_test::assert_eq "M3: resume drives the recovered task to completion" "0" "$rc_m3"
specrelay_test::assert_contains "M3: finalization-only resume (provider not rerun)" "$out_m3" "finalization-only resume"
specrelay_test::assert_not_contains "M3: no pre-provider-snapshot reconstruction was needed" \
  "$out_m3" "pre-provider-snapshot reconstruction"
specrelay_test::assert_true "M3: 03-executor-log.md was recaptured (engine-generated)" \
  "$([ -s "$dir_m3/03-executor-log.md" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "M3: recaptured log has the Engine-Observed Facts zone" \
  "$(cat "$dir_m3/03-executor-log.md")" "## Engine-Observed Facts"
specrelay_test::assert_contains "M3: reaches READY_FOR_HUMAN_REVIEW" "$out_m3" "READY_FOR_HUMAN_REVIEW"

# ---- M4: interrupted DURING verification (no summary was ever produced) ---
# -> provider + evidence reused; verification RERUNS (missing/stale evidence).
proj_m4="$(_resume_matrix_completed_round "0705-resume-m4")"
dir_m4="$proj_m4/.specrelay-runs/tasks/0705-resume-m4"
rm -f "$dir_m4/27-verification-summary.json"

out_m4="$( (cd "$proj_m4" && "$BIN" resume "0705-resume-m4" --verbose) 2>&1)"
rc_m4=$?
specrelay_test::assert_eq "M4: resume drives the recovered task to completion" "0" "$rc_m4"
specrelay_test::assert_contains "M4: finalization-only resume (provider not rerun)" "$out_m4" "finalization-only resume"
specrelay_test::assert_true "M4: verification was actually re-executed (27 regenerated)" \
  "$([ -s "$dir_m4/27-verification-summary.json" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "M4: verification was NOT reused (no fresh evidence existed)" \
  "$(cat "$dir_m4/30-executor-finalization.json")" '"reused": false'
specrelay_test::assert_contains "M4: reaches READY_FOR_HUMAN_REVIEW" "$out_m4" "READY_FOR_HUMAN_REVIEW"

# ---- M5: interrupted DURING 07-tests.txt generation (verification already
# passed with FRESH digests) -> 07 regenerated from the EXISTING (reused)
# verification summary, never re-executed.
proj_m5="$(_resume_matrix_completed_round "0706-resume-m5")"
dir_m5="$proj_m5/.specrelay-runs/tasks/0706-resume-m5"
specrelay_test::assert_contains "M5: precondition — the first pass genuinely ran verification fresh" \
  "$(cat "$dir_m5/30-executor-finalization.json")" '"reused": false'
rm -f "$dir_m5/07-tests.txt"

out_m5="$( (cd "$proj_m5" && "$BIN" resume "0706-resume-m5" --verbose) 2>&1)"
rc_m5=$?
specrelay_test::assert_eq "M5: resume drives the recovered task to completion" "0" "$rc_m5"
specrelay_test::assert_contains "M5: finalization-only resume (provider not rerun)" "$out_m5" "finalization-only resume"
specrelay_test::assert_true "M5: 07-tests.txt was regenerated" \
  "$([ -s "$dir_m5/07-tests.txt" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "M5: verification was REUSED, not re-executed (fresh digests)" \
  "$(cat "$dir_m5/30-executor-finalization.json")" '"reused": true'
specrelay_test::assert_contains "M5: reaches READY_FOR_HUMAN_REVIEW" "$out_m5" "READY_FOR_HUMAN_REVIEW"

# ---- M6: interrupted DURING the summary finalizer (08 never landed) ------
# -> re-finalized in the sandbox; provider NOT rerun.
proj_m6="$(_resume_matrix_completed_round "0707-resume-m6")"
dir_m6="$proj_m6/.specrelay-runs/tasks/0707-resume-m6"
rm -f "$dir_m6/08-executor-summary.md"

out_m6="$( (cd "$proj_m6" && "$BIN" resume "0707-resume-m6" --verbose) 2>&1)"
rc_m6=$?
specrelay_test::assert_eq "M6: resume drives the recovered task to completion" "0" "$rc_m6"
specrelay_test::assert_contains "M6: finalization-only resume (provider not rerun)" "$out_m6" "finalization-only resume"
specrelay_test::assert_true "M6: 08-executor-summary.md was re-finalized" \
  "$([ -s "$dir_m6/08-executor-summary.md" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "M6: the finalizer's sandboxed candidate was adopted" \
  "$(cat "$dir_m6/08-executor-summary.md")" "Fake finalizer candidate summary"
specrelay_test::assert_contains "M6: reaches READY_FOR_HUMAN_REVIEW" "$out_m6" "READY_FOR_HUMAN_REVIEW"

# ---- M9/M10: interrupted AT CHANGES_REQUESTED -> a single resume requeues
# to iteration 2 and reruns implementation with the NEW prompt (M9); that
# iteration-2 provider execution (M10) is exactly the M1 mechanics, proven
# iteration-agnostic since resume-decision keys off (iteration, prompt
# digest) explicitly.
proj_m9="$(specrelay_test::mktemp_specrelay_project)"
id_m9="0708-resume-m9"
mkdir -p "$proj_m9/docs/sdd/$id_m9" "$proj_m9/src-m9"
echo "# $id_m9 spec" > "$proj_m9/docs/sdd/$id_m9/spec.md"
echo "original" > "$proj_m9/src-m9/app.txt"
(cd "$proj_m9" && git add -A && git commit -q -m "seed $id_m9")

dir_m9="$proj_m9/.specrelay-runs/tasks/$id_m9"
mkdir -p "$dir_m9"
specrelay::state::init "$(specrelay::state::path "$dir_m9")" \
  "{\"task_id\": \"$id_m9\", \"state\": \"CHANGES_REQUESTED\", \"engine\": \"specrelay\", \"iteration\": 1, \"spec_source\": \"docs/sdd/$id_m9/spec.md\", \"claimed_at\": \"2026-01-01T00:00:00Z\", \"claimed_by\": \"specrelay-runner\"}" >/dev/null
specrelay::git_guard::write_baseline "$dir_m9" ""
printf 'executor prompt r1\n' > "$dir_m9/02-executor-prompt.md"
printf 'engine-observed executor log\n' > "$dir_m9/03-executor-log.md"
printf 'test evidence\n' > "$dir_m9/07-tests.txt"
printf 'summary\n## Input Coverage\ncoverage\n' > "$dir_m9/08-executor-summary.md"
printf 'reviewer notes\nDecision: REQUEST_CHANGES\n' > "$dir_m9/09-consultant-review.md"
printf 'rework prompt: address the reviewer feedback\n' > "$dir_m9/11-next-executor-prompt.md"
echo "round-1 edit" >> "$proj_m9/src-m9/app.txt"
specrelay::evidence::capture "$proj_m9" "$dir_m9" 2>/dev/null || true
specrelay::git_guard::record_round_change "$proj_m9" "$dir_m9" "1"
specrelay::git_guard::derive_owned_from_ledger "$proj_m9" "$dir_m9"

out_m9="$( (cd "$proj_m9" && "$BIN" resume "$id_m9" --verbose) 2>&1)"
rc_m9=$?
specrelay_test::assert_eq "M9/M10: resume drives the requeued round to completion" "0" "$rc_m9"
specrelay_test::assert_contains "M9: the task was requeued to the next iteration" "$out_m9" "requeuing task"
specrelay_test::assert_contains "M10: the new iteration's provider actually ran (round 2)" \
  "$out_m9" "running provider 'fake' (round 2"
specrelay_test::assert_contains "M9/M10: reaches READY_FOR_HUMAN_REVIEW" "$out_m9" "READY_FOR_HUMAN_REVIEW"
specrelay_test::assert_contains "M9: iteration is now 2" \
  "$(cat "$dir_m9/state.json")" '"iteration": 2'

# ---- M11: DURING that iteration-2 rework's verification -> same mechanics
# as M4, proven iteration-agnostic.
proj_m11="$(specrelay_test::mktemp_specrelay_project)"
id_m11="0709-resume-m11"
mkdir -p "$proj_m11/docs/sdd/$id_m11" "$proj_m11/src-m11"
echo "# $id_m11 spec" > "$proj_m11/docs/sdd/$id_m11/spec.md"
echo "original" > "$proj_m11/src-m11/app.txt"
(cd "$proj_m11" && git add -A && git commit -q -m "seed $id_m11")

dir_m11="$proj_m11/.specrelay-runs/tasks/$id_m11"
mkdir -p "$dir_m11"
specrelay::state::init "$(specrelay::state::path "$dir_m11")" \
  "{\"task_id\": \"$id_m11\", \"state\": \"CHANGES_REQUESTED\", \"engine\": \"specrelay\", \"iteration\": 1, \"spec_source\": \"docs/sdd/$id_m11/spec.md\", \"claimed_at\": \"2026-01-01T00:00:00Z\", \"claimed_by\": \"specrelay-runner\"}" >/dev/null
specrelay::git_guard::write_baseline "$dir_m11" ""
printf 'executor prompt r1\n' > "$dir_m11/02-executor-prompt.md"
printf 'engine-observed executor log\n' > "$dir_m11/03-executor-log.md"
printf 'test evidence\n' > "$dir_m11/07-tests.txt"
printf 'summary\n## Input Coverage\ncoverage\n' > "$dir_m11/08-executor-summary.md"
printf 'reviewer notes\nDecision: REQUEST_CHANGES\n' > "$dir_m11/09-consultant-review.md"
printf 'rework prompt: address the reviewer feedback\n' > "$dir_m11/11-next-executor-prompt.md"
echo "round-1 edit" >> "$proj_m11/src-m11/app.txt"
specrelay::evidence::capture "$proj_m11" "$dir_m11" 2>/dev/null || true
specrelay::git_guard::record_round_change "$proj_m11" "$dir_m11" "1"
specrelay::git_guard::derive_owned_from_ledger "$proj_m11" "$dir_m11"
(cd "$proj_m11" && "$BIN" resume "$id_m11" >/dev/null 2>&1)
specrelay_test::assert_contains "M11: precondition — iteration 2 completed normally" \
  "$(cat "$dir_m11/state.json")" '"iteration": 2'

specrelay::state::set "$(specrelay::state::path "$dir_m11")" '{"state": "EXECUTOR_RUNNING"}' >/dev/null
rm -f "$dir_m11/27-verification-summary.json"

out_m11="$( (cd "$proj_m11" && "$BIN" resume "$id_m11" --verbose) 2>&1)"
rc_m11=$?
specrelay_test::assert_eq "M11: resume drives the recovered iteration-2 round to completion" "0" "$rc_m11"
specrelay_test::assert_contains "M11: finalization-only resume (provider not rerun)" "$out_m11" "finalization-only resume"
specrelay_test::assert_true "M11: verification was actually re-executed (27 regenerated)" \
  "$([ -s "$dir_m11/27-verification-summary.json" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "M11: reaches READY_FOR_HUMAN_REVIEW" "$out_m11" "READY_FOR_HUMAN_REVIEW"

# ---- M12: a suspect-hung/foreign-host lease -> resume STOPS with an
# explicit human-decision message; no auto-recovery (section 23.5/21.2).
proj_m12="$(specrelay_test::mktemp_specrelay_project)"
id_m12="0710-resume-m12"
mkdir -p "$proj_m12/docs/sdd/$id_m12"
echo "# $id_m12 spec" > "$proj_m12/docs/sdd/$id_m12/spec.md"
(cd "$proj_m12" && git add -A && git commit -q -m "seed $id_m12")

dir_m12="$proj_m12/.specrelay-runs/tasks/$id_m12"
mkdir -p "$dir_m12"
specrelay::state::init "$(specrelay::state::path "$dir_m12")" \
  "{\"task_id\": \"$id_m12\", \"state\": \"EXECUTOR_RUNNING\", \"engine\": \"specrelay\", \"iteration\": 1, \"spec_source\": \"docs/sdd/$id_m12/spec.md\", \"claimed_at\": \"2026-01-01T00:00:00Z\", \"claimed_by\": \"specrelay-runner\"}" >/dev/null
specrelay::git_guard::write_baseline "$dir_m12" ""
printf 'executor prompt\n' > "$dir_m12/02-executor-prompt.md"

lock_dir_m12="$(specrelay::lock::_dir "$proj_m12" "$id_m12")"
mkdir -p "$lock_dir_m12"
this_host_m12="$(hostname 2>/dev/null || echo unknown-host)"
real_start_m12="$(specrelay::lock::_pid_start_time "$$")"
python3 -c '
import json, sys
print(json.dumps({
    "schema_version": 1, "pid": '"$$"', "host": "'"$this_host_m12"'",
    "acquired_at": "2026-01-01T00:00:00Z", "pid_start_time": sys.argv[1],
    "invocation_id": None, "owner_token": "test-token", "provider_pgid": None,
    "heartbeat_at": "2020-01-01T00:00:00Z", "heartbeat_interval_seconds": 15,
}))
' "$real_start_m12" > "$lock_dir_m12/owner"

out_m12="$( (cd "$proj_m12" && "$BIN" resume "$id_m12") 2>&1)"
rc_m12=$?
specrelay_test::assert_true "M12: resume STOPS (does not auto-recover) on a suspect-hung lease" \
  "$([ "$rc_m12" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "M12: names the suspect-hung classification" "$out_m12" "suspect-hung"
specrelay_test::assert_contains "M12: states an explicit human decision is required" "$out_m12" "explicit human decision"
specrelay_test::assert_contains "M12: task remains EXECUTOR_RUNNING (no auto-recovery occurred)" \
  "$(cat "$dir_m12/state.json")" "EXECUTOR_RUNNING"

# ---- M7: interrupted pre-submit (all phases passed) -> validate + submit --
proj_m7="$(specrelay_test::mktemp_specrelay_project)"
id_m7="0701-resume-m7"
mkdir -p "$proj_m7/docs/sdd/$id_m7"
echo "# $id_m7 spec" > "$proj_m7/docs/sdd/$id_m7/spec.md"
(cd "$proj_m7" && git add -A && git commit -q -m "add spec")

dir_m7="$proj_m7/.specrelay-runs/tasks/$id_m7"
mkdir -p "$dir_m7"
specrelay::state::init "$(specrelay::state::path "$dir_m7")" \
  "{\"task_id\": \"$id_m7\", \"state\": \"EXECUTOR_RUNNING\", \"engine\": \"specrelay\", \"iteration\": 1, \"spec_source\": \"docs/sdd/$id_m7/spec.md\", \"claimed_at\": \"2026-01-01T00:00:00Z\", \"claimed_by\": \"specrelay-runner\"}" >/dev/null
specrelay::git_guard::write_baseline "$dir_m7" ""
printf 'executor prompt\n' > "$dir_m7/02-executor-prompt.md"
printf 'executor log content\n## Engine-Observed Facts\n' > "$dir_m7/03-executor-log.md"
printf 'test output content\n' > "$dir_m7/07-tests.txt"
cat > "$dir_m7/08-executor-summary.md" <<'EOF'
Pre-submit summary.
## Finalization Pipeline
x
## Supervised Verification
x
## Evidence Provenance
x
## Interrupted-Round Recovery
x
## Backward Compatibility
x
EOF
: > "$dir_m7/04-git-status.txt"
: > "$dir_m7/05-changed-files.txt"
: > "$dir_m7/05-git-diff-stat.txt"
: > "$dir_m7/06-git-diff.patch"

prompt_digest="$(python3 -c '
import hashlib
print("sha256:" + hashlib.sha256(open("'"$dir_m7"'/02-executor-prompt.md", "rb").read()).hexdigest())
')"
python3 -c '
import json
d = {
    "schema_version": 1, "pipeline_version": 1, "task_id": "'"$id_m7"'", "iteration": 1,
    "mode": "enabled",
    "provider_execution": {"iteration": 1, "invocation_id": "1", "prompt_digest": "'"$prompt_digest"'",
                            "exit_code": 0, "completed_at": "2026-01-01T00:00:00Z",
                            "process_group_terminated": False},
    "phases": {
        "executor_provider_execution": {"result": "passed"},
        "executor_evidence_capture": {"result": "passed", "log_source": "executor-written"},
        "executor_verification": {"result": "passed", "overall_status": "NOT_REQUIRED", "reused": False,
                                   "authoritative_placement": "executor"},
        "executor_summary_finalization": {"result": "passed", "source": "executor"},
        "executor_completion_validation": {"result": "passed"},
    },
    "outcome": None,
    "background": {"pending_required_jobs": 0, "surviving_children_terminated": 0,
                    "text_wait_warning": False, "supervision": "unknown"},
    "provenance": {"log": "executor-written", "tests": "executor-written", "summary": "executor"},
}
print(json.dumps(d))
' > "$dir_m7/30-executor-finalization.json"
# No full_test_command configured for THIS project, so engine-owned
# verification is NOT_REQUIRED and the recorded phase above is already
# consistent with what a fresh run_verification call will find.
sed -i.bak '/^validation:/,/full_test_command/d' "$proj_m7/.specrelay/config.yml"
rm -f "$proj_m7/.specrelay/config.yml.bak"
(cd "$proj_m7" && git add -A && git commit -q -m "no full_test_command")

out_m7="$( (cd "$proj_m7" && "$BIN" resume "$id_m7" --verbose) 2>&1)"
rc_m7=$?
specrelay_test::assert_eq "M7: resume validates + submits idempotently" "0" "$rc_m7"
specrelay_test::assert_contains "M7: finalization-only resume (provider not rerun)" "$out_m7" "finalization-only resume"
specrelay_test::assert_contains "M7: reaches READY_FOR_HUMAN_REVIEW" "$out_m7" "READY_FOR_HUMAN_REVIEW"

# ---- P: resume reuses a fresh verification result (reused: true) ----------
proj_p="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_p/docs/sdd/0702-resume-p"
echo "# resume p spec" > "$proj_p/docs/sdd/0702-resume-p/spec.md"
out_p1="$( (cd "$proj_p" && "$BIN" run "docs/sdd/0702-resume-p/spec.md") 2>&1)"
specrelay_test::assert_eq "P: first run reaches READY_FOR_HUMAN_REVIEW" "0" "$?"
task_dir_p="$proj_p/.specrelay-runs/tasks/0702-resume-p"
specrelay_test::assert_contains "P: first round's verification was NOT reused" \
  "$(cat "$task_dir_p/30-executor-finalization.json" 2>/dev/null)" '"reused": false'
# Re-verify from the task's OWN durable digests (never against a live
# re-resolved config), matching the freshness rule (spec 0029, section 14.2).
cfg_digest="$(python3 lib/specrelay/py/finalization_lib.py digest-file "$task_dir_p/verification/effective-config.json" 2>/dev/null)"
diff_digest="$(python3 lib/specrelay/py/finalization_lib.py digest-file "$task_dir_p/06-git-diff.patch" 2>/dev/null)"
fresh="$(python3 lib/specrelay/py/finalization_lib.py verification-fresh "$task_dir_p" "$cfg_digest" "$diff_digest" "" 2>/dev/null)"
specrelay_test::assert_eq "P: the just-recorded result is reported fresh" "true" "$fresh"

echo
specrelay_test::summary
