#!/usr/bin/env bash
# discovery_test.sh — tests for `specrelay workflow inspect` and the
# read-only/no-mutation guarantee of the whole CLI. Uses only temporary
# fixture directories — never the real repository's .ai/ or .ai-runs/.
#   tools/specrelay/test/discovery_test.sh

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# --- workflow inspect: no legacy workflow present -> honest, non-failing ----
proj_empty="$(specrelay_test::mktemp_project)"
out_empty="$(cd "$proj_empty" && "$SPECRELAY_BIN" workflow inspect)"
rc=$?
specrelay_test::assert_eq "workflow inspect exits 0 with no legacy workflow present" "0" "$rc"
specrelay_test::assert_contains "workflow inspect reports no workflow found" \
  "$out_empty" "No legacy/current AI workflow detected"

# --- workflow inspect: fixture with a fake legacy workflow ------------------
proj="$(specrelay_test::mktemp_project)"
mkdir -p "$proj/.ai/scripts/internal"
mkdir -p "$proj/.claude/agents"
mkdir -p "$proj/.ai-runs/tasks"
: > "$proj/.ai/scripts/example-public.sh"
chmod +x "$proj/.ai/scripts/example-public.sh"
: > "$proj/.ai/protocol.md"
: > "$proj/.ai/reviewer.md"
: > "$proj/.mcp.json"
: > "$proj/.claude/agents/example-reviewer.md"

out="$(cd "$proj" && "$SPECRELAY_BIN" workflow inspect)"
rc=$?
specrelay_test::assert_eq "workflow inspect exits 0 with a fixture workflow present" "0" "$rc"
specrelay_test::assert_contains "workflow inspect reports the legacy workflow root" \
  "$out" "$proj/.ai"
specrelay_test::assert_contains "workflow inspect reports the public entry point" \
  "$out" "$proj/.ai/scripts/example-public.sh"
specrelay_test::assert_contains "workflow inspect reports the internal helper root" \
  "$out" "$proj/.ai/scripts/internal"
specrelay_test::assert_contains "workflow inspect reports the protocol file" \
  "$out" "$proj/.ai/protocol.md"
specrelay_test::assert_contains "workflow inspect reports the reviewer contract file" \
  "$out" "$proj/.ai/reviewer.md"
specrelay_test::assert_contains "workflow inspect reports the task run root as existing" \
  "$out" "$proj/.ai-runs/tasks (exists)"
specrelay_test::assert_contains "workflow inspect reports the MCP registration" \
  "$out" ".mcp.json"
specrelay_test::assert_contains "workflow inspect reports the Claude sub-agent definition" \
  "$out" "example-reviewer.md"

# --- 11. no CLI command mutates .ai/, .ai-runs/, or any task state ----------
# Snapshot every fixture file's relative path + mtime + content hash, run a
# representative set of CLI commands, then snapshot again and diff.
snapshot() {
  (cd "$proj" && find .ai .ai-runs .claude .mcp.json -type f -exec sh -c '
      for f; do
        printf "%s %s %s\n" "$f" "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")" "$(cksum < "$f")"
      done
    ' sh {} + | sort)
}

before="$(snapshot)"
(
  cd "$proj"
  "$SPECRELAY_BIN" version >/dev/null
  "$SPECRELAY_BIN" help >/dev/null
  "$SPECRELAY_BIN" project root >/dev/null
  "$SPECRELAY_BIN" project inspect >/dev/null
  "$SPECRELAY_BIN" workflow inspect >/dev/null
  "$SPECRELAY_BIN" run >/dev/null 2>&1 || true
)
after="$(snapshot)"

specrelay_test::assert_eq "no CLI command mutates .ai/, .ai-runs/, .claude/, or .mcp.json" \
  "$before" "$after"

specrelay_test::summary
exit $?
