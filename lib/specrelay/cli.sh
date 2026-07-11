#!/usr/bin/env bash
# cli.sh — SpecRelay CLI command dispatch.
#
# This is a thin dispatcher: each command below composes the single-purpose
# helpers in project.sh / config.sh / discovery.sh / state.sh / task.sh /
# lock.sh / auth.sh / transitions.sh / evidence.sh / git_guard.sh /
# providers/*.sh / context/*.sh / workflow.sh / output.sh. As of SDD 0084,
# SpecRelay has a REAL, executable workflow engine (task lifecycle,
# executor/reviewer provider dispatch, evidence capture, review/rework
# loop) in addition to the SDD 0083 read-only discovery commands below.

SPECRELAY_UNIMPLEMENTED_MESSAGE="This command is not implemented in SpecRelay."

specrelay::cli::usage() {
  cat <<'USAGE'
Usage: specrelay <command> [subcommand] [args]

Setup:
  init [--path <dir>] [--force]
                         Initialize the current (or given) project for
                         SpecRelay: create .specrelay/config.yml from the
                         built-in template, create the spec root, and make a
                         safe, idempotent .gitignore entry for the runtime
                         evidence directory. Never overwrites an existing
                         config unless --force is given.

Discovery (read-only):
  version                Print the SpecRelay version and exit.
  help, --help, -h       Show this help.
  project root           Print the discovered project root.
  project inspect        Print a read-only summary of this project's
                         SpecRelay configuration.
  workflow inspect       Print a read-only summary of the existing (legacy)
                         AI workflow discovered on disk.
  doctor                 Read-only readiness diagnostics: git repo, config,
                         spec root, task runtime root, executor/reviewer
                         provider availability, context capability, active
                         engine mode, compatibility shims, rollback engine,
                         and engine-lock conflicts. Exits non-zero if any
                         mandatory check fails.

Workflow engine:
  run <spec-path> [--task-id <id>] [--allow-dirty-baseline]
                         Run the full lifecycle for a spec: create/resolve
                         the task, approve it, run executor/reviewer rounds
                         until READY_FOR_HUMAN_REVIEW, CHANGES_REQUESTED-only
                         (manual reviewer), BLOCKED, a provider failure, or
                         the configured maximum iterations.
  resume <task-ref>      Inspect a task's persisted state and run exactly one
                         safe next step (never restarts from the beginning).
  status [<task-ref>]    Show one task's summary, or every known task's
                         id/state/iteration.
  show <task-ref>        Show one task's full detail (delegates to
                         'task show').
  list                   List every known task, most recently updated first
                         (delegates to 'task list').

  task create <spec-path> [--task-id <id>] [--allow-dirty-baseline]
                         Create a new task from a spec (state DRAFT); does
                         NOT approve or run it.
  task show <task-ref>       Full detail view for one task.
  task status [<task-ref>]   Same as top-level 'status'.
  task list                  Same as top-level 'list'.
  task approve <task-ref>    Human-approval gate: DRAFT/WAITING_FOR_HUMAN ->
                             READY_FOR_EXECUTOR.
  task requeue <task-ref>    CHANGES_REQUESTED -> READY_FOR_EXECUTOR (manual
                             recovery; 'run'/'resume' do this automatically).
  task accept <task-ref>     READY_FOR_REVIEW -> READY_FOR_HUMAN_REVIEW
                             (requires 09/10 already written).
  task request-changes <task-ref> "<reason>"
                             READY_FOR_REVIEW -> CHANGES_REQUESTED (requires
                             09/11 already written).
  task block <task-ref> "<reason>"
                             EXECUTOR_RUNNING -> BLOCKED.
  task authorize-submit <task-ref>
                             Manual-recovery entry point for the runner-owned
                             EXECUTOR_RUNNING -> READY_FOR_REVIEW submit
                             transition (mirrors the legacy workflow's
                             authorize-submit.sh; see docs/engine-parity.md).

<task-ref> accepts a full task id, a unique numeric prefix, or a unique
partial slug (e.g. 'specrelay show 0084').

A task's own "engine" field records which engine owns mutating it; read-only
commands (show/status/list) work regardless, but mutating commands refuse a
task they do not own.

See the bundled README.md and docs/ (architecture, configuration, providers,
context-adapters, task-lifecycle, installation) for background. When SpecRelay
is incubated inside a repository that has a pre-existing `.ai/` workflow, see
docs/migration.md and docs/engine-parity.md for the compatibility model.
USAGE
}

specrelay::cli::cmd_init() {
  local self_dir="$1"; shift
  specrelay::init::run "$self_dir" "$@"
}

specrelay::cli::version() {
  local home="$1"
  local version_file="$home/VERSION"
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

# --- shared option parsing for run / task create ----------------------------
# specrelay::cli::_parse_run_args <argv...>
# Prints three lines on success: spec, task-id-override (may be empty),
# allow-dirty (0|1).
specrelay::cli::_parse_run_args() {
  local spec="" task_id_override="" allow_dirty=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task-id)
        [ "$#" -ge 2 ] || { specrelay::out::err "--task-id requires a value"; return 2; }
        task_id_override="$2"; shift 2 ;;
      --allow-dirty-baseline)
        allow_dirty=1; shift ;;
      -*)
        specrelay::out::err "unknown option: $1"; return 2 ;;
      *)
        if [ -n "$spec" ]; then
          specrelay::out::err "too many arguments"
          return 2
        fi
        spec="$1"; shift ;;
    esac
  done
  if [ -z "$spec" ]; then
    specrelay::out::err "a <spec-path> is required"
    return 2
  fi
  printf '%s\n%s\n%s\n' "$spec" "$task_id_override" "$allow_dirty"
}

# --- workflow engine commands ------------------------------------------------

specrelay::cli::cmd_run() {
  local root parsed spec task_id_override allow_dirty
  root="$(specrelay::cli::require_project_root)" || return 1
  parsed="$(specrelay::cli::_parse_run_args "$@")" || return 2
  spec="$(printf '%s\n' "$parsed" | sed -n '1p')"
  task_id_override="$(printf '%s\n' "$parsed" | sed -n '2p')"
  allow_dirty="$(printf '%s\n' "$parsed" | sed -n '3p')"
  specrelay::workflow::run "$root" "$spec" "$task_id_override" "$allow_dirty"
}

specrelay::cli::cmd_resume() {
  local root ref task_id
  root="$(specrelay::cli::require_project_root)" || return 1
  ref="${1:?usage: specrelay resume <task-ref>}"
  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  specrelay::workflow::resume "$root" "$task_id"
}

specrelay::cli::_task_dir_for_ref() {
  local root="$1" ref="$2" task_id
  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  specrelay::task::dir "$root" "$task_id"
}

specrelay::cli::task_create() {
  local root parsed spec task_id_override allow_dirty spec_abs spec_rel task_id
  root="$(specrelay::cli::require_project_root)" || return 1
  parsed="$(specrelay::cli::_parse_run_args "$@")" || return 2
  spec="$(printf '%s\n' "$parsed" | sed -n '1p')"
  task_id_override="$(printf '%s\n' "$parsed" | sed -n '2p')"
  allow_dirty="$(printf '%s\n' "$parsed" | sed -n '3p')"

  spec_abs="$(specrelay::task::resolve_spec_path "$root" "$spec")" || return 1
  spec_rel="${spec_abs#"$root"/}"
  if [ -n "$task_id_override" ]; then
    task_id="$task_id_override"
  else
    task_id="$(specrelay::task::id_from_spec_path "$spec_abs")"
  fi
  if ! specrelay::task::valid_id "$task_id"; then
    specrelay::out::err "could not derive a safe task id from spec path: $spec"
    return 1
  fi

  specrelay::transitions::create "$root" "$task_id" "$spec_rel" "$allow_dirty" || return 1
  specrelay::workflow::seed_task_from_spec "$root" "$task_id" "$spec_abs"
  echo "Task '$task_id' created in DRAFT."
  echo "Approve it with: specrelay task approve $task_id"
}

specrelay::cli::task_show() {
  local root ref task_id task_dir state_file
  root="$(specrelay::cli::require_project_root)" || return 1
  ref="${1:?usage: specrelay task show <task-ref>}"
  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"

  local state iteration spec_source created updated last_decision human_status
  state="$(specrelay::state::canonical "$state_file")"
  iteration="$(specrelay::state::get "$state_file" "iteration" 2>/dev/null)"
  spec_source="$(specrelay::state::get "$state_file" "spec_source" 2>/dev/null)"
  created="$(specrelay::state::get "$state_file" "created_at" 2>/dev/null)"

  updated=""
  local field
  for field in blocked_at reviewed_at changes_requested_at submitted_for_review_at requeued_at claimed_at approved_at created_at; do
    local v
    v="$(specrelay::state::get "$state_file" "$field" 2>/dev/null)"
    if [ -n "$v" ]; then
      updated="$v"
      break
    fi
  done

  last_decision="$(specrelay::state::get "$state_file" "review_result" 2>/dev/null)"
  if [ -z "$last_decision" ]; then
    local reason
    reason="$(specrelay::state::get "$state_file" "changes_requested_reason" 2>/dev/null)"
    [ -n "$reason" ] && last_decision="changes requested: $reason"
  fi
  [ -n "$last_decision" ] || last_decision="(none yet)"

  if [ "$state" = "READY_FOR_HUMAN_REVIEW" ]; then
    human_status="pending human review"
  else
    human_status="(not yet reached)"
  fi

  echo "Task: $task_id"
  echo "State: ${state:-(unknown)}"
  echo "Iteration: ${iteration:-(none)}"
  echo "Spec: ${spec_source:-(none recorded)}"
  echo "Executor provider: $(specrelay::workflow::executor_provider "$root")"
  echo "Reviewer provider: $(specrelay::workflow::reviewer_provider "$root")"
  echo "Created: ${created:-(unknown)}"
  echo "Updated: ${updated:-(unknown)}"
  echo "Last decision: $last_decision"
  echo "Human review status: $human_status"
  echo "Task runtime path: $task_dir"
}

specrelay::cli::_status_row() {
  local root="$1" task_id="$2" task_dir state_file state iteration
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  state_file="$(specrelay::state::path "$task_dir")"
  state="$(specrelay::state::canonical "$state_file")"
  iteration="$(specrelay::state::get "$state_file" "iteration" 2>/dev/null)"
  printf '%s\t%s\t%s\n' "$task_id" "${state:-INVALID_STATE}" "${iteration:-\-}"
}

specrelay::cli::task_status() {
  local root ref
  root="$(specrelay::cli::require_project_root)" || return 1
  ref="${1:-}"

  local rows="TASK	STATE	ITERATION"
  if [ -n "$ref" ]; then
    local task_id
    task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
    rows="$rows
$(specrelay::cli::_status_row "$root" "$task_id")"
  else
    local id found=0
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      found=1
      rows="$rows
$(specrelay::cli::_status_row "$root" "$id")"
    done < <(specrelay::task::list_ids "$root")
    if [ "$found" -eq 0 ]; then
      echo "No tasks found."
      return 0
    fi
  fi

  if command -v column >/dev/null 2>&1; then
    printf '%s\n' "$rows" | column -t -s "$(printf '\t')"
  else
    printf '%s\n' "$rows"
  fi
}

specrelay::cli::task_list() {
  local root runs_root
  root="$(specrelay::cli::require_project_root)" || return 1
  runs_root="$(specrelay::task::runs_root "$root")"
  if [ ! -d "$runs_root" ]; then
    echo "No tasks found under $runs_root"
    return 0
  fi

  local id state_file mtime pairs=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    state_file="$(specrelay::state::path "$(specrelay::task::dir "$root" "$id")")"
    mtime="$(stat -f %m "$state_file" 2>/dev/null || stat -c %Y "$state_file" 2>/dev/null || echo 0)"
    pairs="$pairs$mtime	$id
"
  done < <(specrelay::task::list_ids "$root")

  if [ -z "$pairs" ]; then
    echo "No tasks found under $runs_root"
    return 0
  fi

  local rows="TASK	STATE	ITERATION"
  local sorted_id
  while IFS= read -r sorted_id; do
    [ -n "$sorted_id" ] || continue
    rows="$rows
$(specrelay::cli::_status_row "$root" "$sorted_id")"
  done < <(printf '%s' "$pairs" | sort -rn | cut -f2)

  if command -v column >/dev/null 2>&1; then
    printf '%s\n' "$rows" | column -t -s "$(printf '\t')"
  else
    printf '%s\n' "$rows"
  fi
}

specrelay::cli::task_approve() {
  local root ref task_id
  root="$(specrelay::cli::require_project_root)" || return 1
  ref="${1:?usage: specrelay task approve <task-ref>}"
  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  specrelay::transitions::approve "$root" "$task_id"
}

specrelay::cli::task_requeue() {
  local root ref task_id
  root="$(specrelay::cli::require_project_root)" || return 1
  ref="${1:?usage: specrelay task requeue <task-ref>}"
  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  specrelay::transitions::requeue "$root" "$task_id"
}

specrelay::cli::task_accept() {
  local root ref task_id
  root="$(specrelay::cli::require_project_root)" || return 1
  ref="${1:?usage: specrelay task accept <task-ref>}"
  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  specrelay::transitions::accept "$root" "$task_id" "$(specrelay::workflow::reviewer_provider "$root")"
}

specrelay::cli::task_request_changes() {
  local root ref task_id reason
  root="$(specrelay::cli::require_project_root)" || return 1
  ref="${1:?usage: specrelay task request-changes <task-ref> \"<reason>\"}"
  shift
  reason="$*"
  if [ -z "${reason//[[:space:]]/}" ]; then
    specrelay::out::err "a non-empty reason is required"
    return 2
  fi
  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  specrelay::transitions::request_changes "$root" "$task_id" "$reason" "$(specrelay::workflow::reviewer_provider "$root")"
}

specrelay::cli::task_block() {
  local root ref task_id reason
  root="$(specrelay::cli::require_project_root)" || return 1
  ref="${1:?usage: specrelay task block <task-ref> \"<reason>\"}"
  shift
  reason="$*"
  if [ -z "${reason//[[:space:]]/}" ]; then
    specrelay::out::err "a non-empty reason is required"
    return 2
  fi
  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  specrelay::transitions::block "$root" "$task_id" "$reason"
}

# specrelay::cli::task_recover <task-ref> --reason "<reason>" [--to <state>]
# SpecRelay-native recovery of an interrupted RUNNING task (SDD 0085B,
# section 3). Refuses if a live process still owns the task; safely reclaims a
# stale lock otherwise; records audited recovery metadata; never fabricates
# evidence and never reaches READY_FOR_HUMAN_REVIEW.
specrelay::cli::task_recover() {
  local root ref="" reason="" target="READY_FOR_EXECUTOR" task_id liveness rc
  root="$(specrelay::cli::require_project_root)" || return 1

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason)
        [ "$#" -ge 2 ] || { specrelay::out::err "--reason requires a value"; return 2; }
        reason="$2"; shift 2 ;;
      --to)
        [ "$#" -ge 2 ] || { specrelay::out::err "--to requires a value"; return 2; }
        target="$2"; shift 2 ;;
      -*)
        specrelay::out::err "unknown option: $1"; return 2 ;;
      *)
        if [ -n "$ref" ]; then
          specrelay::out::err "too many arguments"; return 2
        fi
        ref="$1"; shift ;;
    esac
  done

  if [ -z "$ref" ]; then
    specrelay::out::err "usage: specrelay task recover <task-ref> --reason \"<reason>\" [--to READY_FOR_EXECUTOR]"
    return 2
  fi
  if [ -z "${reason//[[:space:]]/}" ]; then
    specrelay::out::err "a non-empty --reason is required (recovery is always audited, never silent)"
    return 2
  fi

  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1

  # 3.2 — liveness FIRST: never touch a task a live process still owns.
  liveness="$(specrelay::lock::owner_liveness "$root" "$task_id")"
  case "$liveness" in
    live-local|live-foreign)
      specrelay::out::err "refusing to recover '$task_id': a live process still owns it ($(specrelay::lock::owner_description "$root" "$task_id"))"
      specrelay::out::err "wait for it to finish, or stop it, before recovering; nothing was changed"
      return 1
      ;;
  esac

  # 3.3 — reclaim a stale lock safely (acquire refuses a live lock and only
  # reclaims a same-host dead-pid lock; it never force-removes a live one).
  if ! specrelay::lock::acquire "$root" "$task_id"; then
    return 1
  fi

  specrelay::transitions::recover "$root" "$task_id" "$target" "$reason"
  rc=$?

  if [ "$rc" -eq 0 ]; then
    # 3.4 — never silent: print exactly what changed.
    echo "Recovered task '$task_id':"
    echo "  recovered_from_state: $(specrelay::state::get "$(specrelay::state::path "$(specrelay::task::dir "$root" "$task_id")")" recovered_from_state)"
    echo "  new state:            $target"
    echo "  recovered_at:         $(specrelay::state::get "$(specrelay::state::path "$(specrelay::task::dir "$root" "$task_id")")" recovered_at)"
    echo "  recovered_by:         $(specrelay::state::get "$(specrelay::state::path "$(specrelay::task::dir "$root" "$task_id")")" recovered_by)"
    echo "  recovery_reason:      $reason"
    echo "Existing evidence files were preserved untouched."
  fi

  specrelay::lock::release "$root" "$task_id"
  return "$rc"
}

specrelay::cli::task_authorize_submit() {
  local root ref task_id token rc
  root="$(specrelay::cli::require_project_root)" || return 1
  ref="${1:?usage: specrelay task authorize-submit <task-ref>}"
  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  token="$(specrelay::auth::mint "$root" "$task_id")"
  echo "Runner transition authorization created for '$task_id' (value not logged)."
  specrelay::transitions::submit "$root" "$task_id" "$token"
  rc=$?
  specrelay::auth::cleanup "$root" "$task_id"
  return "$rc"
}

specrelay::cli::task_dispatch() {
  local sub="${1:-}"
  [ "$#" -gt 0 ] && shift
  case "$sub" in
    create) specrelay::cli::task_create "$@" ;;
    show) specrelay::cli::task_show "$@" ;;
    status) specrelay::cli::task_status "$@" ;;
    list) specrelay::cli::task_list ;;
    approve) specrelay::cli::task_approve "$@" ;;
    requeue) specrelay::cli::task_requeue "$@" ;;
    accept) specrelay::cli::task_accept "$@" ;;
    request-changes) specrelay::cli::task_request_changes "$@" ;;
    block) specrelay::cli::task_block "$@" ;;
    recover) specrelay::cli::task_recover "$@" ;;
    authorize-submit) specrelay::cli::task_authorize_submit "$@" ;;
    "")
      specrelay::out::err "usage: specrelay task <create|show|status|list|approve|requeue|accept|request-changes|block|recover|authorize-submit>"
      return 2
      ;;
    *)
      specrelay::out::err "unknown 'task' subcommand: $sub"
      return 2
      ;;
  esac
}

# specrelay::cli::main <specrelay-home> <argv...>
# specrelay-home is SpecRelay's own install/source root (used to locate
# VERSION and templates); it is NOT the consumer project root.
specrelay::cli::main() {
  local home="$1"
  shift

  if [ "$#" -eq 0 ]; then
    specrelay::cli::usage >&2
    return 2
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    init)
      specrelay::cli::cmd_init "$home" "$@"
      ;;
    version)
      specrelay::cli::version "$home"
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
    run)
      specrelay::cli::cmd_run "$@"
      ;;
    resume)
      specrelay::cli::cmd_resume "$@"
      ;;
    status)
      specrelay::cli::task_status "$@"
      ;;
    show)
      specrelay::cli::task_show "$@"
      ;;
    list)
      specrelay::cli::task_list
      ;;
    task)
      specrelay::cli::task_dispatch "$@"
      ;;
    doctor)
      specrelay::doctor::run "$home"
      ;;
    review)
      specrelay::cli::unimplemented "$cmd"
      ;;
    *)
      specrelay::out::err "unknown command: $cmd"
      specrelay::cli::usage >&2
      return 2
      ;;
  esac
}
