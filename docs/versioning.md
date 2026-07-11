# SpecRelay versioning & compatibility

SpecRelay has a single canonical version: the `VERSION` file at the repository
root. Everything else (the changelog, a consumer project's version pin, task
metadata) refers back to that one value.

## Semantic versioning

Versions are `MAJOR.MINOR.PATCH`.

- **MAJOR** — incompatible engine or task/state schema changes. A task created
  by one major version is **not** safely resumable by a different major version.
- **MINOR** — backward-compatible engine features. A task created by an older
  minor version of the same major is safely resumable by a newer minor.
- **PATCH** — backward-compatible fixes.

## Task engine metadata

Every task's `state.json` records, at creation:

```json
{ "engine": "specrelay", "engine_version": "0.4.0", "schema_version": 1 }
```

`engine_version` is the `VERSION` of the engine that created the task. It is
written once, at task creation, and is used for upgrade diagnostics and resume
safety. Historical tasks created before this field existed simply have no
`engine_version`; they are treated as "unknown origin" and are not blocked.

`schema_version` is an integer describing the shape of `state.json` itself
(independent of the human-readable engine version). It is the single source of
truth in `lib/specrelay/py/state_lib.py` (`CURRENT_SCHEMA_VERSION`), written
once at creation, and is what the schema-compatibility guard reasons about (see
below). The current schema version is **1**. Historical tasks created before
this field existed have no `schema_version`; they are treated as an implicit
version 1 and are not blocked.

## Resume / active-task safety

When `specrelay run` resumes an existing task, or `specrelay resume` acts on a
task, the engine compares the task's recorded `engine_version` with its own
`VERSION` and refuses an **unsafe** action rather than silently resuming old
task state with an incompatible engine:

| Situation | Result |
|---|---|
| No recorded `engine_version` (historical task) | allowed (nothing to compare) |
| Same major version | allowed (minor/patch are backward compatible) |
| Different major version | **refused** |
| Task created by a newer engine than the one running | **refused** |

A deliberate, per-invocation override exists for human-driven recovery:

```sh
SPECRELAY_ALLOW_ENGINE_MISMATCH=1 specrelay resume <task>
```

It is never the default, and every use is logged. Read-only inspection
(`specrelay show`, `status`, `list`) is never blocked by this check — only
mutating resume/run.

## Schema compatibility

The task/state schema carries an explicit integer `schema_version`, and is
additive within a major engine version. There is intentionally **no** migration
framework: the guard below stops an unsafe resume rather than transforming old
or unknown state, and asks the operator to install a matching engine version.
This is a guardrail, not an automated migrator.

When `specrelay run` resumes a task, or `specrelay resume` acts on one, the
engine compares the task's recorded `schema_version` with the version it writes
today:

| Situation | Result |
|---|---|
| No recorded `schema_version` (historical task) | allowed (implicit v1) |
| `schema_version` ≤ current | allowed (schema is additive within a major version) |
| `schema_version` > current (unknown future schema) | **refused** |
| Non-integer / unreadable `schema_version` | **refused** |

A refused resume prints an actionable message and the same kind of deliberate,
per-invocation override the engine check uses:

```sh
SPECRELAY_ALLOW_SCHEMA_MISMATCH=1 specrelay resume <task>
```

It is never the default, and every use is logged. As with the engine check,
read-only inspection (`specrelay show`, `status`, `list`) is **never** blocked
by the schema guard — only mutating resume/run. Fields older tasks are missing
are simply absent (`task show` prints them as "none recorded" / implicit
defaults); only the current `state` field is required for a task to be
operable.

## For consuming projects

A consuming project pins the exact engine version it expects (for the incubation
host, in `.specrelay/version`) and verifies the installed engine satisfies that
pin before running a task. See that project's SpecRelay integration
documentation for the host-side pin, bootstrap, and mismatch behavior.
