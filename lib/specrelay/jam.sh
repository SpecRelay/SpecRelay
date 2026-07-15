#!/usr/bin/env bash
# jam.sh — Jam recording capability adapter (spec 0023, sections 18-18.8).
#
# Jam is globally optional (spec section 18): a project with no Jam
# configuration and no task ever mentioning a Jam link is fully usable.
# A discovered Jam reference inside a task's bundle makes Jam REQUIRED for
# that specific task (section 18.7) — retrieval must happen during the
# specification-bundle analysis phase, before Executor invocation, or task
# creation must fail with an actionable reason.
#
# Readiness inspection mirrors context/contextplus.sh's proven pattern
# (`claude mcp list` + project .mcp.json inspection) rather than depending on
# unstable provider-specific MCP tool names (section 18.2).
#
# Env hooks (test-only; normal operation needs none of these):
#   SPECRELAY_JAM_CLAUDE_BIN     claude-compatible binary (default: claude)
#   SPECRELAY_JAM_SERVER_NAME    registered MCP server name (default: jam)
#   SPECRELAY_JAM_FAKE_RETRIEVE  path to a fake retrieval script (test-only
#                                seam; never used by real installations). When
#                                set, specrelay::jam::retrieve calls this
#                                script instead of the real bounded MCP
#                                invocation. Section 27 requires automated
#                                tests never touch a real Jam recording.

specrelay::jam::_claude_bin() {
  printf '%s\n' "${SPECRELAY_JAM_CLAUDE_BIN:-claude}"
}

specrelay::jam::_server_name() {
  printf '%s\n' "${SPECRELAY_JAM_SERVER_NAME:-jam}"
}

# --- reference discovery (spec section 18.1) ---------------------------------

# specrelay::jam::extract_refs <file>
# Prints one deduped Jam URL per line found in the given (text) file.
specrelay::jam::extract_refs() {
  local f="$1"
  grep -Eo 'https?://[A-Za-z0-9._-]*jam\.dev/[^[:space:]"'"'"'<>)]*' "$f" 2>/dev/null \
    | sed -E 's/[.,;:!?]+$//' \
    | LC_ALL=C sort -u
}

# specrelay::jam::canonical_id <url>
# A stable, filesystem-safe id for a Jam URL: the last non-empty path
# segment (query/fragment stripped), sanitized; falls back to a digest of
# the whole URL when no usable segment exists.
specrelay::jam::canonical_id() {
  local url="$1" segment
  segment="$(printf '%s' "$url" | sed -E 's/[?#].*$//; s#/+$##')"
  segment="${segment##*/}"
  segment="$(printf '%s' "$segment" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
  if [ -z "$segment" ]; then
    if command -v shasum >/dev/null 2>&1; then
      segment="$(printf '%s' "$url" | shasum -a 1 | awk '{print $1}')"
    else
      segment="$(printf '%s' "$url" | sha1sum | awk '{print $1}')"
    fi
  fi
  printf '%s\n' "$segment"
}

# specrelay::jam::global_required <root>
# Prints "true"/"false" (default false — spec section 18: Jam is globally
# optional by default).
specrelay::jam::global_required() {
  local root="$1"
  if specrelay::config::exists "$root"; then
    specrelay::config::get "$root" "jam.required" "false"
  else
    printf 'false\n'
  fi
}

# specrelay::jam::configured <root>
# True (exit 0) when a jam: block exists in project config OR a project
# .mcp.json entry for the configured server name exists.
specrelay::jam::configured() {
  local root="$1" server
  server="$(specrelay::jam::_server_name)"
  # An explicit jam.required: true is a deliberate configuration signal.
  # jam.required: false (the shipped default template's own value) is NOT —
  # it must never be conflated with "the operator configured Jam" (that
  # would make Jam look "configured" for every project that just used the
  # default template, which is exactly backwards).
  if [ "$(specrelay::jam::global_required "$root")" = "true" ]; then
    return 0
  fi
  if [ -f "$root/.mcp.json" ]; then
    SERVER="$server" python3 -c '
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)
servers = data.get("mcpServers", {}) if isinstance(data, dict) else {}
sys.exit(0 if os.environ["SERVER"] in servers else 1)
' "$root/.mcp.json" && return 0
  fi
  return 1
}

# --- readiness / doctor reporting (spec section 18.3) ------------------------

# specrelay::jam::_mcp_list_status <claude-bin> <server> <root>
# Same key=value contract as context/contextplus.sh's helper of the same
# shape: registered=yes|no, connected=yes|no|unknown, error=none|list-failed|list-empty.
specrelay::jam::_mcp_list_status() {
  local claude_bin="$1" server="$2" root="$3" out rc
  out="$(cd "$root" && "$claude_bin" mcp list 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'registered=no\nconnected=unknown\nerror=list-failed\n'
    return 0
  fi
  if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
    printf 'registered=no\nconnected=unknown\nerror=list-empty\n'
    return 0
  fi
  printf '%s\n' "$out" | SERVER="$server" python3 -c '
import os, re, sys

server = os.environ["SERVER"]
found = False
connected = "unknown"
for raw_line in sys.stdin:
    line = raw_line.strip()
    if not line or ":" not in line:
        continue
    name, rest = line.split(":", 1)
    if name.strip() != server:
        continue
    found = True
    negative_symbols = ("✗", "✘")
    positive_symbols = ("✓", "✔")
    if (
        re.search(r"(?i)(disconnected|failed|error|needs authentication|unauthenticated)", rest)
        or any(sym in rest for sym in negative_symbols)
    ):
        connected = "no"
    elif re.search(r"(?i)\bconnected\b", rest) or any(sym in rest for sym in positive_symbols):
        connected = "yes"
    break

print("registered=yes" if found else "registered=no")
print("connected=" + (connected if found else "unknown"))
print("error=none")
'
}

# specrelay::jam::_project_config_status <root> <server>
specrelay::jam::_project_config_status() {
  local root="$1" server="$2" path
  path="$root/.mcp.json"
  [ -f "$path" ] || { printf 'missing\n'; return 0; }
  SERVER="$server" python3 - "$path" <<'PY'
import json, os, sys

path = sys.argv[1]
server = os.environ["SERVER"]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print("invalid")
    sys.exit(0)
if not isinstance(data, dict) or not isinstance(data.get("mcpServers"), dict):
    print("invalid")
    sys.exit(0)
servers = data["mcpServers"]
if server not in servers:
    print("server-missing")
    sys.exit(0)
entry = servers[server]
if not isinstance(entry, dict) or not entry:
    print("invalid")
    sys.exit(0)
print("valid")
PY
}

# specrelay::jam::readiness <root>
# Prints key=value lines: status, configured, registered, connected,
# authenticated, tools_available, project_config, ready, server, bin, reason.
# ALWAYS exits 0 (a report, not a gate). "authenticated" and "tools_available"
# are derived from "connected" — `claude mcp list` gives no finer-grained
# per-tool signal, so this module reports that derivation honestly in
# `reason` rather than inventing an independent probe (spec section 18.3:
# "doctor output must include actionable failure detail").
specrelay::jam::readiness() {
  local root="$1" claude_bin server configured_flag="no"

  claude_bin="$(specrelay::jam::_claude_bin)"
  server="$(specrelay::jam::_server_name)"
  specrelay::jam::configured "$root" && configured_flag="yes"

  if [ "$configured_flag" = "no" ]; then
    printf 'status=not-configured\n'
    printf 'configured=no\nregistered=no\nconnected=no\nauthenticated=no\ntools_available=no\nready=no\n'
    printf 'server=%s\nbin=%s\n' "$server" "$claude_bin"
    printf 'reason=No jam configuration or .mcp.json entry was found for this project; Jam is not required unless a task references it.\n'
    return 0
  fi

  if ! command -v "$claude_bin" >/dev/null 2>&1; then
    printf 'status=configured\n'
    printf 'configured=yes\nregistered=no\nconnected=no\nauthenticated=no\ntools_available=no\nready=no\n'
    printf 'server=%s\nbin=%s\n' "$server" "$claude_bin"
    printf "reason=Claude-compatible executable '%s' was not found on PATH.\n" "$claude_bin"
    return 0
  fi

  local mcp_out reg conn err
  mcp_out="$(specrelay::jam::_mcp_list_status "$claude_bin" "$server" "$root")"
  reg="$(printf '%s\n' "$mcp_out" | sed -n 's/^registered=//p')"
  conn="$(printf '%s\n' "$mcp_out" | sed -n 's/^connected=//p')"
  err="$(printf '%s\n' "$mcp_out" | sed -n 's/^error=//p')"

  if [ "$reg" != "yes" ]; then
    printf 'status=configured\n'
    printf 'configured=yes\nregistered=no\nconnected=no\nauthenticated=no\ntools_available=no\nready=no\n'
    printf 'server=%s\nbin=%s\n' "$server" "$claude_bin"
    case "$err" in
      list-failed) printf "reason='%s mcp list' failed; registration cannot be determined.\n" "$claude_bin" ;;
      list-empty) printf "reason='%s mcp list' produced no output; registration cannot be determined.\n" "$claude_bin" ;;
      *) printf "reason=Jam MCP server '%s' is not registered.\n" "$server" ;;
    esac
    return 0
  fi

  if [ "$conn" != "yes" ]; then
    printf 'status=registered\n'
    printf 'configured=yes\nregistered=yes\nconnected=no\nauthenticated=no\ntools_available=no\nready=no\n'
    printf 'server=%s\nbin=%s\n' "$server" "$claude_bin"
    printf "reason=Jam MCP server '%s' is registered but not reported connected.\n" "$server"
    return 0
  fi

  local pc
  pc="$(specrelay::jam::_project_config_status "$root" "$server")"
  if [ "$pc" != "valid" ]; then
    printf 'status=config-incomplete\n'
    printf 'configured=yes\nregistered=yes\nconnected=yes\nauthenticated=unknown\ntools_available=unknown\nready=no\n'
    printf 'server=%s\nbin=%s\n' "$server" "$claude_bin"
    printf 'reason=Registered and connected, but no valid project .mcp.json entry (%s) exists for a scoped retrieval config.\n' "$pc"
    return 0
  fi

  printf 'status=ready\n'
  printf 'configured=yes\nregistered=yes\nconnected=yes\nauthenticated=yes\ntools_available=yes\nready=yes\n'
  printf 'server=%s\nbin=%s\n' "$server" "$claude_bin"
  printf 'reason=Registered, connected (treated as authenticated with tools available — claude mcp list reports no finer-grained signal), and a valid project .mcp.json entry are all present.\n'
}

# specrelay::jam::doctor_report <root>
# Human-readable Jam readiness block for `specrelay doctor` (spec section
# 18.3), reported SEPARATELY from repository context capabilities. Never
# fails overall doctor unless jam.required is explicitly true globally and
# Jam is not ready.
specrelay::jam::doctor_report() {
  local root="$1" out status reason global_required
  out="$(specrelay::jam::readiness "$root")"
  status="$(printf '%s\n' "$out" | sed -n 's/^status=//p')"
  reason="$(printf '%s\n' "$out" | sed -n 's/^reason=//p')"
  global_required="$(specrelay::jam::global_required "$root")"

  echo "Jam capability:"
  echo "  Status: $status"
  echo "  Configured: $(printf '%s\n' "$out" | sed -n 's/^configured=//p')"
  echo "  Registered: $(printf '%s\n' "$out" | sed -n 's/^registered=//p')"
  echo "  Connected:  $(printf '%s\n' "$out" | sed -n 's/^connected=//p')"
  echo "  Authenticated: $(printf '%s\n' "$out" | sed -n 's/^authenticated=//p')"
  echo "  Required tools available: $(printf '%s\n' "$out" | sed -n 's/^tools_available=//p')"
  echo "  Globally required: $global_required"
  echo "  Reason: ${reason:-no additional detail}"
  if [ "$global_required" = "true" ] && [ "$status" != "ready" ]; then
    echo "  Overall doctor readiness: FAILED (jam.required is true and Jam is not ready)"
    return 1
  fi
  echo "  Overall doctor readiness: not affected (Jam is globally optional unless a task references it)"
  return 0
}

# --- redaction (spec section 18.8) -------------------------------------------

# specrelay::jam::redact <input-json-or-text-file> <output-file> <report-file> <artifact-name>
# Redacts recognized secrets before durable storage. Appends one JSON record
# per (artifact, category) to <report-file> (a JSONL accumulator consumed by
# specrelay::jam::_finalize_redaction_report). Never preserves the removed
# value.
specrelay::jam::redact() {
  local in_file="$1" out_file="$2" report_jsonl="$3" artifact="$4"
  ARTIFACT="$artifact" REPORT="$report_jsonl" python3 -c '
import json, os, re, sys

artifact = os.environ["ARTIFACT"]
report_path = os.environ["REPORT"]

with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fh:
    text = fh.read()

patterns = [
    ("authorization-header", re.compile(r"(?i)(\"?authorization\"?\s*[:=]\s*\"?)(bearer\s+[^\"\r\n,}]+|[^\"\r\n,}]+)")),
    ("cookie", re.compile(r"(?i)(\"?cookie\"?\s*[:=]\s*\"?)([^\"\r\n,}]+)")),
    ("session-identifier", re.compile(r"(?i)\b(session[_-]?id\"?\s*[:=]\s*\"?)([A-Za-z0-9._-]{8,})")),
    ("access-token", re.compile(r"(?i)\b(access[_-]?token\"?\s*[:=]\s*\"?)([A-Za-z0-9._-]{8,})")),
    ("refresh-token", re.compile(r"(?i)\b(refresh[_-]?token\"?\s*[:=]\s*\"?)([A-Za-z0-9._-]{8,})")),
    ("api-key", re.compile(r"(?i)\b(api[_-]?key\"?\s*[:=]\s*\"?)([A-Za-z0-9._-]{8,})")),
    ("bearer-token", re.compile(r"(?i)\bbearer\s+([A-Za-z0-9._-]{8,})")),
]

counts = {}

def make_sub(category, keep_prefix):
    def _sub(m):
        counts[category] = counts.get(category, 0) + 1
        if keep_prefix:
            return m.group(1) + "[REDACTED:" + category + "]"
        return "[REDACTED:" + category + "]"
    return _sub

for category, pattern in patterns:
    keep_prefix = pattern.groups >= 2
    text = pattern.sub(make_sub(category, keep_prefix), text)

with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.write(text)

with open(report_path, "a", encoding="utf-8") as fh:
    for category, count in counts.items():
        fh.write(json.dumps({
            "artifact": artifact,
            "redaction_category": category,
            "count": count,
            "policy_applied": "spec-0023-section-18.8-default-patterns",
        }) + "\n")
' "$in_file" "$out_file"
}

# specrelay::jam::_finalize_redaction_report <report-jsonl> <out-json>
specrelay::jam::_finalize_redaction_report() {
  local jsonl="$1" out="$2"
  if [ ! -f "$jsonl" ]; then
    printf '{"entries": []}\n' > "$out"
    return 0
  fi
  python3 -c '
import json, sys
entries = []
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if line:
            entries.append(json.loads(line))
print(json.dumps({"entries": entries}, indent=2))
' "$jsonl" > "$out"
}

# --- retrieval (spec section 18.4-18.5) --------------------------------------

# specrelay::jam::_snapshot_dir <task-dir> <canonical-id>
specrelay::jam::_snapshot_dir() {
  printf '%s/01-input-bundle/external/jam/%s\n' "$1" "$2"
}

# specrelay::jam::retrieve <root> <task-dir> <canonical-id> <url>
# Retrieves, normalizes, redacts, and snapshots all available Jam evidence
# for one canonical reference. Real retrieval uses a bounded `claude --print`
# invocation with ONLY the Jam MCP server's read tools allowed (mirroring
# context/contextplus.sh's `_run`); SPECRELAY_JAM_FAKE_RETRIEVE lets tests
# substitute a fixture script so no automated test ever touches a real Jam
# recording (spec section 27). Returns 0 and marks retrieval_status=retrieved
# on success (even if some evidence classes are missing — those are recorded
# honestly), non-zero on failure (unreachable, unauthenticated, etc).
specrelay::jam::retrieve() {
  local root="$1" task_dir="$2" canonical_id="$3" url="$4"
  local snap_dir raw_dir
  snap_dir="$(specrelay::jam::_snapshot_dir "$task_dir" "$canonical_id")"
  raw_dir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-jam-raw.XXXXXX")"
  mkdir -p "$snap_dir"

  local retrieved_at status="failed" reason=""
  retrieved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"

  # Retrieval adapter selection (spec section 18.2, "stable internal adapter
  # contract rather than unstable provider-specific MCP tool names"):
  #   1. SPECRELAY_JAM_FAKE_RETRIEVE — test-only seam, always wins when set,
  #      so automated tests never depend on real project configuration.
  #   2. jam.retrieval_command (project config) — the real, operator-provided
  #      adapter: any executable invoked as `<cmd> <canonical-id> <url>
  #      <out-dir>`, expected to write "<class>.raw" files into <out-dir> for
  #      whatever evidence classes it can retrieve (e.g. a wrapper around a
  #      bounded `claude --print --strict-mcp-config` MCP call, matching
  #      context/contextplus.sh's `_run`, or a direct Jam API client).
  #   3. Neither configured — retrieval fails honestly; readiness=ready alone
  #      is never treated as sufficient to fabricate a successful retrieval.
  local retrieval_cmd=""
  if [ -z "${SPECRELAY_JAM_FAKE_RETRIEVE:-}" ]; then
    retrieval_cmd="$(specrelay::config::exists "$root" && specrelay::config::get "$root" "jam.retrieval_command" "" || true)"
  fi

  if [ -n "${SPECRELAY_JAM_FAKE_RETRIEVE:-}" ]; then
    if [ -x "$SPECRELAY_JAM_FAKE_RETRIEVE" ] && "$SPECRELAY_JAM_FAKE_RETRIEVE" "$canonical_id" "$url" "$raw_dir"; then
      status="retrieved"
    else
      status="failed"
      reason="fake retrieval adapter failed or is not executable"
    fi
  elif [ -n "$retrieval_cmd" ]; then
    if $retrieval_cmd "$canonical_id" "$url" "$raw_dir"; then
      status="retrieved"
    else
      status="failed"
      reason="configured jam.retrieval_command exited non-zero"
    fi
  else
    status="failed"
    reason="jam capability has no configured retrieval adapter (set jam.retrieval_command in .specrelay/config.yml); see 'specrelay doctor' for readiness detail"
  fi

  local -a evidence_classes=(metadata transcript user-events console-logs console-errors network-requests network-errors environment)
  local -a available=() missing=()
  local report_jsonl="$raw_dir/.redaction-report.jsonl"

  local class src
  for class in "${evidence_classes[@]}"; do
    src="$raw_dir/${class}.raw"
    if [ "$status" = "retrieved" ] && [ -f "$src" ]; then
      available+=("$class")
      case "$class" in
        transcript)
          specrelay::jam::redact "$src" "$snap_dir/transcript.md" "$report_jsonl" "transcript.md" ;;
        metadata) specrelay::jam::redact "$src" "$snap_dir/metadata.json" "$report_jsonl" "metadata.json" ;;
        user-events) specrelay::jam::redact "$src" "$snap_dir/user-events.json" "$report_jsonl" "user-events.json" ;;
        console-logs) specrelay::jam::redact "$src" "$snap_dir/console-logs.json" "$report_jsonl" "console-logs.json" ;;
        console-errors) specrelay::jam::redact "$src" "$snap_dir/console-errors.json" "$report_jsonl" "console-errors.json" ;;
        network-requests) specrelay::jam::redact "$src" "$snap_dir/network-requests.json" "$report_jsonl" "network-requests.json" ;;
        network-errors) specrelay::jam::redact "$src" "$snap_dir/network-errors.json" "$report_jsonl" "network-errors.json" ;;
        environment) specrelay::jam::redact "$src" "$snap_dir/environment.json" "$report_jsonl" "environment.json" ;;
      esac
    else
      missing+=("$class")
    fi
  done

  specrelay::jam::_finalize_redaction_report "$report_jsonl" "$snap_dir/redaction-report.json"

  URL="$url" CID="$canonical_id" STATUS="$status" REASON="$reason" RETRIEVED_AT="$retrieved_at" \
    python3 -c '
import json, os
print(json.dumps({
    "canonical_id": os.environ["CID"],
    "original_url": os.environ["URL"],
    "retrieval_status": os.environ["STATUS"],
    "retrieval_timestamp": os.environ["RETRIEVED_AT"],
    "reason": os.environ["REASON"] or None,
}, indent=2))
' > "$snap_dir/reference.json"

  AVAIL_JSON="$(printf '%s\n' "${available[@]:-}" | sed '/^$/d' | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  MISSING_JSON="$(printf '%s\n' "${missing[@]:-}" | sed '/^$/d' | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  DIGEST=""
  if command -v shasum >/dev/null 2>&1; then
    DIGEST="$(find "$snap_dir" -type f \( -name '*.json' -o -name '*.md' \) 2>/dev/null | LC_ALL=C sort | xargs -I{} shasum -a 256 {} 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  fi
  AVAIL="$AVAIL_JSON" MISS="$MISSING_JSON" DIGEST="$DIGEST" RETRIEVED_AT="$retrieved_at" STATUS="$status" \
    python3 -c '
import json, os
print(json.dumps({
    "retrieved_at": os.environ["RETRIEVED_AT"],
    "status": os.environ["STATUS"],
    "available_evidence_types": json.loads(os.environ["AVAIL"] or "[]"),
    "missing_evidence_types": json.loads(os.environ["MISS"] or "[]"),
    "content_digest": os.environ["DIGEST"] or None,
}, indent=2))
' > "$snap_dir/retrieval-evidence.json"

  rm -rf "$raw_dir"

  if [ "$status" = "retrieved" ]; then
    return 0
  fi
  specrelay::out::err "jam: retrieval failed for $canonical_id ($url): ${reason:-unknown reason}"
  return 1
}

# --- manifest integration (spec section 18.1, 11) ----------------------------

# specrelay::jam::record_references <root> <task-dir> <manifest-path> <pairs-file>
# <pairs-file> has one "relpath<TAB>url" line per local reference occurrence
# (possibly duplicated across files). Dedupes by canonical id, retains
# per-reference provenance, retrieves+snapshots each canonical reference, and
# rewrites the manifest's external_evidence array. Blocks (returns non-zero)
# when a required reference cannot be retrieved (spec section 18.7).
specrelay::jam::record_references() {
  local root="$1" task_dir="$2" manifest="$3" pairs_file="$4"

  # No associative arrays here deliberately: this codebase targets macOS's
  # shipped bash 3.2 (no `declare -A`), same as every other lib/specrelay/*.sh
  # file. Dedup by ordinary unique-URL iteration instead — one canonical_id
  # per unique URL, referencing files grouped per URL via awk.
  local -a uniq_urls=()
  local u
  while IFS= read -r u; do
    [ -n "$u" ] && uniq_urls+=("$u")
  done < <(cut -f2 "$pairs_file" | LC_ALL=C sort -u)

  local entries_file="$task_dir/.jam-entries.jsonl"
  : > "$entries_file"
  local cid blocked=0 files_csv status snap_dir
  for u in "${uniq_urls[@]:-}"; do
    [ -n "$u" ] || continue
    cid="$(specrelay::jam::canonical_id "$u")"
    files_csv="$(awk -F'\t' -v want="$u" '$2 == want { print $1 }' "$pairs_file" | LC_ALL=C sort -u | paste -sd, -)"

    if ! specrelay::jam::retrieve "$root" "$task_dir" "$cid" "$u"; then
      blocked=1
    fi
    snap_dir="$(specrelay::jam::_snapshot_dir "$task_dir" "$cid")"
    status="failed"
    [ -f "$snap_dir/reference.json" ] && status="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        print(json.load(fh).get("retrieval_status", "failed"))
except Exception:
    print("failed")
' "$snap_dir/reference.json" 2>/dev/null)"
    CID="$cid" URL="$u" FILES="$files_csv" STATUS="$status" SNAP="01-input-bundle/external/jam/$cid" \
      python3 -c '
import json, os
print(json.dumps({
    "provider": "jam",
    "canonical_id": os.environ["CID"],
    "canonical_reference": os.environ["URL"],
    "referencing_local_files": os.environ["FILES"].split(","),
    "retrieval_status": os.environ["STATUS"],
    "adapter": "jam",
    "snapshot_path": os.environ["SNAP"],
}))
' >> "$entries_file"
  done

  MANIFEST="$manifest" ENTRIES="$entries_file" python3 -c '
import json, os

manifest_path = os.environ["MANIFEST"]
with open(manifest_path, encoding="utf-8") as fh:
    manifest = json.load(fh)

entries = []
with open(os.environ["ENTRIES"], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if line:
            entries.append(json.loads(line))

manifest["external_evidence"] = entries
with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2)
'
  rm -f "$entries_file"

  if [ "$blocked" -eq 1 ]; then
    specrelay::out::err "jam: one or more required Jam references could not be retrieved; task creation is blocked (spec 0023, section 18.7)"
    return 1
  fi
  return 0
}
