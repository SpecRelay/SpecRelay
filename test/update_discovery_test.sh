#!/usr/bin/env bash
# update_discovery_test.sh — spec 0022, section 5: daily update discovery,
# the 24h cache, version-specific dismissal, CI/non-interactive safety, and
# discovery-failure non-blocking behavior. Exercises the REAL installed
# 'specrelay run' entry point against a fake-provider consumer project, with
# a REAL local Git repo standing in for the "official" update source (no
# network). Closed stdin simulates CI.
#
#   test/update_discovery_test.sh
#
# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

INSTALL_SH="$SPECRELAY_ROOT/install/install.sh"
SOURCE_VERSION="$(tr -d '[:space:]' < "$SPECRELAY_ROOT/VERSION")"

WORK="$(specrelay_test::mktemp_project)"
UPSTREAM="$WORK/upstream"
mkdir -p "$UPSTREAM"
cp -R "$SPECRELAY_ROOT"/. "$UPSTREAM"/
rm -rf "$UPSTREAM/.git" "$UPSTREAM/.specrelay-runs" "$UPSTREAM/.specrelay-cache" "$UPSTREAM/.specrelay-locks"
# The upstream fixture's FIRST tag matches the installed SOURCE_VERSION
# exactly (so "no update available yet" is genuinely true), not an arbitrary
# higher number.
(
  cd "$UPSTREAM" \
    && git init -q \
    && git config core.hooksPath /dev/null \
    && git config user.name "SpecRelay Test" \
    && git config user.email "specrelay-test@example.invalid" \
    && git add -A \
    && git commit -q -m "v$SOURCE_VERSION" \
    && git tag "v$SOURCE_VERSION"
)

PREFIX="$WORK/prefix"
"$INSTALL_SH" --prefix "$PREFIX" >/dev/null 2>&1
INSTALLED="$PREFIX/bin/specrelay"
SHARE="$PREFIX/share/specrelay"
META="$SHARE/install-metadata.json"
python3 -c '
import json, sys
meta, repo = sys.argv[1], sys.argv[2]
d = json.load(open(meta))
d["update_source"] = {"type": "official-git", "repository": repo, "ref": "main"}
json.dump(d, open(meta, "w"))
' "$META" "$UPSTREAM"

# A fresh fake-provider consumer project per scenario — a task run leaves the
# fake executor's implementation artifact UNCOMMITTED in the working tree, so
# reusing one consumer across multiple NEW task creations would trip the
# (unrelated, legitimate) dirty-baseline guard. Only scenarios that re-run the
# SAME already-terminal task (scenario 2) intentionally reuse one.
specrelay::fresh_consumer() {
  local c spec_dir
  c="$(specrelay_test::mktemp_specrelay_project)"
  spec_dir="$c/docs/sdd/0001-demo"
  mkdir -p "$spec_dir"
  echo "# demo" > "$spec_dir/spec.md"
  (cd "$c" && git add -A && git commit -q -m "add spec")
  printf '%s\n' "$c"
}

specrelay::run_installed_in() {
  local consumer="$1"; shift
  (cd "$consumer" && env -u SPECRELAY_HOME "$@")
}

# --- 1. no newer version yet: no advisory, no state mutation surprises -----
CONSUMER="$(specrelay::fresh_consumer)"
same_out="$(specrelay::run_installed_in "$CONSUMER" "$INSTALLED" run docs/sdd/0001-demo/spec.md --task-id demo-a 2>&1 </dev/null)"
specrelay_test::assert_true "'run' succeeds with no update available" "$?"
specrelay_test::assert_not_contains "'run' prints no update-available advisory when already current" "$same_out" "an update is available"
specrelay_test::assert_true "an automatic check recorded last_checked_at" \
  "$( [ -n "$(python3 -c 'import json; print(json.load(open("'"$SHARE/update-state.json"'")).get("last_checked_at",""))' 2>/dev/null)" ]; echo $? )"

# --- 2. 24h cache: a second run within the window does not re-check --------
# Re-runs the SAME already-terminal task (idempotent; no new task creation,
# so the dirty-baseline guard never applies here).
before_state="$(cat "$SHARE/update-state.json")"
specrelay::run_installed_in "$CONSUMER" "$INSTALLED" run docs/sdd/0001-demo/spec.md --task-id demo-a 2>&1 >/dev/null </dev/null
after_state="$(cat "$SHARE/update-state.json")"
specrelay_test::assert_eq "a second run inside the 24h window leaves update-state.json unchanged" "$before_state" "$after_state"

# --- 3. bump the fake upstream to a newer release, force the cache stale ---
echo "9.9.10" > "$UPSTREAM/VERSION"
(cd "$UPSTREAM" && git add -A && git commit -q -m "v9.9.10" && git tag v9.9.10)
python3 -c '
import json
p = "'"$SHARE/update-state.json"'"
d = json.load(open(p))
d["last_checked_at"] = "2020-01-01T00:00:00Z"
json.dump(d, open(p, "w"))
'

# --- 4. non-interactive / closed-stdin: advisory only, never prompts, never blocks
CONSUMER_B="$(specrelay::fresh_consumer)"
noninteractive_out="$(specrelay::run_installed_in "$CONSUMER_B" "$INSTALLED" run docs/sdd/0001-demo/spec.md --task-id demo-b 2>&1 </dev/null)"
noninteractive_rc=$?
specrelay_test::assert_eq "'run' with a newer release and closed stdin still completes (never hangs)" "0" "$noninteractive_rc"
specrelay_test::assert_contains "a closed-stdin session gets a concise advisory, never a prompt" "$noninteractive_out" "an update is available"
specrelay_test::assert_not_contains "a closed-stdin session is never asked to confirm" "$noninteractive_out" "Proceed? [y/N]"

# --- 5. environment disable: SPECRELAY_UPDATE_CHECK=0 skips discovery entirely
python3 -c '
import json
p = "'"$SHARE/update-state.json"'"
d = json.load(open(p))
d["last_checked_at"] = "2020-01-01T00:00:00Z"
json.dump(d, open(p, "w"))
'
CONSUMER_C="$(specrelay::fresh_consumer)"
disabled_out="$(specrelay::run_installed_in "$CONSUMER_C" env SPECRELAY_UPDATE_CHECK=0 "$INSTALLED" run docs/sdd/0001-demo/spec.md --task-id demo-c 2>&1 </dev/null)"
specrelay_test::assert_not_contains "SPECRELAY_UPDATE_CHECK=0 never advises or prompts" "$disabled_out" "an update is available"

# --- 6. --check bypasses the cache regardless of last_checked_at -----------
python3 -c '
import json
p = "'"$SHARE/update-state.json"'"
d = json.load(open(p))
d["last_checked_at"] = "'"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"'"
json.dump(d, open(p, "w"))
'
check_bypass_out="$(env -u SPECRELAY_HOME "$INSTALLED" update --check 2>&1)"
specrelay_test::assert_contains "'update --check' bypasses the 24h cache and still discovers 9.9.10" "$check_bypass_out" "9.9.10"

# --- 7. discovery failure never blocks run/resume ---------------------------
python3 -c '
import json
meta = "'"$META"'"
d = json.load(open(meta))
d["update_source"] = {"type": "official-git", "repository": "/nonexistent/specrelay-upstream-xyz", "ref": "main"}
json.dump(d, open(meta, "w"))
p = "'"$SHARE/update-state.json"'"
d2 = json.load(open(p))
d2["last_checked_at"] = "2020-01-01T00:00:00Z"
json.dump(d2, open(p, "w"))
'
CONSUMER_D="$(specrelay::fresh_consumer)"
failure_out="$(specrelay::run_installed_in "$CONSUMER_D" "$INSTALLED" run docs/sdd/0001-demo/spec.md --task-id demo-d 2>&1 </dev/null)"
failure_rc=$?
specrelay_test::assert_eq "an unreachable update source never blocks 'run'" "0" "$failure_rc"
last_status="$(python3 -c 'import json; print(json.load(open("'"$SHARE/update-state.json"'")).get("last_check_status",""))' 2>/dev/null)"
specrelay_test::assert_eq "a discovery failure is recorded honestly as 'failure'" "failure" "$last_status"

specrelay_test::summary
exit $?
