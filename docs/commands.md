# SpecRelay Command Reference

SpecRelay is this repository's active workflow engine (SDD 0085). This is
the command reference required by spec section 45.

## Direct CLI (`tools/specrelay/bin/specrelay`)

```
specrelay run <spec-path> [--task-id <id>] [--allow-dirty-baseline]
```
Full lifecycle for a spec: create/resolve the task, approve it (running
`run` IS the human approval for that spec — see "Approval semantics" in
`engine-parity.md`), run executor/reviewer rounds until
`READY_FOR_HUMAN_REVIEW`, a `CHANGES_REQUESTED`-only stop (manual reviewer),
`BLOCKED`, a provider failure, or the configured maximum iterations. Exit
codes: `0` success, `1` usage/config/lookup error, `2` reviewer is `manual`
(human action required), `3` `BLOCKED`, `4` provider failure, `5` maximum
iterations reached.

```
specrelay resume <task-ref>
```
Inspects a task's persisted state and runs exactly one safe next step
(never restarts from the beginning). Used internally by `specrelay run`'s
own loop, and by the `run-ai-loop.sh` compatibility shim.

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
capability, current engine mode, compatibility shims installed, rollback
engine exists, no conflicting active engine lock. Returns non-zero if any
mandatory check fails.

```
specrelay task create <spec-path> [--task-id <id>] [--allow-dirty-baseline]
specrelay task show <task-ref>
specrelay task status [<task-ref>]
specrelay task list
specrelay task approve <task-ref>
specrelay task requeue <task-ref>
specrelay task accept <task-ref>
specrelay task request-changes <task-ref> "<reason>"
specrelay task block <task-ref> "<reason>"
specrelay task authorize-submit <task-ref>
```
Lower-level task lifecycle operations. `create` only creates (state
`DRAFT`); it does not approve or run. `approve` is the human-approval gate
(`DRAFT`/`WAITING_FOR_HUMAN` → `READY_FOR_EXECUTOR`). `requeue`, `accept`,
`request-changes` are normally driven automatically by `run`/`resume`;
`authorize-submit` is the manual-recovery equivalent of the legacy
`authorize-submit.sh` for the runner-owned `EXECUTOR_RUNNING` →
`READY_FOR_REVIEW` transition. `block` is the safe recovery path after an
interrupted/crashed executor round (see `docs/dogfood-report.md`, scenario
C).

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

## Compatibility commands (`.ai/scripts/`)

These are supported during the migration phase (spec section 44) and
delegate to the direct CLI above by default:

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
