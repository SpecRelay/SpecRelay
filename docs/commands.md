# SpecRelay Command Reference

SpecRelay is this repository's **only active** workflow engine (SDD 0085B); the
legacy `.ai/` engine is **frozen** (rollback/reference only — see
`architecture.md`, "Legacy engine freeze"). This is the command reference
required by spec section 45.

**Canonical active command set (SDD 0085B, section 2.3).** All new
operator/developer work uses the `specrelay` CLI directly — `bin/specrelay ...`
from a standalone source checkout, or the installed `specrelay ...` on your
`PATH` — never `.ai/scripts/*`:

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
| `specrelay task timeline <task-ref> [--json]` | Read-only execution-timeline report (spec 0019) | `0` on success; `1` unknown task |
| `specrelay models [<provider>]` | Read-only model-selection guidance for configured automated providers | `0` on success; `1` unknown provider |

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
`run` IS the human approval for that spec — see "Approval semantics" in
`engine-parity.md`), run executor/reviewer rounds until
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
and always logs an explicit reason. Also used by the `run-ai-loop.sh`
compatibility shim.

```
specrelay status [<task-ref>]
specrelay show <task-ref>
specrelay list
```
Read-only. `status` (no arg) lists every task's id/state/iteration;
`status <task-ref>` and `show <task-ref>` give one task's detail (`show` is
richer). `<task-ref>` accepts a full task id, a unique numeric prefix, or a
unique partial slug (e.g. `specrelay show 0084`). These work for tasks
created by either engine (SpecRelay or legacy), never mutate anything.

```
specrelay doctor
```
Read-only readiness diagnostics (added in SDD 0085): git repository
detected, project root, config readable, spec root exists, task runtime
root accessible, executor/reviewer provider availability, context
capability, **Jam capability readiness** (spec 0023 — reported separately from
repository context capabilities; not-configured/configured/registered/
connected/authenticated/tools-available/ready), current engine mode,
compatibility shims installed, rollback engine exists, no conflicting active
engine lock. Returns non-zero if any mandatory check fails — Jam's absence
alone never fails it unless a project sets `jam.required: true`. See
[jam-capability.md](jam-capability.md).

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
specrelay task authorize-submit <task-ref>
specrelay task timeline <task-ref> [--json]
```

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
`authorize-submit` is the manual-recovery equivalent of the legacy
`authorize-submit.sh` for the runner-owned `EXECUTOR_RUNNING` →
`READY_FOR_REVIEW` transition. `block` moves a stuck `EXECUTOR_RUNNING` task
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
workflow location).

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
specrelay run <spec> --verbose
specrelay resume <task> --verbose
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

## Compatibility commands (`.ai/scripts/`) — deprecated wrappers

These public shims survive **only** as deprecated wrappers during the cutover
window (SDD 0085B, section 2.4). They are **not** the supported path for new
work — use the `specrelay` CLI directly (`bin/specrelay ...` from a source
checkout, or the installed `specrelay ...`). Under the default
engine selection each shim delegates unambiguously to the direct CLI below and
propagates its exit code; a shim **never** silently falls back to legacy.
Selecting legacy requires the explicit, rollback-only opt-in
(`SPECRELAY_ENGINE=legacy`). By default they delegate as:

| Compatibility command | Delegates to (default engine) |
|---|---|
| `.ai/scripts/start-spec-task.sh <spec>` | `specrelay run <spec>` |
| `.ai/scripts/show-task.sh <task-ref>` | `specrelay show <task-ref>` |
| `.ai/scripts/approve-task.sh <task-id>` | `specrelay task approve <task-ref>` |
| `.ai/scripts/run-ai-loop.sh <task-id>` | loops `specrelay resume <task-id>` |
| `.ai/scripts/start-ai-task.sh <task-id>` | no safe mapping — refuses cleanly (see `engine-parity.md`) |

## Rollback mode

The legacy engine remains available ONLY as an explicit, temporary rollback
(see `architecture.md`, "H7. Rollback"):

```
SPECRELAY_ENGINE=legacy .ai/scripts/start-spec-task.sh <spec>
# or, equivalently:
.ai/scripts/legacy/start-spec-task.sh <spec>
```

`SPECRELAY_ENGINE` accepts only `specrelay` or `legacy`; any other value is
a hard error (never a silent fallback). With no override, the engine is
read from `.specrelay/config.yml`'s `workflow.current_engine` (default
`specrelay` if the field or file is absent).

## Engine ownership behavior

Every task's `state.json` records which engine owns mutating it
(`"engine": "specrelay"`, or absent for a legacy/pre-0085 task). Read-only
commands (`show`/`status`/`list`, and the legacy `show-task.sh`/
`list-tasks.sh`) work regardless of ownership. Mutating commands on either
engine refuse a task they do not own — see `engine-parity.md`,
"Compatibility cutover (SDD 0085)" for the full evidence table.

## Exit semantics

Compatibility shims propagate the real underlying `specrelay` (or legacy)
exit code unchanged. `specrelay run`'s own exit codes are documented above
under `run`. No command in either engine auto-commits, auto-pushes,
auto-merges, or deploys; reaching `READY_FOR_HUMAN_REVIEW` always requires a
separate human final review.
