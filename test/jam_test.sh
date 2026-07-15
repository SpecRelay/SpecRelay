#!/usr/bin/env bash
# jam_test.sh — Jam capability adapter tests for spec 0023 (reference
# discovery/dedup/provenance, doctor readiness reporting, task-specific
# requirement semantics, retrieval+redaction via a FAKE adapter — section
# 27 forbids ever touching a real Jam recording in automated tests).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/test_helper.sh
. "$SCRIPT_DIR/test_helper.sh"

for f in output.sh project.sh config.sh discovery.sh state.sh task.sh jam.sh bundle.sh resolved_spec.sh; do
  # shellcheck disable=SC1090
  . "$SPECRELAY_ROOT/lib/specrelay/$f"
done

# A fixture "fake retrieval adapter" script: writes recognizable evidence
# classes with embedded secrets, so redaction can be proven for real without
# ever touching a real Jam recording (spec section 27). Written into an
# isolated temp dir (never this repo's own test/fixtures/) so the suite's
# host-repository mutation safety check (spec 0085, section 66) never sees a
# stray untracked file appear under the real checkout.
JAM_FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-jam-fixtures.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$JAM_FIXTURE_DIR")
FAKE_JAM_SCRIPT="$JAM_FIXTURE_DIR/fake-jam-retrieve.sh"
cat > "$FAKE_JAM_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
out_dir="$3"
cat > "$out_dir/metadata.raw" <<JSON
{"title": "Demo recording", "url": "$2"}
JSON
cat > "$out_dir/transcript.raw" <<MD
User clicked Submit. Authorization: Bearer sk-secret-token-abcdef123456 was sent.
MD
cat > "$out_dir/user-events.raw" <<JSON
[{"type": "click", "target": "#submit"}]
JSON
cat > "$out_dir/console-errors.raw" <<JSON
[{"message": "TypeError: x is not a function"}]
JSON
cat > "$out_dir/network-errors.raw" <<JSON
[{"status": 500, "url": "/offers", "cookie": "session_id=deadbeefcafefeed"}]
JSON
cat > "$out_dir/environment.raw" <<JSON
{"browser": "Chrome", "os": "macOS"}
JSON
exit 0
SCRIPT
chmod +x "$FAKE_JAM_SCRIPT"

FAKE_FAIL_SCRIPT="$JAM_FIXTURE_DIR/fake-jam-retrieve-fail.sh"
cat > "$FAKE_FAIL_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
chmod +x "$FAKE_FAIL_SCRIPT"

# --- canonical id derivation --------------------------------------------------
cid="$(specrelay::jam::canonical_id "https://jam.dev/c/abc123-def456")"
specrelay_test::assert_eq "canonical_id derives from the last URL path segment" "abc123-def456" "$cid"
cid2="$(specrelay::jam::canonical_id "https://jam.dev/c/abc123-def456?query=1")"
specrelay_test::assert_eq "canonical_id strips query strings" "abc123-def456" "$cid2"

# --- (32) SpecRelay works without Jam when no Jam reference exists ----------
proj="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj/docs/sdd/0200-no-jam"
printf '# Spec\n\nNo external evidence here.\n' > "$proj/docs/sdd/0200-no-jam/spec.md"
(cd "$proj" && git add -A && git commit -q -m fixture)
(cd "$proj" && SPECRELAY_JAM_CLAUDE_BIN=/nonexistent "$SPECRELAY_BIN" task create docs/sdd/0200-no-jam >/tmp/specrelay-jam-out.$$ 2>&1)
rc=$?
specrelay_test::assert_true "a task with no Jam reference succeeds with no Jam configured" "$rc"
ext_count="$(python3 -c "import json; print(len(json.load(open('$proj/.specrelay-runs/tasks/0200-no-jam/01-input-manifest.json'))['external_evidence']))")"
specrelay_test::assert_eq "a task with no Jam reference records zero external evidence entries" "0" "$ext_count"

# --- (33) general doctor reports Jam optional and not configured, no overall failure ---
readiness="$(SPECRELAY_JAM_CLAUDE_BIN=/nonexistent specrelay::jam::readiness "$proj")"
status="$(printf '%s\n' "$readiness" | sed -n 's/^status=//p')"
specrelay_test::assert_eq "readiness reports not-configured when nothing is set up" "not-configured" "$status"
(cd "$proj" && SPECRELAY_JAM_CLAUDE_BIN=/nonexistent specrelay::jam::doctor_report "$proj" >/tmp/specrelay-jam-doctor.$$ 2>&1)
doctor_rc=$?
specrelay_test::assert_true "doctor's Jam section does not fail overall readiness when Jam is unconfigured and globally optional" "$doctor_rc"
specrelay_test::assert_contains "doctor's Jam section distinguishes configured/registered/connected/authenticated/tools-available states" \
  "$(cat /tmp/specrelay-jam-doctor.$$)" "Authenticated:"

# --- jam.required: true makes an unready Jam fail overall doctor readiness ---
cat >> "$proj/.specrelay/config.yml" <<'YAML'
jam:
  required: true
YAML
(cd "$proj" && SPECRELAY_JAM_CLAUDE_BIN=/nonexistent specrelay::jam::doctor_report "$proj" >/tmp/specrelay-jam-doctor2.$$ 2>&1)
required_rc=$?
specrelay_test::assert_true "jam.required: true fails the Jam doctor section when Jam is not ready" "$([ "$required_rc" -ne 0 ] && echo 0 || echo 1)"

# --- (35)-(36) a Jam reference makes Jam required for the task; blocks when unavailable ---
proj2="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj2/docs/sdd/0201-jam-required"
printf '# Spec\n\nSee https://jam.dev/c/xyz789 for the bug recording.\n' > "$proj2/docs/sdd/0201-jam-required/spec.md"
(cd "$proj2" && git add -A && git commit -q -m fixture)
err="$(cd "$proj2" && SPECRELAY_JAM_CLAUDE_BIN=/nonexistent "$SPECRELAY_BIN" task create docs/sdd/0201-jam-required 2>&1 1>/dev/null)"
rc=$?
specrelay_test::assert_true "a Jam reference with no retrieval path available blocks task creation" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "the block names the Jam requirement reason" "$err" "jam"
specrelay_test::assert_true "a blocked Jam-referencing task leaves no task directory behind" \
  "$([ ! -d "$proj2/.specrelay-runs/tasks/0201-jam-required" ] && echo 0 || echo 1)"

# --- happy path: fake retrieval adapter succeeds; task is created -----------
(cd "$proj2" && SPECRELAY_JAM_CLAUDE_BIN=/nonexistent SPECRELAY_JAM_FAKE_RETRIEVE="$FAKE_JAM_SCRIPT" \
  "$SPECRELAY_BIN" task create docs/sdd/0201-jam-required >/tmp/specrelay-jam-out2.$$ 2>&1)
rc=$?
specrelay_test::assert_true "with a working retrieval adapter, the Jam-referencing task is created" "$rc"
jam_dir="$proj2/.specrelay-runs/tasks/0201-jam-required/01-input-bundle/external/jam/xyz789"
specrelay_test::assert_true "Jam snapshot directory exists at the canonical-id path" "$([ -d "$jam_dir" ] && echo 0 || echo 1)"

# --- (38) referencing local files are recorded as provenance ---------------
provenance="$(python3 -c "
import json
m = json.load(open('$proj2/.specrelay-runs/tasks/0201-jam-required/01-input-manifest.json'))
print(m['external_evidence'][0]['referencing_local_files'])
")"
specrelay_test::assert_contains "manifest external_evidence records the referencing local file" "$provenance" "spec.md"

# --- (39)-(43) transcript / user-events / console / network / environment snapshotted ---
specrelay_test::assert_true "transcript evidence is snapshotted" "$([ -s "$jam_dir/transcript.md" ] && echo 0 || echo 1)"
specrelay_test::assert_true "user-events evidence is snapshotted" "$([ -s "$jam_dir/user-events.json" ] && echo 0 || echo 1)"
specrelay_test::assert_true "console-errors evidence is snapshotted" "$([ -s "$jam_dir/console-errors.json" ] && echo 0 || echo 1)"
specrelay_test::assert_true "network-errors evidence is snapshotted" "$([ -s "$jam_dir/network-errors.json" ] && echo 0 || echo 1)"
specrelay_test::assert_true "environment evidence is snapshotted" "$([ -s "$jam_dir/environment.json" ] && echo 0 || echo 1)"

# --- (44) missing evidence classes reported honestly -------------------------
missing="$(python3 -c "import json; print(json.load(open('$jam_dir/retrieval-evidence.json'))['missing_evidence_types'])")"
specrelay_test::assert_contains "console-logs (never provided by the fixture) is honestly reported missing" "$missing" "console-logs"
specrelay_test::assert_contains "network-requests (never provided by the fixture) is honestly reported missing" "$missing" "network-requests"

# --- (45) resolved specification includes Jam-derived findings with provenance ---
resolved_jam="$(cat "$proj2/.specrelay-runs/tasks/0201-jam-required/02-resolved-specification.md")"
specrelay_test::assert_contains "resolved specification's External Evidence section cites the Jam canonical id" "$resolved_jam" "xyz789"
specrelay_test::assert_contains "resolved specification's External Evidence section cites the Jam snapshot path" "$resolved_jam" "01-input-bundle/external/jam/xyz789"

# --- (48) Jam is never marked inspected when retrieval did not occur --------
retrieval_status="$(python3 -c "import json; print(json.load(open('$jam_dir/reference.json'))['retrieval_status'])")"
specrelay_test::assert_eq "a successful fake retrieval is marked retrieved" "retrieved" "$retrieval_status"

proj3="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj3/docs/sdd/0202-jam-fails"
printf '# Spec\n\nSee https://jam.dev/c/willfail for context.\n' > "$proj3/docs/sdd/0202-jam-fails/spec.md"
(cd "$proj3" && git add -A && git commit -q -m fixture)
(cd "$proj3" && SPECRELAY_JAM_CLAUDE_BIN=/nonexistent SPECRELAY_JAM_FAKE_RETRIEVE="$FAKE_FAIL_SCRIPT" \
  "$SPECRELAY_BIN" task create docs/sdd/0202-jam-fails >/tmp/specrelay-jam-out3.$$ 2>&1)
rc=$?
specrelay_test::assert_true "a failing fake retrieval adapter still blocks task creation (never marked inspected)" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# --- (37) duplicate Jam URLs produce one canonical snapshot -----------------
proj4="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj4/docs/sdd/0203-dup-jam"
cat > "$proj4/docs/sdd/0203-dup-jam/spec.md" <<'EOF'
# Spec
First mention: https://jam.dev/c/dup111
EOF
cat > "$proj4/docs/sdd/0203-dup-jam/notes.md" <<'EOF'
Second mention of the same recording: https://jam.dev/c/dup111
EOF
(cd "$proj4" && git add -A && git commit -q -m fixture)
(cd "$proj4" && SPECRELAY_JAM_CLAUDE_BIN=/nonexistent SPECRELAY_JAM_FAKE_RETRIEVE="$FAKE_JAM_SCRIPT" \
  "$SPECRELAY_BIN" task create docs/sdd/0203-dup-jam >/tmp/specrelay-jam-out4.$$ 2>&1)
ext_count4="$(python3 -c "import json; print(len(json.load(open('$proj4/.specrelay-runs/tasks/0203-dup-jam/01-input-manifest.json'))['external_evidence']))")"
specrelay_test::assert_eq "duplicate references to the same recording resolve to one canonical entry" "1" "$ext_count4"
refs4="$(python3 -c "
import json
m = json.load(open('$proj4/.specrelay-runs/tasks/0203-dup-jam/01-input-manifest.json'))
print(sorted(m['external_evidence'][0]['referencing_local_files']))
")"
specrelay_test::assert_eq "the canonical entry retains provenance from BOTH referencing files" "['notes.md', 'spec.md']" "$refs4"

# --- (49)-(53) redaction of authorization headers, cookies, tokens ----------
transcript="$(cat "$jam_dir/transcript.md")"
specrelay_test::assert_not_contains "the bearer token secret is not preserved in the redacted transcript" "$transcript" "sk-secret-token-abcdef123456"
specrelay_test::assert_contains "the redacted transcript shows the redaction marker" "$transcript" "REDACTED:authorization-header"

network_errors="$(cat "$jam_dir/network-errors.json")"
specrelay_test::assert_not_contains "the session cookie secret is not preserved in redacted network evidence" "$network_errors" "deadbeefcafefeed"
specrelay_test::assert_contains "the redacted network evidence shows a redaction marker" "$network_errors" "REDACTED"

redaction_report="$(cat "$jam_dir/redaction-report.json")"
specrelay_test::assert_contains "redaction report records the artifact and category" "$redaction_report" "authorization-header"
specrelay_test::assert_not_contains "redaction report never preserves the removed secret value" "$redaction_report" "sk-secret-token-abcdef123456"
specrelay_test::assert_not_contains "redaction report never preserves the removed cookie value" "$redaction_report" "deadbeefcafefeed"

# --- jam.retrieval_command config path (real adapter, not just the test-only env hook) ---
proj5="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj5/docs/sdd/0204-retrieval-command"
printf '# Spec\n\nSee https://jam.dev/c/cfg001 for context.\n' > "$proj5/docs/sdd/0204-retrieval-command/spec.md"
cat >> "$proj5/.specrelay/config.yml" <<YAML
jam:
  retrieval_command: $FAKE_JAM_SCRIPT
YAML
(cd "$proj5" && git add -A && git commit -q -m fixture)
(cd "$proj5" && SPECRELAY_JAM_CLAUDE_BIN=/nonexistent "$SPECRELAY_BIN" task create docs/sdd/0204-retrieval-command >/tmp/specrelay-jam-out5.$$ 2>&1)
rc=$?
specrelay_test::assert_true "jam.retrieval_command (config, not just the test-env hook) retrieves successfully" "$rc"
status5="$(python3 -c "import json; print(json.load(open('$proj5/.specrelay-runs/tasks/0204-retrieval-command/01-input-bundle/external/jam/cfg001/reference.json'))['retrieval_status'])" 2>/dev/null)"
specrelay_test::assert_eq "jam.retrieval_command retrieval is marked retrieved" "retrieved" "$status5"

specrelay_test::summary
