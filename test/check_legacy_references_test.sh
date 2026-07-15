#!/usr/bin/env bash
# check_legacy_references_test.sh — tests for scripts/check-legacy-references,
# the automated legacy-reference regression gate (spec 0024, section 25;
# required test cases 27.14-27.16).

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

GATE="$SPECRELAY_ROOT/scripts/check-legacy-references"

mk_fixture_root() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-legacy-gate.XXXXXX")"
  SPECRELAY_TEST_TMP_DIRS+=("$d")
  mkdir -p "$d/bin" "$d/lib" "$d/templates" "$d/test" "$d/scripts" "$d/install" "$d/docs"
  printf 'clean\n' > "$d/README.md"
  printf 'clean\n' > "$d/CHANGELOG.md"
  printf '%s\n' "$d"
}

# --- baseline: a clean fixture root passes -----------------------------------
clean_root="$(mk_fixture_root)"
out_clean="$("$GATE" --root "$clean_root" 2>&1)"; rc_clean=$?
specrelay_test::assert_true "clean fixture root: gate exits 0" "$([ "$rc_clean" -eq 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "clean fixture root: gate reports no violation" "$out_clean" "no forbidden legacy reference"

# --- 27.14 / 27.16: a NEW forbidden reference in a non-allowlisted current
# file fails verification ----------------------------------------------------
bad_root="$(mk_fixture_root)"
printf '#!/usr/bin/env bash\n# resolves from tools/specrelay always\n' > "$bad_root/lib/new_legacy_helper.sh"
out_bad="$("$GATE" --root "$bad_root" 2>&1)"; rc_bad=$?
specrelay_test::assert_true "27.14/27.16: gate fails on a new unclassified legacy reference" "$([ "$rc_bad" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "27.16: gate names the offending file" "$out_bad" "lib/new_legacy_helper.sh"

# --- 27.15: an explicitly allowed historical reference passes ONLY when the
# EXACT file is allowlisted; the identical content at a different path still
# fails ------------------------------------------------------------------------
allowlisted_root="$(mk_fixture_root)"
printf 'Historical changelog entry mentioning tools/specrelay and .ai/scripts.\n' > "$allowlisted_root/CHANGELOG.md"
out_allow="$("$GATE" --root "$allowlisted_root" 2>&1)"; rc_allow=$?
specrelay_test::assert_true "27.15: the exact allowlisted file (CHANGELOG.md) passes" "$([ "$rc_allow" -eq 0 ] && echo 0 || echo 1)"

not_allowlisted_root="$(mk_fixture_root)"
printf 'Historical changelog entry mentioning tools/specrelay and .ai/scripts.\n' > "$not_allowlisted_root/docs/not-on-the-allowlist.md"
out_not_allow="$("$GATE" --root "$not_allowlisted_root" 2>&1)"; rc_not_allow=$?
specrelay_test::assert_true "27.15: the identical content at a non-allowlisted path fails" "$([ "$rc_not_allow" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "27.15: gate names the non-allowlisted file" "$out_not_allow" "docs/not-on-the-allowlist.md"

# --- the gate itself passes against the real repository ---------------------
out_real="$("$GATE" 2>&1)"; rc_real=$?
specrelay_test::assert_true "gate passes against the real repository" "$([ "$rc_real" -eq 0 ] && echo 0 || echo 1)"

specrelay_test::summary
exit $?
