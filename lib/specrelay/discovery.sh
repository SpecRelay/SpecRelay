#!/usr/bin/env bash
# discovery.sh — read-only filesystem discovery of the existing (legacy)
# workflow implementation, for `specrelay workflow inspect`.
#
# Everything here is READ-ONLY: it only stats/lists paths under the project
# root. It never creates, modifies, or deletes anything, and it never touches
# .ai-runs/ task state.
#
# Nothing here hardcodes ".ai" as the ONLY possible legacy workflow location:
# callers pass the project root, and the well-known relative path checked is
# documented as such (this repository's actual current workflow root, per
# tools/specrelay/docs/current-workflow-contract.md). A future repository
# incubating SpecRelay with a differently-named legacy workflow directory
# would configure it in .specrelay/config.yml instead (see
# knowledge-boundaries.md, C3).

# specrelay::discovery::ai_root <project-root>
# Prints the legacy workflow root's absolute path if present, else nothing.
# Always returns 0: absence is a normal result, never an error (callers under
# `set -e` must be able to write `x="$(specrelay::discovery::ai_root ...)"`
# without a "not found" result aborting the script).
specrelay::discovery::ai_root() {
  local root="$1"
  if [ -d "$root/.ai" ]; then
    printf '%s/.ai\n' "$root"
  fi
  return 0
}

# specrelay::discovery::public_entrypoints <project-root>
# Lists the public (root-level, non-internal) workflow scripts, one per line,
# sorted. Empty output if no legacy workflow root is present.
specrelay::discovery::public_entrypoints() {
  local root="$1" ai_root
  ai_root="$(specrelay::discovery::ai_root "$root")" || return 0
  [ -n "$ai_root" ] || return 0
  [ -d "$ai_root/scripts" ] || return 0
  find "$ai_root/scripts" -maxdepth 1 -type f -name '*.sh' | sort
}

# specrelay::discovery::internal_helper_root <project-root>
# Prints the internal helper directory's absolute path if present.
specrelay::discovery::internal_helper_root() {
  local root="$1" ai_root
  ai_root="$(specrelay::discovery::ai_root "$root")"
  if [ -n "$ai_root" ] && [ -d "$ai_root/scripts/internal" ]; then
    printf '%s/scripts/internal\n' "$ai_root"
  fi
  return 0
}

# specrelay::discovery::protocol_file <project-root>
# Prints the workflow protocol file's absolute path if present.
specrelay::discovery::protocol_file() {
  local root="$1" ai_root
  ai_root="$(specrelay::discovery::ai_root "$root")"
  if [ -n "$ai_root" ] && [ -f "$ai_root/protocol.md" ]; then
    printf '%s/protocol.md\n' "$ai_root"
  fi
  return 0
}

# specrelay::discovery::reviewer_file <project-root>
# Prints the reviewer contract file's absolute path if present.
specrelay::discovery::reviewer_file() {
  local root="$1" ai_root
  ai_root="$(specrelay::discovery::ai_root "$root")"
  if [ -n "$ai_root" ] && [ -f "$ai_root/reviewer.md" ]; then
    printf '%s/reviewer.md\n' "$ai_root"
  fi
  return 0
}

# specrelay::discovery::task_run_root <project-root> <configured-runs-root>
# Prints the absolute task-run root's path, whether or not it currently
# exists on disk (existence is reported separately by the caller).
specrelay::discovery::task_run_root() {
  local root="$1" configured="$2"
  printf '%s/%s\n' "$root" "${configured:-.ai-runs/tasks}"
}

# specrelay::discovery::provider_integrations <project-root>
# Lists detected provider-integration locations, one per line: the Claude
# Code MCP config and any Claude sub-agent definitions. Empty output if none
# are present.
specrelay::discovery::provider_integrations() {
  local root="$1"
  [ -f "$root/.mcp.json" ] && printf '%s/.mcp.json (MCP server registration)\n' "$root"
  if [ -d "$root/.claude/agents" ]; then
    local f
    for f in "$root"/.claude/agents/*.md; do
      [ -e "$f" ] || continue
      printf '%s (Claude sub-agent definition)\n' "$f"
    done
  fi
  return 0
}
