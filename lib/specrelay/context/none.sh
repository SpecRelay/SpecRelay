#!/usr/bin/env bash
# context/none.sh — the "no context capability required" adapter. A project
# with no context-retrieval requirement (or a test run that deliberately
# does not want to spend on a real Context Plus call) configures
# `context.adapter: none` and gets this no-op, always-succeeds adapter.

specrelay::context::none::preflight() {
  local role="$1"
  echo "[$role] context: adapter 'none' configured; no preflight required"
  return 0
}
