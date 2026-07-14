#!/usr/bin/env bash
# decision_marker_test.sh — the mandatory DECISION marker contract (spec
# 0019, "C. Mandatory Decision Marker" / marker.sh).
#   tools/specrelay/test/decision_marker_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/marker.sh
. "$SPECRELAY_ROOT/lib/specrelay/marker.sh"

# =============================================================================
# Valid markers parse
# =============================================================================
specrelay_test::assert_eq "valid ACCEPT marker parses" \
  "ACCEPT" "$(specrelay::marker::parse "some review notes
DECISION: ACCEPT")"
specrelay_test::assert_true "valid ACCEPT marker: exit 0" \
  "$(specrelay::marker::parse "notes
DECISION: ACCEPT" >/dev/null; echo $?)"

specrelay_test::assert_eq "valid REQUEST_CHANGES marker parses" \
  "REQUEST_CHANGES" "$(specrelay::marker::parse "some review notes
DECISION: REQUEST_CHANGES")"

# =============================================================================
# Lowercase marker is rejected
# =============================================================================
specrelay_test::assert_eq "lowercase marker is rejected" \
  "1" "$(specrelay::marker::parse "decision: accept" >/dev/null 2>&1; echo $?)"
specrelay_test::assert_eq "lowercase marker: no decision printed" \
  "" "$(specrelay::marker::parse "decision: accept" 2>/dev/null)"

# =============================================================================
# Marker not on the final line is rejected
# =============================================================================
specrelay_test::assert_eq "marker not on the final line is rejected" \
  "1" "$(specrelay::marker::parse "DECISION: ACCEPT
one more trailing line of prose" >/dev/null 2>&1; echo $?)"

# =============================================================================
# Duplicate markers are rejected
# =============================================================================
specrelay_test::assert_eq "duplicate ACCEPT markers are rejected" \
  "1" "$(specrelay::marker::parse "DECISION: ACCEPT
more notes
DECISION: ACCEPT" >/dev/null 2>&1; echo $?)"

# =============================================================================
# Conflicting markers are rejected
# =============================================================================
specrelay_test::assert_eq "conflicting ACCEPT + REQUEST_CHANGES markers are rejected" \
  "1" "$(specrelay::marker::parse "DECISION: ACCEPT
DECISION: REQUEST_CHANGES" >/dev/null 2>&1; echo $?)"

# =============================================================================
# Prose without a marker is rejected (never inferred)
# =============================================================================
specrelay_test::assert_eq "prose without a marker is rejected" \
  "1" "$(specrelay::marker::parse "I accept this implementation." >/dev/null 2>&1; echo $?)"
specrelay_test::assert_eq "vague sentiment prose is rejected" \
  "1" "$(specrelay::marker::parse "looks good overall, no major concerns" >/dev/null 2>&1; echo $?)"

# =============================================================================
# Trailing whitespace/blank lines after the marker are tolerated (it is still
# the final NON-EMPTY line)
# =============================================================================
specrelay_test::assert_eq "trailing blank lines after the marker are tolerated" \
  "ACCEPT" "$(specrelay::marker::parse "DECISION: ACCEPT


")"

# =============================================================================
# Marker preserved through semantic event rendering (providers/claude.sh /
# py/render_agent_events.py never strip or wrap the final assistant text —
# the extracted final text is written VERBATIM, spec 0019 "Decision Marker
# Enforcement in Provider Adapter").
# =============================================================================
render_py="$SPECRELAY_ROOT/lib/specrelay/py/render_agent_events.py"
if command -v python3 >/dev/null 2>&1 && [ -f "$render_py" ]; then
  events_file="$(mktemp "${TMPDIR:-/tmp}/specrelay-events.XXXXXX")"
  final_file="$(mktemp "${TMPDIR:-/tmp}/specrelay-final.XXXXXX")"
  stderr_file="$(mktemp "${TMPDIR:-/tmp}/specrelay-stderr.XXXXXX")"
  cat > "$events_file" <<'JSONL'
{"type":"system","subtype":"init","model":"test-model"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Reviewing the diff now."}]}}
{"type":"result","subtype":"success","result":"Findings: none blocking.\nDECISION: ACCEPT"}
JSONL
  python3 "$render_py" --role "reviewer:test" --provider claude --repo-root "$SPECRELAY_ROOT" \
    --raw-events /dev/null --final-stdout "$final_file" < "$events_file" > "$stderr_file" 2>&1
  final_content="$(cat "$final_file" 2>/dev/null)"
  specrelay_test::assert_contains "semantic rendering preserves the DECISION marker verbatim" \
    "$final_content" "DECISION: ACCEPT"
  specrelay_test::assert_eq "the extracted final text's marker still parses" \
    "ACCEPT" "$(specrelay::marker::parse "$final_content")"
  rm -f "$events_file" "$final_file" "$stderr_file"
fi

# =============================================================================
# Decision Consistency (spec 0019, "Decision Consistency") — marker agrees
# with artifacts; a conflicting artifact/marker combination is rejected.
# =============================================================================
consistency_dir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-consistency.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$consistency_dir")

printf 'review\n' > "$consistency_dir/09-consultant-review.md"
printf 'summary\n' > "$consistency_dir/10-business-summary.md"
specrelay_test::assert_true "ACCEPT agrees with complete 09+10 artifacts" \
  "$(specrelay::marker::artifacts_consistent "$consistency_dir" ACCEPT >/dev/null 2>&1; echo $?)"

rm -f "$consistency_dir/10-business-summary.md"
specrelay_test::assert_eq "ACCEPT is rejected when 10-business-summary.md is missing (conflicting state)" \
  "1" "$(specrelay::marker::artifacts_consistent "$consistency_dir" ACCEPT >/dev/null 2>&1; echo $?)"

printf 'next steps\n' > "$consistency_dir/11-next-executor-prompt.md"
specrelay_test::assert_true "REQUEST_CHANGES agrees with complete 09+11 artifacts" \
  "$(specrelay::marker::artifacts_consistent "$consistency_dir" REQUEST_CHANGES >/dev/null 2>&1; echo $?)"

rm -f "$consistency_dir/11-next-executor-prompt.md"
specrelay_test::assert_eq "REQUEST_CHANGES is rejected when 11-next-executor-prompt.md is missing" \
  "1" "$(specrelay::marker::artifacts_consistent "$consistency_dir" REQUEST_CHANGES >/dev/null 2>&1; echo $?)"

: > "$consistency_dir/09-consultant-review.md"
printf 'summary\n' > "$consistency_dir/10-business-summary.md"
specrelay_test::assert_eq "an empty 09-consultant-review.md is rejected regardless of decision" \
  "1" "$(specrelay::marker::artifacts_consistent "$consistency_dir" ACCEPT >/dev/null 2>&1; echo $?)"

specrelay_test::summary
exit $?
