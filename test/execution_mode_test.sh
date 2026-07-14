#!/usr/bin/env bash
# execution_mode_test.sh — spec 0022, section 1: source-local vs installed
# execution-mode contract. Exercises the REAL bin/specrelay both as the
# in-repo source checkout and as a freshly installed copy in a temp prefix
# (never the developer's real installation). No network.
#
#   test/execution_mode_test.sh
#
# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

INSTALL_SH="$SPECRELAY_ROOT/install/install.sh"

# --- 1. source-local detection + environment output --------------------------
src_out="$("$SPECRELAY_BIN" environment 2>&1)"
specrelay_test::assert_true "'environment' exits 0 in source-local mode" "$?"
specrelay_test::assert_contains "source-local reports 'Execution mode: source-local'" "$src_out" "Execution mode: source-local"
specrelay_test::assert_contains "source-local reports update checks disabled" "$src_out" "Update checks:  disabled"
specrelay_test::assert_contains "source-local reports the real executable path" "$src_out" "$SPECRELAY_ROOT/bin/specrelay"

json_out="$("$SPECRELAY_BIN" environment --json 2>&1)"
specrelay_test::assert_true "'environment --json' exits 0" "$?"
mode_json="$(printf '%s' "$json_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_mode"])' 2>/dev/null)"
specrelay_test::assert_eq "'environment --json' reports source-local" "source-local" "$mode_json"

# --- 2. install-info in source-local mode: no metadata claim, no mutation ----
install_info_out="$("$SPECRELAY_BIN" install-info 2>&1)"
specrelay_test::assert_true "'install-info' exits 0 in source-local mode" "$?"
specrelay_test::assert_contains "source-local install-info explains it is not applicable" "$install_info_out" "source-local"

# --- 3. symlink safety: a symlink to bin/specrelay elsewhere is STILL source-local
WORK="$(specrelay_test::mktemp_project)"
ln -s "$SPECRELAY_ROOT/bin/specrelay" "$WORK/specrelay-link"
link_out="$("$WORK/specrelay-link" environment 2>&1)"
specrelay_test::assert_contains "a symlink to bin/specrelay is still classified source-local" "$link_out" "Execution mode: source-local"

# --- 4. installed launcher detection -----------------------------------------
PREFIX="$WORK/prefix"
"$INSTALL_SH" --prefix "$PREFIX" >/dev/null 2>&1
INSTALLED="$PREFIX/bin/specrelay"

inst_env_out="$(env -u SPECRELAY_HOME "$INSTALLED" environment 2>&1)"
specrelay_test::assert_contains "a freshly installed copy is classified installed" "$inst_env_out" "Execution mode: installed"
specrelay_test::assert_contains "installed environment reports update checks enabled" "$inst_env_out" "Update checks:  enabled"
specrelay_test::assert_contains "installed environment reports the 24h check interval" "$inst_env_out" "Check interval: 24h"

inst_env_disabled="$(env -u SPECRELAY_HOME SPECRELAY_UPDATE_CHECK=0 "$INSTALLED" environment 2>&1)"
specrelay_test::assert_contains "SPECRELAY_UPDATE_CHECK=0 reports update checks disabled" "$inst_env_disabled" "Update checks:  disabled"

# --- 5. installed install-info reports real version/commit/metadata ---------
inst_info_out="$(env -u SPECRELAY_HOME "$INSTALLED" install-info 2>&1)"
specrelay_test::assert_contains "installed install-info reports installed mode" "$inst_info_out" "installed"
specrelay_test::assert_contains "installed install-info reports the installed version" "$inst_info_out" "$(tr -d '[:space:]' < "$SPECRELAY_ROOT/VERSION")"

inst_info_json="$(env -u SPECRELAY_HOME "$INSTALLED" install-info --json 2>&1)"
meta_present="$(printf '%s' "$inst_info_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["metadata_present"])' 2>/dev/null)"
specrelay_test::assert_eq "installed install-info --json reports metadata_present true" "True" "$meta_present"

# --- 6. no update-state file is ever created by SOURCE-LOCAL commands -------
specrelay_test::assert_true "source-local checkout never has an update-state.json" \
  "$( [ ! -f "$SPECRELAY_ROOT/update-state.json" ]; echo $? )"

specrelay_test::summary
exit $?
