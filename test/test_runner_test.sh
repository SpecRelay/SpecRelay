#!/usr/bin/env bash
# test_runner_test.sh — spec 0016: parallel test runner and timing profiler.
#
# Exercises scripts/test itself: argument parsing, discovery, bounded parallel
# execution, deterministic output, per-file timing + JSON, slowest reporting,
# slow-threshold marking, serial-only classification, targeted execution,
# interrupt cleanup, and the scripts/smoke --skip-tests contract.
#
# It NEVER runs the real standalone suite (that would recurse and be slow):
# every runner invocation points SPECRELAY_TEST_DIR at a throwaway fixture test
# directory and SPECRELAY_CACHE_DIR / TMPDIR at isolated temp dirs, so the whole
# file is hermetic and parallel-safe.  Run: test/test_runner_test.sh
#
# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

RUNNER="$SPECRELAY_ROOT/scripts/test"
SMOKE="$SPECRELAY_ROOT/scripts/smoke"

# --- fixture + assertion helpers ---------------------------------------------
mk_tmp() {
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/srtr.XXXXXX")"
  d="$(cd "$d" && pwd -P)"
  SPECRELAY_TEST_TMP_DIRS+=("$d")   # cleaned by test_helper's EXIT trap
  printf '%s\n' "$d"
}

# add_test <dir> <name> [body]   — default body prints "<name> ran" and exits 0
add_test() {
  local dir="$1" name="$2" body="${3:-printf '%s ran\\n' \"$2\"}"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$dir/$name"
  chmod +x "$dir/$name"
}

# run the runner against a fixture dir/cache; extra args passed through
run_rt() {
  local fx="$1" cache="$2"; shift 2
  SPECRELAY_TEST_DIR="$fx" SPECRELAY_CACHE_DIR="$cache" "$RUNNER" "$@"
}

# assert an awk boolean expression is true
assert_awk() {
  local desc="$1" expr="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if awk "BEGIN{exit !($expr)}" 2>/dev/null; then
    echo "ok - $desc"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "NOT OK - $desc (expr: $expr)"
  fi
}

json_num() { # <file> <top-level key>
  python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2"
}

########################################################################
echo "## Argument parsing"
########################################################################
fx="$(mk_tmp)"; cache="$(mk_tmp)"
add_test "$fx" aaa_test.sh
add_test "$fx" bbb_test.sh

out="$(run_rt "$fx" "$cache" 2>/dev/null)"; rc=$?
specrelay_test::assert_eq "default invocation exits 0" "0" "$rc"
specrelay_test::assert_contains "default invocation reports success" "$out" "All standalone tests passed."

out="$(run_rt "$fx" "$cache" --jobs 1 2>/dev/null)"; rc=$?
specrelay_test::assert_eq "--jobs 1 exits 0" "0" "$rc"
w="$(printf '%s\n' "$out" | awk '/^Workers:/{print $2}')"
specrelay_test::assert_eq "--jobs 1 uses one worker" "1" "$w"

out="$(run_rt "$fx" "$cache" --jobs auto 2>/dev/null)"; rc=$?
specrelay_test::assert_eq "--jobs auto exits 0" "0" "$rc"
w="$(printf '%s\n' "$out" | awk '/^Workers:/{print $2}')"
assert_awk "--jobs auto selects >= 1 worker" "$w >= 1"

out="$(SPECRELAY_TEST_DIR="$fx" SPECRELAY_CACHE_DIR="$cache" SPECRELAY_TEST_JOBS=2 "$RUNNER" 2>/dev/null)"
w="$(printf '%s\n' "$out" | awk '/^Workers:/{print $2}')"
specrelay_test::assert_eq "SPECRELAY_TEST_JOBS override works" "2" "$w"

out="$(SPECRELAY_TEST_DIR="$fx" SPECRELAY_CACHE_DIR="$cache" SPECRELAY_TEST_JOBS=2 "$RUNNER" --jobs 3 2>/dev/null)"
w="$(printf '%s\n' "$out" | awk '/^Workers:/{print $2}')"
specrelay_test::assert_eq "--jobs overrides SPECRELAY_TEST_JOBS" "3" "$w"

for bad in 0 -1 abc 999999; do
  run_rt "$fx" "$cache" --jobs "$bad" >/dev/null 2>&1
  specrelay_test::assert_true "invalid --jobs $bad is rejected" "$( [ $? -ne 0 ]; echo $? )"
done

out="$(run_rt "$fx" "$cache" --serial 2>/dev/null)"
w="$(printf '%s\n' "$out" | awk '/^Workers:/{print $2}')"
specrelay_test::assert_eq "--serial forces one worker" "1" "$w"

out="$(run_rt "$fx" "$cache" --timings 2>/dev/null)"
specrelay_test::assert_contains "--timings prints the slowest section" "$out" "Slowest test files:"

run_rt "$fx" "$cache" --slowest abc >/dev/null 2>&1
specrelay_test::assert_true "--slowest validates its argument" "$( [ $? -ne 0 ]; echo $? )"
run_rt "$fx" "$cache" --slow-threshold notnum >/dev/null 2>&1
specrelay_test::assert_true "--slow-threshold validates its argument" "$( [ $? -ne 0 ]; echo $? )"
run_rt "$fx" "$cache" --nope >/dev/null 2>&1
specrelay_test::assert_true "unknown option is rejected" "$( [ $? -ne 0 ]; echo $? )"

########################################################################
echo "## Discovery"
########################################################################
fx="$(mk_tmp)"; cache="$(mk_tmp)"
add_test "$fx" ccc_test.sh
add_test "$fx" aaa_test.sh
add_test "$fx" bbb_test.sh
# non-test files must be ignored
printf '#!/usr/bin/env bash\necho helper\n' > "$fx/my_helper.sh"; chmod +x "$fx/my_helper.sh"
printf '#!/usr/bin/env bash\necho notatest\n' > "$fx/plainfile.sh"; chmod +x "$fx/plainfile.sh"

out="$(run_rt "$fx" "$cache" 2>/dev/null)"
n="$(printf '%s\n' "$out" | awk '/^Test files:/{print $3}')"
specrelay_test::assert_eq "discovers exactly the *_test.sh files (helpers excluded)" "3" "$n"
order="$(printf '%s\n' "$out" | awk -F'=== | ===' '/^=== /{print $2}' | tr '\n' ',')"
specrelay_test::assert_eq "discovery order is deterministic (sorted)" "aaa_test.sh,bbb_test.sh,ccc_test.sh," "$order"

# explicit selection + order
out="$(run_rt "$fx" "$cache" "$fx/bbb_test.sh" "$fx/aaa_test.sh" 2>/dev/null)"
order="$(printf '%s\n' "$out" | awk -F'=== | ===' '/^=== /{print $2}' | tr '\n' ',')"
specrelay_test::assert_eq "explicit test selection preserves given order" "bbb_test.sh,aaa_test.sh," "$order"

run_rt "$fx" "$cache" "$fx/does_not_exist_test.sh" >/dev/null 2>&1
specrelay_test::assert_true "missing explicit test is rejected" "$( [ $? -ne 0 ]; echo $? )"
outside="$(mk_tmp)"; add_test "$outside" zzz_test.sh
run_rt "$fx" "$cache" "$outside/zzz_test.sh" >/dev/null 2>&1
specrelay_test::assert_true "test file outside the test root is rejected" "$( [ $? -ne 0 ]; echo $? )"

########################################################################
echo "## Parallel execution"
########################################################################
fx="$(mk_tmp)"; cache="$(mk_tmp)"
counter="$fx/.counter"; : > "$counter"
for t in aaa bbb ddd eee; do
  add_test "$fx" "${t}_test.sh" "printf '%s\n' ${t}_test.sh >> '$counter'; sleep 0.5"
done
out="$(run_rt "$fx" "$cache" --jobs 4 --timings 2>/dev/null)"; rc=$?
specrelay_test::assert_eq "parallel run of all-passing suite exits 0" "0" "$rc"
lines="$(wc -l < "$counter" | tr -d ' ')"
specrelay_test::assert_eq "each test file runs exactly once (line count)" "4" "$lines"
dups="$(sort "$counter" | uniq -d | wc -l | tr -d ' ')"
specrelay_test::assert_eq "no test file runs more than once" "0" "$dups"
wall="$(json_num "$cache/tests/latest.json" wall_seconds)"
ssum="$(json_num "$cache/tests/latest.json" serial_sum_seconds)"
assert_awk "parallel tests overlap in wall-clock (wall < serial sum)" "$wall < $ssum"

# exit codes + failure aggregation
fx="$(mk_tmp)"; cache="$(mk_tmp)"
add_test "$fx" aaa_test.sh "exit 0"
add_test "$fx" bbb_test.sh "exit 7"
add_test "$fx" ccc_test.sh "exit 5"
out="$(run_rt "$fx" "$cache" --jobs 3 --timings 2>/dev/null)"; rc=$?
specrelay_test::assert_true "one (or more) failing test makes the suite fail" "$( [ "$rc" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "all failures are reported (bbb)" "$out" "bbb_test.sh"
specrelay_test::assert_contains "all failures are reported (ccc)" "$out" "ccc_test.sh"
ec_bbb="$(python3 -c "import json;print([t['exit_code'] for t in json.load(open('$cache/tests/latest.json'))['tests'] if t['name']=='bbb_test.sh'][0])")"
specrelay_test::assert_eq "exit code is preserved in timing JSON" "7" "$ec_bbb"

########################################################################
echo "## Deterministic output (completion order independent)"
########################################################################
fx="$(mk_tmp)"; cache="$(mk_tmp)"
add_test "$fx" aaa_test.sh "printf 'aaa-1\naaa-2\naaa-3\n'; sleep 1"   # finishes LAST
add_test "$fx" bbb_test.sh "printf 'bbb-1\n'; echo bbb-err >&2; sleep 0.4"
add_test "$fx" ccc_test.sh "printf 'ccc-1\n'"                          # finishes FIRST
out="$(run_rt "$fx" "$cache" --jobs 3 2>/dev/null)"
order="$(printf '%s\n' "$out" | awk -F'=== | ===' '/^=== /{print $2}' | tr '\n' ',')"
specrelay_test::assert_eq "final order stays deterministic despite completion order" "aaa_test.sh,bbb_test.sh,ccc_test.sh," "$order"
specrelay_test::assert_contains "complete stdout preserved" "$out" "aaa-3"
specrelay_test::assert_contains "complete stderr preserved (merged into capture)" "$out" "bbb-err"
# not interleaved: aaa's three lines appear contiguously under its header
specrelay_test::assert_contains "output is not interleaved between files" "$out" "=== aaa_test.sh ===
aaa-1
aaa-2
aaa-3"
# redirected output remains complete
redir="$fx/redir.log"
run_rt "$fx" "$cache" --jobs 3 >"$redir" 2>/dev/null
specrelay_test::assert_contains "redirected output keeps every test block" "$(cat "$redir")" "=== ccc_test.sh ==="
specrelay_test::assert_contains "redirected output keeps the summary" "$(cat "$redir")" "Wall time:"

########################################################################
echo "## Timing + JSON"
########################################################################
fx="$(mk_tmp)"; cache="$(mk_tmp)"
add_test "$fx" fast_test.sh "printf fast\n"
add_test "$fx" slow_test.sh "sleep 1"
add_test "$fx" mid_test.sh "sleep 0.5"
out="$(run_rt "$fx" "$cache" --jobs 3 --timings --slow-threshold 0.4 2>/dev/null)"
specrelay_test::assert_contains "wall time is recorded" "$out" "Wall time:"
specrelay_test::assert_contains "serial sum is recorded" "$out" "Serial sum:"
# slowest list is sorted descending (slow_test first of the three)
slow_first="$(printf '%s\n' "$out" | awk '/^Slowest test files:/{getline; print $2}')"
specrelay_test::assert_eq "slowest list is sorted (slowest first)" "slow_test.sh" "$slow_first"
specrelay_test::assert_contains "slow-threshold marks slow files" "$out" "SLOW  slow_test.sh"
# every test (incl. any failing one) has a numeric duration
python3 - "$cache/tests/latest.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schema_version"] == 1
for t in d["tests"]:
    assert isinstance(t["duration_seconds"], (int, float)), t
assert isinstance(d["wall_seconds"], (int, float))
assert isinstance(d["serial_sum_seconds"], (int, float))
print("JSON_OK")
PY
specrelay_test::assert_true "timing JSON is valid and well-typed" "$?"
# failing test still receives timing
fx3="$(mk_tmp)"; cache3="$(mk_tmp)"
add_test "$fx3" boom_test.sh "sleep 0.3; exit 1"
run_rt "$fx3" "$cache3" --timings >/dev/null 2>&1
dur="$(python3 -c "import json;print(json.load(open('$cache3/tests/latest.json'))['tests'][0]['duration_seconds'])")"
assert_awk "failing test still receives a duration" "$dur >= 0"
# atomic write leaves no leftover temp file
leftovers="$(ls "$cache/tests/"*.tmp.* 2>/dev/null | wc -l | tr -d ' ')"
specrelay_test::assert_eq "no leftover temp JSON file remains (atomic write)" "0" "$leftovers"
# no cache dir/files created without timing persistence enabled
fx4="$(mk_tmp)"; cache4="$(mk_tmp)"
add_test "$fx4" aaa_test.sh
run_rt "$fx4" "$cache4" >/dev/null 2>&1
specrelay_test::assert_true "plain run creates no timing directory (no new dir policy)" \
  "$( [ ! -d "$cache4/tests" ]; echo $? )"
# task-specific timing evidence to an explicit destination
tout="$fx4/07-test-timings.json"
SPECRELAY_TEST_DIR="$fx4" SPECRELAY_CACHE_DIR="$cache4" SPECRELAY_TEST_TIMINGS_OUT="$tout" "$RUNNER" >/dev/null 2>&1
specrelay_test::assert_true "explicit task timing destination is written" "$( [ -f "$tout" ]; echo $? )"
python3 -c "import json;json.load(open('$tout'))" && specrelay_test::assert_true "task timing JSON is valid" 0 \
  || specrelay_test::assert_true "task timing JSON is valid" 1

########################################################################
echo "## Serial-only tests"
########################################################################
fx="$(mk_tmp)"; cache="$(mk_tmp)"
add_test "$fx" aaa_test.sh "sleep 0.6"
add_test "$fx" bbb_test.sh "sleep 0.6"
printf '# comment\naaa_test.sh\nbbb_test.sh\n' > "$fx/serial-tests.txt"
run_rt "$fx" "$cache" --jobs 4 --timings >/dev/null 2>&1
wall="$(json_num "$cache/tests/latest.json" wall_seconds)"
ssum="$(json_num "$cache/tests/latest.json" serial_sum_seconds)"
# both serial-only => they must NOT overlap => wall ~ sum (not halved)
assert_awk "serial-only tests do not overlap each other" "$wall >= ($ssum * 0.8)"
modes="$(python3 -c "import json;d=json.load(open('$cache/tests/latest.json'));print(','.join(sorted(set(t['execution_mode'] for t in d['tests']))))")"
specrelay_test::assert_eq "serial-only tests run in serial mode" "serial" "$modes"

# a mix: one serial + two parallel-safe => the parallel pair overlaps
fx="$(mk_tmp)"; cache="$(mk_tmp)"
add_test "$fx" aaa_test.sh "sleep 0.6"
add_test "$fx" bbb_test.sh "sleep 0.6"
add_test "$fx" sss_test.sh "sleep 0.6"
printf 'sss_test.sh\n' > "$fx/serial-tests.txt"
run_rt "$fx" "$cache" --jobs 3 --timings >/dev/null 2>&1
wall="$(json_num "$cache/tests/latest.json" wall_seconds)"
ssum="$(json_num "$cache/tests/latest.json" serial_sum_seconds)"
# parallel pair overlaps, so wall (~1.2s) < serial sum (~1.8s)
assert_awk "parallel-safe tests still run concurrently around a serial one" "$wall < $ssum"
smode="$(python3 -c "import json;print([t['execution_mode'] for t in json.load(open('$cache/tests/latest.json'))['tests'] if t['name']=='sss_test.sh'][0])")"
specrelay_test::assert_eq "declared test runs serial while others run parallel" "serial" "$smode"

# invalid serial metadata fails clearly
fx="$(mk_tmp)"; cache="$(mk_tmp)"
add_test "$fx" aaa_test.sh
printf 'this is not a valid entry\n' > "$fx/serial-tests.txt"
err="$(run_rt "$fx" "$cache" --jobs 2 2>&1 >/dev/null)"; rc=$?
specrelay_test::assert_true "invalid serial metadata fails" "$( [ "$rc" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "invalid serial metadata error is clear" "$err" "serial-tests.txt"

########################################################################
echo "## Interrupt handling (SIGTERM)"
########################################################################
# NOTE: SIGTERM (not SIGINT) is used here because a shell backgrounds jobs with
# SIGINT set to ignore, which a script's trap cannot re-enable; a real Ctrl-C in
# a foreground terminal is SIGINT and is handled the same way by the trap.
fx="$(mk_tmp)"; cache="$(mk_tmp)"; priv="$(mk_tmp)"; pids="$(mk_tmp)"
mkdir -p "$cache/tests"
printf '{"schema_version":1,"marker":"PREEXISTING"}\n' > "$cache/tests/latest.json"
add_test "$fx" quick_test.sh "printf quick\n"
add_test "$fx" slow_test.sh "sleep 30 & echo \$! > '$pids/child.pid'; wait"
TMPDIR="$priv" SPECRELAY_TEST_DIR="$fx" SPECRELAY_CACHE_DIR="$cache" "$RUNNER" --jobs 2 --timings \
  >"$fx/int.out" 2>"$fx/int.err" &
runner_pid=$!
# wait for the slow child to spawn, then interrupt
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -f "$pids/child.pid" ] && break
  sleep 0.2
done
child_pid="$(cat "$pids/child.pid" 2>/dev/null)"
kill -TERM "$runner_pid" 2>/dev/null
wait "$runner_pid"; int_rc=$?
sleep 0.3
specrelay_test::assert_true "interrupted run exits non-zero" "$( [ "$int_rc" -ne 0 ]; echo $? )"
specrelay_test::assert_true "no orphan child test process remains" \
  "$( kill -0 "$child_pid" 2>/dev/null; [ $? -ne 0 ]; echo $? )"
specrelay_test::assert_true "per-worker temp capture dir is cleaned up" \
  "$( ls -d "$priv"/specrelay-test-run.* >/dev/null 2>&1; [ $? -ne 0 ]; echo $? )"
specrelay_test::assert_contains "interrupt report names a cancelled test" "$(cat "$fx/int.out")" "cancelled"
marker="$(python3 -c "import json;print(json.load(open('$cache/tests/latest.json')).get('marker'))" 2>/dev/null)"
specrelay_test::assert_eq "prior valid timing JSON is left intact by an interrupt" "PREEXISTING" "$marker"

########################################################################
echo "## Smoke --skip-tests contract"
########################################################################
# The smoke script's other steps (install/upgrade/fake-run) are exercised by
# install_upgrade_test.sh and scripts/smoke itself; running the whole thing here
# would be slow and would re-run the suite. We assert the runner-relevant
# contract on the smoke source (the same non-recursive approach
# release_readiness_test.sh uses) plus a live invalid-option check.
smoke_src="$(cat "$SMOKE")"
specrelay_test::assert_contains "smoke supports --skip-tests" "$smoke_src" "--skip-tests"
specrelay_test::assert_contains "smoke skip is announced visibly" "$smoke_src" "Standalone suite: SKIPPED by explicit --skip-tests"
specrelay_test::assert_contains "smoke still runs the suite by default (scripts/test)" "$smoke_src" '"$ROOT/scripts/test"'
for step in doctor version install upgrade uninstall; do
  specrelay_test::assert_contains "smoke still performs the $step check" "$smoke_src" "$step"
done
"$SMOKE" --bogus-option >/dev/null 2>&1
specrelay_test::assert_true "invalid smoke option fails" "$( [ $? -ne 0 ]; echo $? )"

specrelay_test::summary
exit $?
