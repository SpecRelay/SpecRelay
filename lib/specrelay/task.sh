#!/usr/bin/env bash
# task.sh — task identity, directory resolution, and lookup.
#
# A safe task id is a single path segment matching ^[A-Za-z0-9._-]+$ (no
# slashes, whitespace, or shell metacharacters) — see
# docs/current-workflow-contract.md, "Task identity".

# specrelay::task::sanitize <raw-string>
# Replaces any run of unsafe characters with a single hyphen and strips
# leading/trailing hyphens.
specrelay::task::sanitize() {
  printf '%s' "$1" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

# specrelay::task::valid_id <task-id>
specrelay::task::valid_id() {
  local id="$1"
  [ -n "$id" ] || return 1
  [ "$id" != "." ] && [ "$id" != ".." ] || return 1
  printf '%s' "$id" | grep -Eq '^[A-Za-z0-9._-]+$'
}

# specrelay::task::id_from_spec_path <spec-path>
# Derives a task id from a spec file's PARENT directory name (the one-dir-per-
# spec convention, e.g. <specs-root>/<task-id>/spec.md), sanitized to a safe
# path segment.
specrelay::task::id_from_spec_path() {
  local spec_path="$1" spec_dir parent
  spec_dir="$(cd "$(dirname "$spec_path")" && pwd -P)" || return 1
  parent="$(basename "$spec_dir")"
  specrelay::task::sanitize "$parent"
}

# specrelay::task::runs_root <project-root>
# Prints the absolute configured task-runtime root (never hardcoded; read
# from .specrelay/config.yml). The generic default when no project config
# sets it is `.specrelay-runs/tasks` (SpecRelay's provider-neutral public
# default — see docs/configuration.md). A consumer project that keeps its
# runtime evidence elsewhere sets `tasks.runs_root` explicitly in its config.
specrelay::task::runs_root() {
  local root="$1" configured="tasks.runs_root"
  local value=".specrelay-runs/tasks"
  if specrelay::config::exists "$root"; then
    value="$(specrelay::config::get "$root" "$configured" ".specrelay-runs/tasks")"
  fi
  printf '%s/%s\n' "$root" "$value"
}

# specrelay::task::dir <project-root> <task-id>
specrelay::task::dir() {
  local root="$1" id="$2" runs_root
  runs_root="$(specrelay::task::runs_root "$root")"
  printf '%s/%s\n' "$runs_root" "$id"
}

# specrelay::task::spec_root <project-root>
# The generic default when no project config sets it is `specs` (SpecRelay's
# provider-neutral public default). A consumer project that keeps its specs
# elsewhere sets `specs.root` explicitly in its config.
specrelay::task::spec_root() {
  local root="$1"
  local value="specs"
  if specrelay::config::exists "$root"; then
    value="$(specrelay::config::get "$root" "specs.root" "specs")"
  fi
  printf '%s/%s\n' "$root" "$value"
}

# specrelay::task::resolve_spec_path <project-root> <spec-path-arg>
# Resolves a user-supplied spec path safely: must exist, must be a regular
# file, and (after resolution) must not escape the project root via traversal.
# Prints the absolute path on success.
specrelay::task::resolve_spec_path() {
  local root="$1" arg="$2" abs
  if [ -f "$arg" ]; then
    abs="$(cd "$(dirname "$arg")" && pwd -P)/$(basename "$arg")"
  elif [ -f "$root/$arg" ]; then
    abs="$(cd "$(dirname "$root/$arg")" && pwd -P)/$(basename "$arg")"
  else
    specrelay::out::err "spec file not found: $arg"
    return 1
  fi
  case "$abs" in
    "$root"/*) ;;
    *)
      specrelay::out::err "refusing spec path outside the project root: $abs"
      return 1
      ;;
  esac
  printf '%s\n' "$abs"
}

# specrelay::task::resolve_input_path <project-root> <input-path-arg>
# Resolves a user-supplied spec FILE OR DIRECTORY path (spec 0023, section 4:
# "run and task create accept a file or a directory"). Prints two lines on
# success: the input kind (file|directory), then the resolved absolute path
# (which must not escape the project root). Fails clearly (never guesses) on
# a missing path, a special filesystem entry, or a path escaping the
# project root — mirrors resolve_spec_path's safety rules for the file case.
specrelay::task::resolve_input_path() {
  local root="$1" arg="$2" abs kind
  if [ -e "$arg" ] || [ -L "$arg" ]; then
    if [ -d "$arg" ]; then
      abs="$(cd "$arg" && pwd -P)"
    else
      abs="$(cd "$(dirname "$arg")" && pwd -P)/$(basename "$arg")"
    fi
  elif [ -e "$root/$arg" ] || [ -L "$root/$arg" ]; then
    if [ -d "$root/$arg" ]; then
      abs="$(cd "$root/$arg" && pwd -P)"
    else
      abs="$(cd "$(dirname "$root/$arg")" && pwd -P)/$(basename "$root/$arg")"
    fi
  else
    specrelay::out::err "input path not found: $arg"
    return 1
  fi

  case "$abs" in
    "$root"/*|"$root") ;;
    *)
      specrelay::out::err "refusing input path outside the project root: $abs"
      return 1
      ;;
  esac

  kind="$(specrelay::bundle::classify_input "$abs")" || return 1
  printf '%s\n%s\n' "$kind" "$abs"
}

# specrelay::task::id_from_input_path <input-abs-path> <input-kind>
# Derives a task id: for a directory input, the directory's OWN basename
# (it IS the one-dir-per-task bundle root); for a file input, the file's
# PARENT directory name (unchanged one-dir-per-spec convention).
specrelay::task::id_from_input_path() {
  local abs="$1" kind="$2" dir_for_name
  if [ "$kind" = "directory" ]; then
    dir_for_name="$(cd "$abs" && pwd -P)" || return 1
  else
    dir_for_name="$(cd "$(dirname "$abs")" && pwd -P)" || return 1
  fi
  specrelay::task::sanitize "$(basename "$dir_for_name")"
}

# specrelay::task::list_ids <project-root>
# Lists every existing task id (directory name) under the configured runs
# root that contains a state.json, one per line, sorted.
specrelay::task::list_ids() {
  local root="$1" runs_root d
  runs_root="$(specrelay::task::runs_root "$root")"
  [ -d "$runs_root" ] || return 0
  for d in "$runs_root"/*/; do
    [ -d "$d" ] || continue
    [ -f "${d}state.json" ] || continue
    basename "$d"
  done | sort
}

# specrelay::task::resolve_ref <project-root> <ref>
# Resolves a full task id, a unique numeric prefix, or a unique partial slug
# to exactly one existing task id. Prints the resolved id on success.
# Fails clearly (never guesses) on zero or multiple matches.
specrelay::task::resolve_ref() {
  local root="$1" ref="$2" runs_root="" match_file
  runs_root="$(specrelay::task::runs_root "$root")"

  # Exact match wins immediately.
  if [ -f "$runs_root/$ref/state.json" ]; then
    printf '%s\n' "$ref"
    return 0
  fi

  local -a matches=()
  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in
      "$ref"-*|*"$ref"*)
        matches+=("$id")
        ;;
    esac
  done < <(specrelay::task::list_ids "$root")

  # Prefer prefix matches (e.g. numeric prefix "0084") over loose substring
  # matches, so a short numeric ref behaves predictably.
  local -a prefix_matches=()
  if [ "${#matches[@]}" -gt 0 ]; then
    for id in "${matches[@]}"; do
      case "$id" in
        "$ref"-*|"$ref") prefix_matches+=("$id") ;;
      esac
    done
  fi
  if [ "${#prefix_matches[@]}" -gt 0 ]; then
    matches=("${prefix_matches[@]}")
  fi

  case "${#matches[@]}" in
    0)
      specrelay::out::err "no task matches '$ref'"
      return 1
      ;;
    1)
      printf '%s\n' "${matches[0]}"
      return 0
      ;;
    *)
      specrelay::out::err "ambiguous task reference '$ref' matches multiple tasks:"
      for id in "${matches[@]}"; do
        echo "  - $id" >&2
      done
      return 1
      ;;
  esac
}
