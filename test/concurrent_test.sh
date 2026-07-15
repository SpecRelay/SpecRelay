#!/usr/bin/env bash
# concurrent_test.sh — proves two SpecRelay processes cannot simultaneously
# mutate the same task (spec section 63). Uses real backgrounded CLI
# processes (not just unit-level lock.sh calls) against a shared temp
# fixture, with deterministic timing via a fake-executor plan that pauses.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

proj="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj/docs/sdd/0001-race"
echo "# Race spec" > "$proj/docs/sdd/0001-race/spec.md"
(cd "$proj" && git add -A && git commit -q -m "commit spec")

# Pre-create and approve the task so both racing processes start from the
# same READY_FOR_EXECUTOR state and race on the CLAIM step specifically.
(cd "$proj" && "$SPECRELAY_BIN" task create docs/sdd/0001-race/spec.md >/dev/null)
(cd "$proj" && "$SPECRELAY_BIN" task approve 0001-race >/dev/null)

# A "slow" fake executor: sleeps briefly after being invoked (i.e. AFTER the
# lock/claim has already happened), giving the second process a real window
# to attempt (and fail) a concurrent claim.
slow_executor_plan="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-plan.XXXXXX")"

out1_file="$(mktemp "${TMPDIR:-/tmp}/specrelay-race-out1.XXXXXX")"
out2_file="$(mktemp "${TMPDIR:-/tmp}/specrelay-race-out2.XXXXXX")"

(
  cd "$proj" || exit 1
  SPECRELAY_FAKE_EXECUTOR_SLEEP=1 "$SPECRELAY_BIN" resume 0001-race
) > "$out1_file" 2>&1 &
pid1=$!

# Give process 1 a head start to acquire the lock first.
sleep 0.3

(
  cd "$proj" || exit 1
  "$SPECRELAY_BIN" resume 0001-race
) > "$out2_file" 2>&1 &
pid2=$!

wait "$pid1"
rc1=$?
wait "$pid2"
rc2=$?

out1="$(cat "$out1_file")"
out2="$(cat "$out2_file")"

specrelay_test::assert_eq "concurrent: exactly one of the two racing processes succeeds" \
  "1" "$(( (rc1 == 0 ? 1 : 0) + (rc2 == 0 ? 1 : 0) ))"

combined="$out1
$out2"
specrelay_test::assert_contains "concurrent: the losing process reports a lock conflict" \
  "$combined" "locked by another process"

# With an automated reviewer, the single process that wins the claim drives the
# full executor<->reviewer loop to completion in the same invocation (spec
# 0010), so the task ends cleanly at READY_FOR_HUMAN_REVIEW. A double-claim
# would instead have errored/blocked — reaching this single terminal state
# confirms exactly one claim went through.
final_state="$(cd "$proj" && "$SPECRELAY_BIN" task status 0001-race 2>&1)"
specrelay_test::assert_contains "concurrent: the task ends up cleanly in READY_FOR_HUMAN_REVIEW (only one claim went through)" \
  "$final_state" "READY_FOR_HUMAN_REVIEW"

rm -f "$out1_file" "$out2_file"

specrelay_test::summary
exit $?
