#!/usr/bin/env bash
# bundle_test.sh — file-or-directory input, discovery/exclusion, content
# classification, manifest+snapshot, and resume-safety tests for spec 0023
# ("Specification Bundle Analysis, Jam Evidence, and Resolved Executor
# Input"), sections 4-13, 21-23.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/test_helper.sh
. "$SCRIPT_DIR/test_helper.sh"

for f in output.sh project.sh config.sh discovery.sh state.sh task.sh jam.sh bundle.sh resolved_spec.sh; do
  # shellcheck disable=SC1090
  . "$SPECRELAY_ROOT/lib/specrelay/$f"
done

# --- (1) single Markdown file still works (24.1 #1) -------------------------
proj="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj/docs/sdd/0100-file"
printf '# File Spec\n\n## Objective\nDo the thing.\n' > "$proj/docs/sdd/0100-file/spec.md"
(cd "$proj" && git add -A && git commit -q -m fixture)

out="$(cd "$proj" && "$SPECRELAY_BIN" task create docs/sdd/0100-file/spec.md 2>&1)"
rc=$?
specrelay_test::assert_true "file input: task create succeeds" "$rc"
task_dir="$proj/.ai-runs/tasks/0100-file"
specrelay_test::assert_true "file input: manifest exists" "$([ -f "$task_dir/01-input-manifest.json" ] && echo 0 || echo 1)"
kind="$(python3 -c "import json; print(json.load(open('$task_dir/01-input-manifest.json'))['input_kind'])")"
specrelay_test::assert_eq "file input: manifest records input_kind=file" "file" "$kind"
role="$(python3 -c "import json; print(json.load(open('$task_dir/01-input-manifest.json'))['files'][0]['role'])")"
specrelay_test::assert_eq "file input: the single file is classified as the functional spec" "authoritative-functional-spec" "$role"
specrelay_test::assert_true "file input: resolved specification is non-empty" "$([ -s "$task_dir/02-resolved-specification.md" ] && echo 0 || echo 1)"

# --- (2)-(4) directory input with spec.md, tech-spec.md, tech_spec.md -------
proj2="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj2/docs/sdd/0101-dir/evidence"
printf '# Dir Spec\n\n## Functional Requirements\n- Must work.\n' > "$proj2/docs/sdd/0101-dir/spec.md"
printf '# Tech\n\n## Technical Requirements\n- Use Postgres.\n' > "$proj2/docs/sdd/0101-dir/tech-spec.md"
printf 'app error trace\n' > "$proj2/docs/sdd/0101-dir/evidence/app.log"
printf '{"a": 1}\n' > "$proj2/docs/sdd/0101-dir/evidence/sample.json"
(cd "$proj2" && git add -A && git commit -q -m fixture)

(cd "$proj2" && "$SPECRELAY_BIN" task create docs/sdd/0101-dir >/tmp/specrelay-bundle-out.$$ 2>&1)
rc=$?
specrelay_test::assert_true "directory input with spec.md + tech-spec.md succeeds" "$rc"
tdir="$proj2/.ai-runs/tasks/0101-dir"
tech="$(python3 -c "import json; print(json.load(open('$tdir/01-input-manifest.json'))['technical_specification_path'])")"
specrelay_test::assert_eq "tech-spec.md is recognized as the technical specification" "tech-spec.md" "$tech"
fcount="$(python3 -c "import json; print(json.load(open('$tdir/01-input-manifest.json'))['bundle_file_count'])")"
specrelay_test::assert_eq "directory bundle file count includes spec + tech-spec + 2 evidence files" "4" "$fcount"

# tech_spec.md (underscore) variant recognized
proj3="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj3/docs/sdd/0102-underscore"
printf '# Spec\n' > "$proj3/docs/sdd/0102-underscore/spec.md"
printf '# Tech\n' > "$proj3/docs/sdd/0102-underscore/tech_spec.md"
(cd "$proj3" && git add -A && git commit -q -m fixture && "$SPECRELAY_BIN" task create docs/sdd/0102-underscore >/tmp/specrelay-bundle-out2.$$ 2>&1)
rc=$?
tech3="$(python3 -c "import json; print(json.load(open('$proj3/.ai-runs/tasks/0102-underscore/01-input-manifest.json'))['technical_specification_path'])" 2>/dev/null)"
specrelay_test::assert_eq "tech_spec.md (underscore variant) is recognized" "tech_spec.md" "$tech3"

# --- (5) both technical filename variants fail with ambiguity (6.2) --------
proj4="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj4/docs/sdd/0103-ambiguous"
printf '# Spec\n' > "$proj4/docs/sdd/0103-ambiguous/spec.md"
printf '# Tech A\n' > "$proj4/docs/sdd/0103-ambiguous/tech-spec.md"
printf '# Tech B\n' > "$proj4/docs/sdd/0103-ambiguous/tech_spec.md"
(cd "$proj4" && git add -A && git commit -q -m fixture)
err="$(cd "$proj4" && "$SPECRELAY_BIN" task create docs/sdd/0103-ambiguous 2>&1 1>/dev/null)"
rc=$?
specrelay_test::assert_true "both tech-spec.md and tech_spec.md fails" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "ambiguity error names both filenames" "$err" "tech-spec.md and tech_spec.md"
specrelay_test::assert_true "ambiguous bundle leaves no task directory behind" "$([ ! -d "$proj4/.ai-runs/tasks/0103-ambiguous" ] && echo 0 || echo 1)"

# --- (6) missing required spec.md fails under default policy (6.1) ---------
proj5="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj5/docs/sdd/0104-missing"
printf 'just some notes\n' > "$proj5/docs/sdd/0104-missing/notes.md"
(cd "$proj5" && git add -A && git commit -q -m fixture)
err="$(cd "$proj5" && "$SPECRELAY_BIN" task create docs/sdd/0104-missing 2>&1 1>/dev/null)"
rc=$?
specrelay_test::assert_true "directory without spec.md fails under default policy" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "missing-spec.md error is actionable" "$err" "spec.md"

# --- (7)-(8) nested files discovered; deterministic ordering ---------------
proj6="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj6/docs/sdd/0105-nested/b" "$proj6/docs/sdd/0105-nested/a"
printf '# Spec\n' > "$proj6/docs/sdd/0105-nested/spec.md"
printf 'z\n' > "$proj6/docs/sdd/0105-nested/z.txt"
printf 'b\n' > "$proj6/docs/sdd/0105-nested/b/file.txt"
printf 'a\n' > "$proj6/docs/sdd/0105-nested/a/file.txt"
(cd "$proj6" && git add -A && git commit -q -m fixture && "$SPECRELAY_BIN" task create docs/sdd/0105-nested >/tmp/specrelay-bundle-out3.$$ 2>&1)
paths="$(python3 -c "import json; print(','.join(f['relative_path'] for f in json.load(open('$proj6/.ai-runs/tasks/0105-nested/01-input-manifest.json'))['files']))" 2>/dev/null)"
specrelay_test::assert_eq "nested files discovered in deterministic normalized-path order" "a/file.txt,b/file.txt,spec.md,z.txt" "$paths"

# --- (9)-(12) local evidence appears in the manifest with the right role ---
proj7="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj7/docs/sdd/0106-evidence"
printf '# Spec\n' > "$proj7/docs/sdd/0106-evidence/spec.md"
printf 'trace line\n' > "$proj7/docs/sdd/0106-evidence/app.log"
printf '{"x": 1}\n' > "$proj7/docs/sdd/0106-evidence/data.json"
printf '\x89PNG\x0d\x0a\x1a\x0a' > "$proj7/docs/sdd/0106-evidence/shot.png"
printf '%%PDF-1.4 fake pdf content' > "$proj7/docs/sdd/0106-evidence/doc.pdf"
(cd "$proj7" && git add -A && git commit -q -m fixture && "$SPECRELAY_BIN" task create docs/sdd/0106-evidence >/tmp/specrelay-bundle-out4.$$ 2>&1)
roles="$(python3 -c "
import json
m = json.load(open('$proj7/.ai-runs/tasks/0106-evidence/01-input-manifest.json'))
print({f['relative_path']: f['role'] for f in m['files']})
" 2>/dev/null)"
specrelay_test::assert_contains "log appears in manifest as log-or-trace" "$roles" "'app.log': 'log-or-trace'"
specrelay_test::assert_contains "JSON appears in manifest as structured-data" "$roles" "'data.json': 'structured-data'"
specrelay_test::assert_contains "PNG appears in manifest as visual" "$roles" "'shot.png': 'visual'"
specrelay_test::assert_contains "PDF appears in manifest as document" "$roles" "'doc.pdf': 'document'"

# --- (13) unsupported binary content reported honestly ----------------------
proj8="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj8/docs/sdd/0107-binary"
printf '# Spec\n' > "$proj8/docs/sdd/0107-binary/spec.md"
printf '\x00\x01\x02\x03binarydata' > "$proj8/docs/sdd/0107-binary/blob.bin"
(cd "$proj8" && git add -A && git commit -q -m fixture && "$SPECRELAY_BIN" task create docs/sdd/0107-binary >/tmp/specrelay-bundle-out5.$$ 2>&1)
bin_role="$(python3 -c "
import json
m = json.load(open('$proj8/.ai-runs/tasks/0107-binary/01-input-manifest.json'))
print(next(f['role'] for f in m['files'] if f['relative_path'] == 'blob.bin'))
" 2>/dev/null)"
bin_cap="$(python3 -c "
import json
m = json.load(open('$proj8/.ai-runs/tasks/0107-binary/01-input-manifest.json'))
print(next(f['inspection_capability'] for f in m['files'] if f['relative_path'] == 'blob.bin'))
" 2>/dev/null)"
specrelay_test::assert_eq "unsupported binary is classified unknown-binary" "unknown-binary" "$bin_role"
specrelay_test::assert_eq "unsupported binary reports inspection capability honestly as unsupported" "unsupported" "$bin_cap"

# --- (14)-(15) escaping / broken symlinks rejected ---------------------------
proj9="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj9/docs/sdd/0108-symlinks"
printf '# Spec\n' > "$proj9/docs/sdd/0108-symlinks/spec.md"
ln -s /etc/hosts "$proj9/docs/sdd/0108-symlinks/escaping"
(cd "$proj9" && git add -A && git commit -q -m fixture)
err="$(cd "$proj9" && "$SPECRELAY_BIN" task create docs/sdd/0108-symlinks 2>&1 1>/dev/null)"
rc=$?
specrelay_test::assert_true "a symlink escaping the input root is rejected" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "escaping-symlink error names the rejection" "$err" "escapes the input root"
rm -f "$proj9/docs/sdd/0108-symlinks/escaping"

ln -s /nonexistent-target-xyz "$proj9/docs/sdd/0108-symlinks/broken"
(cd "$proj9" && git add -A && git commit -q -m fixture2)
err="$(cd "$proj9" && "$SPECRELAY_BIN" task create docs/sdd/0108-symlinks 2>&1 1>/dev/null)"
rc=$?
specrelay_test::assert_true "a broken symlink is rejected" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "broken-symlink error names the rejection" "$err" "broken symlink"
rm -f "$proj9/docs/sdd/0108-symlinks/broken"
(cd "$proj9" && git add -A && git commit -q -m fixture3 && "$SPECRELAY_BIN" task create docs/sdd/0108-symlinks >/tmp/specrelay-bundle-out6.$$ 2>&1)
specrelay_test::assert_true "the same directory (now clean of symlinks) creates successfully" "$([ -d "$proj9/.ai-runs/tasks/0108-symlinks" ] && echo 0 || echo 1)"

# --- (16) excluded directories are not captured -----------------------------
proj10="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj10/docs/sdd/0109-excluded/node_modules"
printf '# Spec\n' > "$proj10/docs/sdd/0109-excluded/spec.md"
printf 'noise\n' > "$proj10/docs/sdd/0109-excluded/node_modules/pkg.js"
(cd "$proj10" && git add -A && git commit -q -m fixture && "$SPECRELAY_BIN" task create docs/sdd/0109-excluded >/tmp/specrelay-bundle-out7.$$ 2>&1)
paths10="$(python3 -c "import json; print([f['relative_path'] for f in json.load(open('$proj10/.ai-runs/tasks/0109-excluded/01-input-manifest.json'))['files']])" 2>/dev/null)"
specrelay_test::assert_eq "node_modules/ is excluded from discovery" "['spec.md']" "$paths10"

# --- (17)-(18) size / count limit violations fail clearly -------------------
proj11="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj11/docs/sdd/0110-limits"
printf '# Spec\n' > "$proj11/docs/sdd/0110-limits/spec.md"
printf 'one\n' > "$proj11/docs/sdd/0110-limits/one.txt"
printf 'two\n' > "$proj11/docs/sdd/0110-limits/two.txt"
cat >> "$proj11/.specrelay/config.yml" <<'YAML'
bundle:
  max_files: 2
YAML
(cd "$proj11" && git add -A && git commit -q -m fixture)
err="$(cd "$proj11" && "$SPECRELAY_BIN" task create docs/sdd/0110-limits 2>&1 1>/dev/null)"
rc=$?
specrelay_test::assert_true "exceeding the configured file-count limit fails" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "file-count-limit error reports the limit" "$err" "limit=2"
specrelay_test::assert_true "a file-count-limit failure leaves no task directory (no partial ingestion)" \
  "$([ ! -d "$proj11/.ai-runs/tasks/0110-limits" ] && echo 0 || echo 1)"

proj12="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$proj12/docs/sdd/0111-sizelimit"
printf '# Spec\n' > "$proj12/docs/sdd/0111-sizelimit/spec.md"
python3 -c "open('$proj12/docs/sdd/0111-sizelimit/big.bin', 'wb').write(b'0' * 2048)"
cat >> "$proj12/.specrelay/config.yml" <<'YAML'
bundle:
  max_total_bytes: 100
YAML
(cd "$proj12" && git add -A && git commit -q -m fixture)
err="$(cd "$proj12" && "$SPECRELAY_BIN" task create docs/sdd/0111-sizelimit 2>&1 1>/dev/null)"
rc=$?
specrelay_test::assert_true "exceeding the configured total-size limit fails" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "size-limit error reports the limit" "$err" "limit=100"

# --- (20)-(21) snapshot + manifest digests match ----------------------------
snap="$proj7/.ai-runs/tasks/0106-evidence/01-input-bundle/local/app.log"
specrelay_test::assert_true "local files are snapshotted beneath 01-input-bundle/local/" "$([ -f "$snap" ] && echo 0 || echo 1)"
digest_match="$(python3 -c "
import json, hashlib
m = json.load(open('$proj7/.ai-runs/tasks/0106-evidence/01-input-manifest.json'))
f = next(x for x in m['files'] if x['relative_path'] == 'app.log')
h = hashlib.sha256(open('$proj7/.ai-runs/tasks/0106-evidence/' + f['snapshot_path'], 'rb').read()).hexdigest()
print('match' if h == f['sha256'] else 'mismatch')
")"
specrelay_test::assert_eq "manifest digest matches the recomputed snapshot digest" "match" "$digest_match"
(cd "$proj7" && specrelay::bundle::verify_snapshot "$proj7/.ai-runs/tasks/0106-evidence")
specrelay_test::assert_true "specrelay::bundle::verify_snapshot succeeds on a valid snapshot" "$?"

# --- (22) modifying the live source after task creation does not affect resume (10.3) ---
live_spec="$proj7/docs/sdd/0106-evidence/spec.md"
printf '# Spec (MUTATED AFTER TASK CREATION)\n' > "$live_spec"
snap_spec_content="$(cat "$proj7/.ai-runs/tasks/0106-evidence/01-input-bundle/local/spec.md")"
specrelay_test::assert_not_contains "task-local snapshot is unaffected by a live-source edit after creation" \
  "$snap_spec_content" "MUTATED AFTER TASK CREATION"

# --- (25)-(26) resolved specification includes functional/technical reqs, with provenance ---
resolved="$(cat "$tdir/02-resolved-specification.md")"
specrelay_test::assert_contains "resolved specification includes Functional Requirements content" "$resolved" "Must work."
specrelay_test::assert_contains "resolved specification includes Technical Requirements content" "$resolved" "Use Postgres."
specrelay_test::assert_contains "resolved specification cites the functional-spec snapshot as its source" "$resolved" "Source: 01-input-bundle/local/spec.md"
specrelay_test::assert_contains "resolved specification cites the technical-spec snapshot as its source" "$resolved" "Source: 01-input-bundle/local/tech-spec.md"

# --- (30) every discovered file receives an analysis status in Input Coverage ---
specrelay_test::assert_contains "resolved specification's Input Coverage table lists the log evidence" "$resolved" "evidence/app.log"
specrelay_test::assert_contains "resolved specification's Input Coverage table lists the structured-data evidence" "$resolved" "evidence/sample.json"

# --- (58)-(59) task show reports bundle provenance concisely ----------------
show_out="$(cd "$proj2" && "$SPECRELAY_BIN" task show 0101-dir)"
specrelay_test::assert_contains "task show reports input kind" "$show_out" "Input kind: directory"
specrelay_test::assert_contains "task show reports bundle file count" "$show_out" "Bundle file count: 4"
specrelay_test::assert_contains "task show reports integrity status" "$show_out" "Integrity status: verified"
line_count="$(printf '%s\n' "$show_out" | wc -l | tr -d '[:space:]')"
specrelay_test::assert_true "default task show output remains a concise, bounded number of lines" "$([ "$line_count" -lt 60 ] && echo 0 || echo 1)"

# --- (60) existing single-file tests remain green (spot-check task.sh helpers) ---
legacy_id="$(specrelay::task::id_from_spec_path "$proj/docs/sdd/0100-file/spec.md")"
specrelay_test::assert_eq "legacy id_from_spec_path still works for a file path" "0100-file" "$legacy_id"

specrelay_test::summary
