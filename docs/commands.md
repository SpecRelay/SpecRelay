# SpecRelay Command Reference

This is the command reference for the standalone SpecRelay CLI: `bin/specrelay
...` from a source checkout, or the installed `specrelay ...` on your `PATH`.

| Command | Purpose | Exit-code semantics |
|---|---|---|
| `specrelay run <input-path> [--task-id <id>] [--allow-dirty-baseline]` | Full create→approve→run→review lifecycle (`<input-path>` is a spec file or a specification directory — spec 0023) | `0`/`1`/`2`/`3`/`4`/`5` (see `run` below) |
| `specrelay resume <task-ref>` | Resume an existing task and drive the executor/reviewer loop to a terminal/stop state | `0`/`1`/`2`/`3`/`4`/`5` (same contract as `run`) |
| `specrelay status [<task-ref>]` | Read-only status (one task, or all) | `0` on success; `1` lookup error |
| `specrelay show <task-ref>` | Read-only full detail | `0` on success; `1` lookup error |
| `specrelay task approve <task-ref>` | Human-approval gate → `READY_FOR_EXECUTOR` | `0` transitioned; non-zero refused |
| `specrelay task requeue <task-ref>` | `CHANGES_REQUESTED` → `READY_FOR_EXECUTOR` | `0` transitioned; non-zero refused |
| `specrelay task accept <task-ref>` | `READY_FOR_REVIEW` → `READY_FOR_HUMAN_REVIEW` | `0` transitioned; non-zero refused |
| `specrelay task request-changes <task-ref> "<reason>"` | `READY_FOR_REVIEW` → `CHANGES_REQUESTED` | `0` transitioned; non-zero refused |
| `specrelay task block <task-ref> "<reason>"` | `EXECUTOR_RUNNING` → `BLOCKED` | `0` transitioned; non-zero refused |
| `specrelay task authorize-submit <task-ref>` | Runner-owned `EXECUTOR_RUNNING` → `READY_FOR_REVIEW` | `0` submitted; non-zero refused |
| `specrelay task recover <task-ref> --reason "<reason>" [--to READY_FOR_EXECUTOR]` | SpecRelay-native interrupted-task recovery | `0` recovered; non-zero refused (live owner / wrong state / not owned / no reason) |
| `specrelay task archive <task-ref> [--include-blocked] [--dry-run]` | Move one completed task out of the active runs root into the archive root (reversible; nothing deleted) | `0` archived (or would, `--dry-run`); non-zero refused (non-terminal / live owner / not owned / collision) |
| `specrelay task archive --all [--include-blocked] [--dry-run]` | Move every completed task into the archive root; active tasks left in place | `0` on success; non-zero if any single task was refused |
| `specrelay task timeline <task-ref> [--json]` | Read-only execution-timeline report (spec 0019) | `0` on success; `1` unknown task |
| `specrelay task coordinate <task-ref> --invocation-point <point> [--situation <json>]` | Runs one bounded AI Coordinator round (spec 0025); disabled by default | `0` decision validated/dispatched (or safe fallback); `10` coordinator disabled; non-zero unknown task |
| `specrelay task coordination <task-ref> [--json]` | Read-only coordinator-activity report (spec 0025) | `0` on success (reports "not recorded" honestly if never invoked); `1` unknown task |
| `specrelay models [<provider>]` | Read-only model-selection guidance for configured automated providers | `0` on success; `1` unknown provider |
| `specrelay config show [--effective] [--sources] [--json]` | Read-only local-developer-configuration-overlay status (spec 0027) | `0` valid; `1` invalid local overlay |
| `specrelay config explain <dotted.path>` | Read-only effective-value provenance for one configuration path (spec 0027) | `0` on success; `1` invalid local overlay |
| `specrelay ui plan <task-ref>` | Read-only UI-impact detection, scenario selection, coverage (spec 0028) | `0` on success; `1` invalid config |
| `specrelay ui run <task-ref> [--resume] [--json]` | Executes UI verification scenarios (spec 0028) | `0` all required scenarios PASS; non-zero otherwise |
| `specrelay ui report <task-ref> [--json]` | Read-only recorded UI scenario results | `0` on success |
| `specrelay ui publish <task-ref> <spec-relpath> [--dry-run]` | Publishes reviewed compact UI evidence (spec 0028) | `0` published/shown; `1` refused |
| `specrelay ui clean [--dry-run]` | Removes stale UI runtime evidence for inactive tasks | `0` on success |

## Direct CLI (`bin/specrelay` / installed `specrelay`)

```
specrelay run <input-path> [--task-id <id>] [--allow-dirty-baseline]
```
`<input-path>` is either a single spec file, or a **specification directory**
(spec 0023): `spec.md` (functional authority) plus an optional `tech-spec.md`
/ `tech_spec.md` (technical authority) and recursively-discovered supporting
evidence. Before either role runs, SpecRelay discovers, classifies, and
immutably snapshots the whole bundle, then analyses it into
`02-resolved-specification.md` — see "Specification-bundle analysis phase" in
`docs/task-lifecycle.md`. Full lifecycle for the resulting task: create/resolve
the task, approve it (running
`run` IS the human approval for that spec — see docs/task-lifecycle.md,
section 3), run executor/reviewer rounds until
`READY_FOR_HUMAN_REVIEW`, a `CHANGES_REQUESTED`-only stop (manual reviewer),
`BLOCKED`, a provider failure, or the configured maximum iterations. Exit
codes: `0` success, `1` usage/config/lookup error, `2` reviewer is `manual`
(human action required), `3` `BLOCKED`, `4` provider failure, `5` maximum
iterations reached.

While the executor and reviewer providers run, their output is **streamed live
to the terminal**, prefixed by role and provider (e.g. `[executor:claude]`,
`[reviewer:claude-subagent]`), so you can see progress instead of a silent
wait. Two layers exist: **generic** raw stdout/stderr streaming for every
provider (spec 0003), and — for the `claude` adapter when the installed CLI
advertises `--output-format stream-json` — **semantic live event rendering**
(spec 0006) that shows concise per-step activity such as
`[executor:claude] reading: …` / `command: …` / `result: success`. Semantic
mode also persists the raw event stream to `19`/`20-*-events.jsonl` and extracts
the final assistant text into the numbered stdout files; it falls back honestly
to generic streaming when unavailable (or when `SPECRELAY_SEMANTIC_EVENTS=0`).
The live output is an operator-visibility layer only — the durable evidence
files under the task directory remain the source of truth. See
`docs/providers.md` → "Live provider output streaming" and "Semantic Claude
live event rendering".

```
specrelay resume <task-ref>
```
Resumes an existing task from its persisted state and drives the **same**
executor/reviewer automation loop as `specrelay run`, to the next terminal or
explicit-stop state (never restarts from the beginning). It shares `run`'s
exit-code contract (`0` success, `1` usage/config/lookup error, `2` reviewer is
`manual`, `3` `BLOCKED`, `4` provider failure, `5` maximum iterations).

Because it uses the same loop, resuming a task whose effective reviewer provider
is **not** `manual` continues from `READY_FOR_REVIEW` **into reviewer execution
in the same invocation** and reaches `READY_FOR_HUMAN_REVIEW` — no second manual
`resume` is required (spec 0010). `READY_FOR_REVIEW` is an internal handoff state
for the automated reviewer, not the normal endpoint of a successful run; `resume`
only rests there when the reviewer is `manual` or the automated reviewer fails,
and always logs an explicit reason.

```
specrelay status [<task-ref>]
specrelay show <task-ref>
specrelay list
```
Read-only. `status` (no arg) lists every task's id/state/iteration;
`status <task-ref>` and `show <task-ref>` give one task's detail (`show` is
richer). `<task-ref>` accepts a full task id, a unique numeric prefix, or a
unique partial slug (e.g. `specrelay show 0084`). These work read-only for
any task regardless of its recorded `engine` field (including a task with no
`engine` field at all, e.g. one created before engine-ownership tracking
existed), and never mutate anything.

```
specrelay doctor
```
Read-only readiness diagnostics: git repository detected, project root,
config readable, spec root exists, task runtime root accessible,
executor/reviewer provider availability, context capability, **Jam capability
readiness** (spec 0023 — reported separately from repository context
capabilities; not-configured/configured/registered/connected/authenticated/
tools-available/ready), no conflicting active engine lock. Returns non-zero
if any mandatory check fails — Jam's absence alone never fails it unless a
project sets `jam.required: true`. See [jam-capability.md](jam-capability.md).
`doctor` also reports the verification-policy engine's configuration mode
(new/legacy/absent/invalid), service/check counts, defaults, placement, and
a wasteful-full-suite-placement warning (spec 0026) — see below. It also
reports UI verification readiness separately (spec 0028): enabled/disabled/
auto, provider/browser availability, runtime start-command configuration,
scenario-manifest validity, expected-reference policy, and publication
destination — configuration readiness only, never task-specific runtime
readiness (that is `ui plan`'s job).

```
specrelay verification plan [--level changed|full|flexible]
                             [--phase executor|reviewer|final_gate]
                             [--changed-from <ref>] [--json]
```
Read-only (spec 0026): validates the verification-policy engine
configuration and prints the selected services/checks, dependency-respecting
execution order, and any fallback/risk-rule decision for the given
level/phase — computed from actual changed paths (`git diff --name-status`
against `--changed-from`, default `HEAD`, plus untracked files). Executes no
configured command.

```
specrelay verification run [--level changed|full|flexible]
                            [--phase executor|reviewer|final_gate] [--json]
```
Plans (as above), then executes the selected checks with bounded,
dependency-aware parallelism, writing durable per-check evidence under
`.specrelay-runs/adhoc-verification/` (a project-level, not task-scoped,
scratch directory — the Executor/Reviewer's own in-task run writes into the
task directory instead, via the same engine). Exits non-zero unless the
overall status is `PASSED`/`NOT_REQUIRED`.

```
specrelay ui plan <task-ref>
```
Read-only (spec 0028): shows whether UI runtime verification is required for
this task (detection reasons), selected scenarios, acceptance-criterion
coverage, a runtime-readiness projection, and expected-reference mapping.
Performs no browser execution and writes only `29-ui-verification/plan.json`.

```
specrelay ui run <task-ref> [--resume] [--json]
```
Executes the deterministic UI verification plan: runtime readiness, then
Playwright (or the deterministic fake provider) for each selected scenario,
capturing compact checkpoint-screenshot, console, and network evidence under
`29-ui-verification/`. `--resume` reuses a prior scenario's evidence only
when it was `PASS` and its config/commit/browser/viewport digest still
matches. Exits non-zero unless every required scenario is `PASS`.

```
specrelay ui report <task-ref> [--json]
```
Read-only: shows recorded scenario results and evidence paths from the last
`ui run` (or "UI verification: not recorded" if none has run).

```
specrelay ui publish <task-ref> <spec-relpath> [--dry-run]
```
Publishes only REVIEWED compact UI evidence to `<spec-relpath>/verification/
ui/`. Refuses (even `--dry-run`) when the task's Reviewer evidence file is
missing a `## UI Verification Evidence Review` section or when required
scenarios did not `PASS`. `--dry-run` shows the file list, destination, and
estimated size without any mutation.

```
specrelay ui clean [--dry-run]
```
Removes stale `29-ui-verification/` runtime directories for tasks no longer
in-flight. Never removes published evidence under `verification/ui/`.

```
specrelay models [<provider>]
```
Read-only model-selection guidance (spec 0014), for inspecting the options
**before** editing `roles.<role>.model` in `.specrelay/config.yml`. With no
argument it covers every configured automated provider; with a provider name
(`claude`, `claude-subagent`, `fake`) it inspects that provider only. For each
provider it prints:

- the three supported configuration forms — `model: provider-default`, the
  structured semantic alias (`model:` / `alias: <alias>`), and the structured
  exact model id (`model:` / `id: <provider-model-id>`) — as copyable YAML;
- the provider's **SpecRelay-declared, provider-scoped aliases** (aliases are
  owned by each provider's capability adapter and never cross providers);
- the provider's honest **model discovery** capability: dynamically discovered
  models are listed only when the provider exposes a reliable, non-billable
  list; otherwise the output states plainly that SpecRelay cannot enumerate the
  account's models and points at the provider's own documentation/CLI. A
  discovery *failure* is reported as a discovery problem, distinct from an
  invalid configuration;
- this project's currently configured selections per role, with both the
  configured and the resolved value.

The output is stream-friendly, append-only, copyable, non-interactive, and
usable without color. It performs no billable or remote provider call. The
legacy `claude-subagent` name reuses the `claude` adapter's capability data and
says so. An unknown provider produces an actionable error listing the
configured and supported provider names. `manual` reports that a human performs
the role and model fields are ignored.

```
specrelay contexts [<adapter>]
```
Read-only context-adapter discovery and diagnostics (spec 0015), for
inspecting the options **before** editing `context:` in
`.specrelay/config.yml`. With no argument it lists every adapter known to the
installed SpecRelay version (built-in), each one's availability, and this
project's configured executor/reviewer adapters — a configured-but-unknown
adapter is explicitly marked not usable, never presumed ready because its name
appears in configuration. With an adapter name it prints that adapter's
description, availability, honest capability level (`none`, `preflight`,
`prepared`, `indexed`, `freshness`), capability matrix (preflight, prepare,
durable artifact, role isolation, network requirement, freshness check),
supported roles, and a copyable configuration snippet. An unavailable adapter
reports its reason and states `This adapter was not invoked.`; an unknown
adapter produces guidance listing the known adapters. The output is
non-interactive, append-only, copyable, CI-safe, and color-free, and the
command never performs a billable AI-provider invocation and never runs an
adapter's preflight or preparation. See `context-adapters.md`.

```
specrelay task create <input-path> [--task-id <id>] [--allow-dirty-baseline]
specrelay task show <task-ref>
specrelay task status [<task-ref>]
specrelay task list
specrelay task approve <task-ref>
specrelay task requeue <task-ref>
specrelay task accept <task-ref>
specrelay task request-changes <task-ref> "<reason>"
specrelay task block <task-ref> "<reason>"
specrelay task recover <task-ref> --reason "<reason>" [--to READY_FOR_EXECUTOR]
specrelay task archive <task-ref> [--include-blocked] [--dry-run]
specrelay task archive --all [--include-blocked] [--dry-run]
specrelay task authorize-submit <task-ref>
specrelay task timeline <task-ref> [--json]
specrelay task coordinate <task-ref> --invocation-point <point> [--situation <json>]
specrelay task coordination <task-ref> [--json]
```

`task coordinate` (spec 0025) runs one bounded round of the optional,
disabled-by-default AI Coordinator: it computes the engine's
`allowed_next_actions` for `<point>` (one of `before_executor`,
`executor_completion_failed`, `executor_completed`, `reviewer_completed`,
`changes_requested`, `recovery_requested`, `human_handoff_preparation`),
invokes the configured coordinator provider (bounded retries), validates the
structured decision deterministically, records it durably
(`23-coordinator-decisions.jsonl`/`23-coordinator-state.json`), and dispatches
only the safe, pre-existing transition it validates to (see
[architecture.md](architecture.md)). Exits `10` (not an error) when the
coordinator is disabled. `task coordination` is the read-only counterpart —
it never invokes the coordinator, only reports what has already happened (the
same summary folded into `task show`/`task report`).

`task timeline` (spec 0019) is a **read-only** report: total wall time,
per-phase durations and status, invocation/resume history, the verification
ledger (which test/smoke/doctor/version operations ran, by role, with
duplicate-work detection), the slowest measured phases, and any phase-budget
warnings. It never mutates task state — it recomputes the summary from the
task's own append-only event log
(`<task-runtime-path>/20-execution-events.jsonl`) each time it is invoked. A
legacy task with no recorded timeline data is reported honestly ("not
recorded") rather than fabricated. `--json` prints the same summary as
machine-readable JSON. See
[verification-and-timeline.md](verification-and-timeline.md) for the full
design.
`task show` additionally reports concise bundle provenance when the task has
an input bundle (spec 0023): input kind, original input path, primary
functional/technical specification paths, bundle file count and total size,
external/Jam reference counts, manifest/snapshot/resolved-specification
paths, and integrity status. A task created before spec 0023 reports this
honestly as "not recorded" rather than fabricating it.

Lower-level task lifecycle operations. `create` only creates (state
`DRAFT`); it does not approve or run. `approve` is the human-approval gate
(`DRAFT`/`WAITING_FOR_HUMAN` → `READY_FOR_EXECUTOR`). `requeue`, `accept`,
`request-changes` are normally driven automatically by `run`/`resume`;
`authorize-submit` is the manual-recovery entry point for the runner-owned
`EXECUTOR_RUNNING` → `READY_FOR_REVIEW` transition. `block` moves a stuck
`EXECUTOR_RUNNING` task
to `BLOCKED` when the executor genuinely cannot complete.

`recover` (SDD 0085B, section 3) is the SpecRelay-native way back out of an
**interrupted** `EXECUTOR_RUNNING` task — one whose provider process exited,
was interrupted, or was orphaned — returning it to `READY_FOR_EXECUTOR` so the
executor can be re-run for a fresh iteration. It:

- checks **liveness first**: if a live process still owns the task (its lock
  pid is alive on this host, or the lock is owned on another host that cannot
  be liveness-checked), it **refuses** with a non-zero exit and changes
  nothing (never force-removes a live lock);
- otherwise **safely reclaims a stale lock** (same mechanism as normal lock
  acquisition — a same-host dead pid), never a foreign-host one;
- is **never silent**: it records audited recovery metadata into `state.json`
  (`recovered_at`, `recovered_by`, `recovered_from_state`, `recovery_reason`)
  and prints exactly what it changed;
- **preserves all evidence/artifact files untouched** (it reclaims lifecycle
  state, it does not discard work);
- **never** fabricates success, overwrites evidence, moves a task to
  `READY_FOR_HUMAN_REVIEW`, changes a task's engine/ownership, or recovers a
  task owned by another engine.

`--reason` is required (recovery is always audited). `--to` currently accepts
only `READY_FOR_EXECUTOR`, the sole supported recovery target: because the
reviewer runs **synchronously** under `READY_FOR_REVIEW` (there is no distinct
reviewer-running state — see `architecture.md`, "Reviewer execution model"), an
interrupted reviewer needs no recovery command; it is simply re-run from
`READY_FOR_REVIEW` via `resume`.

```
specrelay project root
specrelay project inspect
```
`root`: prints the discovered project root. `inspect`: read-only summary of
this project's SpecRelay configuration (config presence, project name,
configured spec/task-run roots, validation command, detected legacy
workflow location, and — spec 0027 — the local developer overlay's status
and the effective precedence order).

```
specrelay config show [--effective] [--sources] [--json]
specrelay config explain <dotted.path>
```
Read-only (spec 0027, "Local Developer Configuration Overlay"): inspects the
shared `.specrelay/config.yml` merged with the optional, Git-ignored
`.specrelay/config.local.yml` overlay. `show`: default output is a concise
shared/local/precedence summary; `--sources` adds loaded source paths and
SHA-256 digests; `--effective` adds the fully merged configuration with
secret-shaped values (names ending in token/api_key/secret/password/cookie/
authorization/credential, case-insensitive) redacted; `--json` emits the
machine-readable equivalent. `explain <path>`: reports the final (redacted
if secret-shaped) value for one dotted configuration path, which layer
supplied it (defaults/shared/local/environment), and any lower-priority
value it replaced. Neither command creates a task or modifies a
configuration file.

```
specrelay workflow inspect
```
Read-only summary of the legacy `.ai/` workflow discovered on disk (public
entry points, internal helper root, protocol/reviewer files, task run root,
detected provider integrations).

```
specrelay version
specrelay help | --help | -h
```

## Execution modes and updates (spec 0022)

```
specrelay environment [--json]
```
Read-only. Reports the **execution-mode contract**: `source-local` (a
repository checkout, e.g. `bin/specrelay`) or `installed` (an installed
`specrelay` launcher), the executable/resources in use, and whether automatic
update checks are enabled (always `disabled` for source-local execution — see
"Execution mode detection" below). `--json` gives the machine-readable form.

```
specrelay install-info [--json]
```
Read-only, no network. For an **installed** SpecRelay: version, commit,
executable/resource paths, configured update source, and last-update time,
read from the installation metadata written under the install prefix (never
in a consumer repository). A **source-local** checkout reports that
installed-update metadata is not applicable. Missing/malformed metadata (a
pre-spec-0022 install) is reported as an actionable diagnostic, never a crash
— see [updates.md](updates.md#migrating-an-existing-installation).

```
specrelay update --check
specrelay update [--yes]
specrelay update --from <path>
specrelay update --dry-run
specrelay update --ignore <version>
specrelay update --reset-notifications
```
**Installed mode only** — `bin/specrelay update` (source-local) always
refuses cleanly and explains why, never mutating the repository. `--check` is
read-only discovery that bypasses the 24h cache. Plain `update` discovers the
newest release, asks for confirmation (unless `--yes`), then atomically
stages, verifies, and activates it — preserving the prior installation until
the new one is verified, rolling back automatically if it is not. `--from`
updates from an explicit local SpecRelay source instead of the configured
official source (refuses a dirty source checkout). `--dry-run` shows the plan
without changing anything. `--ignore`/`--reset-notifications` control the
daily-check dismissal state. Full behavior, the daily-check contract, CI
safety, and rollback design are in [updates.md](updates.md).

```
specrelay run <input-path> --verbose
specrelay resume <task-ref> --verbose
```
`--verbose` prints the full execution-timeline/command-timing/agent-efficiency
detail inline, **in addition to** the concise default summary (see
"Summary-first terminal output" below).

```
specrelay task report <task-ref> [--json]
```
Read-only: the combined execution-timeline + command-timing + agent-efficiency
report for one task — the full detail the default summary no longer dumps
automatically. `task timeline`/`task commands`/`task efficiency` remain
available as focused single-topic views.

### Summary-first terminal output

A normal `run`/`resume` now ends with a concise "SpecRelay Result" card
(task, executor/reviewer status+duration, tests, context readiness, active
time, a collapsed warning count) instead of an automatic full telemetry dump.
The Execution Timeline, Verification Ledger, Duplicate Work, Command Timing,
Repeated Agent Commands, Tool Counts, and Agent Efficiency detail blocks are
still fully captured — they are simply no longer printed by default. Use
`--verbose`, or `specrelay task report|timeline|commands|efficiency`, to see
them.

## Release commands (source-local only; spec 0022)

```
bin/specrelay release plan
bin/specrelay release prepare
bin/specrelay release verify
bin/specrelay release tag
```
Manage **this SpecRelay checkout's own** `VERSION`/`CHANGELOG.md`/tags — never
a consumer project's. `plan` is read-only (current version, pending
release-impact metadata from specs after 0022, proposed version, source
task(s)). `prepare` updates `VERSION` and `CHANGELOG.md` for the highest
pending impact and shows the diff; it never commits, tags, or pushes. `verify`
checks semver syntax, monotonic increase, a `CHANGELOG.md` entry, and that
source-local `specrelay version` reports it. `tag` creates the `vX.Y.Z`
annotated tag from a clean, committed tree; it refuses a dirty tree or an
existing tag and never pushes. See [release-process.md](release-process.md)
for the release-impact metadata contract and the pre-1.0 versioning policy.

## Archiving completed tasks

`specrelay task archive` moves completed tasks out of the active runs root
(`tasks.runs_root`) into the archive root (`tasks.archive_root`, default
`.specrelay-runs/archive`) so `task list`/`status` stop showing them. It is a
plain, **reversible move**: the task's directory — `state.json` plus every
numbered artifact and its `iterations/` history — is relocated verbatim and
stamped with `archived_at` / `archived_from_state`; nothing is deleted. To
restore one, move its directory back under `tasks.runs_root`.

- **Completed** means a terminal state: `READY_FOR_HUMAN_REVIEW` (archived by
  default) or `BLOCKED` (archived only with `--include-blocked`, so terminal
  failures are never hidden by accident).
- Archiving **refuses** a task a live process still owns (it never hides an
  in-flight run), a task in any non-terminal state, a task not owned by the
  SpecRelay engine, and never overwrites an existing archived copy.
- `--all` (alias `--completed`) archives every completed task and leaves active
  tasks in place; one task's refusal never aborts the rest.
- `--dry-run` reports exactly what would be archived and mutates nothing.

## Engine ownership behavior

Every task's `state.json` records which engine owns mutating it
(`"engine": "specrelay"`, or absent for a task created before engine-ownership
tracking existed, or by another tool). Read-only commands (`show`/`status`/
`list`) work regardless of ownership. Mutating commands refuse a task they do
not own, naming the reason explicitly.

## Exit semantics

`specrelay run`'s exit codes are documented above under `run`. No command
auto-commits, auto-pushes, auto-merges, or deploys; reaching
`READY_FOR_HUMAN_REVIEW` always requires a separate human final review.

If you are migrating a project away from a former in-host `.ai/scripts/`/
`tools/specrelay/` layout, see docs/migration.md.
