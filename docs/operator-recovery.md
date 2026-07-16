# SpecRelay Operator Recovery Runbook

A focused runbook for **recovering an interrupted SpecRelay task** — one that
was left `EXECUTOR_RUNNING` after its executor process exited, was interrupted,
or was orphaned. It pairs with the SpecRelay-native `specrelay task recover`
command (SDD 0085B, section 3).

SpecRelay is this repository's **only active** workflow engine; the legacy
`.ai/` engine is frozen (rollback/reference only). Recovery is SpecRelay-native
only — there is no legacy equivalent, and you never edit `state.json` by hand or
`rm` a task directory to "unstick" a task. See also `commands.md` (the command
reference) and `architecture.md` (section "H9. Interrupted-task recovery and
reviewer execution model").

All commands below use the `specrelay` CLI. From a standalone source checkout,
run `bin/specrelay <command> …` at the repository root; with SpecRelay installed
on your `PATH`, run `specrelay <command> …` from anywhere:

```
bin/specrelay <command> …
```

## 1. How to tell a task is interrupted

An interrupted task has **two** properties at once:

1. Its state is `EXECUTOR_RUNNING`, and
2. **no live process still owns it** — the run that claimed it is gone.

Check the state (read-only, never mutates anything):

```
bin/specrelay show <task-ref>
# State: EXECUTOR_RUNNING
```

`<task-ref>` accepts a full task id, a unique numeric prefix, or a unique
partial slug (e.g. `specrelay show 9202b`).

A task sitting in `EXECUTOR_RUNNING` is **not, by itself, proof of a problem** —
a healthy run is `EXECUTOR_RUNNING` while its executor is working. What
distinguishes an *interrupted* task is that the owning process is no longer
alive. SpecRelay tracks the owner in a lock directory:

```
.specrelay-runs/tasks/.specrelay-locks/<task-id>.lock/owner
```

That `owner` file records the holding process's `pid`, `host`, and
`acquired_at`. Reading it is read-only and always safe:

```
cat .specrelay-runs/tasks/.specrelay-locks/<task-id>.lock/owner
# pid=12345
# host=<this-host>
# acquired_at=2026-07-11T11:37:32Z
```

Interpretation:

- **Same host, pid no longer alive** (`kill -0 <pid>` fails) → the task is
  interrupted and safe to recover. SpecRelay classifies this as `stale`.
- **Same host, pid still alive** → a live run still owns it (`live-local`). It is
  **not** interrupted; do not recover it. Let it finish, or stop that process
  first.
- **A different host** → SpecRelay cannot liveness-check another machine, so it
  conservatively treats a foreign-host lock as live (`live-foreign`) and will
  refuse to recover it.
- **No lock directory at all** → nothing owns the task; `recover` can still
  return it to a re-runnable state.

You do not have to make this judgement by hand — `specrelay task recover`
performs exactly this liveness check itself, **before** changing anything, and
refuses when the owner is live (see section 2).

### `EXECUTOR_RUNNING` for a reason other than interruption (spec 0021)

Since the agent execution-efficiency and completion-gate specification (spec
0021), a task can also sit in `EXECUTOR_RUNNING` with **no live owning
process** for a reason that is *not* an interrupted/crashed provider:

- **Completion-gate failure**: the executor process exited **zero**, but
  SpecRelay refused to accept the round as complete because a required
  artifact (`03-executor-log.md` / `07-tests.txt` / `08-executor-summary.md`)
  was missing or empty, or the executor's final output declared unresolved
  background work (e.g. "I will wait for the background task"). The terminal
  prints `Executor Result: INCOMPLETE` (never `SUCCESS`) with the concrete
  reason, and the same reason is recorded in `22-agent-efficiency.json` under
  that round's `completion_gate_reason`.

This is diagnostically different from a genuine provider interruption/crash
(process killed, host rebooted, `specrelay` itself terminated mid-run): the
process actually finished and reported success, but the round's *work* was
incomplete by SpecRelay's own contract. `bin/specrelay task show <task-ref>`
and `bin/specrelay task efficiency <task-ref>` both surface which case you are
in before you decide what to do next — do not assume every `EXECUTOR_RUNNING`
with no live owner is a crash.

Either way, the ordinary recovery command below (`EXECUTOR_RUNNING ->
READY_FOR_EXECUTOR`) is what re-queues the task; spec 0021 intentionally adds
**no** new recovery transition. Recovering does not "submit" or "complete"
anything that was previously incomplete — see section 3 below.

## 2. The recovery command

```
bin/specrelay task recover <task-ref> --reason "<reason>" [--to READY_FOR_EXECUTOR]
```

`--reason` is **required** — recovery is always audited, never silent. Omitting
it is refused before anything is touched. `--to` is optional and currently
accepts only `READY_FOR_EXECUTOR` (its default), the sole supported recovery
target (see section 4 for why the reviewer needs no recovery target).

**What it checks (liveness first).** Before touching anything, it classifies the
lock owner:

- If a **live** process still owns the task — a live pid on this host, or any
  lock owned on another host that cannot be liveness-checked — it **refuses**
  with a non-zero exit and changes nothing:

  ```
  refusing to recover '<task-id>': a live process still owns it (pid <pid> on <host>)
  wait for it to finish, or stop it, before recovering; nothing was changed
  ```

- It also refuses if the task is **not owned by SpecRelay** (`state.json` has no
  `engine: "specrelay"`) or is **not in `EXECUTOR_RUNNING`** (the only supported
  source state). In every refusal case the task's state is left unchanged.

**What it does.** When the owner is stale (a same-host, dead pid) or absent, it:

- safely reclaims the stale lock — the same dead-pid check used by normal lock
  acquisition; it never reclaims a foreign-host lock;
- returns the task from `EXECUTOR_RUNNING` to `READY_FOR_EXECUTOR`, so the
  executor can be re-run for a fresh iteration;
- clears the previous claim stamp so the next executor iteration re-claims
  cleanly;
- releases the lock it reclaimed when it is done.

**What it records.** It writes audited recovery metadata into the task's
`state.json` and prints exactly what it changed (it is never silent):

- `recovered_at` — when recovery happened;
- `recovered_by` — who/what performed it (`specrelay-recover`);
- `recovered_from_state` — the state it recovered from (`EXECUTOR_RUNNING`);
- `recovery_reason` — the `--reason` you supplied.

Example of a successful recovery:

```
$ bin/specrelay task recover 9202b --reason "executor process was orphaned"
Recovered task '9202b-scenario-b-operator-recovery-doc':
  recovered_from_state: EXECUTOR_RUNNING
  new state:            READY_FOR_EXECUTOR
  recovered_at:         2026-07-11T12:05:44Z
  recovered_by:         specrelay-recover
  recovery_reason:      executor process was orphaned
Existing evidence files were preserved untouched.
```

After recovery the task is back in `READY_FOR_EXECUTOR`; re-run it normally with
`specrelay run <spec-path>` or `specrelay resume <task-ref>`.

## 3. What recovery never does

Recovery is deliberately narrow. It **never**:

- **force-removes a live lock** — a live-local or foreign-host owner is refused,
  not overridden;
- **fabricates or overwrites evidence** — all existing evidence/artifact files
  (executor log, tests, summary, git snapshots, reviewer files) are left
  untouched;
- **reaches `READY_FOR_HUMAN_REVIEW`** — recovery only returns a task to
  `READY_FOR_EXECUTOR`; it is not a shortcut past the executor/reviewer loop or
  the human gate;
- **changes a task's engine or ownership** — it refuses tasks not owned by
  SpecRelay and never rewrites the `engine` field.

Because it only ever moves `EXECUTOR_RUNNING → READY_FOR_EXECUTOR`, recovery
cannot skip review or manufacture a "done" state. Human final review remains
mandatory in every case.

## 4. Reviewer interruption

There is **no** distinct reviewer-running state. The reviewer runs
**synchronously** while the task sits in `READY_FOR_REVIEW`. If the reviewer is
interrupted, no state was left half-changed and no recovery command is needed —
simply re-run it from `READY_FOR_REVIEW`:

```
bin/specrelay resume <task-ref>
```

This is exactly why `specrelay task recover --to` supports only
`READY_FOR_EXECUTOR`: an interrupted **executor** needs the recovery command to
get back out of `EXECUTOR_RUNNING`, but an interrupted **reviewer** just gets
re-run from the state it was already in.

**A missing decision marker is not the same thing as an interruption** (spec
0019). If the reviewer provider ran to completion but forgot the final
`DECISION:` line, SpecRelay does not treat that as a crash to resume from
scratch — it attempts one narrow, marker-only corrective read of the
already-written review artifacts first (see
[verification-and-timeline.md](verification-and-timeline.md), "Smart
marker-only recovery"). Only if that is unsafe or fails does the task behave
like an ordinary interrupted/failed reviewer round above.

## 5. When to `block` instead

Recovery assumes the work can be retried. If the executor **genuinely cannot
complete** the task — a missing prerequisite, an impossible or contradictory
requirement, a dependency that will not be resolved — do not loop recovery.
Move the task to `BLOCKED` with a reason:

```
bin/specrelay task block <task-ref> "<reason>"
```

This transitions `EXECUTOR_RUNNING → BLOCKED` and records why, so a human can
decide what to do next. Use `recover` when a healthy task was merely
interrupted; use `block` when the task cannot proceed as specified.

## 6. When a compatibility check refuses a resume

`specrelay run`/`resume` refuse to **mutate** a task whose recorded metadata is
incompatible with the running engine, rather than silently resuming state it may
not understand. Two guards can fire (see `docs/versioning.md`):

- **Engine version** — a different MAJOR version, or a task created by a *newer*
  engine than the one running. Message: `incompatible engine version`.
- **State schema** — a `schema_version` greater than the one this engine writes,
  or an unreadable/non-integer `schema_version`. Message:
  `incompatible state schema`.

Neither guard blocks read-only inspection. When one fires:

1. Inspect the task first — `specrelay show <task-ref>` reports both the
   `Engine version` and `Schema version` it recorded, and never mutates state.
2. Prefer installing the **matching (or newer) engine version** so the task
   resumes under an engine that understands its metadata.
3. Only if you have deliberately decided it is safe, override for that single
   invocation — the override is logged every time:

   ```sh
   SPECRELAY_ALLOW_ENGINE_MISMATCH=1 specrelay resume <task-ref>   # engine guard
   SPECRELAY_ALLOW_SCHEMA_MISMATCH=1 specrelay resume <task-ref>   # schema guard
   ```

Historical tasks with **no** `engine_version`/`schema_version` are treated as
unknown-origin / implicit v1 and are **not** blocked; no action is needed for
them.

### 6a. Verification-policy configuration drift (spec 0026)

A separate, narrower guard applies only to the verification-policy engine
(`verification.services`, spec 0026). The first time a task plans
verification it snapshots a digest of the project's effective configuration
into `verification/effective-config.json` inside the task directory. A
later planning/execution pass **for that same task** refuses — rather than
silently switching policy mid-task — if the project's `verification:`
configuration has since changed:

```text
verification run: refused — the project's verification configuration changed
since this task first captured it at ... — resume refuses to silently switch
policy (spec 0026, section 51); this requires explicit human recovery
```

To recover: either revert the configuration change so it matches what this
task originally captured, or — only if the new policy is intentional for
this task — remove `verification/effective-config.json` from the task
directory to deliberately re-capture the new policy. There is no automatic
override flag for this guard (unlike the engine/schema guards above):
verification-policy drift is a project-configuration decision, not an
engine-compatibility one.

### 6b. Local/shared configuration drift note (spec 0027)

If you edit `.specrelay/config.yml` or `.specrelay/config.local.yml` while a
task is in flight, `resume` never refuses and never silently re-resolves the
change — it always continues with the configuration the task already
captured (`configuration_effective`, recorded the first time the task
reached an executor iteration). This is deliberately looser than the
verification-policy guard in §6a above: there is nothing to recover from,
because the task's provider/model/agent/context/verification settings were
already pinned at capture time and are unaffected either way.

You can tell whether a change is being ignored because `resume` prints an
explicit note when it detects it:

```
[specrelay] note: .specrelay/config.yml or .specrelay/config.local.yml
changed since this task captured its effective configuration; continuing
with the CAPTURED configuration (spec 0027) — create a new task to pick up
the new configuration
```

If you want the new configuration to actually apply, there is no repair
flag or state edit for this (unlike §6a) — start a new task. Inspect what a
task actually captured, and how the merged configuration currently reads,
with `specrelay task show <task-ref>` and `specrelay config show
[--effective] [--sources]`. A task created before spec 0027 (or before its
first executor iteration) reports this honestly as "configuration
provenance: not recorded" rather than fabricating a comparison.

### 6c. UI runtime verification recovery note (spec 0028)

`specrelay task accept` (and the automated Reviewer's ACCEPT path — both go
through the same `transitions.sh::accept`) independently RECOMPUTES whether
UI verification is required, and refuses with an explicit reason when it is
required but incomplete:

```
specrelay: refusing to accept '<task-id>': UI verification completion gate
failed — UI verification is required for this task (specification language
matched UI keyword(s): button, page) but was never run (missing
29-ui-verification/summary.json)
```

To recover: run `specrelay ui plan <task-ref>` to see the detection reasons
and selected scenarios, then `specrelay ui run <task-ref>` until every
required scenario is `PASS`, and ensure the Reviewer's
`09-consultant-review.md` contains a `## UI Verification Evidence Review`
section. There is no override flag — a task explicitly marked UI-impacting
can only satisfy this by producing real evidence, never by configuration.
A resumed `ui run --resume` reuses a scenario's prior evidence only when it
was `PASS` and its recorded config/commit/browser/viewport digest still
matches exactly; anything else reruns automatically. A task with no UI
impact (or UI verification disabled) is entirely unaffected by this gate.

## 7. Coordinator failure and human-decision packets (spec 0025)

The optional, disabled-by-default AI Coordinator (see
[architecture.md](architecture.md), [task-lifecycle.md](task-lifecycle.md))
fails **safely** by design: a coordinator that returns invalid output, times
out, or exhausts its bounded retries never mutates task state, never mints
authorization, never overwrites evidence — it durably records the failure
(`23-coordinator-decisions.jsonl`, `validation_outcome: "invalid"`) and falls
back to the documented policy, almost always `REQUEST_HUMAN_DECISION`.

When that happens, SpecRelay writes `<task-runtime-path>/24-human-decision-
request.md` — inspect it read-only:

```
cat .specrelay-runs/tasks/<task-id>/24-human-decision-request.md
```

It states, in plain language: current task state, what happened, why
automatic progress stopped, the coordinator's (or the fallback policy's)
recommendation, the available human choices and each one's effect, and
relevant evidence paths. It never exposes hidden chain-of-thought.

**Never edit coordinator state artifacts by hand**
(`23-coordinator-decisions.jsonl`, `23-coordinator-state.json`,
`24-human-decision-request.md`) — they are durable evidence, not
configuration. Instead, act on the packet's stated choices using the
ordinary audited commands (`task accept`, `task request-changes`, `task
block`, `task requeue`, ...) exactly as you would without a coordinator.
Inspect coordinator activity read-only at any time with `specrelay task
coordination <task-ref> [--json]` or `specrelay task show <task-ref>`; a task
that never invoked the coordinator reports this honestly as "not recorded".
If the coordinator is misbehaving or you simply do not want it, set
`roles.coordinator.enabled: false` (or omit the section entirely) — existing
deterministic workflow behavior is completely unaffected either way.

## Quick reference

| Situation | Command |
|---|---|
| Check a task's state (read-only) | `specrelay show <task-ref>` |
| Inspect the lock owner (read-only) | `cat .specrelay-runs/tasks/.specrelay-locks/<task-id>.lock/owner` |
| Recover an interrupted `EXECUTOR_RUNNING` task | `specrelay task recover <task-ref> --reason "…"` |
| Re-run an interrupted reviewer | `specrelay resume <task-ref>` |
| Mark a task that cannot complete | `specrelay task block <task-ref> "<reason>"` |
| Resume refused: incompatible engine version | install matching engine, or `SPECRELAY_ALLOW_ENGINE_MISMATCH=1 specrelay resume <task-ref>` |
| Resume refused: incompatible state schema | install matching engine, or `SPECRELAY_ALLOW_SCHEMA_MISMATCH=1 specrelay resume <task-ref>` |
| Coordinator requested a human decision | `cat .specrelay-runs/tasks/<task-id>/24-human-decision-request.md`, then act via the ordinary task commands |
| Inspect coordinator activity (read-only) | `specrelay task coordination <task-ref> [--json]` |

Never edit `state.json` by hand and never `rm` a task directory or its lock to
recover a task — use the audited commands above so every recovery is recorded.
