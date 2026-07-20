#!/usr/bin/env bash
# architecture_version_test.sh — focused suite for the architecture-version
# contract validator and its release integration (spec 0031, section 15).
#
# Every case runs against an ISOLATED temporary repository (never the real
# checkout, except the read-only "real repo validates" case), uses no network,
# no real AI provider, and does not depend on the developer's global Git config.
#
#   test/architecture_version_test.sh
#
# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

RB="$SPECRELAY_ROOT/lib/specrelay/architecture_validate.rb"

# new_root — isolated temp dir (canonical physical path), tracked for cleanup.
new_root() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-arch.XXXXXX")"
  d="$(cd "$d" && pwd -P)"
  SPECRELAY_TEST_TMP_DIRS+=("$d")
  printf '%s\n' "$d"
}

# arch_base <root> [status-word=Accepted] — the stable, valid parts of an
# architecture layer whose status surfaces (ADR `## Status`, north-star /
# principles `**Status:**`, and the index status column) are all COHERENT with
# the given lifecycle word, so the coherence checks (finding 1) pass.
arch_base() {
  local root="$1" word="${2:-Accepted}" lower
  lower="$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')"
  mkdir -p "$root/architecture/decisions" "$root/docs/specs"
  printf '# North Star\n\n**Status:** %s\n' "$lower" > "$root/architecture/north-star.md"
  printf '# Principles\n\n**Status:** %s\n' "$lower" > "$root/architecture/principles.md"
  cat > "$root/architecture/decisions/ADR-0001-min.md" <<ADR
# ADR-0001 — Minimal

## Status
$word.

## Architecture version
1

## Context
c

## Decision
d

## Alternatives considered
a

## Consequences
c

## Compatibility / migration impact
m

## Supersedes / superseded by
s

## Verification or evidence
v

## Open questions
o
ADR
  cat > "$root/architecture/decisions/README.md" <<IDX
# ADRs

| ADR | Title | Status |
|---|---|---|
| [0001](ADR-0001-min.md) | Minimal | $word |
IDX
}

# good_version <root> — a valid ACCEPTED version file (boundary 31), with a
# quoted full-ISO-8601 ratified_at (explicit timezone; finding 4).
good_version() {
  cat > "$1/architecture/architecture-version.yml" <<'YML'
version: 1
status: accepted
ratified_at: "2026-07-19T08:50:41Z"
documents:
  north_star: architecture/north-star.md
  principles: architecture/principles.md
  decisions_index: architecture/decisions/README.md
decisions:
  - architecture/decisions/ADR-0001-min.md
spec_contract:
  required_field: architecture_version
  enforcement: machine-validated
  adoption_boundary:
    exempt_specs_up_to_and_including: 31
YML
}

# mk_valid_accepted <root> — a full, valid accepted layer plus two exempt specs
# (one historical, one the bootstrap 0031 at the boundary), no post-boundary
# specs.
mk_valid_accepted() {
  local root="$1"
  arch_base "$root"
  good_version "$root"
  mkdir -p "$root/docs/specs/0005-historical" "$root/docs/specs/0031-ratify"
  printf '# Spec 0005\n\n## Status\n\nproposed\n' > "$root/docs/specs/0005-historical/spec.md"
  printf '# Spec 0031\n\n## Status\n\naccepted\n' > "$root/docs/specs/0031-ratify/spec.md"
}

# add_post_boundary_spec <root> <number-name> <metadata-body...>
# Writes docs/specs/<number-name>/spec.md with the given raw body appended.
write_spec() {
  local root="$1" name="$2" body="$3"
  mkdir -p "$root/docs/specs/$name"
  printf '%s\n' "$body" > "$root/docs/specs/$name/spec.md"
}

# V <root> [--json] — run the validator, capture combined output + rc into
# globals OUT / RC.
V() {
  OUT="$(ruby "$RB" "$@" 2>&1)"
  RC=$?
}

# -----------------------------------------------------------------------------
# 1. The real post-ratification repository validates successfully (read-only).
V --root "$SPECRELAY_ROOT"
specrelay_test::assert_eq "1. the real ratified repository validates (exit 0)" "0" "$RC"
specrelay_test::assert_contains "1. real repo reports accepted + boundary 0031" "$OUT" "accepted"

# 2. JSON success output carries the required stable fields.
VALID="$(new_root)"; mk_valid_accepted "$VALID"
json="$(ruby "$RB" --root "$VALID" --json 2>&1)"
specrelay_test::assert_contains "2. JSON has ok:true" "$json" '"ok": true'
specrelay_test::assert_contains "2. JSON has architecture_version" "$json" '"architecture_version": 1'
specrelay_test::assert_contains "2. JSON has status accepted" "$json" '"status": "accepted"'
specrelay_test::assert_contains "2. JSON has adoption_boundary" "$json" '"adoption_boundary": 31'
specrelay_test::assert_contains "2. JSON has checked_specs" "$json" '"checked_specs":'
specrelay_test::assert_contains "2. JSON has errors" "$json" '"errors": []'

# 3. Malformed architecture YAML fails cleanly (no stack trace).
R="$(new_root)"; mk_valid_accepted "$R"
printf ':\n : :\n  - [unbalanced\n' > "$R/architecture/architecture-version.yml"
V --root "$R"
specrelay_test::assert_true "3. malformed YAML fails" "$( [ "$RC" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "3. malformed YAML is reported as such" "$OUT" "malformed YAML"
specrelay_test::assert_not_contains "3. no Ruby backtrace leaks" "$OUT" ".rb:"

# 4. A non-mapping architecture root fails.
R="$(new_root)"; mk_valid_accepted "$R"
printf -- '- a\n- b\n' > "$R/architecture/architecture-version.yml"
V --root "$R"
specrelay_test::assert_true "4. non-mapping root fails" "$( [ "$RC" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "4. non-mapping root is named" "$OUT" "must be a mapping"

# 5. Missing/invalid version, status, timestamp, enforcement, boundary fail.
R="$(new_root)"; arch_base "$R"
printf 'status: accepted\n' > "$R/architecture/architecture-version.yml" # no version
V --root "$R"
specrelay_test::assert_contains "5a. missing version fails" "$OUT" "version must be a positive integer"

R="$(new_root)"; arch_base "$R"; good_version "$R"
ruby -i -pe 'sub(/^status: accepted/, "status: bogus")' "$R/architecture/architecture-version.yml"
V --root "$R"
specrelay_test::assert_contains "5b. invalid status fails" "$OUT" "status must be one of"

R="$(new_root)"; arch_base "$R"; good_version "$R"
ruby -i -pe 'sub(/^ratified_at:.*/, "ratified_at: null")' "$R/architecture/architecture-version.yml"
V --root "$R"
specrelay_test::assert_contains "5c. accepted + null ratified_at fails" "$OUT" "ratified_at"

R="$(new_root)"; arch_base "$R"; good_version "$R"
ruby -i -pe 'sub(/^  enforcement:.*/, "  enforcement: documentation-only")' "$R/architecture/architecture-version.yml"
V --root "$R"
specrelay_test::assert_contains "5d. accepted + documentation-only enforcement fails" "$OUT" "enforcement must be one of machine-validated"

R="$(new_root)"; arch_base "$R"; good_version "$R"
ruby -i -pe 'sub(/^    exempt_specs_up_to_and_including:.*/, "    exempt_specs_up_to_and_including: null")' "$R/architecture/architecture-version.yml"
V --root "$R"
specrelay_test::assert_contains "5e. accepted + null boundary fails" "$OUT" "adoption_boundary"

# 6. Missing, duplicate, escaping, out-of-root architecture paths fail.
R="$(new_root)"; mk_valid_accepted "$R"
rm -f "$R/architecture/decisions/ADR-0001-min.md"
V --root "$R"
specrelay_test::assert_contains "6a. a missing listed path fails" "$OUT" "does not exist"

R="$(new_root)"; arch_base "$R"
cat > "$R/architecture/architecture-version.yml" <<'YML'
version: 1
status: accepted
ratified_at: "2026-07-19T08:50:41Z"
documents:
  north_star: architecture/north-star.md
  principles: architecture/principles.md
  decisions_index: architecture/decisions/README.md
decisions:
  - architecture/decisions/ADR-0001-min.md
  - architecture/decisions/ADR-0001-min.md
spec_contract:
  required_field: architecture_version
  enforcement: machine-validated
  adoption_boundary:
    exempt_specs_up_to_and_including: 31
YML
V --root "$R"
specrelay_test::assert_contains "6b. a duplicate decision path fails" "$OUT" "duplicate decision path"

R="$(new_root)"; mk_valid_accepted "$R"
ruby -i -pe 'sub(%r{^  north_star:.*}, "  north_star: ../evil.md")' "$R/architecture/architecture-version.yml"
V --root "$R"
specrelay_test::assert_contains "6c. a '..' escaping path fails" "$OUT" "escapes the repository"

R="$(new_root)"; mk_valid_accepted "$R"
OUTSIDE="$(new_root)"; printf 'x\n' > "$OUTSIDE/target.md"
ln -s "$OUTSIDE/target.md" "$R/architecture/north-star.md" 2>/dev/null && cp /dev/null /dev/null
rm -f "$R/architecture/north-star.md"; ln -s "$OUTSIDE/target.md" "$R/architecture/north-star.md"
V --root "$R"
specrelay_test::assert_contains "6d. an out-of-root symlink target fails" "$OUT" "outside the repository"

# 7. A missing listed ADR (6a) and an ADR version mismatch both fail.
R="$(new_root)"; mk_valid_accepted "$R"
ruby -i -pe 'sub(/^1$/, "2")' "$R/architecture/decisions/ADR-0001-min.md"
V --root "$R"
specrelay_test::assert_contains "7. an ADR version mismatch fails" "$OUT" "does not match version-file version"

# 8. Decision-index / version-set disagreement fails.
R="$(new_root)"; mk_valid_accepted "$R"
printf '| [0002](ADR-0002-extra.md) | Extra | Accepted |\n' >> "$R/architecture/decisions/README.md"
V --root "$R"
specrelay_test::assert_contains "8. index/version-set disagreement fails" "$OUT" "does not match the architecture-version.yml decision set"

# 9. An exempt historical spec without metadata passes.
R="$(new_root)"; arch_base "$R"; good_version "$R"
write_spec "$R" "0005-historical" "# Spec 0005"$'\n\n'"## Status"$'\n\n'"proposed"
V --root "$R"
specrelay_test::assert_eq "9. an exempt historical spec (no metadata) passes" "0" "$RC"

# 10. The bootstrap Spec 0031 passes without architecture_version at the boundary.
R="$(new_root)"; arch_base "$R"; good_version "$R"
write_spec "$R" "0031-ratify" "# Spec 0031"$'\n\n'"## Status"$'\n\n'"accepted"
V --root "$R"
specrelay_test::assert_eq "10. boundary spec 0031 (no metadata) passes" "0" "$RC"

# 11. The first post-boundary spec with integer version 1 passes.
R="$(new_root)"; mk_valid_accepted "$R"
write_spec "$R" "0032-first" "# Spec 0032"$'\n\n'"## Architecture metadata"$'\n\n'"\`\`\`yaml"$'\n'"architecture_version: 1"$'\n'"\`\`\`"
V --root "$R"
specrelay_test::assert_eq "11. post-boundary spec 0032 with architecture_version:1 passes" "0" "$RC"
json="$(ruby "$RB" --root "$R" --json 2>&1)"
specrelay_test::assert_contains "11. checked_specs counts the post-boundary spec" "$json" '"checked_specs": 1'

# 12. A missing metadata section fails.
R="$(new_root)"; mk_valid_accepted "$R"
write_spec "$R" "0032-nometa" "# Spec 0032"$'\n\n'"## Summary"$'\n\n'"nothing here"
V --root "$R"
specrelay_test::assert_true "12. post-boundary spec without the section fails" "$( [ "$RC" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "12. the diagnostic names the missing section" "$OUT" "missing Architecture metadata section"

# 13. A prose-only mention of architecture_version fails.
R="$(new_root)"; mk_valid_accepted "$R"
write_spec "$R" "0032-prose" "# Spec 0032"$'\n\n'"## Summary"$'\n\n'"This spec targets architecture_version: 1 in passing."
V --root "$R"
specrelay_test::assert_true "13. a prose-only mention fails" "$( [ "$RC" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "13. prose-only mention reported as missing section" "$OUT" "missing Architecture metadata section"

# 14. Duplicate sections or duplicate fields fail.
R="$(new_root)"; mk_valid_accepted "$R"
write_spec "$R" "0032-dupsec" "# Spec 0032"$'\n\n'"## Architecture metadata"$'\n\n'"\`\`\`yaml"$'\n'"architecture_version: 1"$'\n'"\`\`\`"$'\n\n'"## Architecture metadata"$'\n\n'"\`\`\`yaml"$'\n'"architecture_version: 1"$'\n'"\`\`\`"
V --root "$R"
specrelay_test::assert_contains "14a. duplicate sections fail" "$OUT" "duplicate Architecture metadata sections"

R="$(new_root)"; mk_valid_accepted "$R"
write_spec "$R" "0032-dupfield" "# Spec 0032"$'\n\n'"## Architecture metadata"$'\n\n'"\`\`\`yaml"$'\n'"architecture_version: 1"$'\n'"architecture_version: 1"$'\n'"\`\`\`"
V --root "$R"
specrelay_test::assert_contains "14b. duplicate field fails" "$OUT" "duplicate architecture_version field"

# 15. A malformed metadata YAML block fails.
R="$(new_root)"; mk_valid_accepted "$R"
write_spec "$R" "0032-badyaml" "# Spec 0032"$'\n\n'"## Architecture metadata"$'\n\n'"\`\`\`yaml"$'\n'"architecture_version: : ["$'\n'"\`\`\`"
V --root "$R"
specrelay_test::assert_true "15. malformed metadata YAML fails" "$( [ "$RC" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "15. malformed metadata YAML is reported" "$OUT" "malformed Architecture metadata YAML"

# 16. Quoted, boolean, float, list, and mismatched version values fail.
for pair in 'quoted|architecture_version: "1"' 'bool|architecture_version: true' 'float|architecture_version: 1.0' 'list|architecture_version: [1]'; do
  label="${pair%%|*}"; line="${pair#*|}"
  R="$(new_root)"; mk_valid_accepted "$R"
  write_spec "$R" "0032-$label" "# Spec 0032"$'\n\n'"## Architecture metadata"$'\n\n'"\`\`\`yaml"$'\n'"$line"$'\n'"\`\`\`"
  V --root "$R"
  specrelay_test::assert_true "16. a $label architecture_version value fails" "$( [ "$RC" -ne 0 ]; echo $? )"
  specrelay_test::assert_contains "16. $label reported as a bare-integer problem" "$OUT" "must be a bare integer"
done
R="$(new_root)"; mk_valid_accepted "$R"
write_spec "$R" "0032-mismatch" "# Spec 0032"$'\n\n'"## Architecture metadata"$'\n\n'"\`\`\`yaml"$'\n'"architecture_version: 2"$'\n'"\`\`\`"
V --root "$R"
specrelay_test::assert_contains "16. a mismatched version value fails" "$OUT" "does not match accepted version 1"

# 17. A higher spec number present produces a higher computed boundary.
R="$(new_root)"; mk_valid_accepted "$R"
specrelay_test::assert_eq "17a. computed boundary is 31 with only exempt specs" "31" "$(ruby "$RB" --root "$R" --compute-boundary)"
mkdir -p "$R/docs/specs/0045-later"; printf '# Spec 0045\n' > "$R/docs/specs/0045-later/spec.md"
specrelay_test::assert_eq "17b. a 0045 spec raises the computed boundary to 45" "45" "$(ruby "$RB" --root "$R" --compute-boundary)"

# 18. Proposed-fixture behavior remains valid but unenforced. Its ADR/doc/index
# status surfaces are Proposed, coherent with the proposed version file.
R="$(new_root)"; arch_base "$R" Proposed
cat > "$R/architecture/architecture-version.yml" <<'YML'
version: 1
status: proposed
ratified_at: null
documents:
  north_star: architecture/north-star.md
  principles: architecture/principles.md
  decisions_index: architecture/decisions/README.md
decisions:
  - architecture/decisions/ADR-0001-min.md
spec_contract:
  required_field: architecture_version
  enforcement: documentation-only
  adoption_boundary:
    exempt_specs_up_to_and_including: null
YML
# A spec that WOULD fail if enforcement were active — but enforcement is
# inactive while proposed, so the whole config is valid.
write_spec "$R" "0099-would-fail-if-enforced" "# Spec 0099"$'\n\n'"## Summary"$'\n\n'"no metadata"
V --root "$R"
specrelay_test::assert_eq "18. a proposed configuration is valid" "0" "$RC"
specrelay_test::assert_contains "18. proposed reports enforcement inactive / not ratified" "$OUT" "NOT ratified"
json="$(ruby "$RB" --root "$R" --json 2>&1)"
specrelay_test::assert_contains "18. proposed checks no specs" "$json" '"checked_specs": 0'

# 22. Validation is read-only (checked here on the proposed fixture above).
before="$(cd "$R" && find . -type f -exec shasum {} \; 2>/dev/null | sort)"
ruby "$RB" --root "$R" >/dev/null 2>&1
ruby "$RB" --root "$R" --json >/dev/null 2>&1
after="$(cd "$R" && find . -type f -exec shasum {} \; 2>/dev/null | sort)"
specrelay_test::assert_eq "22. validation mutates nothing (files unchanged)" "$before" "$after"

# =============================================================================
# Review-round regression tests (spec 0031, review findings 1-5).
# =============================================================================

# R1a. An ADR whose lifecycle status disagrees with the accepted version fails.
R="$(new_root)"; mk_valid_accepted "$R"
ruby -i -pe 'sub(/^Accepted\.$/, "Proposed.")' "$R/architecture/decisions/ADR-0001-min.md"
V --root "$R"
specrelay_test::assert_true "R1a. an incoherent ADR status fails" "$( [ "$RC" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "R1a. names the ADR status incoherence" "$OUT" "incoherent with the accepted architecture version"

# R1b. north-star.md status incoherent with the accepted version fails.
R="$(new_root)"; mk_valid_accepted "$R"
ruby -i -pe 'sub(/\*\*Status:\*\* accepted/, "**Status:** proposed")' "$R/architecture/north-star.md"
V --root "$R"
specrelay_test::assert_contains "R1b. north-star status incoherence fails" "$OUT" "north-star.md"
specrelay_test::assert_contains "R1b. names the incoherence" "$OUT" "incoherent with the accepted architecture version"

# R1c. principles.md status incoherent with the accepted version fails.
R="$(new_root)"; mk_valid_accepted "$R"
ruby -i -pe 'sub(/\*\*Status:\*\* accepted/, "**Status:** proposed")' "$R/architecture/principles.md"
V --root "$R"
specrelay_test::assert_contains "R1c. principles status incoherence fails" "$OUT" "principles.md"

# R1d. A decisions-index row that lists a version-set ADR with the wrong status fails.
R="$(new_root)"; mk_valid_accepted "$R"
ruby -i -pe 'sub(/\| Accepted \|/, "| Proposed |")' "$R/architecture/decisions/README.md"
V --root "$R"
specrelay_test::assert_contains "R1d. incoherent index status fails" "$OUT" "index status"

# R1e. A missing status surface (north-star with no **Status:**) fails.
R="$(new_root)"; mk_valid_accepted "$R"
printf '# North Star\n\nno status surface here\n' > "$R/architecture/north-star.md"
V --root "$R"
specrelay_test::assert_contains "R1e. a missing status surface fails" "$OUT" "does not declare a '**Status:**' surface"

# R2. Two spec directories sharing a number are rejected, not silently overwritten.
R="$(new_root)"; mk_valid_accepted "$R"
mkdir -p "$R/docs/specs/0005-duplicate-number"
printf '# Spec 0005 (dup)\n' > "$R/docs/specs/0005-duplicate-number/spec.md"
V --root "$R"
specrelay_test::assert_true "R2. a duplicate spec number fails" "$( [ "$RC" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "R2. names the duplicated number and both dirs" "$OUT" "duplicate spec directories share number 0005"

# R3. A duplicate architecture_version key via a QUOTED key variant fails.
R="$(new_root)"; mk_valid_accepted "$R"
write_spec "$R" "0032-dupkey-quoted" "# Spec 0032"$'\n\n'"## Architecture metadata"$'\n\n'"\`\`\`yaml"$'\n'"architecture_version: 1"$'\n'"\"architecture_version\": 2"$'\n'"\`\`\`"
V --root "$R"
specrelay_test::assert_true "R3. a quoted-key duplicate fails" "$( [ "$RC" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "R3. names the duplicate field" "$OUT" "duplicate architecture_version field"

# R4a. ratified_at present but WITHOUT a timezone fails.
R="$(new_root)"; arch_base "$R"; good_version "$R"
ruby -i -pe 'sub(/^ratified_at:.*/, %q{ratified_at: "2026-07-19T08:50:41"})' "$R/architecture/architecture-version.yml"
V --root "$R"
specrelay_test::assert_true "R4a. ratified_at without a timezone fails" "$( [ "$RC" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "R4a. requires an explicit timezone" "$OUT" "explicit timezone"

# R4b. An unquoted (bare YAML) ratified_at is rejected in favour of a quoted string.
R="$(new_root)"; arch_base "$R"; good_version "$R"
ruby -i -pe 'sub(/^ratified_at:.*/, "ratified_at: 2026-07-19T08:50:41Z")' "$R/architecture/architecture-version.yml"
V --root "$R"
specrelay_test::assert_true "R4b. a bare YAML timestamp fails" "$( [ "$RC" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "R4b. requires a QUOTED string" "$OUT" "must be a QUOTED full ISO-8601 string"

# R4c. A date-only ratified_at (no time) fails.
R="$(new_root)"; arch_base "$R"; good_version "$R"
ruby -i -pe 'sub(/^ratified_at:.*/, %q{ratified_at: "2026-07-19"})' "$R/architecture/architecture-version.yml"
V --root "$R"
specrelay_test::assert_true "R4c. a date-only ratified_at fails" "$( [ "$RC" -ne 0 ]; echo $? )"

# R5. An unsupported enforcement value on an accepted version fails.
R="$(new_root)"; arch_base "$R"; good_version "$R"
ruby -i -pe 'sub(/^  enforcement:.*/, "  enforcement: totally-made-up")' "$R/architecture/architecture-version.yml"
V --root "$R"
specrelay_test::assert_true "R5a. an unsupported enforcement value fails" "$( [ "$RC" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "R5a. names the supported value" "$OUT" "enforcement must be one of machine-validated"

# R5b. A proposed version with a non-documentation-only enforcement fails.
R="$(new_root)"; arch_base "$R" Proposed
cat > "$R/architecture/architecture-version.yml" <<'YML'
version: 1
status: proposed
ratified_at: null
documents:
  north_star: architecture/north-star.md
  principles: architecture/principles.md
  decisions_index: architecture/decisions/README.md
decisions:
  - architecture/decisions/ADR-0001-min.md
spec_contract:
  required_field: architecture_version
  enforcement: machine-validated
  adoption_boundary:
    exempt_specs_up_to_and_including: null
YML
V --root "$R"
specrelay_test::assert_true "R5b. proposed + machine-validated enforcement fails" "$( [ "$RC" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "R5b. names the supported proposed value" "$OUT" "enforcement must be one of documentation-only"

# --- CLI + release integration (full source-tree fixtures) ------------------
# Build ONE full-tree fixture reused by the installed-mode and release cases.
WORK="$(specrelay_test::mktemp_project)"
FIX="$WORK/src"
mkdir -p "$FIX"
cp -R "$SPECRELAY_ROOT"/. "$FIX"/
rm -rf "$FIX/.git" "$FIX/.specrelay-runs" "$FIX/.specrelay-cache" "$FIX/.specrelay-locks"
(cd "$FIX" && git init -q && git config core.hooksPath /dev/null \
  && git config user.name "SpecRelay Test" && git config user.email "specrelay-test@example.invalid" \
  && git add -A && git commit -q -m "baseline")

# 19. `architecture validate` refuses installed mode.
PREFIX="$WORK/prefix"
"$SPECRELAY_ROOT/install/install.sh" --prefix "$PREFIX" >/dev/null 2>&1
inst_out="$(env -u SPECRELAY_HOME "$PREFIX/bin/specrelay" architecture validate 2>&1)"
inst_rc=$?
specrelay_test::assert_true "19. architecture validate refuses installed mode" "$( [ "$inst_rc" -ne 0 ]; echo $? )"
specrelay_test::assert_contains "19. installed-mode refusal is actionable" "$inst_out" "source-local"

# 19b. source-local `architecture validate` on the fixture (valid) passes.
sl_out="$(env -u SPECRELAY_HOME "$FIX/bin/specrelay" architecture validate 2>&1)"
specrelay_test::assert_eq "19b. source-local architecture validate passes on the fixture" "0" "$?"
specrelay_test::assert_contains "19b. reports accepted" "$sl_out" "accepted"

# 21. Release behavior is unchanged when architecture validation passes.
ok_plan="$(env -u SPECRELAY_HOME "$FIX/bin/specrelay" release plan 2>&1)"
specrelay_test::assert_contains "21. release plan runs normally with a valid contract" "$ok_plan" "Current version:"

# 20. All release commands refuse an invalid architecture contract BEFORE any
#     mutation.
version_before="$(tr -d '[:space:]' < "$FIX/VERSION")"
changelog_before="$(shasum "$FIX/CHANGELOG.md" 2>/dev/null | awk '{print $1}')"
printf 'version: 1\nstatus: bogus\n' > "$FIX/architecture/architecture-version.yml"
for sub in plan prepare verify tag; do
  bad_out="$(env -u SPECRELAY_HOME "$FIX/bin/specrelay" release "$sub" 2>&1)"
  bad_rc=$?
  specrelay_test::assert_true "20. release $sub refuses an invalid architecture contract" "$( [ "$bad_rc" -ne 0 ]; echo $? )"
  specrelay_test::assert_contains "20. release $sub names the architecture problem" "$bad_out" "architecture"
done
specrelay_test::assert_eq "20. no release command mutated VERSION when blocked" "$version_before" "$(tr -d '[:space:]' < "$FIX/VERSION")"
specrelay_test::assert_eq "20. no release command mutated CHANGELOG when blocked" "$changelog_before" "$(shasum "$FIX/CHANGELOG.md" 2>/dev/null | awk '{print $1}')"

specrelay_test::summary
exit $?
