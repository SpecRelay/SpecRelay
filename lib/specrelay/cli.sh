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
  config show [--effective] [--sources] [--json]
                         Read-only (spec 0027): local developer configuration
                         overlay status. Default: concise shared/local/
                         precedence summary. --sources: loaded source paths
                         and digests. --effective: merged effective
                         configuration with secret-shaped values redacted.
                         --json: machine-readable equivalent. Never creates a
                         task or modifies a configuration file.
  config explain <dotted.path>
                         Read-only (spec 0027): reports the final (redacted
                         if secret-shaped) effective value for a dotted
                         configuration path, which layer supplied it
                         (defaults/shared/local/environment), and any
                         lower-priority value it replaced.
  workflow inspect       Print a read-only summary of the former in-host AI
                         workflow (no longer supported), if still present on
                         disk, to assist migration.
  doctor                 Read-only readiness diagnostics: git repo, config,
                         spec root, task runtime root, executor/reviewer
                         provider availability, role model selection
                         (configured/resolved/validation level), context
                         capability, and conflicting active-lock detection.
                         Exits non-zero if any mandatory check fails.
  verification plan [--level changed|full|flexible] [--phase executor|reviewer|final_gate]
                         [--changed-from <ref>] [--json]
                         Read-only (spec 0026): validates the verification-
                         policy engine configuration and shows selected
                         services/checks, dependency order, and fallback/
                         risk-rule decisions for the given level/phase.
                         Performs NO verification command execution.
  verification run [--level changed|full|flexible] [--phase executor|reviewer|final_gate]
                         [--changed-from <ref>] [--json]
                         Plans (as above) THEN executes the selected checks
                         with bounded, dependency-aware parallelism, writing
                         durable per-check evidence under the current
                         directory's .specrelay-verification/ scratch area
                         (or, when run from inside 'run'/'resume', under the
                         task's own runtime directory). Exits non-zero when
                         the overall verification status is not PASSED/
                         NOT_REQUIRED.
  ui plan <task-ref>     Read-only (spec 0028): shows whether UI runtime
                         verification is required for this task (detection
                         reasons), selected scenarios, acceptance-criterion
                         coverage, runtime-readiness projection, and expected-
                         reference mapping. Performs no browser execution.
  ui run <task-ref> [--resume] [--json]
                         Executes the deterministic UI verification plan
                         (starts/connects to the runtime, runs Playwright or
                         the deterministic fake provider, captures compact
                         screenshot/console/network evidence) and writes
                         runtime evidence under the task's own
                         29-ui-verification/ directory. Exits non-zero unless
                         every required scenario is PASS.
  ui report <task-ref> [--json]
                         Read-only: shows recorded scenario results and
                         evidence paths from the last 'ui run'.
  ui publish <task-ref> <spec-relpath> [--dry-run]
                         Publishes only REVIEWED compact UI evidence under
                         <spec-relpath>/verification/ui/. Refuses when the
                         Reviewer's UI Verification Evidence Review section is
                         missing or when required scenarios did not PASS.
                         --dry-run shows the file list/destination/size
                         without mutation.
  ui clean [--dry-run]   Removes stale 29-ui-verification/ runtime directories
                         for tasks no longer in-flight. Never touches
                         published evidence under verification/ui/.
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
  environment [--json]  Execution-mode contract (spec 0022): source-local vs
                         installed, the executable/resources in use, and
                         whether automatic update checks are enabled.
  install-info [--json] Read-only installation detail for an INSTALLED
                         SpecRelay: version, commit, executable/resource
                         paths, update source, and last-update time. A
                         source-local checkout reports that installed-update
                         metadata is not applicable. Never mutates, never
                         touches the network.

Updates (installed execution only; spec 0022):
  update --check         Read-only discovery: installed vs. available
                         version, bypassing the 24h cache. Never mutates.
  update [--yes]         Discover, confirm (or --yes), atomically stage,
                         verify, and activate the newest release. Prints the
                         installed version/commit as proof. Rolls back
                         automatically if post-activation verification fails.
  update --from <path>   Update from an explicit local SpecRelay source
                         checkout instead of the configured official source.
                         Refuses a dirty source checkout.
  update --dry-run       Shows the update plan without changing anything.
  update --ignore <ver>  Never offer this exact version again (a later
                         version is still offered).
  update --reset-notifications
                         Clears cached update-check/dismissal state.
  bin/specrelay never performs automatic update discovery — only an
  installed 'specrelay' launcher does, at most once per 24h before 'run'/
  'resume', and never in a non-interactive session (see docs/updates.md).

Release (source-local only; spec 0022):
  release plan            Read-only: current VERSION, pending release-impact
                         metadata from specs after 0022, proposed version,
                         and source task(s). No mutation.
  release prepare         Updates VERSION and CHANGELOG.md for the highest
                         pending release-impact bump and shows the diff.
                         Never commits, tags, or pushes.
  release verify          Verifies semantic-version syntax, monotonic
                         increase, a CHANGELOG.md entry for the new version,
                         and that source-local 'specrelay version' reports it.
  release tag             Creates the vX.Y.Z annotated tag from a clean
                         working tree. Refuses a dirty tree or an existing
                         tag. Never pushes.

Workflow engine:
  run <input-path> [--task-id <id>] [--allow-dirty-baseline] [--verbose]
                         <input-path> is a single spec file OR a
                         specification directory (spec.md + tech-spec.md/
                         tech_spec.md + supporting evidence; spec 0023).
                         Run the full lifecycle for it: create/resolve
                         the task, approve it, run executor/reviewer rounds
                         until READY_FOR_HUMAN_REVIEW, CHANGES_REQUESTED-only
                         (manual reviewer), BLOCKED, a provider failure, or
                         the configured maximum iterations. Ends with a
                         concise operator-summary card by default (spec
                         0022); --verbose also prints the full execution
                         timeline, command timing, and agent-efficiency
                         detail inline.
  resume <task-ref> [--verbose]
                         Resume an existing task from its persisted state and
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

  task create <input-path> [--task-id <id>] [--allow-dirty-baseline]
                         Create a new task from a spec file OR specification
                         directory (spec DRAFT); does NOT approve or run it.
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
                             transition.
  task archive <task-ref> [--include-blocked] [--dry-run]
  task archive --all [--include-blocked] [--dry-run]
                             Move completed tasks out of the active runs root
                             into the archive root (default
                             .specrelay-runs/archive), preserving every
                             artifact — a reversible move, nothing is deleted.
                             READY_FOR_HUMAN_REVIEW is archived by default;
                             BLOCKED only with --include-blocked. Refuses a
                             task a live process still owns or that is not
                             owned by SpecRelay; --all leaves active tasks in
                             place; --dry-run mutates nothing.
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
  task efficiency <task-ref> [--json]
                             Read-only agent execution-efficiency and
                             completion-gate report (spec 0021): observable
                             operations by category (exploration/
                             implementation/verification/waiting/artifact-
                             writing), the completion-gate result per role,
                             unjustified repeated verification, and
                             post-verification timing. Never mutates task
                             state. A legacy/never-instrumented task is
                             reported honestly as not recorded.
  task report <task-ref> [--json]
                             Read-only (spec 0022): the combined execution
                             timeline, command-timing, and agent-efficiency
                             report for one task — the full detail a normal
                             run's concise operator summary no longer dumps
                             automatically. Never mutates task state.

<task-ref> accepts a full task id, a unique numeric prefix, or a unique
partial slug (e.g. 'specrelay show 0084').

A task's own "engine" field records which engine owns mutating it; read-only
commands (show/status/list) work regardless, but mutating commands refuse a
task they do not own.

See the bundled README.md and docs/ (architecture, configuration, providers,
context-adapters, task-lifecycle, installation) for background. If you are
migrating a project away from a former in-host `.ai/scripts/`/
`tools/specrelay/` layout, see docs/migration.md.
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

  # Local developer configuration overlay (spec 0027, section 16.1). Reported
  # regardless of whether the shared config exists, since a project can be
  # inspected either way; never prints a secret value.
  local local_status
  if ! specrelay::config::local_exists "$root"; then
    local_status="not present"
  elif specrelay::config::effective_ok "$root"; then
    local_status="loaded"
  else
    local_status="invalid"
  fi
  echo "Shared configuration: .specrelay/config.yml"
  echo "Local overlay: .specrelay/config.local.yml ($local_status)"
  echo "Effective precedence: defaults < shared < local < environment < CLI"

  local ai_root
  ai_root="$(specrelay::discovery::ai_root "$root")"
  if [ -n "$ai_root" ]; then
    echo "Detected legacy AI workflow location (no longer supported): $ai_root"
  else
    echo "Detected legacy AI workflow location (no longer supported): (none found)"
  fi

  return 0
}

specrelay::cli::workflow_inspect() {
  local root
  root="$(specrelay::cli::require_project_root)" || return 1

  local runs_root_configured=""
  if specrelay::config::exists "$root"; then
    specrelay::config::validate "$root" || return 1
    runs_root_configured="$(specrelay::config::get "$root" "tasks.runs_root" ".specrelay-runs/tasks")"
  fi

  local ai_root
  ai_root="$(specrelay::discovery::ai_root "$root")"
  if [ -z "$ai_root" ]; then
    echo "No legacy AI workflow detected under: $root/.ai"
    return 0
  fi

  echo "Legacy AI workflow root (no longer supported): $ai_root"

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

# --- execution mode / installation (spec 0022) ------------------------------

# specrelay::cli::_update_checks_enabled -> "enabled" or "disabled", honoring
# SPECRELAY_UPDATE_CHECK=0 (spec 5.9). Only meaningful in installed mode.
specrelay::cli::_update_checks_enabled() {
  case "${SPECRELAY_UPDATE_CHECK:-1}" in
    0) printf 'disabled\n' ;;
    *) printf 'enabled\n' ;;
  esac
}

# specrelay::cli::cmd_environment <home> [--json]
specrelay::cli::cmd_environment() {
  local home="$1"; shift
  local as_json=0
  case "${1:-}" in
    --json) as_json=1 ;;
    "") ;;
    *) specrelay::out::err "usage: specrelay environment [--json]"; return 2 ;;
  esac

  local mode executable resources update_checks
  mode="$(specrelay::execution_mode::detect "$home")"
  executable="$(specrelay::execution_mode::executable_path "$home")"
  resources="$(specrelay::execution_mode::resource_path "$home")"
  if [ "$mode" = "installed" ]; then
    local meta_exe
    meta_exe="$(specrelay::install_metadata::read_field "$home" executable_path 2>/dev/null)"
    [ -n "$meta_exe" ] && executable="$meta_exe"
    update_checks="$(specrelay::cli::_update_checks_enabled)"
  else
    update_checks="disabled"
  fi

  if [ "$as_json" -eq 1 ]; then
    EXEC_MODE="$mode" EXECUTABLE="$executable" RESOURCES="$resources" UPDATE_CHECKS="$update_checks" \
      python3 -c '
import json, os
d = {
    "execution_mode": os.environ["EXEC_MODE"],
    "executable": os.environ["EXECUTABLE"],
    "resources": os.environ["RESOURCES"],
    "update_checks": os.environ["UPDATE_CHECKS"],
}
if os.environ["EXEC_MODE"] == "installed":
    d["check_interval_hours"] = 24
print(json.dumps(d, indent=2, sort_keys=True))
'
    return 0
  fi

  echo "SpecRelay environment"
  echo "  Execution mode: $mode"
  echo "  Executable:     $executable"
  echo "  Resources:      $resources"
  echo "  Update checks:  $update_checks"
  [ "$mode" = "installed" ] && echo "  Check interval: 24h"
  return 0
}

# specrelay::cli::cmd_install_info <home> [--json]
# Read-only, no mutation, no network (spec section 3).
specrelay::cli::cmd_install_info() {
  local home="$1"; shift
  local as_json=0
  case "${1:-}" in
    --json) as_json=1 ;;
    "") ;;
    *) specrelay::out::err "usage: specrelay install-info [--json]"; return 2 ;;
  esac

  local mode
  mode="$(specrelay::execution_mode::detect "$home")"

  if [ "$mode" = "source-local" ]; then
    if [ "$as_json" -eq 1 ]; then
      printf '{\n  "mode": "source-local",\n  "note": "installed update metadata is not applicable to a source-local checkout"\n}\n'
      return 0
    fi
    echo "SpecRelay installation: source-local"
    echo "This is a repository checkout (bin/specrelay). It always runs the current"
    echo "working tree and has no installed-update metadata — that only exists for an"
    echo "installed 'specrelay' launcher. See docs/updates.md."
    return 0
  fi

  local version commit resources update_type update_repo update_ref installed_at exe meta_ok=1
  if ! specrelay::install_metadata::validate "$home" >/dev/null 2>&1; then
    meta_ok=0
  fi
  version="$(specrelay::install_metadata::read_field "$home" installed_version 2>/dev/null)"
  commit="$(specrelay::install_metadata::read_field "$home" installed_commit 2>/dev/null)"
  exe="$(specrelay::install_metadata::read_field "$home" executable_path 2>/dev/null)"
  resources="$(specrelay::install_metadata::read_field "$home" resource_path 2>/dev/null)"
  update_type="$(specrelay::install_metadata::read_field "$home" update_source.type 2>/dev/null)"
  update_repo="$(specrelay::install_metadata::read_field "$home" update_source.repository 2>/dev/null)"
  update_ref="$(specrelay::install_metadata::read_field "$home" update_source.ref 2>/dev/null)"
  installed_at="$(specrelay::install_metadata::read_field "$home" installed_at 2>/dev/null)"
  [ -n "$exe" ] || exe="$(specrelay::execution_mode::executable_path "$home")"
  [ -n "$resources" ] || resources="$home"

  if [ "$as_json" -eq 1 ]; then
    META_OK="$meta_ok" VERSION="$version" COMMIT="$commit" EXE="$exe" RES="$resources" \
      UPDATE_TYPE="$update_type" UPDATE_REPO="$update_repo" UPDATE_REF="$update_ref" INSTALLED_AT="$installed_at" \
      python3 -c '
import json, os
print(json.dumps({
    "mode": "installed",
    "metadata_present": os.environ["META_OK"] == "1",
    "version": os.environ.get("VERSION", ""),
    "commit": os.environ.get("COMMIT", ""),
    "executable": os.environ.get("EXE", ""),
    "resources": os.environ.get("RES", ""),
    "update_source": {
        "type": os.environ.get("UPDATE_TYPE", ""),
        "repository": os.environ.get("UPDATE_REPO", ""),
        "ref": os.environ.get("UPDATE_REF", ""),
    },
    "installed_at": os.environ.get("INSTALLED_AT", ""),
}, indent=2, sort_keys=True))
'
    return 0
  fi

  local last_update="${installed_at:-(unknown)}"
  case "$last_update" in
    *T*Z) last_update="$(printf '%s' "$last_update" | sed 's/T/ /; s/Z$/ UTC/')" ;;
  esac

  if [ "$meta_ok" -eq 0 ]; then
    specrelay::out::card yellow "SpecRelay Installation" \
      "$(printf '%-16s%s' "Mode" "installed")" \
      "$(printf '%-16s%s' "Executable" "$exe")" \
      "$(printf '%-16s%s' "Resources" "$resources")" \
      "Installation metadata is missing or malformed." \
      "Reinstall from an official source to restore it (see docs/updates.md#migration)."
    return 0
  fi

  specrelay::out::card blue "SpecRelay Installation" \
    "$(printf '%-16s%s' "Mode" "installed")" \
    "$(printf '%-16s%s' "Executable" "$exe")" \
    "$(printf '%-16s%s' "Version" "${version:-(unknown)}")" \
    "$(printf '%-16s%s' "Commit" "${commit:-(unknown)}")" \
    "$(printf '%-16s%s' "Resources" "$resources")" \
    "$(printf '%-16s%s' "Update source" "${update_type:-(unknown)}${update_repo:+ $update_repo}${update_ref:+ ($update_ref)}")" \
    "$(printf '%-16s%s' "Last update" "$last_update")"
  return 0
}

# specrelay::cli::cmd_update <home> [args...]
# Explicit update commands (spec 0022, section 4). Installed mode only —
# source-local execution refuses every form here without mutating anything
# (spec 1.1, 4.6).
specrelay::cli::cmd_update() {
  local home="$1"; shift

  if specrelay::execution_mode::is_source_local "$home"; then
    echo "specrelay update: not applicable to a source-local checkout."
    echo "bin/specrelay always runs the current repository working tree; there is"
    echo "nothing installed here to update. Installed-update operations only apply"
    echo "to an installed 'specrelay' launcher — see docs/updates.md."
    return 1
  fi

  local check=0 dry_run=0 yes=0 from="" ignore_version="" reset=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) check=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      --yes) yes=1; shift ;;
      --from) [ "$#" -ge 2 ] || { specrelay::out::err "--from requires a value"; return 2; }
              from="$2"; shift 2 ;;
      --ignore) [ "$#" -ge 2 ] || { specrelay::out::err "--ignore requires a value"; return 2; }
                ignore_version="$2"; shift 2 ;;
      --reset-notifications) reset=1; shift ;;
      *) specrelay::out::err "unknown 'update' option: $1"; return 2 ;;
    esac
  done

  if [ "$reset" -eq 1 ]; then
    specrelay::update_state::reset "$home"
    echo "Update notification state cleared."
    return 0
  fi
  if [ -n "$ignore_version" ]; then
    specrelay::update_state::set_ignored "$home" "$ignore_version"
    echo "Version $ignore_version will not be offered again (later versions still will be)."
    return 0
  fi

  local installed_version bin_target
  installed_version="$(tr -d '[:space:]' < "$home/VERSION" 2>/dev/null)"
  bin_target="$(specrelay::install_metadata::read_field "$home" executable_path 2>/dev/null)"
  [ -n "$bin_target" ] && [ -x "$bin_target" ] || bin_target="$(specrelay::execution_mode::executable_path "$home")"

  local available="" commit="" source_desc="" cloned_dir="" repo=""
  if [ -n "$from" ]; then
    if [ ! -d "$from" ]; then
      specrelay::out::err "update: --from path does not exist: $from"
      return 1
    fi
    # Structural validity is checked BEFORE dirtiness: a path that is not a
    # SpecRelay source at all should be reported as that (not misreported as
    # "dirty" merely because it sits inside some ancestor Git repository).
    local pair
    pair="$(specrelay::update_discovery::from_path "$from")" || {
      specrelay::out::err "update: '$from' does not look like a valid SpecRelay source checkout (missing VERSION, bin/specrelay, or lib/specrelay)"
      return 1
    }
    if [ -d "$from/.git" ] && specrelay::update_discovery::is_dirty "$from"; then
      specrelay::out::err "update: --from source '$from' has uncommitted changes; refusing (a dirty checkout is never reset or overwritten — commit or stash first)"
      return 1
    fi
    available="${pair%% *}"
    commit="${pair#* }"
    source_desc="$from (explicit --from)"
  else
    local ref
    repo="$(specrelay::install_metadata::read_field "$home" update_source.repository 2>/dev/null)"
    ref="$(specrelay::install_metadata::read_field "$home" update_source.ref 2>/dev/null)"
    if [ -z "$repo" ]; then
      specrelay::out::err "update: no update source is configured in installation metadata, and no --from was given"
      [ "$check" -eq 1 ] && specrelay::update_state::write "$home" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "" "" "failure"
      return 1
    fi
    source_desc="$repo (official-git, ref ${ref:-main})"
    local pair
    if ! pair="$(specrelay::update_discovery::from_tags "$repo")"; then
      specrelay::out::err "update: could not discover a release from $repo (network, git, or tag lookup failure)"
      [ "$check" -eq 1 ] && specrelay::update_state::write "$home" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "" "" "failure"
      return 1
    fi
    available="${pair%% *}"
    commit="${pair#* }"
  fi

  if [ "$check" -eq 1 ]; then
    echo "Installed version: $installed_version"
    echo "Available version: $available"
    specrelay::update_state::write "$home" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$available" \
      "$(specrelay::update_state::read_field "$home" ignored_version "")" "success"
    if specrelay::semver::gt "$available" "$installed_version"; then
      echo "An update is available."
    else
      echo "Already up to date."
    fi
    return 0
  fi

  if ! specrelay::semver::gt "$available" "$installed_version"; then
    echo "Already up to date (installed $installed_version; latest known is $available)."
    return 0
  fi

  if [ "$dry_run" -eq 1 ]; then
    echo "Update plan (dry run — nothing will be changed):"
    echo "  Current installation: $installed_version at $home"
    echo "  Selected source:      $source_desc"
    echo "  Proposed version:     $available (commit ${commit:-unknown})"
    echo "  Installation areas:   $home (lib, templates, VERSION, docs, README.md)"
    echo "  Verification steps:   staged payload check, launcher probe, post-activation re-verify"
    echo "  Activation:           would occur only if all verification steps pass"
    return 0
  fi

  if [ "$yes" -ne 1 ]; then
    if [ -t 0 ] && [ -t 1 ]; then
      printf 'Update %s -> %s. Proceed? [y/N] ' "$installed_version" "$available"
      local reply=""
      read -r reply || reply=""
      case "$reply" in
        y|Y|yes|Yes|YES) : ;;
        *) echo "Update declined."; return 1 ;;
      esac
    else
      specrelay::out::err "update: refusing to update without confirmation in a non-interactive session; pass --yes"
      return 1
    fi
  fi

  local stage_source="$from"
  if [ -z "$stage_source" ]; then
    cloned_dir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-update-src.XXXXXX")"
    if ! git clone --quiet --depth 1 --branch "v$available" "$repo" "$cloned_dir" >/dev/null 2>&1; then
      specrelay::out::err "update: could not fetch tag v$available from the update source ($repo)"
      rm -rf "$cloned_dir"
      return 1
    fi
    stage_source="$cloned_dir"
  fi

  local metadata_repo="${from:-$repo}"
  local rc=0
  specrelay::update::perform "$home" "$bin_target" "$stage_source" "$available" "$commit" "$metadata_repo" || rc=1
  [ -n "$cloned_dir" ] && rm -rf "$cloned_dir"
  return "$rc"
}

specrelay::cli::unimplemented() {
  local cmd="$1"
  specrelay::out::err "command '$cmd' is not implemented."
  echo "$SPECRELAY_UNIMPLEMENTED_MESSAGE" >&2
  return 1
}

# specrelay::cli::_maybe_daily_update_check <home> <cmd> <args...>
# Cached (<=1/24h), read-only-unless-accepted update discovery before an
# operational command (spec 0022, section 5). Installed mode only; disabled
# entirely for source-local execution (spec 1.1). Never prompts and never
# blocks in a non-interactive session (5.7); a discovery failure is always
# non-blocking (5.8). On an ACCEPTED interactive update it re-executes the
# exact original command exactly once (5.5, loop prevention via
# SPECRELAY_UPDATE_REEXEC) and does not return to the caller.
specrelay::cli::_maybe_daily_update_check() {
  local home="$1" cmd="$2"; shift 2

  specrelay::execution_mode::is_installed "$home" || return 0
  [ "${SPECRELAY_UPDATE_CHECK:-1}" != "0" ] || return 0
  [ -z "${SPECRELAY_UPDATE_REEXEC:-}" ] || return 0
  specrelay::update_state::should_check "$home" || return 0

  local repo
  repo="$(specrelay::install_metadata::read_field "$home" update_source.repository 2>/dev/null)"
  [ -n "$repo" ] || return 0

  local now installed_version pair available commit
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  installed_version="$(tr -d '[:space:]' < "$home/VERSION" 2>/dev/null)"

  if ! pair="$(specrelay::update_discovery::from_tags "$repo")"; then
    specrelay::update_state::write "$home" "$now" "" \
      "$(specrelay::update_state::read_field "$home" ignored_version "")" "failure"
    if [ ! -t 0 ] || [ ! -t 1 ]; then
      specrelay::out::err "update check failed (network or source unavailable); continuing with $installed_version"
    fi
    return 0
  fi
  available="${pair%% *}"
  commit="${pair#* }"
  specrelay::update_state::write "$home" "$now" "$available" \
    "$(specrelay::update_state::read_field "$home" ignored_version "")" "success"

  specrelay::semver::gt "$available" "$installed_version" || return 0

  local ignored
  ignored="$(specrelay::update_state::read_field "$home" ignored_version "")"
  [ "$available" != "$ignored" ] || return 0

  if [ ! -t 0 ] || [ ! -t 1 ]; then
    specrelay::out::err "an update is available: $installed_version -> $available (run 'specrelay update' to install it, or 'specrelay update --ignore $available' to silence this)"
    return 0
  fi

  specrelay::out::card yellow "SpecRelay Update Available" \
    "$(printf '%-10s%s' Installed "$installed_version")" \
    "$(printf '%-10s%s' Available "$available")"
  printf 'Update before running this task? [y/N] '
  local reply=""
  read -r reply || reply=""
  case "$reply" in
    y|Y|yes|Yes|YES)
      local bin_target cloned_dir
      bin_target="$(specrelay::install_metadata::read_field "$home" executable_path 2>/dev/null)"
      [ -n "$bin_target" ] && [ -x "$bin_target" ] || bin_target="$(specrelay::execution_mode::executable_path "$home")"
      cloned_dir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-update-src.XXXXXX")"
      if git clone --quiet --depth 1 --branch "v$available" "$repo" "$cloned_dir" >/dev/null 2>&1 \
        && specrelay::update::perform "$home" "$bin_target" "$cloned_dir" "$available" "$commit" "$repo" >&2; then
        rm -rf "$cloned_dir"
        specrelay::out::log "[specrelay] update installed; re-running the original command"
        SPECRELAY_UPDATE_REEXEC=1 exec "$0" "$cmd" "$@"
      fi
      rm -rf "$cloned_dir"
      specrelay::out::err "update failed; continuing with the current installation ($installed_version)"
      return 0
      ;;
    *)
      specrelay::update_state::set_ignored "$home" "$available"
      return 0
      ;;
  esac
}

# --- shared option parsing for run / task create ----------------------------
# specrelay::cli::_parse_run_args <argv...>
# Prints four lines on success: spec, task-id-override (may be empty),
# allow-dirty (0|1), verbose (0|1).
specrelay::cli::_parse_run_args() {
  local spec="" task_id_override="" allow_dirty=0 verbose=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task-id)
        [ "$#" -ge 2 ] || { specrelay::out::err "--task-id requires a value"; return 2; }
        task_id_override="$2"; shift 2 ;;
      --allow-dirty-baseline)
        allow_dirty=1; shift ;;
      --verbose)
        verbose=1; shift ;;
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
    specrelay::out::err "an <input-path> (spec file or specification directory) is required"
    return 2
  fi
  printf '%s\n%s\n%s\n%s\n' "$spec" "$task_id_override" "$allow_dirty" "$verbose"
}

# --- workflow engine commands ------------------------------------------------

specrelay::cli::cmd_run() {
  local root parsed spec task_id_override allow_dirty verbose
  root="$(specrelay::cli::require_project_root)" || return 1
  parsed="$(specrelay::cli::_parse_run_args "$@")" || return 2
  spec="$(printf '%s\n' "$parsed" | sed -n '1p')"
  task_id_override="$(printf '%s\n' "$parsed" | sed -n '2p')"
  allow_dirty="$(printf '%s\n' "$parsed" | sed -n '3p')"
  verbose="$(printf '%s\n' "$parsed" | sed -n '4p')"
  specrelay::workflow::run "$root" "$spec" "$task_id_override" "$allow_dirty" "$verbose"
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

# --- verification-policy engine CLI (spec 0026, section 34) -----------------

specrelay::cli::_parse_verification_args() {
  local level="" phase="" from_ref="HEAD" as_json=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --level) level="${2:?--level requires a value}"; shift 2 ;;
      --level=*) level="${1#*=}"; shift ;;
      --phase) phase="${2:?--phase requires a value}"; shift 2 ;;
      --phase=*) phase="${1#*=}"; shift ;;
      --changed-from) from_ref="${2:?--changed-from requires a value}"; shift 2 ;;
      --changed-from=*) from_ref="${1#*=}"; shift ;;
      --json) as_json=1; shift ;;
      *) specrelay::out::err "unknown option: $1"; return 2 ;;
    esac
  done
  case "$level" in ""|changed|full|flexible) ;; *) specrelay::out::err "invalid --level: $level (must be changed, full, or flexible)"; return 2 ;; esac
  case "$phase" in ""|executor|reviewer|final_gate) ;; *) specrelay::out::err "invalid --phase: $phase (must be executor, reviewer, or final_gate)"; return 2 ;; esac
  printf '%s\n%s\n%s\n%s\n' "$level" "$phase" "$from_ref" "$as_json"
}

specrelay::cli::cmd_verification_plan() {
  local root parsed level phase from_ref as_json changed_json
  root="$(specrelay::cli::require_project_root)" || return 1
  parsed="$(specrelay::cli::_parse_verification_args "$@")" || return 2
  level="$(printf '%s\n' "$parsed" | sed -n '1p')"
  phase="$(printf '%s\n' "$parsed" | sed -n '2p')"
  from_ref="$(printf '%s\n' "$parsed" | sed -n '3p')"
  as_json="$(printf '%s\n' "$parsed" | sed -n '4p')"

  changed_json="$(specrelay::verification_policy::changed_paths "$root" "$from_ref")"
  local -a extra=()
  [ "$as_json" -eq 1 ] && extra+=(--json)
  specrelay::verification_policy::plan "$root" "$phase" "$level" "$changed_json" "" ${extra[@]+"${extra[@]}"}
}

# specrelay::cli::cmd_verification_run <flags>
# A project-level (not task-scoped) manual entrypoint (spec section 34: "add
# an execution command only if it fits existing CLI architecture cleanly").
# Writes durable evidence under a single reusable adhoc scratch directory
# rather than a numbered task directory, since there is no task context here.
specrelay::cli::cmd_verification_run() {
  local root parsed level phase from_ref as_json changed_json scratch_dir
  root="$(specrelay::cli::require_project_root)" || return 1
  parsed="$(specrelay::cli::_parse_verification_args "$@")" || return 2
  level="$(printf '%s\n' "$parsed" | sed -n '1p')"
  phase="$(printf '%s\n' "$parsed" | sed -n '2p')"
  from_ref="$(printf '%s\n' "$parsed" | sed -n '3p')"
  as_json="$(printf '%s\n' "$parsed" | sed -n '4p')"

  changed_json="$(specrelay::verification_policy::changed_paths "$root" "$from_ref")"
  scratch_dir="$root/.specrelay-runs/adhoc-verification"
  mkdir -p "$scratch_dir"
  local -a extra=()
  [ "$as_json" -eq 1 ] && extra+=(--json)
  specrelay::verification_runner::run "$root" "$scratch_dir" "adhoc" 1 "$phase" "$level" "$changed_json" '[]' ${extra[@]+"${extra[@]}"}
}

# --- UI runtime verification CLI (spec 0028, section 34) --------------------

specrelay::cli::cmd_ui_plan() {
  local root task_id as_json=0 ref=""
  root="$(specrelay::cli::require_project_root)" || return 1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) as_json=1; shift ;;
      -*) specrelay::out::err "unknown option: $1"; return 2 ;;
      *) [ -n "$ref" ] && { specrelay::out::err "too many arguments"; return 2; }; ref="$1"; shift ;;
    esac
  done
  [ -n "$ref" ] || { specrelay::out::err "usage: specrelay ui plan <task-ref> [--json]"; return 2; }
  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  local -a extra=()
  [ "$as_json" -eq 1 ] && extra+=(--json)
  specrelay::ui_verification::plan "$root" "$task_id" ${extra[@]+"${extra[@]}"}
}

specrelay::cli::cmd_ui_run() {
  local root task_id ref="" resume=0 as_json=0
  root="$(specrelay::cli::require_project_root)" || return 1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --resume) resume=1; shift ;;
      --json) as_json=1; shift ;;
      -*) specrelay::out::err "unknown option: $1"; return 2 ;;
      *) [ -n "$ref" ] && { specrelay::out::err "too many arguments"; return 2; }; ref="$1"; shift ;;
    esac
  done
  [ -n "$ref" ] || { specrelay::out::err "usage: specrelay ui run <task-ref> [--resume] [--json]"; return 2; }
  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  local -a extra=()
  [ "$resume" -eq 1 ] && extra+=(--resume)
  [ "$as_json" -eq 1 ] && extra+=(--json)
  specrelay::ui_verification::run "$root" "$task_id" ${extra[@]+"${extra[@]}"}
}

specrelay::cli::cmd_ui_report() {
  local root task_id ref="" as_json=0
  root="$(specrelay::cli::require_project_root)" || return 1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) as_json=1; shift ;;
      -*) specrelay::out::err "unknown option: $1"; return 2 ;;
      *) [ -n "$ref" ] && { specrelay::out::err "too many arguments"; return 2; }; ref="$1"; shift ;;
    esac
  done
  [ -n "$ref" ] || { specrelay::out::err "usage: specrelay ui report <task-ref> [--json]"; return 2; }
  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  local -a extra=()
  [ "$as_json" -eq 1 ] && extra+=(--json)
  specrelay::ui_verification::report "$root" "$task_id" ${extra[@]+"${extra[@]}"}
}

specrelay::cli::cmd_ui_publish() {
  local root task_id ref="" spec_rel="" dry_run=0
  root="$(specrelay::cli::require_project_root)" || return 1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      -*) specrelay::out::err "unknown option: $1"; return 2 ;;
      *)
        if [ -z "$ref" ]; then ref="$1";
        elif [ -z "$spec_rel" ]; then spec_rel="$1";
        else specrelay::out::err "too many arguments"; return 2; fi
        shift ;;
    esac
  done
  [ -n "$ref" ] && [ -n "$spec_rel" ] || { specrelay::out::err "usage: specrelay ui publish <task-ref> <spec-relpath> [--dry-run]"; return 2; }
  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  local -a extra=()
  [ "$dry_run" -eq 1 ] && extra+=(--dry-run)
  specrelay::ui_verification::publish "$root" "$task_id" "$spec_rel" ${extra[@]+"${extra[@]}"}
}

specrelay::cli::cmd_ui_clean() {
  local root dry_run=0
  root="$(specrelay::cli::require_project_root)" || return 1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      *) specrelay::out::err "unknown option: $1"; return 2 ;;
    esac
  done
  local -a extra=()
  [ "$dry_run" -eq 1 ] && extra+=(--dry-run)
  specrelay::ui_verification::clean "$root" ${extra[@]+"${extra[@]}"}
}

specrelay::cli::cmd_resume() {
  local root ref="" verbose=0 task_id
  root="$(specrelay::cli::require_project_root)" || return 1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --verbose) verbose=1; shift ;;
      -*) specrelay::out::err "unknown option: $1"; return 2 ;;
      *)
        if [ -n "$ref" ]; then specrelay::out::err "too many arguments"; return 2; fi
        ref="$1"; shift ;;
    esac
  done
  [ -n "$ref" ] || { specrelay::out::err "usage: specrelay resume <task-ref> [--verbose]"; return 2; }
  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  specrelay::workflow::resume "$root" "$task_id" "$verbose"
}

specrelay::cli::_task_dir_for_ref() {
  local root="$1" ref="$2" task_id
  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  specrelay::task::dir "$root" "$task_id"
}

specrelay::cli::task_create() {
  local root parsed spec task_id_override allow_dirty input_kind spec_abs spec_rel task_id
  root="$(specrelay::cli::require_project_root)" || return 1
  parsed="$(specrelay::cli::_parse_run_args "$@")" || return 2
  spec="$(printf '%s\n' "$parsed" | sed -n '1p')"
  task_id_override="$(printf '%s\n' "$parsed" | sed -n '2p')"
  allow_dirty="$(printf '%s\n' "$parsed" | sed -n '3p')"

  parsed="$(specrelay::task::resolve_input_path "$root" "$spec")" || return 1
  input_kind="$(printf '%s\n' "$parsed" | sed -n '1p')"
  spec_abs="$(printf '%s\n' "$parsed" | sed -n '2p')"
  spec_rel="${spec_abs#"$root"/}"
  if [ -n "$task_id_override" ]; then
    task_id="$task_id_override"
  else
    task_id="$(specrelay::task::id_from_input_path "$spec_abs" "$input_kind")"
  fi
  if ! specrelay::task::valid_id "$task_id"; then
    specrelay::out::err "could not derive a safe task id from input path: $spec"
    return 1
  fi

  local staging
  staging="$(specrelay::workflow::stage_input "$root" "$input_kind" "$spec_abs")" || return 1
  if ! specrelay::transitions::create "$root" "$task_id" "$spec_rel" "$allow_dirty"; then
    rm -rf "$staging"
    return 1
  fi
  specrelay::workflow::commit_staged_input "$root" "$task_id" "$spec_abs" "$staging"
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

  specrelay::cli::_task_show_bundle_summary "$task_dir"
  specrelay::cli::_task_show_timeline_summary "$task_dir"
  specrelay::verification_policy::report "$task_dir"
  specrelay::coordinator::report_text "$task_dir"
}

# specrelay::cli::_task_show_bundle_summary <task-dir>
# Concise bundle provenance (spec 0023, section 20). A task created before
# spec 0023 has no manifest — that is reported honestly, never fabricated.
specrelay::cli::_task_show_bundle_summary() {
  local task_dir="$1" manifest
  manifest="$task_dir/01-input-manifest.json"
  if [ ! -f "$manifest" ]; then
    echo "Input bundle: not recorded (task created before spec 0023, or file-based legacy layout)"
    return 0
  fi
  MANIFEST="$manifest" python3 -c '
import json, os
with open(os.environ["MANIFEST"], encoding="utf-8") as fh:
    m = json.load(fh)
print("Input kind: " + str(m.get("input_kind")))
print("Original input path: " + str(m.get("original_input_path")))
print("Primary functional specification: " + str(m.get("primary_functional_specification_path") or "(none)"))
print("Technical specification: " + str(m.get("technical_specification_path") or "(none)"))
print("Bundle file count: " + str(m.get("bundle_file_count")))
print("Bundle total size: " + str(m.get("bundle_total_size")) + " bytes")
ext = m.get("external_evidence", [])
jam = [e for e in ext if e.get("provider") == "jam"]
print("External reference count: " + str(len(ext)))
print("Jam reference count: " + str(len(jam)))
'
  echo "Manifest path: ${task_dir}/01-input-manifest.json"
  echo "Snapshot path: ${task_dir}/01-input-bundle/"
  local resolved_path="$task_dir/02-resolved-specification.md"
  if [ -s "$resolved_path" ]; then
    echo "Resolved specification path: $resolved_path"
    echo "Analysis status: complete"
  else
    echo "Resolved specification path: (missing or empty)"
    echo "Analysis status: incomplete"
  fi
  if specrelay::bundle::verify_snapshot "$task_dir" >/dev/null 2>&1; then
    echo "Integrity status: verified (manifest digests match snapshot)"
  else
    echo "Integrity status: FAILED (manifest/snapshot digest mismatch)"
  fi
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
  specrelay::cli::_task_full_report "timeline" "$@"
}

# specrelay::cli::task_report <task-ref> [--json]
# Spec 0022, section 7.3: the single explicit-inspection command that shows
# the FULL detail (execution timeline, command timing, agent efficiency) a
# normal run's concise operator summary no longer dumps automatically. Same
# read-only report 'task timeline' has always produced — a distinct command
# name because the default terminal output no longer hints at "timeline"
# specifically as the place to look for full detail.
specrelay::cli::task_report() {
  specrelay::cli::_task_full_report "report" "$@"
}

specrelay::cli::_task_full_report() {
  local usage_cmd="$1"; shift
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
    specrelay::out::err "usage: specrelay task $usage_cmd <task-ref> [--json]"
    return 2
  fi

  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  task_dir="$(specrelay::task::dir "$root" "$task_id")"

  if [ "$as_json" -eq 1 ]; then
    if [ "$usage_cmd" = "report" ]; then
      # 'task report --json' combines all three read-only reports into one
      # object (spec 0022, section 7.3) — 'task timeline --json' keeps its
      # existing single-report contract unchanged.
      local current mode
      current="$(specrelay::state::canonical "$(specrelay::state::path "$task_dir")" 2>/dev/null || true)"
      case "$current" in
        READY_FOR_HUMAN_REVIEW|BLOCKED) mode=final ;;
        *) mode=partial ;;
      esac
      TIMELINE_JSON="$(specrelay::timeline::report "$root" "$task_dir" "$task_id" "$mode" --json 2>/dev/null)" \
      COMMANDS_JSON="$(specrelay::command_timing::report "$task_dir" "$task_id" "$mode" --json 2>/dev/null)" \
      EFFICIENCY_JSON="$(specrelay::agent_efficiency::report "$task_dir" "$task_id" "$mode" --json 2>/dev/null)" \
      COORDINATOR_JSON="$(specrelay::coordinator::report_json "$task_dir" 2>/dev/null)" \
      VERIFICATION_JSON="$(specrelay::verification_policy::report_json "$task_dir" 2>/dev/null)" \
      TASK_ID="$task_id" python3 -c '
import json, os

def load(name):
    raw = os.environ.get(name, "")
    if not raw:
        return {"recorded": False}
    try:
        return json.loads(raw)
    except ValueError:
        return {"recorded": False}

print(json.dumps({
    "task_id": os.environ["TASK_ID"],
    "timeline": load("TIMELINE_JSON"),
    "command_timing": load("COMMANDS_JSON"),
    "agent_efficiency": load("EFFICIENCY_JSON"),
    "coordinator": load("COORDINATOR_JSON"),
    "verification": load("VERIFICATION_JSON"),
}, indent=2, sort_keys=True))
'
      return 0
    fi
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
    if [ "$usage_cmd" = "report" ]; then
      echo "Task report: not recorded for task '$task_id' (legacy task, or no invocation has run yet)."
      # Verification-policy (spec 0026) and coordinator activity (spec 0025,
      # section 33) are both independent of execution-timeline recording — a
      # task may have either without ever having run an Executor/Reviewer
      # round yet.
      specrelay::verification_policy::report "$task_dir"
      specrelay::coordinator::report_text "$task_dir"
    else
      echo "Execution timeline: not recorded for task '$task_id' (legacy task, or no invocation has run yet)."
    fi
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

  # Agent-efficiency summary (spec 0021, "Task Inspection" — extend 'task
  # timeline' to include the efficiency summary). Read-only recompute, never
  # a write; a task with no recorded completion-gate/command-timing evidence
  # at all reports "not recorded" via 'task efficiency' instead of here.
  specrelay::agent_efficiency::report "$task_dir" "$task_id" "$mode"

  # Verification-policy engine summary (spec 0026). Honest "not recorded"
  # for a task that never ran the engine (legacy/historical task).
  specrelay::verification_policy::report "$task_dir"

  # Coordinator activity summary (spec 0025, section 33). Honest "not
  # recorded" for a task that never invoked the coordinator.
  specrelay::coordinator::report_text "$task_dir"
}

# specrelay::cli::task_efficiency <task-ref> [--json]
# Read-only (spec 0021, "Task Inspection"): the agent execution-efficiency
# and completion-gate report for one task. Never mutates task state. A
# legacy/never-instrumented task is reported honestly rather than fabricated.
specrelay::cli::task_efficiency() {
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
    specrelay::out::err "usage: specrelay task efficiency <task-ref> [--json]"
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
    specrelay::agent_efficiency::report "$task_dir" "$task_id" "$mode" --json
    return 0
  fi

  local blob recorded
  blob="$(specrelay::agent_efficiency::report "$task_dir" "$task_id" "$mode" --json 2>/dev/null)"
  recorded="$(printf '%s' "$blob" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
roles = d.get("roles") or {}
any_recorded = any(
    (r.get("completion_gate") not in (None, "not_recorded")) or (r.get("observable_operations") or 0) > 0
    for r in roles.values()
)
print("yes" if any_recorded else "no")' 2>/dev/null)"
  if [ "$recorded" != "yes" ]; then
    echo "Agent efficiency: not recorded for task '$task_id' (legacy task, or no invocation has run yet)."
    return 0
  fi

  specrelay::agent_efficiency::report "$task_dir" "$task_id" "$mode"
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

# specrelay::cli::task_archive [<task-ref>] [--all] [--include-blocked] [--dry-run]
# Move completed (terminal-state) tasks out of the active runs root into the
# archive root, preserving every artifact. Two modes:
#   * a single <task-ref> — archive exactly that task;
#   * --all (alias --completed) — archive every completed task, leaving active
#     tasks in place; one task's refusal never aborts the rest.
# READY_FOR_HUMAN_REVIEW is archived by default; BLOCKED only with
# --include-blocked. --dry-run reports what would happen and mutates nothing.
specrelay::cli::task_archive() {
  local root ref="" all=0 include_blocked=0 dry_run=0
  root="$(specrelay::cli::require_project_root)" || return 1

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all|--completed) all=1; shift ;;
      --include-blocked) include_blocked=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      -*)
        specrelay::out::err "unknown option: $1"; return 2 ;;
      *)
        if [ -n "$ref" ]; then
          specrelay::out::err "too many arguments"; return 2
        fi
        ref="$1"; shift ;;
    esac
  done

  if [ -n "$ref" ] && [ "$all" = "1" ]; then
    specrelay::out::err "specify EITHER a task ref OR --all, not both"
    return 2
  fi
  if [ -z "$ref" ] && [ "$all" != "1" ]; then
    specrelay::out::err "usage: specrelay task archive <task-ref> [--include-blocked] [--dry-run]"
    specrelay::out::err "   or: specrelay task archive --all [--include-blocked] [--dry-run]"
    return 2
  fi

  # Single-task mode.
  if [ -n "$ref" ]; then
    local task_id
    task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
    specrelay::archive::task "$root" "$task_id" "$include_blocked" "$dry_run"
    return $?
  fi

  # Bulk mode: archive every completed task; active tasks are left in place, and
  # a single task's refusal (e.g. a live owner) never aborts the rest.
  local id state archived=0 skipped=0 rc=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    state="$(specrelay::state::canonical "$(specrelay::state::path "$(specrelay::task::dir "$root" "$id")")")"
    if ! specrelay::archive::is_archivable_state "$state" "$include_blocked"; then
      skipped=$((skipped + 1))
      continue
    fi
    if specrelay::archive::task "$root" "$id" "$include_blocked" "$dry_run"; then
      archived=$((archived + 1))
    else
      rc=1
    fi
  done < <(specrelay::task::list_ids "$root")

  local verb="Archived"
  [ "$dry_run" = "1" ] && verb="Would archive"
  if [ "$archived" = "0" ]; then
    echo "No completed tasks to archive ($skipped active task(s) left in place)."
  else
    echo "$verb $archived task(s); $skipped active task(s) left in place."
  fi
  return "$rc"
}

# specrelay::cli::task_coordination <task-ref> [--json]
# Read-only (spec 0025, section 33): a dedicated coordinator-activity report,
# distinct from (and identical in content to) the coordinator summary already
# folded into 'task show'/'task report'. Never mutates task state. A task
# that never invoked the coordinator reports "not recorded" honestly.
specrelay::cli::task_coordination() {
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
    specrelay::out::err "usage: specrelay task coordination <task-ref> [--json]"
    return 2
  fi

  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  task_dir="$(specrelay::task::dir "$root" "$task_id")"

  if [ "$as_json" -eq 1 ]; then
    specrelay::coordinator::report_json "$task_dir"
    return 0
  fi
  specrelay::coordinator::report_text "$task_dir"
}

# specrelay::cli::task_coordinate <task-ref> --invocation-point <point>
#     [--situation <json>] [--scenario <fake-scenario>]
# Runs ONE bounded AI Coordinator round for a task (spec 0025). This is the
# ONLY CLI entrypoint that actually invokes the coordinator; every mutation
# it can cause still goes exclusively through
# specrelay::coordinator::dispatch's pre-existing, independently-guarded
# transition functions (never a direct state.json edit). Requires
# roles.coordinator.enabled: true — a disabled coordinator is reported, not
# an error (spec section 32).
specrelay::cli::task_coordinate() {
  local root ref="" invocation_point="" situation="{}" scenario="valid_request_human" task_id
  root="$(specrelay::cli::require_project_root)" || return 1

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --invocation-point) invocation_point="${2:?--invocation-point requires a value}"; shift 2 ;;
      --situation) situation="${2:?--situation requires a JSON value}"; shift 2 ;;
      --scenario) scenario="${2:?--scenario requires a value}"; shift 2 ;;
      -*) specrelay::out::err "unknown option: $1"; return 2 ;;
      *)
        if [ -n "$ref" ]; then specrelay::out::err "too many arguments"; return 2; fi
        ref="$1"; shift ;;
    esac
  done
  if [ -z "$ref" ] || [ -z "$invocation_point" ]; then
    specrelay::out::err "usage: specrelay task coordinate <task-ref> --invocation-point <point> [--situation <json>] [--scenario <fake-scenario>]"
    return 2
  fi

  task_id="$(specrelay::task::resolve_ref "$root" "$ref")" || return 1
  specrelay::coordinator::invoke "$SPECRELAY_HOME" "$root" "$task_id" "$invocation_point" "$situation" "$scenario"
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
    archive) specrelay::cli::task_archive "$@" ;;
    authorize-submit) specrelay::cli::task_authorize_submit "$@" ;;
    timeline) specrelay::cli::task_timeline "$@" ;;
    commands) specrelay::cli::task_commands "$@" ;;
    efficiency) specrelay::cli::task_efficiency "$@" ;;
    report) specrelay::cli::task_report "$@" ;;
    coordinate) specrelay::cli::task_coordinate "$@" ;;
    coordination) specrelay::cli::task_coordination "$@" ;;
    "")
      specrelay::out::err "usage: specrelay task <create|show|status|list|approve|requeue|accept|request-changes|block|recover|archive|authorize-submit|timeline|commands|efficiency|report|coordinate|coordination>"
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
    config)
      local root
      root="$(specrelay::cli::require_project_root)" || return 1
      case "${1:-}" in
        show)
          shift
          specrelay::config::cmd_show "$root" "$@"
          ;;
        explain)
          shift
          specrelay::config::cmd_explain "$root" "${1:-}"
          ;;
        "")
          specrelay::out::err "usage: specrelay config <show|explain>"
          return 2
          ;;
        *)
          specrelay::out::err "unknown 'config' subcommand: $1"
          return 2
          ;;
      esac
      ;;
    run)
      specrelay::cli::_maybe_daily_update_check "$home" run "$@"
      specrelay::cli::cmd_run "$@"
      ;;
    resume)
      specrelay::cli::_maybe_daily_update_check "$home" resume "$@"
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
    verification)
      case "${1:-}" in
        plan)
          shift
          specrelay::cli::cmd_verification_plan "$@"
          ;;
        run)
          shift
          specrelay::cli::cmd_verification_run "$@"
          ;;
        "")
          specrelay::out::err "usage: specrelay verification <plan|run>"
          return 2
          ;;
        *)
          specrelay::out::err "unknown 'verification' subcommand: $1"
          return 2
          ;;
      esac
      ;;
    ui)
      case "${1:-}" in
        plan) shift; specrelay::cli::cmd_ui_plan "$@" ;;
        run) shift; specrelay::cli::cmd_ui_run "$@" ;;
        report) shift; specrelay::cli::cmd_ui_report "$@" ;;
        publish) shift; specrelay::cli::cmd_ui_publish "$@" ;;
        clean) shift; specrelay::cli::cmd_ui_clean "$@" ;;
        "")
          specrelay::out::err "usage: specrelay ui <plan|run|report|publish|clean>"
          return 2
          ;;
        *)
          specrelay::out::err "unknown 'ui' subcommand: $1"
          return 2
          ;;
      esac
      ;;
    models)
      specrelay::cli::cmd_models "$@"
      ;;
    contexts)
      specrelay::cli::cmd_contexts "$@"
      ;;
    environment)
      specrelay::cli::cmd_environment "$home" "$@"
      ;;
    install-info)
      specrelay::cli::cmd_install_info "$home" "$@"
      ;;
    update)
      specrelay::cli::cmd_update "$home" "$@"
      ;;
    release)
      case "${1:-}" in
        plan) specrelay::release::plan "$home" ;;
        prepare) specrelay::release::prepare "$home" ;;
        verify) specrelay::release::verify "$home" ;;
        tag) specrelay::release::tag "$home" ;;
        "")
          specrelay::out::err "usage: specrelay release <plan|prepare|verify|tag>"
          return 2
          ;;
        *)
          specrelay::out::err "unknown 'release' subcommand: $1"
          return 2
          ;;
      esac
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
