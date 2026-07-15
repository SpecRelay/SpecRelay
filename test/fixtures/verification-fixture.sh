#!/usr/bin/env bash
# verification-fixture.sh — deterministic fixture command for verification-
# policy-engine tests (spec 0026, section 44, "Fake verification support").
#
# A plain, dependency-free script (no fake-AI-provider machinery involved —
# that is a completely different kind of "fake" in this codebase, see
# providers/fake.sh) usable directly as a configured check `command:` string.
# Supports exactly the primitives spec section 44 lists: pass, fail, timeout
# (via --sleep past the configured check timeout), emit stdout/stderr,
# sleep, and asserting the cwd/environment the runner actually launched it
# with — so tests can prove (not assume) that the engine applied the
# configured cwd/environment correctly.
#
# Usage:
#   verification-fixture.sh [--exit N] [--sleep SECONDS]
#       [--stdout TEXT] [--stderr TEXT]
#       [--assert-cwd PATH] [--assert-env NAME=VALUE]...
set -uo pipefail

exit_code=0
sleep_seconds=0
stdout_text=""
stderr_text=""
assert_cwd=""
declare -a assert_envs=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --exit) exit_code="$2"; shift 2 ;;
    --sleep) sleep_seconds="$2"; shift 2 ;;
    --stdout) stdout_text="$2"; shift 2 ;;
    --stderr) stderr_text="$2"; shift 2 ;;
    --assert-cwd) assert_cwd="$2"; shift 2 ;;
    --assert-env) assert_envs+=("$2"); shift 2 ;;
    *) echo "verification-fixture.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done

if [ -n "$assert_cwd" ]; then
  actual="$(pwd -P)"
  expected="$(cd "$assert_cwd" 2>/dev/null && pwd -P)"
  if [ "$actual" != "$expected" ]; then
    echo "verification-fixture.sh: cwd assertion failed: expected '$expected' (from $assert_cwd), got '$actual'" >&2
    exit 9
  fi
fi

for kv in ${assert_envs[@]+"${assert_envs[@]}"}; do
  name="${kv%%=*}"
  expected_value="${kv#*=}"
  actual_value="${!name:-}"
  if [ "$actual_value" != "$expected_value" ]; then
    echo "verification-fixture.sh: env assertion failed: $name expected '$expected_value', got '$actual_value'" >&2
    exit 8
  fi
done

[ -n "$stdout_text" ] && echo "$stdout_text"
[ -n "$stderr_text" ] && echo "$stderr_text" >&2

if [ "$sleep_seconds" != "0" ]; then
  sleep "$sleep_seconds"
fi

exit "$exit_code"
