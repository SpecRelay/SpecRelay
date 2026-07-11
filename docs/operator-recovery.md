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
.ai-runs/tasks/.specrelay-locks/<task-id>.lock/owner
```

That `owner` file records the holding process's `pid`, `host`, and
`acquired_at`. Reading it is read-only and always safe:

```
cat .ai-runs/tasks/.specrelay-locks/<task-id>.lock/owner
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

## Quick reference

| Situation | Command |
|---|---|
| Check a task's state (read-only) | `specrelay show <task-ref>` |
| Inspect the lock owner (read-only) | `cat .ai-runs/tasks/.specrelay-locks/<task-id>.lock/owner` |
| Recover an interrupted `EXECUTOR_RUNNING` task | `specrelay task recover <task-ref> --reason "…"` |
| Re-run an interrupted reviewer | `specrelay resume <task-ref>` |
| Mark a task that cannot complete | `specrelay task block <task-ref> "<reason>"` |
| Resume refused: incompatible engine version | install matching engine, or `SPECRELAY_ALLOW_ENGINE_MISMATCH=1 specrelay resume <task-ref>` |
| Resume refused: incompatible state schema | install matching engine, or `SPECRELAY_ALLOW_SCHEMA_MISMATCH=1 specrelay resume <task-ref>` |

Never edit `state.json` by hand and never `rm` a task directory or its lock to
recover a task — use the audited commands above so every recovery is recorded.
