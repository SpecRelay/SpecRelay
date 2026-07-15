#!/usr/bin/env bash
# verification_ledger_test.sh — verification ledger: classification, count
# and duration aggregation, role separation, and duplicate-work detection
# (spec 0019, "D. Execution Timeline" / "Verification Ledger").

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/config.sh
. "$SPECRELAY_ROOT/lib/specrelay/config.sh"
# shellcheck source=../lib/specrelay/timeline.sh
. "$SPECRELAY_ROOT/lib/specrelay/timeline.sh"
# shellcheck source=../lib/specrelay/verification.sh
. "$SPECRELAY_ROOT/lib/specrelay/verification.sh"

tdir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ledger.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$tdir")
root="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ledger-root.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$root")

# =============================================================================
# Per-operation classification, count, and duration aggregation.
# =============================================================================
specrelay::verification::record "$tdir" executor "scripts/test test/foo_test.sh" 1.0 0
specrelay::verification::record "$tdir" executor "scripts/test test/bar_test.sh" 1.5 0
specrelay::verification::record "$tdir" executor "scripts/test test/baz_test.sh" 2.0 0
specrelay::verification::record "$tdir" executor "scripts/test --changed --jobs auto --timings" 3.0 0
specrelay::verification::record "$tdir" executor "scripts/test --jobs auto --timings" 10.0 0
specrelay::verification::record "$tdir" executor "scripts/smoke --skip-tests" 4.0 0
specrelay::verification::record "$tdir" executor "bin/specrelay doctor" 0.1 0
specrelay::verification::record "$tdir" executor "bin/specrelay version" 0.05 0
specrelay::verification::record "$tdir" reviewer "scripts/test test/foo_test.sh" 1.0 0

json="$(specrelay::timeline::render "$root" "$tdir" ledger-task final --json)"

specrelay_test::assert_eq "focused test is classified" \
  "test_focused" "$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next(r for r in d["verification_ledger"] if r["role"]=="executor" and r["count"]==3)
print(row["operation"])
' 2>/dev/null)"
specrelay_test::assert_eq "focused test operation count is correct (3 distinct focused runs)" \
  "3" "$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next(r for r in d["verification_ledger"] if r["operation"]=="test_focused" and r["role"]=="executor")
print(row["count"])
')"
specrelay_test::assert_eq "focused test duration aggregation is correct (1.0+1.5+2.0=4.5)" \
  "4.5" "$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next(r for r in d["verification_ledger"] if r["operation"]=="test_focused" and r["role"]=="executor")
print(row["duration_seconds"])
')"
specrelay_test::assert_eq "targeted test is classified with count 1" \
  "1" "$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next((r for r in d["verification_ledger"] if r["operation"]=="test_targeted" and r["role"]=="executor"), None)
print(row["count"] if row else "MISSING")
')"
specrelay_test::assert_eq "full suite is classified with count 1" \
  "1" "$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next((r for r in d["verification_ledger"] if r["operation"]=="test_full" and r["role"]=="executor"), None)
print(row["count"] if row else "MISSING")
')"
specrelay_test::assert_eq "smoke is classified" \
  "1" "$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next((r for r in d["verification_ledger"] if r["operation"]=="smoke" and r["role"]=="executor"), None)
print(row["count"] if row else "MISSING")
')"
specrelay_test::assert_eq "doctor is classified" \
  "1" "$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next((r for r in d["verification_ledger"] if r["operation"]=="doctor" and r["role"]=="executor"), None)
print(row["count"] if row else "MISSING")
')"
specrelay_test::assert_eq "version is classified" \
  "1" "$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next((r for r in d["verification_ledger"] if r["operation"]=="version" and r["role"]=="executor"), None)
print(row["count"] if row else "MISSING")
')"

# =============================================================================
# Unknown command remains unclassified.
# =============================================================================
specrelay::verification::record "$tdir" executor "rake db:migrate" 0.5 0
json2="$(specrelay::timeline::render "$root" "$tdir" ledger-task final --json)"
specrelay_test::assert_eq "an unknown command is recorded as unclassified" \
  "1" "$(printf '%s' "$json2" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next((r for r in d["verification_ledger"] if r["operation"]=="agent_tool_execution_unclassified"), None)
print(row["count"] if row else "MISSING")
')"

# =============================================================================
# Role separation: the same operation for executor and reviewer is tracked
# separately, never merged.
# =============================================================================
specrelay_test::assert_eq "role separation: reviewer's focused-test count is independent of executor's" \
  "1" "$(printf '%s' "$json2" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next(r for r in d["verification_ledger"] if r["operation"]=="test_focused" and r["role"]=="reviewer")
print(row["count"])
')"

# =============================================================================
# Duplicate detection: unjustified vs justified.
# =============================================================================
tdir2="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ledger2.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$tdir2")
specrelay::verification::record "$tdir2" executor "scripts/test --jobs auto --timings" 5.0 0
specrelay::verification::record "$tdir2" executor "scripts/test --jobs auto --timings" 5.0 0 \
  "the test runner changed after the first full-suite result"

json3="$(specrelay::timeline::render "$root" "$tdir2" dup-task final --json)"
specrelay_test::assert_eq "a duplicate operation is reported" \
  "2" "$(printf '%s' "$json3" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next(r for r in d["duplicate_work"] if r["operation"]=="test_full")
print(row["count"])
')"
specrelay_test::assert_eq "a justified duplicate is distinguishable (reason recorded)" \
  "True" "$(printf '%s' "$json3" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next(r for r in d["duplicate_work"] if r["operation"]=="test_full")
print(row["justified"])
')"

tdir3="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ledger3.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$tdir3")
specrelay::verification::record "$tdir3" executor "scripts/test --jobs auto --timings" 5.0 0
specrelay::verification::record "$tdir3" executor "scripts/test --jobs auto --timings" 5.0 0
json4="$(specrelay::timeline::render "$root" "$tdir3" undup-task final --json)"
specrelay_test::assert_eq "an unjustified duplicate is distinguishable (no reason recorded)" \
  "False" "$(printf '%s' "$json4" | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next(r for r in d["duplicate_work"] if r["operation"]=="test_full")
print(row["justified"])
')"

# =============================================================================
# No false duplicate is reported for two DIFFERENT targeted commands
# (different operations never collapse into one duplicate entry).
# =============================================================================
tdir4="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-ledger4.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$tdir4")
specrelay::verification::record "$tdir4" executor "scripts/test --changed --jobs auto" 1.0 0
specrelay::verification::record "$tdir4" executor "scripts/test test/config_test.sh" 1.0 0
json5="$(specrelay::timeline::render "$root" "$tdir4" nodup-task final --json)"
specrelay_test::assert_eq "no false duplicate for two different classified operations" \
  "0" "$(printf '%s' "$json5" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(len(d["duplicate_work"]))
')"

specrelay_test::summary
exit $?
