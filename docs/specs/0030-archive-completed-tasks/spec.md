# Spec 0030 — Archive Completed Tasks

## 1. Status

```yaml
status: proposed
```

## 2. Release metadata

```yaml
release:
  impact: minor
  rationale: Adds a backward-compatible `specrelay task archive` command that moves completed (terminal-state) tasks out of the active runs root into a separate archive root, preserving every artifact. Purely additive; no existing behavior, state, or on-disk layout changes.
```

## 3. Task identity

```yaml
task_id: 0030-archive-completed-tasks
```

## 4. Objective

Give operators a first-class, safe, reversible way to move **completed** tasks
out of the active runs root so `specrelay task list` / `status` stop showing
them, without deleting any evidence.

A "completed" task is one in a terminal lifecycle state:

- `READY_FOR_HUMAN_REVIEW` — the automated reviewer accepted and the task is at
  the human final gate (the normal end of a successful run); archived by
  default.
- `BLOCKED` — a terminal failure the pipeline could not complete; archived only
  on explicit opt-in, so failures are never hidden by accident.

Archiving is a plain **move** of the whole task directory (`state.json` plus
every numbered artifact and its `iterations/` history) into a separate archive
root. Nothing is deleted; restoring a task is a move back under the runs root.

## 5. Background

SpecRelay keeps durable per-task run state under `tasks.runs_root` (default
`.specrelay-runs/tasks`). `specrelay task list` / `status` enumerate every
directory there that contains a `state.json`
(`specrelay::task::list_ids`). Over a project's life this accumulates dozens of
finished tasks, so the active list becomes cluttered with tasks that are done.

There is no bulk-cleanup command today. The only existing use of the word
"archive" in the engine is the **per-round** archiving *inside* a single task
(`specrelay::transitions::_archive_round` → `iterations/round-<N>/`), which is
unrelated to this feature. This spec adds a **task-level** archive.

## 6. Product decision

Add `specrelay task archive`, with two modes:

```text
specrelay task archive <task-ref> [--include-blocked] [--dry-run]
specrelay task archive --all       [--include-blocked] [--dry-run]
```

- **Single mode** (`<task-ref>`): archive exactly that task. A full id, a unique
  numeric prefix, or a unique partial slug resolves it (same
  `specrelay::task::resolve_ref` semantics as every other task command).
- **Bulk mode** (`--all`, alias `--completed`): archive every completed task;
  active tasks are left in place, and one task's refusal never aborts the rest.
- Supplying both a `<task-ref>` and `--all`, or neither, is a usage error.

Flags:

- `--include-blocked` — also archive `BLOCKED` tasks (both modes). Without it,
  `BLOCKED` is refused.
- `--dry-run` — report exactly what would be archived and mutate nothing.

## 7. Archive location

- New configuration key `tasks.archive_root` (relative path), default
  `.specrelay-runs/archive`.
- It MUST be **outside** `tasks.runs_root` so archived tasks are never
  re-discovered by `specrelay::task::list_ids`. The default is a sibling of the
  default runs root.
- An archived task lands at `<archive_root>/<task-id>`.

## 8. Safety requirements

Archiving MUST refuse (non-zero, nothing changed) when:

1. the task is in any **non-terminal** state (only `READY_FOR_HUMAN_REVIEW`, and
   `BLOCKED` with `--include-blocked`, qualify);
2. a **live** process still owns the task — lock liveness `live-local` or
   `live-foreign` (`specrelay::lock::owner_liveness`); an in-flight task is
   never archived out from under a run, and a live lock is never force-removed;
3. the task is **not owned** by the SpecRelay engine (`engine != "specrelay"`),
   mirroring the ownership contract every other mutating command enforces;
4. an archived copy already exists at the destination (never overwrite).

A **stale** (dead-owner) lock on a terminal task is meaningless and is removed
as part of archiving; a live lock is refused per (2).

## 9. Provenance

Before moving, the engine stamps the task's `state.json` with:

- `archived_at` — UTC ISO-8601 timestamp;
- `archived_from_state` — the terminal state at archive time.

This is a metadata merge (`specrelay::state::set`), **not** a lifecycle
transition: the task keeps its terminal state, so a restored task reads exactly
as it did before archiving.

## 10. Output and exit semantics

- Single mode: prints `archived <id> (<state>) -> <dest>` (or
  `would archive …` under `--dry-run`); exit `0` on success, non-zero on any
  refusal.
- Bulk mode: prints one line per archived task plus a summary
  (`Archived N task(s); M active task(s) left in place.`); exit `0` when every
  candidate succeeded, non-zero if any single task was refused.
- No command auto-commits, pushes, or deletes anything.

## 11. Backward compatibility

Purely additive. No existing command, state name, transition, or on-disk layout
changes. Projects with no `tasks.archive_root` configured get the default. A
task created before this feature archives identically (the provenance fields are
simply added on archive).

## 12. Implementation surface

- `lib/specrelay/archive.sh` — `specrelay::archive::root`,
  `specrelay::archive::is_archivable_state`, `specrelay::archive::task`.
- `bin/specrelay` — source `archive.sh` after `transitions.sh`.
- `lib/specrelay/cli.sh` — `specrelay::cli::task_archive`, dispatch entry, usage.
- `docs/commands.md`, `docs/configuration.md`, `docs/task-lifecycle.md` — docs.
- `test/archive_test.sh` — full behavior + safety coverage.
