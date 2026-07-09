#!/usr/bin/env bash
# config.sh — minimal, safe loader for .specrelay/config.yml.
#
# Parser choice and rationale (Phase G of SDD 0083): this repository's native
# runtime is Ruby (Gemfile, .ruby-version), and Ruby's standard library already
# ships Psych (YAML) — requiring "yaml" adds no new gem, no new language
# runtime, and no large dependency stack. `YAML.safe_load` is used explicitly
# (never `YAML.load`/`YAML.unsafe_load`), which restricts parsing to plain
# scalars, arrays, and hashes and never instantiates arbitrary Ruby objects —
# satisfying "does not use unsafe YAML object deserialization" directly rather
# than reimplementing a YAML subset parser by hand.
#
# Every accessor below shells out to a small, self-contained `ruby -e` snippet
# per call. The config path and dotted field path are passed as argv (never
# interpolated into the Ruby source), so untrusted values cannot inject code.

# specrelay::config::path <project-root>
# Prints the expected config file path (whether or not it exists).
specrelay::config::path() {
  local root="$1"
  printf '%s/.specrelay/config.yml\n' "$root"
}

# specrelay::config::exists <project-root>
# True (exit 0) if the config file exists and is a regular file.
specrelay::config::exists() {
  local root="$1"
  [ -f "$(specrelay::config::path "$root")" ]
}

# specrelay::config::validate <project-root>
# Prints nothing on success (exit 0). On a missing or malformed config, prints
# a clear error to stderr and returns non-zero. "Malformed" covers both
# YAML syntax errors and a top level that is not a mapping (object).
specrelay::config::validate() {
  local root="$1" path
  path="$(specrelay::config::path "$root")"

  if [ ! -f "$path" ]; then
    specrelay::out::err "config not found: $path"
    return 1
  fi

  if ! command -v ruby >/dev/null 2>&1; then
    specrelay::out::err "ruby is required to read .specrelay/config.yml but was not found on PATH"
    return 1
  fi

  ruby -e '
    require "yaml"
    path = ARGV[0]
    begin
      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
    rescue Psych::SyntaxError, Psych::DisallowedClass => e
      warn "specrelay: malformed config (#{e.class}): #{e.message}"
      exit 1
    end
    unless data.is_a?(Hash)
      warn "specrelay: malformed config: top level must be a mapping (got #{data.class})"
      exit 1
    end
  ' "$path"
}

# specrelay::config::get <project-root> <dotted.field.path> [default]
# Prints the value at the dotted path (e.g. "specs.root") as a plain string.
# Prints the optional default (or nothing) if the path is missing. Assumes
# the config has already been validated by the caller.
specrelay::config::get() {
  local root="$1" field="$2" default="${3:-}" path
  path="$(specrelay::config::path "$root")"

  if [ ! -f "$path" ]; then
    printf '%s\n' "$default"
    return 0
  fi

  ruby -e '
    require "yaml"
    path, field, default = ARGV[0], ARGV[1], ARGV[2]
    data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
    data = {} unless data.is_a?(Hash)
    value = field.split(".").reduce(data) do |acc, key|
      acc.is_a?(Hash) ? acc[key] : nil
    end
    puts value.nil? ? default.to_s : value.to_s
  ' "$path" "$field" "$default"
}
