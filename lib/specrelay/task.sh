#!/usr/bin/env bash
# task.sh — task identity, directory resolution, and lookup.
#
# A safe task id is a single path segment matching ^[A-Za-z0-9._-]+$ (no
# slashes, whitespace, or shell metacharacters) — identical to the legacy
# workflow's rule (see docs/current-workflow-contract.md, "Task identity"),
# reimplemented here as SpecRelay's own validation rather than sourced from
# .ai/.

# specrelay::task::sanitize <raw-string>
# Replaces any run of unsafe characters with a single hyphen and strips
# leading/trailing hyphens. Mirrors the legacy start-spec-task.sh derivation.
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
# Derives a task id from a spec file's PARENT directory name (the SDD
# convention: docs/sdd/<task-id>/spec.md), sanitized to a safe path segment.
specrelay::task::id_from_spec_path() {
  local spec_path="$1" spec_dir parent
  spec_dir="$(cd "$(dirname "$spec_path")" && pwd -P)" || return 1
  parent="$(basename "$spec_dir")"
  specrelay::task::sanitize "$parent"
}

# specrelay::task::runs_root <project-root>
# Prints the absolute configured task-runtime root (never hardcoded; read
# from .specrelay/config.yml, default .ai-runs/tasks — matching this
# repository's existing runtime root, per spec section 48).
specrelay::task::runs_root() {
  local root="$1" configured="tasks.runs_root"
  local value=".ai-runs/tasks"
  if specrelay::config::exists "$root"; then
    value="$(specrelay::config::get "$root" "$configured" ".ai-runs/tasks")"
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
specrelay::task::spec_root() {
  local root="$1"
  local value="docs/sdd"
  if specrelay::config::exists "$root"; then
    value="$(specrelay::config::get "$root" "specs.root" "docs/sdd")"
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
