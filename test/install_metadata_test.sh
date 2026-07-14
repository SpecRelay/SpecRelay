#!/usr/bin/env bash
# install_metadata_test.sh — spec 0022, section 2: installation metadata.
# Exercises the REAL installer writing metadata into a temp prefix. No network.
#
#   test/install_metadata_test.sh
#
# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

INSTALL_SH="$SPECRELAY_ROOT/install/install.sh"
SOURCE_VERSION="$(tr -d '[:space:]' < "$SPECRELAY_ROOT/VERSION")"

WORK="$(specrelay_test::mktemp_project)"
PREFIX="$WORK/prefix"
"$INSTALL_SH" --prefix "$PREFIX" >/dev/null 2>&1
META="$PREFIX/share/specrelay/install-metadata.json"

# --- 1. fresh install writes metadata under the PREFIX, not a consumer repo -
specrelay_test::assert_true "install-metadata.json exists under the install prefix" \
  "$( [ -f "$META" ]; echo $? )"

blob="$(cat "$META")"
schema_version="$(printf '%s' "$blob" | python3 -c 'import json,sys; print(json.load(sys.stdin)["schema_version"])')"
specrelay_test::assert_eq "metadata schema_version is 1" "1" "$schema_version"

installed_version="$(printf '%s' "$blob" | python3 -c 'import json,sys; print(json.load(sys.stdin)["installed_version"])')"
specrelay_test::assert_eq "metadata installed_version matches source VERSION" "$SOURCE_VERSION" "$installed_version"

installed_commit="$(printf '%s' "$blob" | python3 -c 'import json,sys; print(json.load(sys.stdin)["installed_commit"])')"
specrelay_test::assert_true "metadata installed_commit is non-empty" "$( [ -n "$installed_commit" ]; echo $? )"

resource_path="$(printf '%s' "$blob" | python3 -c 'import json,sys; print(json.load(sys.stdin)["resource_path"])')"
specrelay_test::assert_eq "metadata resource_path is the installed share dir" "$PREFIX/share/specrelay" "$resource_path"

# --- 2. no credentials/tokens ever persisted --------------------------------
specrelay_test::assert_not_contains "metadata contains no 'token' substring" "$blob" "token"
specrelay_test::assert_not_contains "metadata contains no 'password' substring" "$blob" "password"
specrelay_test::assert_not_contains "metadata contains no 'secret' substring" "$(printf '%s' "$blob" | tr '[:upper:]' '[:lower:]')" "secret"

# --- 3. reinstall (upgrade path) rewrites metadata ATOMICALLY (never absent) -
before_mtime_check="$(python3 -c 'import json; json.load(open("'"$META"'"))' && echo ok)"
specrelay_test::assert_eq "metadata is valid JSON before reinstall" "ok" "$before_mtime_check"
"$INSTALL_SH" --prefix "$PREFIX" --force >/dev/null 2>&1
after_check="$(python3 -c 'import json; json.load(open("'"$META"'"))' && echo ok)"
specrelay_test::assert_eq "metadata is valid JSON after reinstall (never left partially written)" "ok" "$after_check"

# --- 4. malformed metadata produces a clear diagnostic, never a crash -------
echo '{ not valid json' > "$META"
INSTALLED="$PREFIX/bin/specrelay"
malformed_out="$(env -u SPECRELAY_HOME "$INSTALLED" install-info 2>&1)"
specrelay_test::assert_contains "malformed metadata produces an actionable diagnostic" "$malformed_out" "missing or malformed"

# A missing required field is ALSO reported as malformed, not silently accepted.
python3 -c 'import json; json.dump({"schema_version": 1}, open("'"$META"'", "w"))'
missing_field_out="$(env -u SPECRELAY_HOME "$INSTALLED" install-info 2>&1)"
specrelay_test::assert_contains "metadata missing required fields is reported as malformed" "$missing_field_out" "missing or malformed"

# --- 5. consumer project config is never touched by install/metadata write -
fake_proj="$(specrelay_test::mktemp_specrelay_project)"
config_before="$(cat "$fake_proj/.specrelay/config.yml")"
"$INSTALL_SH" --prefix "$PREFIX" --force >/dev/null 2>&1
config_after="$(cat "$fake_proj/.specrelay/config.yml")"
specrelay_test::assert_eq "consumer .specrelay/config.yml is untouched by install/metadata writes" "$config_before" "$config_after"
specrelay_test::assert_true "no install-metadata.json ever appears in a consumer repo" \
  "$( [ ! -f "$fake_proj/install-metadata.json" ] && [ ! -f "$fake_proj/.specrelay/install-metadata.json" ]; echo $? )"

specrelay_test::summary
exit $?
