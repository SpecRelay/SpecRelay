#!/usr/bin/env bash
# doctor_hooks_test.sh — spec 0002: `specrelay doctor` must detect an active
# Git commit hook that contains non-ASCII shell punctuation (the class of hook
# bug that produces `fatal: ambiguous argument '<endash>abbrev-ref'`,
# `grep: illegal byte sequence`, and `sed: invalid command code` noise), warn
# actionably, and STILL exit 0 (a warning, never a hard failure). It must NOT
# warn on a clean ASCII hook, nor on em/en dashes that appear only in prose
# comments. Run directly: test/doctor_hooks_test.sh
#
# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# Byte-literal Unicode punctuation used to build the malformed fixture hook.
ENDASH="$(printf '\xe2\x80\x93')"   # U+2013
LDQ="$(printf '\xe2\x80\x9c')"      # U+201C
RDQ="$(printf '\xe2\x80\x9d')"      # U+201D
LSQ="$(printf '\xe2\x80\x98')"      # U+2018
RSQ="$(printf '\xe2\x80\x99')"      # U+2019

# --- Case 1: a bad hook triggers a warning but doctor still passes -----------
proj_bad="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_bad/docs/sdd"  # satisfy the configured spec-root mandatory check
bad_hooks="$proj_bad/.badhooks"
mkdir -p "$bad_hooks"
{
  printf '#!/bin/sh\n'
  printf 'MSG_FILE=%s$1%s\n' "$LDQ" "$RDQ"
  printf 'BRANCH=$(git rev-parse %sabbrev-ref HEAD)\n' "$ENDASH"
  printf 'TICKET=$(echo %s$BRANCH%s | grep -oE %s[A-Z]+-[0-9]+%s | head -1)\n' "$LDQ" "$RDQ" "$LSQ" "$RSQ"
} > "$bad_hooks/prepare-commit-msg"
chmod +x "$bad_hooks/prepare-commit-msg"
(cd "$proj_bad" && git config core.hooksPath "$bad_hooks")

bad_out="$(cd "$proj_bad" && "$SPECRELAY_BIN" doctor 2>&1)"
bad_rc=$?
specrelay_test::assert_eq "doctor still exits 0 despite a bad commit hook (warning, not failure)" \
  "0" "$bad_rc"
specrelay_test::assert_contains "doctor warns about non-ASCII shell punctuation in the active hook" \
  "$bad_out" "non-ASCII shell punctuation"
specrelay_test::assert_contains "doctor names the offending hook file" \
  "$bad_out" "$bad_hooks/prepare-commit-msg"
specrelay_test::assert_contains "doctor still reports overall success" \
  "$bad_out" "all checks passed"

# --- Case 2: a clean ASCII hook produces no warning --------------------------
proj_ok="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_ok/docs/sdd"
ok_hooks="$proj_ok/.okhooks"
mkdir -p "$ok_hooks"
cat > "$ok_hooks/prepare-commit-msg" <<'SH'
#!/bin/sh
MSG_FILE="$1"
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
TICKET=$(printf '%s\n' "$BRANCH" | grep -oE '[A-Z]+-[0-9]+' | head -1)
SH
chmod +x "$ok_hooks/prepare-commit-msg"
(cd "$proj_ok" && git config core.hooksPath "$ok_hooks")

ok_out="$(cd "$proj_ok" && "$SPECRELAY_BIN" doctor 2>&1)"
ok_rc=$?
specrelay_test::assert_eq "doctor exits 0 with a clean ASCII hook" "0" "$ok_rc"
specrelay_test::assert_not_contains "doctor does not warn on a clean ASCII hook" \
  "$ok_out" "breaks commits with"
specrelay_test::assert_contains "doctor reports the hooks check passed" \
  "$ok_out" "no non-ASCII shell punctuation detected"

# --- Case 3: em/en dashes in a hook's PROSE comment are not flagged ----------
proj_prose="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj_prose/docs/sdd"
prose_hooks="$proj_prose/.prosehooks"
mkdir -p "$prose_hooks"
{
  printf '#!/bin/sh\n'
  # An em dash and smart quotes appearing only in a natural-language comment,
  # not adjacent to a command nor used as an option prefix.
  printf '# prepare-commit-msg %s prefixes the ticket id (see the team%s wiki)\n' \
    "$(printf '\xe2\x80\x94')" "$RSQ"
  printf 'BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)\n'
} > "$prose_hooks/prepare-commit-msg"
chmod +x "$prose_hooks/prepare-commit-msg"
(cd "$proj_prose" && git config core.hooksPath "$prose_hooks")

prose_out="$(cd "$proj_prose" && "$SPECRELAY_BIN" doctor 2>&1)"
prose_rc=$?
specrelay_test::assert_eq "doctor exits 0 with prose-only Unicode in a hook comment" "0" "$prose_rc"
specrelay_test::assert_not_contains "doctor does not flag prose Unicode in a hook comment" \
  "$prose_out" "breaks commits with"

specrelay_test::summary
exit $?
