#!/usr/bin/env bash
# project.sh — project-root discovery for the SpecRelay CLI.
#
# SpecRelay is incubated inside a real repository (this one), and must be
# usable from any subdirectory of it, not only from the repository root.
#
# Discovery order (first match wins):
#   1. Git repository root (`git rev-parse --show-toplevel`), when the
#      current directory is inside a git working tree. This is the preferred,
#      evidence-based signal (see docs/current-workflow-contract.md, "Task
#      identity").
#   2. Otherwise, walk upward from the current directory looking for a
#      `.specrelay/` directory (SpecRelay's own project marker), so a
#      non-git project that has been explicitly configured for SpecRelay is
#      still discoverable.
#
# Prints the absolute project root on success; prints nothing and returns 1 on
# failure (no project root could be discovered).

specrelay::project::root() {
  local git_root
  if git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    (cd "$git_root" && pwd -P)
    return 0
  fi

  local dir="$PWD"
  while :; do
    if [ -d "$dir/.specrelay" ]; then
      (cd "$dir" && pwd -P)
      return 0
    fi
    local parent
    parent="$(dirname "$dir")"
    if [ "$parent" = "$dir" ]; then
      break
    fi
    dir="$parent"
  done

  return 1
}
