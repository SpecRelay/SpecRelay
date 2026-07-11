#!/usr/bin/env bash
# compat_shim_test.sh — SDD 0085 compatibility shim tests (spec section 33).
#
# Exercises the REAL .ai/scripts/ shims (start-spec-task.sh, show-task.sh,
# approve-task.sh, run-ai-loop.sh) against an isolated temp fixture project —
# never this repository's own .ai-runs/. The fixture project is configured
# with the deterministic 'fake' executor/reviewer providers (never a real
# provider), so these tests are fast and hermetic.
#   tools/specrelay/test/compat_shim_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

HOST_ROOT="$SPECRELAY_ROOT"
while [ -n "$HOST_ROOT" ] && [ ! -d "$HOST_ROOT/.git" ]; do
  parent="$(dirname "$HOST_ROOT")"
  [ "$parent" = "$HOST_ROOT" ] && HOST_ROOT="" && break
  HOST_ROOT="$parent"
done
specrelay_test::assert_true "host repository root was discovered" "$([ -n "$HOST_ROOT" ] && echo 0 || echo 1)"

AI_SCRIPTS="$HOST_ROOT/.ai/scripts"

# SDD 0087: the shims now resolve an INSTALLED, versioned SpecRelay (not the
# in-repo tools/specrelay/ tree). Install the host vendor ONCE into a shared
# temp prefix, and point every fixture shim run at it via SPECRELAY_PREFIX. The
# fixture also carries a matching .specrelay/version pin. tools/specrelay/ is
# still copied into each fixture only as the transitional install SOURCE and to
# exercise the direct `bin/specrelay` command — never as the shim runtime path.
SHIM_PREFIX="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-shim-prefix.XXXXXX")"
env -u SPECRELAY_HOME bash "$HOST_ROOT/tools/specrelay/install/install.sh" --prefix "$SHIM_PREFIX" >/dev/null 2>&1
PIN_VER="$(tr -d '[:space:]' < "$HOST_ROOT/tools/specrelay/VERSION")"
export SPECRELAY_PREFIX="$SHIM_PREFIX"
specrelay_test::assert_true "installed a versioned specrelay for the shim tests" \
  "$([ -x "$SHIM_PREFIX/bin/specrelay" ] && echo 0 || echo 1)"

# specrelay_test::_install_shims_into <fixture-root>
# Copies the REAL .ai/scripts/ tree (shims + legacy/ + internal/ helpers) and
# the REAL tools/specrelay/ tree into an isolated fixture, and writes the
# version pin the shims require, so the shims run against fixture data only
# (never the host's .ai-runs/) and resolve the shared installed copy.
_install_shims_into() {
  local fixture="$1"
  specrelay_test::safe_fixture_root_or_abort "$fixture" "$HOST_ROOT" || return 1
  mkdir -p "$fixture/.ai"
  cp -R "$AI_SCRIPTS" "$fixture/.ai/scripts"
  mkdir -p "$fixture/tools"
  cp -R "$HOST_ROOT/tools/specrelay" "$fixture/tools/specrelay"
  mkdir -p "$fixture/.specrelay"
  printf '%s\n' "$PIN_VER" > "$fixture/.specrelay/version"
  # Commit the copied tooling so the dirty-tree guard sees a clean baseline
  # (these are the fixture's OWN tooling files, not "unrelated dirt" — this
  # mirrors how the real repository already has .ai/ and tools/specrelay/
  # committed before any task is created).
  (cd "$fixture" && git add -A .ai tools .specrelay && git commit -q -m "install shims + specrelay for fixture")
}

# --- fixture 1: start-spec-task.sh delegates to specrelay run --------------
proj1="$(specrelay_test::mktemp_specrelay_project)"
_install_shims_into "$proj1"
mkdir -p "$proj1/docs/sdd/0100-shim-fixture"
printf '# Fixture spec for shim test\n' > "$proj1/docs/sdd/0100-shim-fixture/spec.md"

out1="$(cd "$proj1" && "$proj1/.ai/scripts/start-spec-task.sh" docs/sdd/0100-shim-fixture/spec.md 2>&1)"
rc1=$?
specrelay_test::assert_true "start-spec-task.sh shim exits 0 for a clean fixture run" "$([ "$rc1" -eq 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "start-spec-task.sh shim prints the active-engine banner" "$out1" "Engine: specrelay"
specrelay_test::assert_contains "start-spec-task.sh shim names the direct command" "$out1" "specrelay run <spec-path>"

state_file="$proj1/.ai-runs/tasks/0100-shim-fixture/state.json"
specrelay_test::assert_true "start-spec-task.sh shim created exactly one task directory" "$([ -f "$state_file" ] && echo 0 || echo 1)"
engine_field="$(grep -o '"engine": *"[a-z]*"' "$state_file" 2>/dev/null)"
specrelay_test::assert_contains "the task created via the shim is engine-owned by specrelay" "$engine_field" "specrelay"
final_state="$(grep -o '"state": *"[A-Z_]*"' "$state_file" | head -1)"
specrelay_test::assert_contains "start-spec-task.sh shim drove the fake-provider task to READY_FOR_HUMAN_REVIEW" "$final_state" "READY_FOR_HUMAN_REVIEW"

task_dirs_count="$(find "$proj1/.ai-runs/tasks" -mindepth 2 -maxdepth 2 -name state.json 2>/dev/null | grep -c .)"
specrelay_test::assert_eq "no duplicate task directory was created" "1" "$task_dirs_count"

# --- fixture 2: --task-id and --allow-dirty are translated correctly, spaces
# in the spec path are handled -----------------------------------------------
proj2="$(specrelay_test::mktemp_specrelay_project)"
_install_shims_into "$proj2"
mkdir -p "$proj2/docs/sdd/0101 shim fixture with spaces"
printf '# Fixture spec with a space in its directory name\n' > "$proj2/docs/sdd/0101 shim fixture with spaces/spec.md"
: > "$proj2/unrelated-dirty-file.txt"

out2="$(cd "$proj2" && "$proj2/.ai/scripts/start-spec-task.sh" --task-id custom-task-id --allow-dirty "docs/sdd/0101 shim fixture with spaces/spec.md" 2>&1)"
rc2=$?
specrelay_test::assert_true "start-spec-task.sh shim handles a spec path containing spaces" "$([ "$rc2" -eq 0 ] && echo 0 || echo 1)"
specrelay_test::assert_true "--task-id override was honored (fixture task dir exists under the override id)" \
  "$([ -f "$proj2/.ai-runs/tasks/custom-task-id/state.json" ] && echo 0 || echo 1)"
specrelay_test::assert_true "no task directory was created under the default spec-derived id" \
  "$([ ! -e "$proj2/.ai-runs/tasks/0101-shim-fixture-with-spaces" ] && echo 0 || echo 1)"

rm -f "$proj2/unrelated-dirty-file.txt"

# --- fixture 3: exit code propagates on failure (nonexistent spec path) ----
proj3="$(specrelay_test::mktemp_specrelay_project)"
_install_shims_into "$proj3"
out3="$(cd "$proj3" && "$proj3/.ai/scripts/start-spec-task.sh" docs/sdd/does-not-exist/spec.md 2>&1)"
rc3=$?
direct3="$(cd "$proj3" && "$proj3/tools/specrelay/bin/specrelay" run docs/sdd/does-not-exist/spec.md 2>&1)"
direct_rc3=$?
specrelay_test::assert_true "start-spec-task.sh shim exits non-zero for a nonexistent spec path" "$([ "$rc3" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_eq "shim and direct command return the SAME exit code for the same failure" "$direct_rc3" "$rc3"

# --- fixture 4: show-task.sh delegates (read-only) and resolves numeric
# prefixes exactly like the direct command -----------------------------------
proj4="$(specrelay_test::mktemp_specrelay_project)"
_install_shims_into "$proj4"
mkdir -p "$proj4/docs/sdd/0102-show-fixture"
printf '# Fixture spec\n' > "$proj4/docs/sdd/0102-show-fixture/spec.md"
(cd "$proj4" && "$proj4/.ai/scripts/start-spec-task.sh" docs/sdd/0102-show-fixture/spec.md >/dev/null 2>&1)

before_snapshot="$(find "$proj4/.ai-runs" -type f -exec cksum {} + | sort)"
show_out="$(cd "$proj4" && "$proj4/.ai/scripts/show-task.sh" 0102 2>&1)"
show_rc=$?
after_snapshot="$(find "$proj4/.ai-runs" -type f -exec cksum {} + | sort)"

specrelay_test::assert_true "show-task.sh shim succeeds with a numeric-prefix task ref" "$([ "$show_rc" -eq 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "show-task.sh shim reports the resolved task id" "$show_out" "0102-show-fixture"
specrelay_test::assert_eq "show-task.sh shim never mutates any task file (read-only)" "$before_snapshot" "$after_snapshot"

# --- fixture 5: direct command remains independently usable ----------------
proj5="$(specrelay_test::mktemp_specrelay_project)"
_install_shims_into "$proj5"
mkdir -p "$proj5/docs/sdd/0103-direct-fixture"
printf '# Fixture spec\n' > "$proj5/docs/sdd/0103-direct-fixture/spec.md"
direct_out5="$(cd "$proj5" && "$proj5/tools/specrelay/bin/specrelay" run docs/sdd/0103-direct-fixture/spec.md 2>&1)"
direct_rc5=$?
specrelay_test::assert_true "the direct 'specrelay run' command works independently of any shim" "$([ "$direct_rc5" -eq 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "direct command reached READY_FOR_HUMAN_REVIEW" "$direct_out5" "READY_FOR_HUMAN_REVIEW"

specrelay_test::summary
exit $?
