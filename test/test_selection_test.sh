#!/usr/bin/env bash
# test_selection_test.sh — spec 0017: change-aware test selection.
#
# Exercises `scripts/test --changed[...]` and the deterministic Ruby selection
# engine (lib/specrelay/select_tests.rb) through the runner: argument parsing,
# mapping validation, rule matching + union + dedup, selection modes, safe
# full-suite fallback, Git change sources (working tree / ref / evidence file),
# explainability, machine-readable evidence, and backward compatibility.
#
# Every case is HERMETIC: it builds an isolated temp project with its OWN test
# tree (fast fake *_test.sh files) and its own test-selection.yml, then points
# the runner at it via SPECRELAY_SELECTION_ROOT / SPECRELAY_TEST_DIR /
# SPECRELAY_CACHE_DIR. The real standalone suite is never run here.
# Run: test/test_selection_test.sh
#
# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

RUNNER="$SPECRELAY_ROOT/scripts/test"

# --- fixture map (references the fake tests created by mk_selproj) ------------
SEL_MAP='version: 1
rules:
  - id: alpha
    paths:
      - src/alpha/**
    tests:
      - test/alpha_test.sh
  - id: beta
    paths:
      - src/beta.sh
    tests:
      - test/beta_test.sh
      - test/shared_test.sh
  - id: gamma
    paths:
      - src/gamma.sh
    tests:
      - test/shared_test.sh
always:
  - test/always_test.sh
full_suite_if_changed:
  - src/core.sh
  - test/test-selection.yml
documentation_only:
  - docs/**
  - "**/*.md"
'

mk_tmp() {
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/srsel.XXXXXX")"; d="$(cd "$d" && pwd -P)"
  SPECRELAY_TEST_TMP_DIRS+=("$d"); printf '%s\n' "$d"
}

# add_seltest <dir> <name> <counter> [extra-body]
add_seltest() {
  local dir="$1" name="$2" counter="$3" body="${4:-}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" %q >> %q\n' "$name" "$counter"
    [ -n "$body" ] && printf '%s\n' "$body"
    printf 'exit 0\n'
  } > "$dir/$name"
  chmod +x "$dir/$name"
}

# mk_selproj — isolated git project with a fake test tree + fixture map.
mk_selproj() {
  local proj testd counter
  proj="$(mk_tmp)"; testd="$proj/test"; counter="$proj/.counter"
  mkdir -p "$testd" "$proj/src/alpha" "$proj/docs"
  : > "$counter"
  add_seltest "$testd" alpha_test.sh  "$counter"
  add_seltest "$testd" beta_test.sh   "$counter"
  add_seltest "$testd" gamma_test.sh  "$counter"
  add_seltest "$testd" shared_test.sh "$counter"
  add_seltest "$testd" always_test.sh "$counter"
  add_seltest "$testd" orphan_test.sh "$counter"
  printf '%s' "$SEL_MAP" > "$testd/test-selection.yml"
  printf 'echo core\n'    > "$proj/src/core.sh"
  printf 'echo beta\n'    > "$proj/src/beta.sh"
  printf 'echo gamma\n'   > "$proj/src/gamma.sh"
  printf 'echo a\n'       > "$proj/src/alpha/a.sh"
  printf 'echo loner\n'   > "$proj/src/loner.sh"
  printf '# guide\n'      > "$proj/docs/guide.md"
  ( cd "$proj" && git init -q && git config core.hooksPath /dev/null \
      && git config user.name t && git config user.email t@e.invalid \
      && git add -A && git commit -q -m base ) >/dev/null 2>&1
  printf '%s\n' "$proj"
}

reset_counter() { : > "$1/.counter"; }

# run_sel <proj> <cache> [args...]
run_sel() {
  local proj="$1" cache="$2"; shift 2
  SPECRELAY_SELECTION_ROOT="$proj" SPECRELAY_TEST_DIR="$proj/test" \
    SPECRELAY_CACHE_DIR="$cache" "$RUNNER" "$@"
}

# selected test names (from the "=== name ===" block headers), comma-joined
selected_names() { printf '%s\n' "$1" | awk -F'=== | ===' '/^=== /{print $2}' | LC_ALL=C sort | tr '\n' ','; }
# how many times a fake test recorded that it ran
ran_count() { grep -c "^$2\$" "$1/.counter" 2>/dev/null || true; }

# write a bad fixture map into a throwaway proj and validate it
validate_badmap() { # <yaml> ; prints stderr, sets global VBM_RC
  local proj cache; proj="$(mk_tmp)"; cache="$(mk_tmp)"
  mkdir -p "$proj/test"
  # a real test file so "nonexistent test" is the only failure when intended
  printf '#!/usr/bin/env bash\nexit 0\n' > "$proj/test/real_test.sh"; chmod +x "$proj/test/real_test.sh"
  printf '%s' "$1" > "$proj/test/test-selection.yml"
  SPECRELAY_SELECTION_ROOT="$proj" SPECRELAY_TEST_DIR="$proj/test" SPECRELAY_CACHE_DIR="$cache" \
    "$RUNNER" --validate-selection-map 2>&1
  VBM_RC=$?
}

########################################################################
echo "## Argument parsing"
########################################################################
proj="$(mk_selproj)"; cache="$(mk_tmp)"

reset_counter "$proj"; : > "$proj/empty.txt"
out="$(run_sel "$proj" "$cache" --changed-files "$proj/empty.txt" 2>/dev/null)"; rc=$?
specrelay_test::assert_eq "--changed-files with an empty list exits 0 (safe fallback)" "0" "$rc"

# --changed works (git working tree; modify a mapped source)
echo "echo a2" >> "$proj/src/alpha/a.sh"
reset_counter "$proj"
out="$(run_sel "$proj" "$cache" --changed --jobs 2 2>/dev/null)"; rc=$?
specrelay_test::assert_eq "--changed exits 0" "0" "$rc"
specrelay_test::assert_contains "--changed selects the mapped test" "$out" "=== alpha_test.sh ==="
git -C "$proj" checkout -- src/alpha/a.sh 2>/dev/null

# --changed-from requires a valid ref
run_sel "$proj" "$cache" --changed-from definitely-not-a-ref >/dev/null 2>&1
specrelay_test::assert_true "--changed-from rejects an invalid ref" "$( [ $? -ne 0 ]; echo $? )"

# --changed-files requires a readable file
run_sel "$proj" "$cache" --changed-files "$proj/no-such-evidence.txt" >/dev/null 2>&1
specrelay_test::assert_true "--changed-files rejects a missing file" "$( [ $? -ne 0 ]; echo $? )"

# incompatible change-source options are rejected
run_sel "$proj" "$cache" --changed --changed-from HEAD >/dev/null 2>&1
specrelay_test::assert_true "incompatible change sources are rejected" "$( [ $? -ne 0 ]; echo $? )"

# --explain works (with a source)
printf 'src/alpha/a.sh\n' > "$proj/ch.txt"
out="$(run_sel "$proj" "$cache" --changed-files "$proj/ch.txt" --explain 2>/dev/null)"
specrelay_test::assert_contains "--explain prints the rationale header" "$out" "Change-aware test selection"
run_sel "$proj" "$cache" --explain >/dev/null 2>&1
specrelay_test::assert_true "--explain without a change source is rejected" "$( [ $? -ne 0 ]; echo $? )"

# --validate-selection-map works
run_sel "$proj" "$cache" --validate-selection-map >/dev/null 2>&1
specrelay_test::assert_eq "--validate-selection-map accepts a valid map" "0" "$?"

# unknown option remains rejected
run_sel "$proj" "$cache" --changed --bogus-opt >/dev/null 2>&1
specrelay_test::assert_true "unknown option is still rejected" "$( [ $? -ne 0 ]; echo $? )"

########################################################################
echo "## Mapping validation"
########################################################################
validate_badmap 'version: 1
rules:
  - id: a
    paths: [src/**]
    tests: [test/real_test.sh]
always:
  - test/real_test.sh
full_suite_if_changed: [test/test-selection.yml]
documentation_only: ["**/*.md"]
' >/dev/null 2>&1
specrelay_test::assert_eq "valid mapping parses" "0" "$VBM_RC"

ebuf="$(mk_tmp)/e.txt"
validate_badmap 'version: 2
rules:
  - id: a
    paths: [x]
    tests: [test/real_test.sh]
' > "$ebuf" 2>&1
specrelay_test::assert_true "unknown schema version rejected" "$( [ "$VBM_RC" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "unknown version error is actionable" "$(cat "$ebuf")" "schema version"

validate_badmap 'version: 1
rules:
  - id: dup
    paths: [x]
    tests: [test/real_test.sh]
  - id: dup
    paths: [y]
    tests: [test/real_test.sh]
' >/dev/null 2>&1
specrelay_test::assert_true "duplicate rule id rejected" "$( [ "$VBM_RC" -ne 0 ]; echo $? )"

validate_badmap 'version: 1
rules:
  - id: a
    paths: [x]
    tests: [test/nope_test.sh]
' > "$ebuf" 2>&1
specrelay_test::assert_true "nonexistent test rejected" "$( [ "$VBM_RC" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "nonexistent test error names the file" "$(cat "$ebuf")" "nope_test.sh"

validate_badmap 'version: 1
rules:
  - id: a
    paths: ["src/[bad"]
    tests: [test/real_test.sh]
' >/dev/null 2>&1
specrelay_test::assert_true "invalid glob rejected" "$( [ "$VBM_RC" -ne 0 ]; echo $? )"

validate_badmap 'version: 1
rules:
  - id: a
    paths: ["../escape"]
    tests: [test/real_test.sh]
' >/dev/null 2>&1
specrelay_test::assert_true "path outside repository rejected" "$( [ "$VBM_RC" -ne 0 ]; echo $? )"

validate_badmap 'version: 1
surprise: true
rules:
  - id: a
    paths: [x]
    tests: [test/real_test.sh]
' >/dev/null 2>&1
specrelay_test::assert_true "unknown key rejected" "$( [ "$VBM_RC" -ne 0 ]; echo $? )"

validate_badmap 'version: 1
rules: []
' >/dev/null 2>&1
specrelay_test::assert_true "empty mapping rejected" "$( [ "$VBM_RC" -ne 0 ]; echo $? )"

########################################################################
echo "## Selection"
########################################################################
proj="$(mk_selproj)"; cache="$(mk_tmp)"

# one changed file selects expected tests (+ always)
reset_counter "$proj"; printf 'src/alpha/a.sh\n' > "$proj/ch.txt"
out="$(run_sel "$proj" "$cache" --changed-files "$proj/ch.txt" --jobs 3 2>/dev/null)"
specrelay_test::assert_eq "single-file selection is exactly {alpha,always}" \
  "alpha_test.sh,always_test.sh," "$(selected_names "$out")"

# multiple rules produce a union; duplicates removed (shared via beta+gamma once)
reset_counter "$proj"; printf 'src/beta.sh\nsrc/gamma.sh\n' > "$proj/ch.txt"
out="$(run_sel "$proj" "$cache" --changed-files "$proj/ch.txt" --jobs 3 2>/dev/null)"
specrelay_test::assert_eq "union of rules, deduped, deterministic order" \
  "always_test.sh,beta_test.sh,shared_test.sh," "$(selected_names "$out")"
specrelay_test::assert_eq "a test shared by two rules runs exactly once" "1" "$(ran_count "$proj" shared_test.sh)"

# always-run test is included in every narrow selection
specrelay_test::assert_eq "always-run test ran" "1" "$(ran_count "$proj" always_test.sh)"

# full-suite trigger selects all tests
reset_counter "$proj"; printf 'src/core.sh\n' > "$proj/ch.txt"
out="$(run_sel "$proj" "$cache" --changed-files "$proj/ch.txt" --jobs 3 2>/dev/null)"
specrelay_test::assert_eq "full-suite trigger runs the whole discovered suite" \
  "6" "$(printf '%s\n' "$out" | awk '/^Test files:/{print $3}')"
specrelay_test::assert_contains "full-suite trigger reports fallback mode" "$out" "full-suite-fallback"

# unmapped code file falls back to full suite
reset_counter "$proj"; printf 'src/loner.sh\n' > "$proj/ch.txt"
out="$(run_sel "$proj" "$cache" --changed-files "$proj/ch.txt" --explain 2>/dev/null)"
specrelay_test::assert_contains "unmapped code file falls back to full suite" "$out" "full-suite-fallback"
specrelay_test::assert_contains "unmapped fallback reason is explicit" "$out" "unmapped"

# documentation-only change follows documented policy
reset_counter "$proj"; printf 'docs/guide.md\n' > "$proj/ch.txt"
out="$(run_sel "$proj" "$cache" --changed-files "$proj/ch.txt" --jobs 2 2>/dev/null)"
specrelay_test::assert_contains "documentation-only mode is reported" "$out" "documentation-only"
specrelay_test::assert_contains "documentation-only never claims all tests passed" \
  "$out" "No implementation tests selected"
specrelay_test::assert_eq "documentation-only runs only the always/validation set" \
  "always_test.sh," "$(selected_names "$out")"

# mapping-file change triggers the full suite
reset_counter "$proj"; printf 'test/test-selection.yml\n' > "$proj/ch.txt"
out="$(run_sel "$proj" "$cache" --changed-files "$proj/ch.txt" 2>/dev/null)"
specrelay_test::assert_contains "mapping-file change triggers full suite" "$out" "full-suite-fallback"
specrelay_test::assert_eq "mapping-file change runs every test" "6" "$(printf '%s\n' "$out" | awk '/^Test files:/{print $3}')"

########################################################################
echo "## Git inputs"
########################################################################
# unstaged tracked change is detected
proj="$(mk_selproj)"; cache="$(mk_tmp)"
echo "echo more" >> "$proj/src/beta.sh"
reset_counter "$proj"
out="$(run_sel "$proj" "$cache" --changed --jobs 3 2>/dev/null)"
specrelay_test::assert_contains "unstaged tracked change is detected" "$out" "=== beta_test.sh ==="

# staged change is detected
proj="$(mk_selproj)"; cache="$(mk_tmp)"
echo "echo staged" >> "$proj/src/gamma.sh"; git -C "$proj" add src/gamma.sh
reset_counter "$proj"
out="$(run_sel "$proj" "$cache" --changed --jobs 3 2>/dev/null)"
specrelay_test::assert_contains "staged change is detected" "$out" "=== shared_test.sh ==="

# untracked file is detected (new file under a mapped path)
proj="$(mk_selproj)"; cache="$(mk_tmp)"
printf 'echo new\n' > "$proj/src/alpha/new.sh"
reset_counter "$proj"
out="$(run_sel "$proj" "$cache" --changed --jobs 3 2>/dev/null)"
specrelay_test::assert_contains "untracked file is detected" "$out" "=== alpha_test.sh ==="

# runtime directories are excluded (a mapped change + a runtime-dir change =>
# still a narrow mapped selection, never full-suite, and never listed)
proj="$(mk_selproj)"; cache="$(mk_tmp)"
echo "echo x" >> "$proj/src/alpha/a.sh"
mkdir -p "$proj/.specrelay-runs/tasks"; printf 'junk\n' > "$proj/.specrelay-runs/tasks/junk.sh"
reset_counter "$proj"
out="$(run_sel "$proj" "$cache" --changed --selection-json "$proj/sel.json" --jobs 3 2>/dev/null)"
specrelay_test::assert_contains "runtime-dir change does not force full suite" "$out" "Selection mode:  mapped"
specrelay_test::assert_true "runtime path is excluded from changed_files" \
  "$( python3 -c "import json;d=json.load(open('$proj/sel.json'));import sys;sys.exit(0 if not any('.specrelay-runs' in f for f in d['changed_files']) else 1)"; echo $? )"

# valid Git ref comparison works
proj="$(mk_selproj)"; cache="$(mk_tmp)"
echo "echo r" >> "$proj/src/beta.sh"
reset_counter "$proj"
out="$(run_sel "$proj" "$cache" --changed-from HEAD --jobs 3 2>/dev/null)"; rc=$?
specrelay_test::assert_eq "valid git ref comparison exits 0" "0" "$rc"
specrelay_test::assert_contains "git ref comparison selects mapped tests" "$out" "=== beta_test.sh ==="

# invalid Git ref fails clearly
err="$(run_sel "$proj" "$cache" --changed-from nope-nope 2>&1 >/dev/null)"
specrelay_test::assert_contains "invalid git ref error is clear" "$err" "invalid git ref"

# rename evidence is handled conservatively (old path's rule still selected)
proj="$(mk_selproj)"; cache="$(mk_tmp)"
reset_counter "$proj"; printf 'R100\tsrc/beta.sh\tsrc/renamed.sh\n' > "$proj/ren.txt"
out="$(run_sel "$proj" "$cache" --changed-files "$proj/ren.txt" --jobs 3 2>/dev/null)"
specrelay_test::assert_contains "rename evidence keeps the old path's tests" "$out" "=== beta_test.sh ==="

########################################################################
echo "## Explicit changed-file input"
########################################################################
proj="$(mk_selproj)"; cache="$(mk_tmp)"

# path-only input works
reset_counter "$proj"; printf 'src/alpha/a.sh\n' > "$proj/p.txt"
out="$(run_sel "$proj" "$cache" --changed-files "$proj/p.txt" 2>/dev/null)"
specrelay_test::assert_contains "path-only input works" "$out" "=== alpha_test.sh ==="

# existing name-status evidence is normalized
reset_counter "$proj"; printf 'M\tsrc/alpha/a.sh\nA\tsrc/beta.sh\n' > "$proj/ns.txt"
out="$(run_sel "$proj" "$cache" --changed-files "$proj/ns.txt" 2>/dev/null)"
specrelay_test::assert_eq "name-status evidence is normalized" \
  "alpha_test.sh,always_test.sh,beta_test.sh,shared_test.sh," "$(selected_names "$out")"

# malformed evidence fails clearly
reset_counter "$proj"; printf 'R100\tonly-one-path\n' > "$proj/bad.txt"
err="$(run_sel "$proj" "$cache" --changed-files "$proj/bad.txt" 2>&1 >/dev/null)"
specrelay_test::assert_true "malformed evidence fails" "$( [ $? -ne 0 ]; echo $? )"
specrelay_test::assert_contains "malformed evidence error is clear" "$err" "malformed"

# missing evidence file fails
run_sel "$proj" "$cache" --changed-files "$proj/absent.txt" >/dev/null 2>&1
specrelay_test::assert_true "missing evidence file fails" "$( [ $? -ne 0 ]; echo $? )"

# duplicate changed paths are removed
reset_counter "$proj"; printf 'src/alpha/a.sh\nsrc/alpha/a.sh\n' > "$proj/dup.txt"
out="$(run_sel "$proj" "$cache" --changed-files "$proj/dup.txt" --selection-json "$proj/d.json" 2>/dev/null)"
cnt="$(python3 -c "import json;print(json.load(open('$proj/d.json'))['changed_files'].count('src/alpha/a.sh'))")"
specrelay_test::assert_eq "duplicate changed paths are removed" "1" "$cnt"

########################################################################
echo "## Execution"
########################################################################
proj="$(mk_selproj)"; cache="$(mk_tmp)"

# selected run exactly once; non-selected do not run
reset_counter "$proj"; printf 'src/beta.sh\n' > "$proj/e.txt"
out="$(run_sel "$proj" "$cache" --changed-files "$proj/e.txt" --jobs 3 --timings 2>/dev/null)"
specrelay_test::assert_eq "selected test runs exactly once (beta)" "1" "$(ran_count "$proj" beta_test.sh)"
specrelay_test::assert_eq "selected test runs exactly once (shared)" "1" "$(ran_count "$proj" shared_test.sh)"
specrelay_test::assert_eq "non-selected test does not run (alpha)" "0" "$(ran_count "$proj" alpha_test.sh)"
specrelay_test::assert_eq "non-selected test does not run (orphan)" "0" "$(ran_count "$proj" orphan_test.sh)"

# selected tests use the parallel runner (Workers reported)
specrelay_test::assert_eq "selected tests use the parallel runner" "3" \
  "$(printf '%s\n' "$out" | awk '/^Workers:/{print $2}')"
# timing output still works alongside selection
specrelay_test::assert_contains "timing output works with selection" "$out" "Slowest test files:"
specrelay_test::assert_true "timing JSON is written with selection" \
  "$( [ -f "$cache/tests/latest.json" ]; echo $? )"

# serial-only behavior is preserved for a selected test
proj="$(mk_selproj)"; cache="$(mk_tmp)"
printf 'shared_test.sh\n' > "$proj/test/serial-tests.txt"
reset_counter "$proj"; printf 'src/beta.sh\n' > "$proj/e.txt"
run_sel "$proj" "$cache" --changed-files "$proj/e.txt" --jobs 3 --timings >/dev/null 2>&1
smode="$(python3 -c "import json;print([t['execution_mode'] for t in json.load(open('$cache/tests/latest.json'))['tests'] if t['name']=='shared_test.sh'][0])" 2>/dev/null)"
specrelay_test::assert_eq "serial-only selected test runs serial" "serial" "$smode"

# a failing selected test fails the command; logs remain available
proj="$(mk_selproj)"; cache="$(mk_tmp)"
add_seltest "$proj/test" beta_test.sh "$proj/.counter" 'echo "BETA-BOOM" >&2; exit 1'
reset_counter "$proj"; printf 'src/beta.sh\n' > "$proj/e.txt"
out="$(run_sel "$proj" "$cache" --changed-files "$proj/e.txt" --jobs 3 2>/dev/null)"; rc=$?
specrelay_test::assert_true "a failing selected test fails the command" "$( [ "$rc" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "complete logs remain available" "$out" "BETA-BOOM"

########################################################################
echo "## Explainability"
########################################################################
proj="$(mk_selproj)"; cache="$(mk_tmp)"
reset_counter "$proj"; printf 'src/alpha/a.sh\ndocs/guide.md\n' > "$proj/x.txt"
out="$(run_sel "$proj" "$cache" --changed-files "$proj/x.txt" --explain 2>/dev/null)"
specrelay_test::assert_contains "every selected test has a reason" "$out" "reason: rule alpha"
specrelay_test::assert_contains "ignored file has a reason" "$out" "documentation-only rule"
specrelay_test::assert_contains "full verification policy is displayed" "$out" "Full verification"
# fallback has an explicit reason (full-suite case)
reset_counter "$proj"; printf 'src/core.sh\n' > "$proj/x.txt"
out="$(run_sel "$proj" "$cache" --changed-files "$proj/x.txt" --explain 2>/dev/null)"
specrelay_test::assert_contains "fallback has an explicit reason" "$out" "matches full-suite trigger"

########################################################################
echo "## Evidence"
########################################################################
proj="$(mk_selproj)"; cache="$(mk_tmp)"
reset_counter "$proj"; printf 'src/alpha/a.sh\n' > "$proj/x.txt"
tim="$proj/07-test-timings.json"; sel="$proj/07-test-selection.json"
run_sel "$proj" "$cache" --changed-files "$proj/x.txt" --timings \
  --selection-json "$sel" >/dev/null 2>&1
# also route task timing to an explicit destination in the same run
SPECRELAY_SELECTION_ROOT="$proj" SPECRELAY_TEST_DIR="$proj/test" SPECRELAY_CACHE_DIR="$cache" \
  SPECRELAY_TEST_TIMINGS_OUT="$tim" "$RUNNER" --changed-files "$proj/x.txt" --timings \
  --selection-json "$sel" >/dev/null 2>&1
specrelay_test::assert_true "selection JSON is valid" \
  "$( python3 -c "import json;json.load(open('$sel'))"; echo $? )"
specrelay_test::assert_true "task-specific selection output can be written explicitly" \
  "$( [ -f "$sel" ]; echo $? )"
# atomic write leaves no temp file
lefto="$(ls "$proj"/07-test-selection.json.tmp.* 2>/dev/null | wc -l | tr -d ' ')"
specrelay_test::assert_eq "selection output is atomic (no leftover temp)" "0" "$lefto"
# timing and selection results can be associated via the common run id
sel_rid="$(python3 -c "import json;print(json.load(open('$sel'))['run_id'])")"
tim_rid="$(python3 -c "import json;print(json.load(open('$tim'))['run_id'])")"
specrelay_test::assert_eq "timing and selection share a run id" "$sel_rid" "$tim_rid"
# no new top-level runtime directory (evidence lives under the cache namespace)
specrelay_test::assert_true "selection evidence uses the existing cache namespace" \
  "$( [ -f "$cache/tests/latest-selection.json" ]; echo $? )"
specrelay_test::assert_true "no new top-level results directory is created" \
  "$( [ ! -d "$proj/results" ] && [ ! -d "$proj/test-selection-runs" ]; echo $? )"

########################################################################
echo "## Compatibility"
########################################################################
proj="$(mk_selproj)"; cache="$(mk_tmp)"

# direct explicit test-file execution remains unchanged (no change-aware output)
reset_counter "$proj"
out="$(run_sel "$proj" "$cache" "$proj/test/alpha_test.sh" 2>/dev/null)"; rc=$?
specrelay_test::assert_eq "explicit test-file execution still exits 0" "0" "$rc"
specrelay_test::assert_contains "explicit execution keeps the standard success message" "$out" "All standalone tests passed."
specrelay_test::assert_not_contains "explicit execution is not change-aware" "$out" "Change-aware selection"
specrelay_test::assert_eq "explicit execution runs only the given file" "1" "$(ran_count "$proj" alpha_test.sh)"

# default scripts/test still runs the full suite
reset_counter "$proj"
out="$(run_sel "$proj" "$cache" --jobs 3 2>/dev/null)"
specrelay_test::assert_eq "default run discovers the whole suite" "6" \
  "$(printf '%s\n' "$out" | awk '/^Test files:/{print $3}')"
specrelay_test::assert_contains "default run reports standard success" "$out" "All standalone tests passed."
specrelay_test::assert_not_contains "default run is not change-aware" "$out" "Change-aware selection"

specrelay_test::summary
exit $?
