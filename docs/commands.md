# SpecRelay Command Reference

SpecRelay is this repository's **only active** workflow engine (SDD 0085B); the
legacy `.ai/` engine is **frozen** (rollback/reference only — see
`architecture.md`, "Legacy engine freeze"). This is the command reference
required by spec section 45.

**Canonical active command set (SDD 0085B, section 2.3).** All new
operator/developer work uses `tools/specrelay/bin/specrelay ...` directly (never
`.ai/scripts/*`):

| Command | Purpose | Exit-code semantics |
|---|---|---|
| `specrelay run <spec-path> [--task-id <id>] [--allow-dirty-baseline]` | Full create→approve→run→review lifecycle | `0`/`1`/`2`/`3`/`4`/`5` (see `run` below) |
| `specrelay resume <task-ref>` | One safe next step on an existing task | `0` step ran; non-zero on error/BLOCKED |
| `specrelay status [<task-ref>]` | Read-only status (one task, or all) | `0` on success; `1` lookup error |
| `specrelay show <task-ref>` | Read-only full detail | `0` on success; `1` lookup error |
| `specrelay task approve <task-ref>` | Human-approval gate → `READY_FOR_EXECUTOR` | `0` transitioned; non-zero refused |
| `specrelay task requeue <task-ref>` | `CHANGES_REQUESTED` → `READY_FOR_EXECUTOR` | `0` transitioned; non-zero refused |
| `specrelay task accept <task-ref>` | `READY_FOR_REVIEW` → `READY_FOR_HUMAN_REVIEW` | `0` transitioned; non-zero refused |
| `specrelay task request-changes <task-ref> "<reason>"` | `READY_FOR_REVIEW` → `CHANGES_REQUESTED` | `0` transitioned; non-zero refused |
| `specrelay task block <task-ref> "<reason>"` | `EXECUTOR_RUNNING` → `BLOCKED` | `0` transitioned; non-zero refused |
| `specrelay task authorize-submit <task-ref>` | Runner-owned `EXECUTOR_RUNNING` → `READY_FOR_REVIEW` | `0` submitted; non-zero refused |
| `specrelay task recover <task-ref> --reason "<reason>" [--to READY_FOR_EXECUTOR]` | SpecRelay-native interrupted-task recovery | `0` recovered; non-zero refused (live owner / wrong state / not owned / no reason) |

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
specrelay task recover <task-ref> --reason "<reason>" [--to READY_FOR_EXECUTOR]
specrelay task authorize-submit <task-ref>
```
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

## Compatibility commands (`.ai/scripts/`) — deprecated wrappers

These public shims survive **only** as deprecated wrappers during the cutover
window (SDD 0085B, section 2.4). They are **not** the supported path for new
work — use `tools/specrelay/bin/specrelay ...` directly. Under the default
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
