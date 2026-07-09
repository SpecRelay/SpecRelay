#!/usr/bin/env bash
# cli.sh — SpecRelay CLI command dispatch (incubation version 0.1).
#
# This is a thin dispatcher: each command below composes the small,
# single-purpose helpers in project.sh / config.sh / discovery.sh /
# output.sh. It implements ONLY read-only discovery/inspection commands
# (SDD 0083, Phase E) — no task lifecycle, no execution engine.

SPECRELAY_UNIMPLEMENTED_MESSAGE="SpecRelay workflow execution is not available in incubation version 0.1.
Use the existing repository workflow for execution."

specrelay::cli::usage() {
  cat <<'USAGE'
Usage: specrelay <command> [subcommand] [args]

Commands:
  version                Print the SpecRelay version and exit.
  help, --help, -h       Show this help.
  project root           Print the discovered project root.
  project inspect        Print a read-only summary of this project's
                         SpecRelay configuration.
  workflow inspect       Print a read-only summary of the existing (legacy)
                         AI workflow discovered on disk.

Not yet implemented in this incubation version (each fails clearly):
  run, task create, review, and other workflow-execution commands.

SpecRelay is currently incubated inside the Sprint Reports repository under
tools/specrelay/. See tools/specrelay/README.md for background.
USAGE
}

specrelay::cli::version() {
  local self_dir="$1"
  local version_file="$self_dir/../VERSION"
  if [ ! -f "$version_file" ]; then
    specrelay::out::err "VERSION file not found: $version_file"
    return 1
  fi
  printf 'specrelay %s\n' "$(tr -d '[:space:]' < "$version_file")"
}

specrelay::cli::require_project_root() {
  local root
  if ! root="$(specrelay::project::root)"; then
    specrelay::out::err "could not discover a project root (not inside a git repository, and no .specrelay/ found in any parent directory)"
    return 1
  fi
  printf '%s\n' "$root"
}

specrelay::cli::project_root() {
  specrelay::cli::require_project_root
}

specrelay::cli::project_inspect() {
  local root
  root="$(specrelay::cli::require_project_root)" || return 1

  echo "Project root: $root"

  if specrelay::config::exists "$root"; then
    echo "Config file (.specrelay/config.yml): present"
    if ! specrelay::config::validate "$root"; then
      return 1
    fi
    local spec_root runs_root validation_cmd project_name
    project_name="$(specrelay::config::get "$root" "project.name" "(not set)")"
    spec_root="$(specrelay::config::get "$root" "specs.root" "(not set)")"
    runs_root="$(specrelay::config::get "$root" "tasks.runs_root" "(not set)")"
    validation_cmd="$(specrelay::config::get "$root" "validation.full_test_command" "(not set)")"
    echo "Project name: $project_name"
    echo "Configured spec root: $spec_root"
    echo "Configured task-run root: $runs_root"
    echo "Configured validation command: $validation_cmd"
  else
    echo "Config file (.specrelay/config.yml): NOT present"
    echo "Project name: (unknown — no config)"
    echo "Configured spec root: (unknown — no config)"
    echo "Configured task-run root: (unknown — no config)"
    echo "Configured validation command: (unknown — no config)"
  fi

  local ai_root
  ai_root="$(specrelay::discovery::ai_root "$root")"
  if [ -n "$ai_root" ]; then
    echo "Detected legacy/current AI workflow location: $ai_root"
  else
    echo "Detected legacy/current AI workflow location: (none found)"
  fi

  return 0
}

specrelay::cli::workflow_inspect() {
  local root
  root="$(specrelay::cli::require_project_root)" || return 1

  local runs_root_configured=""
  if specrelay::config::exists "$root"; then
    specrelay::config::validate "$root" || return 1
    runs_root_configured="$(specrelay::config::get "$root" "tasks.runs_root" ".ai-runs/tasks")"
  fi

  local ai_root
  ai_root="$(specrelay::discovery::ai_root "$root")"
  if [ -z "$ai_root" ]; then
    echo "No legacy/current AI workflow detected under: $root/.ai"
    return 0
  fi

  echo "Legacy/current AI workflow root: $ai_root"

  specrelay::out::section "Public workflow entry points:"
  local found_entrypoints=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    found_entrypoints=1
    echo "  $f"
  done < <(specrelay::discovery::public_entrypoints "$root")
  [ "$found_entrypoints" -eq 1 ] || echo "  (none found)"

  specrelay::out::section "Internal helper root:"
  local internal_root
  internal_root="$(specrelay::discovery::internal_helper_root "$root")"
  echo "  ${internal_root:-(none found)}"

  specrelay::out::section "Protocol file:"
  local protocol_file
  protocol_file="$(specrelay::discovery::protocol_file "$root")"
  echo "  ${protocol_file:-(none found)}"

  specrelay::out::section "Reviewer contract file:"
  local reviewer_file
  reviewer_file="$(specrelay::discovery::reviewer_file "$root")"
  echo "  ${reviewer_file:-(none found)}"

  specrelay::out::section "Task run root:"
  local task_run_root
  task_run_root="$(specrelay::discovery::task_run_root "$root" "$runs_root_configured")"
  if [ -d "$task_run_root" ]; then
    echo "  $task_run_root (exists)"
  else
    echo "  $task_run_root (configured/expected; does not exist yet)"
  fi

  specrelay::out::section "Detected provider integration locations:"
  local found_providers=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    found_providers=1
    echo "  $line"
  done < <(specrelay::discovery::provider_integrations "$root")
  [ "$found_providers" -eq 1 ] || echo "  (none found)"

  return 0
}

specrelay::cli::unimplemented() {
  local cmd="$1"
  specrelay::out::err "command '$cmd' is not implemented."
  echo "$SPECRELAY_UNIMPLEMENTED_MESSAGE" >&2
  return 1
}

# specrelay::cli::main <self-dir> <argv...>
# self-dir is the directory containing bin/specrelay (used to locate VERSION).
specrelay::cli::main() {
  local self_dir="$1"
  shift

  if [ "$#" -eq 0 ]; then
    specrelay::cli::usage >&2
    return 2
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    version)
      specrelay::cli::version "$self_dir"
      ;;
    help|--help|-h)
      specrelay::cli::usage
      ;;
    project)
      case "${1:-}" in
        root)
          specrelay::cli::project_root
          ;;
        inspect)
          specrelay::cli::project_inspect
          ;;
        "")
          specrelay::out::err "usage: specrelay project <root|inspect>"
          return 2
          ;;
        *)
          specrelay::out::err "unknown 'project' subcommand: $1"
          return 2
          ;;
      esac
      ;;
    workflow)
      case "${1:-}" in
        inspect)
          specrelay::cli::workflow_inspect
          ;;
        "")
          specrelay::out::err "usage: specrelay workflow inspect"
          return 2
          ;;
        *)
          specrelay::cli::unimplemented "workflow $1"
          ;;
      esac
      ;;
    run|task|review)
      specrelay::cli::unimplemented "$cmd"
      ;;
    *)
      specrelay::out::err "unknown command: $cmd"
      specrelay::cli::usage >&2
      return 2
      ;;
  esac
}
