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
                         provider availability, role model selection
                         (configured/resolved/validation level), context
                         capability, active engine mode, compatibility shims,
                         rollback engine, and engine-lock conflicts. Exits
                         non-zero if any mandatory check fails.
  models [<provider>]    Model-selection guidance for configured automated
                         providers: the supported configuration forms
                         (provider-default, semantic alias, exact model id),
                         each provider's declared aliases, and its honest
                         model-discovery capability. With a provider name,
                         inspects that provider only.
  contexts [<adapter>]   Context-adapter discovery and diagnostics: the
                         adapters known to this SpecRelay version, each one's
                         availability, and this project's configured
                         executor/reviewer context adapters. With an adapter
                         name, inspects that adapter's description,
                         availability, capability level, and capabilities.
                         Never performs a billable provider invocation.

Workflow engine:
  run <spec-path> [--task-id <id>] [--allow-dirty-baseline]
                         Run the full lifecycle for a spec: create/resolve
                         the task, approve it, run executor/reviewer rounds
                         until READY_FOR_HUMAN_REVIEW, CHANGES_REQUESTED-only
                         (manual reviewer), BLOCKED, a provider failure, or
                         the configured maximum iterations.
  resume <task-ref>      Resume an existing task from its persisted state and
                         drive the executor/reviewer loop to the next terminal
                         or explicit-stop state, exactly like 'run' (never
                         restarts from the beginning). With an automated
                         reviewer it continues from READY_FOR_REVIEW into
                         reviewer execution in the same invocation.
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
  task timeline <task-ref> [--json]
                             Read-only execution-timeline report: total wall
                             time, per-phase durations, invocation/resume
                             history, the verification ledger, duplicate-work
                             detection, slowest phases, phase-budget
                             warnings, and (spec 0020) the agent command-
                             timing summary. Never mutates task state. A
                             legacy task with no recorded timeline data is
                             reported honestly rather than fabricated.
  task commands <task-ref> [--json]
                             Read-only agent command-timing ledger (spec
                             0020): slowest observed agent tool commands,
                             per-role/per-tool timing, repeated commands, and
                             waiting/polling commands. Never mutates task
                             state. A legacy/never-instrumented task is
                             reported honestly as not recorded.

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

specrelay::cli::cmd_models() {
  local root
  root="$(specrelay::cli::require_project_root)" || return 1
  if [ "$#" -gt 1 ]; then
    specrelay::out::err "usage: specrelay models [<provider>]"
    return 2
  fi
  specrelay::models::run "$root" "${1:-}"
}

specrelay::cli::cmd_contexts() {
  local root
  root="$(specrelay::cli::require_project_root)" || return 1
  if [ "$#" -gt 1 ]; then
    specrelay::out::err "usage: specrelay contexts [<adapter>]"
    return 2
  fi
  specrelay::contexts::run "$root" "${1:-}"
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

  local state iteration spec_source created updated last_decision human_status engine engine_version schema_version
  state="$(specrelay::state::canonical "$state_file")"
  iteration="$(specrelay::state::get "$state_file" "iteration" 2>/dev/null)"
  spec_source="$(specrelay::state::get "$state_file" "spec_source" 2>/dev/null)"
  created="$(specrelay::state::get "$state_file" "created_at" 2>/dev/null)"
  engine="$(specrelay::state::get "$state_file" "engine" 2>/dev/null)"
  engine_version="$(specrelay::state::get "$state_file" "engine_version" 2>/dev/null)"
  schema_version="$(specrelay::state::get "$state_file" "schema_version" 2>/dev/null)"

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
  echo "Engine: ${engine:-(none recorded)}"
  echo "Engine version: ${engine_version:-(none recorded)}"
  echo "Schema version: ${schema_version:-1 (implicit; historical task)}"
  # Role configuration for an EXISTING task prefers the durable roles_effective
  # values captured at task creation over silently re-resolving (possibly
  # changed) project configuration — this preserves the audit trail for runs
  # created before a config change (spec 0012, "Status and Diagnostic Output").
  # A task that predates capture falls back to the live resolved config.
  # The captured "model" is the RESOLVED value; "model configured" additionally
  # shows the durable configured selection (kind:value) when the task captured
  # the spec-0014 structured metadata. An old task that captured only a string
  # model remains fully displayable — the configured line reports the metadata
  # as not recorded rather than re-resolving current project configuration.
  local exec_cfg rev_cfg
  exec_cfg="$(specrelay::workflow::captured_role_model_configured "$root" "$task_id" executor 2>/dev/null || true)"
  rev_cfg="$(specrelay::workflow::captured_role_model_configured "$root" "$task_id" reviewer 2>/dev/null || true)"
  echo "Executor provider: $(specrelay::workflow::effective_role_provider "$root" "$task_id" executor)"
  echo "Executor model: $(specrelay::workflow::effective_role_model "$root" "$task_id" executor)"
  echo "Executor model configured: ${exec_cfg:-(not recorded — captured before structured model metadata)}"
  echo "Executor agent: $(specrelay::workflow::effective_role_agent "$root" "$task_id" executor)"
  echo "Reviewer provider: $(specrelay::workflow::effective_role_provider "$root" "$task_id" reviewer)"
  echo "Reviewer model: $(specrelay::workflow::effective_role_model "$root" "$task_id" reviewer)"
  echo "Reviewer model configured: ${rev_cfg:-(not recorded — captured before structured model metadata)}"
  echo "Reviewer agent: $(specrelay::workflow::effective_role_agent "$root" "$task_id" reviewer)"
  # Durable context metadata (spec 0015): adapter/required prefer the captured
  # context_effective values (falling back to live config for a task created
  # before capture); status/artifact exist ONLY as durable metadata — an old
  # task without them remains fully displayable and reports them as not
  # recorded rather than fabricating a preparation that never happened.
  local r label status kind ref
  for r in executor reviewer; do
    if [ "$r" = "executor" ]; then label="Executor"; else label="Reviewer"; fi
    echo "$label context adapter: $(specrelay::workflow::effective_role_context_adapter "$root" "$task_id" "$r")"
    echo "$label context required: $(specrelay::workflow::effective_role_context_required "$root" "$task_id" "$r")"
    status="$(specrelay::workflow::captured_context "$root" "$task_id" "$r" status 2>/dev/null || true)"
    echo "$label context status: ${status:-(not recorded — legacy/default behavior)}"
    ref="$(specrelay::workflow::captured_context "$root" "$task_id" "$r" artifact_reference 2>/dev/null || true)"
    if [ -n "$ref" ]; then
      kind="$(specrelay::workflow::captured_context "$root" "$task_id" "$r" artifact_kind 2>/dev/null || true)"
      echo "$label context artifact: ${kind:-unknown}:$ref"
    fi
  done
  echo "Created: ${created:-(unknown)}"
  echo "Updated: ${updated:-(unknown)}"
  echo "Last decision: $last_decision"
  echo "Human review status: $human_status"
  echo "Task runtime path: $task_dir"

  specrelay::cli::_task_show_timeline_summary "$task_dir"
}

# specrelay::cli::_task_show_timeline_summary <task-dir>
# Read-only (spec 0019, "Task Show Integration"). A legacy task with no
# recorded timeline data prints an honest one-liner rather than fabricating
# a summary.
specrelay::cli::_task_show_timeline_summary() {
  local task_dir="$1" blob recorded
  blob="$(specrelay::timeline::show_json "$task_dir" 2>/dev/null)"
  recorded="$(printf '%s' "$blob" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print("no" if d.get("recorded") is False else "yes")' 2>/dev/null)"
  if [ "$recorded" != "yes" ]; then
    echo "Execution timeline: not recorded"
    return 0
  fi
  printf '%s' "$blob" | python3 -c '
import json, sys

def fmt(seconds):
    if seconds is None:
        return "n/a"
    seconds = int(round(seconds))
    if seconds < 60:
        return "%ds" % seconds
    m, s = divmod(seconds, 60)
    if m < 60:
        return "%dm %ds" % (m, s)
    h, m = divmod(m, 60)
    return "%dh %dm %ds" % (h, m, s)

d = json.load(sys.stdin)
full_suite = next((v["count"] for v in d.get("verification_ledger", []) if v["operation"] == "test_full"), 0)
mr = d.get("marker_recovery", {})
print("Total wall time: %s" % fmt(d.get("wall_seconds")))
print("Invocation count: %d" % d.get("invocation_count", 0))
print("Resume count: %d" % d.get("resume_count", 0))
print("Full-suite runs: %d" % full_suite)
print("Reviewer marker recovery: %s" % (mr.get("outcome") if mr.get("attempted") else "not used"))
print("Budget warnings: %d" % len(d.get("budget_warnings", [])))
' 2>/dev/null
  echo "Timeline: $task_dir/20-execution-timeline.json"
}

# specrelay::cli::task_timeline <task-ref> [--json]
# Read-only (spec 0019, "CLI Inspection"): prints the current execution-
# timeline report WITHOUT mutating any task file (it recomputes the derived
# summary from the append-only event log — a pure read+derive, never a
# write to task state). Fails clearly for an unknown task; a legacy task
# with no recorded timeline data remains inspectable (an honest "not
# recorded" report rather than an error).
specrelay::cli::task_timeline() {
  local root ref="" as_json=0 task_id task_dir
  root="$(specrelay::cli::require_project_root)" || return 1

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) as_json=1; shift ;;
      -*) specrelay::out::err "unknown option: $1"; return 2 ;;
      *)
        if [ -n "$ref" ]; then specrelay::out::err "too many arguments"; return 2; fi
        ref="$1"; shift ;;
    esac
  done
  if [ -z "$ref" ]; then
    specrelay::out::err "usage: specrelay task timeline <task-ref> [--json]"
    return 2
  fi

  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  task_dir="$(specrelay::task::dir "$root" "$task_id")"

  if [ "$as_json" -eq 1 ]; then
    specrelay::timeline::show_json "$task_dir"
    return 0
  fi

  local blob recorded
  blob="$(specrelay::timeline::show_json "$task_dir" 2>/dev/null)"
  recorded="$(printf '%s' "$blob" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print("no" if d.get("recorded") is False else "yes")' 2>/dev/null)"
  if [ "$recorded" != "yes" ]; then
    echo "Execution timeline: not recorded for task '$task_id' (legacy task, or no invocation has run yet)."
    return 0
  fi

  # READ-ONLY: report (not render) recomputes the summary in memory from the
  # durable event log and prints it, but never writes
  # 20-execution-timeline.json — 'task timeline' never mutates task files.
  # "final" only for a task that has actually reached a terminal-for-now
  # state (READY_FOR_HUMAN_REVIEW / BLOCKED); anything else can still
  # progress automatically, so it is reported honestly as partial.
  local current mode
  current="$(specrelay::state::canonical "$(specrelay::state::path "$task_dir")" 2>/dev/null || true)"
  case "$current" in
    READY_FOR_HUMAN_REVIEW|BLOCKED) mode=final ;;
    *) mode=partial ;;
  esac
  specrelay::timeline::report "$root" "$task_dir" "$task_id" "$mode"

  # Command-timing summary (spec 0020, "Task Inspection" — 'task timeline'
  # includes the command timing summary). Read-only recompute, never a write;
  # a task with no recorded command-timing events prints nothing extra here
  # (the same honest "not recorded" contract as the timeline itself — 'task
  # commands' below reports that case explicitly).
  specrelay::command_timing::report "$task_dir" "$task_id" "$mode"
}

# specrelay::cli::task_commands <task-ref> [--json]
# Read-only (spec 0020, "Task Inspection"): the agent command-timing ledger
# for one task — slowest observed commands, repeated commands, and
# waiting/polling commands by default; the full per-operation JSON with
# --json. Never mutates task state. A legacy/never-instrumented task is
# reported honestly rather than fabricated.
specrelay::cli::task_commands() {
  local root ref="" as_json=0 task_id task_dir
  root="$(specrelay::cli::require_project_root)" || return 1

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) as_json=1; shift ;;
      -*) specrelay::out::err "unknown option: $1"; return 2 ;;
      *)
        if [ -n "$ref" ]; then specrelay::out::err "too many arguments"; return 2; fi
        ref="$1"; shift ;;
    esac
  done
  if [ -z "$ref" ]; then
    specrelay::out::err "usage: specrelay task commands <task-ref> [--json]"
    return 2
  fi

  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  task_dir="$(specrelay::task::dir "$root" "$task_id")"

  local current mode
  current="$(specrelay::state::canonical "$(specrelay::state::path "$task_dir")" 2>/dev/null || true)"
  case "$current" in
    READY_FOR_HUMAN_REVIEW|BLOCKED) mode=final ;;
    *) mode=partial ;;
  esac

  if [ "$as_json" -eq 1 ]; then
    specrelay::command_timing::report "$task_dir" "$task_id" "$mode" --json
    return 0
  fi

  local blob operation_count
  blob="$(specrelay::command_timing::report "$task_dir" "$task_id" "$mode" --json 2>/dev/null)"
  operation_count="$(printf '%s' "$blob" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("operation_count", 0))' 2>/dev/null)"
  case "$operation_count" in
    ''|0)
      echo "Command timing: not recorded for task '$task_id' (legacy task, or no agent tool calls were observed yet)."
      return 0
      ;;
  esac

  specrelay::command_timing::report "$task_dir" "$task_id" "$mode"
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
    timeline) specrelay::cli::task_timeline "$@" ;;
    commands) specrelay::cli::task_commands "$@" ;;
    "")
      specrelay::out::err "usage: specrelay task <create|show|status|list|approve|requeue|accept|request-changes|block|recover|authorize-submit|timeline|commands>"
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
    models)
      specrelay::cli::cmd_models "$@"
      ;;
    contexts)
      specrelay::cli::cmd_contexts "$@"
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
