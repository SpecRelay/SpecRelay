#!/usr/bin/env bash
# shim_loop_test.sh — SDD 0085 shim-loop / recursion protection (spec
# sections 33.6, 55, 56).
#
# Proves the real .ai/scripts/ shims never recurse into themselves (legacy
# command -> SpecRelay -> legacy command -> ...), and that `specrelay doctor`
# would DETECT such a loop if one were ever introduced (a real assertion
# against the doctor check added in doctor.sh, not just a static grep).
#   tools/specrelay/test/shim_loop_test.sh

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

_install_shims_into() {
  local fixture="$1"
  specrelay_test::safe_fixture_root_or_abort "$fixture" "$HOST_ROOT" || return 1
  mkdir -p "$fixture/.ai"
  cp -R "$AI_SCRIPTS" "$fixture/.ai/scripts"
  mkdir -p "$fixture/tools"
  cp -R "$HOST_ROOT/tools/specrelay" "$fixture/tools/specrelay"
  (cd "$fixture" && git add -A .ai tools && git commit -q -m "install shims + specrelay for fixture")
}

# --- static: none of the real .ai/scripts/legacy/ files reference the
# specrelay executable (this is the actual loop-prevention property: the
# frozen legacy engine never calls back into SpecRelay) ---------------------
loop_refs="$(grep -rl "tools/specrelay/bin/specrelay" "$HOST_ROOT/.ai/scripts/legacy" 2>/dev/null || true)"
specrelay_test::assert_eq "no file under .ai/scripts/legacy/ references the specrelay executable" "" "$loop_refs"

# --- static: each public shim delegates via specrelay-shim.sh exactly once
# (a single sourcing line), never nesting another public shim ---------------
for f in start-spec-task.sh start-ai-task.sh approve-task.sh run-ai-loop.sh show-task.sh; do
  count="$(grep -cE '^\s*\.\s+"\$ROOT/\.ai/scripts/internal/lib/specrelay-shim\.sh"' "$HOST_ROOT/.ai/scripts/$f")"
  specrelay_test::assert_true "$f sources specrelay-shim.sh exactly once" "$([ "$count" -eq 1 ] && echo 0 || echo 1)"
done

# --- dynamic: doctor reports "no shim-loop" for the real, correct shims ----
proj_ok="$(specrelay_test::mktemp_specrelay_project)"
_install_shims_into "$proj_ok"
doctor_ok_out="$(cd "$proj_ok" && tools/specrelay/bin/specrelay doctor 2>&1)"
specrelay_test::assert_contains "doctor reports no shim-loop for the real (correct) shims" "$doctor_ok_out" "No shim-loop detected"

# --- dynamic: doctor DETECTS a shim-loop if one is deliberately introduced
# into an isolated fixture's legacy/ copy (never the host repository) ------
proj_bad="$(specrelay_test::mktemp_specrelay_project)"
_install_shims_into "$proj_bad"
specrelay_test::safe_fixture_root_or_abort "$proj_bad" "$HOST_ROOT" || exit 1
echo '# deliberately reintroduces a call back into SpecRelay for this test only' \
  >> "$proj_bad/.ai/scripts/legacy/start-spec-task.sh"
echo 'echo "tools/specrelay/bin/specrelay run fake" >&2' >> "$proj_bad/.ai/scripts/legacy/start-spec-task.sh"
doctor_bad_out="$(cd "$proj_bad" && tools/specrelay/bin/specrelay doctor 2>&1)"
doctor_bad_rc=$?
specrelay_test::assert_true "doctor exits non-zero when a shim-loop reference is present" "$([ "$doctor_bad_rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "doctor names the shim-loop risk" "$doctor_bad_out" "Shim-loop risk"

specrelay_test::summary
exit $?
