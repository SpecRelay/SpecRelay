#!/usr/bin/env bash
# shim_deprecation_test.sh — SDD 0085B, section 2.4 + test 8.7: the public
# .ai/scripts/ shims are DEPRECATED wrappers only. Under the default engine
# selection they delegate to SpecRelay and never silently fall back to legacy;
# selecting legacy requires an explicit rollback-only opt-in.
#   tools/specrelay/test/shim_deprecation_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# Locate the real host repository root (holds .ai/scripts).
HOST_ROOT="$SPECRELAY_ROOT"
while [ -n "$HOST_ROOT" ] && [ ! -d "$HOST_ROOT/.git" ]; do
  parent="$(dirname "$HOST_ROOT")"
  [ "$parent" = "$HOST_ROOT" ] && HOST_ROOT="" && break
  HOST_ROOT="$parent"
done
specrelay_test::assert_true "host repository root was discovered" "$([ -n "$HOST_ROOT" ] && echo 0 || echo 1)"

SHIM_HELPER="$HOST_ROOT/.ai/scripts/internal/lib/specrelay-shim.sh"
specrelay_test::assert_true "shim helper exists" "$([ -f "$SHIM_HELPER" ] && echo 0 || echo 1)"
# shellcheck source=/dev/null
. "$SHIM_HELPER"

# Build a fixture whose config explicitly selects specrelay.
proj="$(specrelay_test::mktemp_specrelay_project)"

# --- default engine resolves to specrelay (no override) ---------------------
unset SPECRELAY_ENGINE
default_engine="$( SPECRELAY_ENGINE= ; unset SPECRELAY_ENGINE; specrelay_shim::engine "$proj" )"
specrelay_test::assert_eq "8.7: default engine resolves to specrelay" "specrelay" "$default_engine"

# --- explicit rollback-only opt-in selects legacy ---------------------------
optin_engine="$( SPECRELAY_ENGINE=legacy specrelay_shim::engine "$proj" )"
specrelay_test::assert_eq "8.7: SPECRELAY_ENGINE=legacy is the explicit legacy opt-in" "legacy" "$optin_engine"

# --- an unrecognized override is a HARD error (never a silent fallback) -----
# (errexit stays OFF here, matching test_helper.sh: a failing command
# substitution must not abort the test.)
bad_out="$( SPECRELAY_ENGINE=bogus specrelay_shim::engine "$proj" 2>&1 )"
bad_rc=$?
specrelay_test::assert_true "8.7: an unrecognized SPECRELAY_ENGINE fails closed (non-zero)" "$([ "$bad_rc" -ne 0 ] && echo 0 || echo 1)"
# Fail-closed must NOT silently resolve to a usable engine: the resolved value
# on stdout must not be a bare 'legacy'/'specrelay' engine name.
bad_stdout="$( SPECRELAY_ENGINE=bogus specrelay_shim::engine "$proj" 2>/dev/null )"
specrelay_test::assert_true "8.7: fail-closed emits no resolved engine on stdout" "$([ "$bad_stdout" != "legacy" ] && [ "$bad_stdout" != "specrelay" ] && echo 0 || echo 1)"
specrelay_test::assert_contains "8.7: fail-closed error names the accepted values" "$bad_out" "must be 'specrelay' or 'legacy'"

# --- the shim advertises the direct SpecRelay command (deprecated wrapper) --
notice="$(specrelay_shim::deprecation_notice "tools/specrelay/bin/specrelay run <spec-path>")"
specrelay_test::assert_contains "8.7: deprecation notice points to the direct specrelay command" "$notice" "tools/specrelay/bin/specrelay run"

# --- the public shim source delegates to specrelay and only execs legacy on
#     the explicit engine=legacy branch (never an unconditional legacy call) --
start_shim="$HOST_ROOT/.ai/scripts/start-spec-task.sh"
shim_src="$(cat "$start_shim")"
specrelay_test::assert_contains "8.7: shim only execs legacy under an explicit engine=legacy guard" "$shim_src" 'if [ "$ENGINE" = "legacy" ]; then'
specrelay_test::assert_contains "8.7: shim delegates to the specrelay bin by default" "$shim_src" 'specrelay_shim::bin'

specrelay_test::summary
exit $?
