#!/usr/bin/env bash
# output.sh — shared, minimal print helpers for the SpecRelay CLI.
#
# Kept intentionally tiny: a consistent way to print an error to stderr and a
# section heading to stdout, nothing more. No color/TTY detection — incubation
# CLI output must stay simple and script-friendly.

specrelay::out::err() {
  echo "specrelay: $1" >&2
}

specrelay::out::section() {
  echo
  echo "$1"
}
