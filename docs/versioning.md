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
{ "engine": "specrelay", "engine_version": "0.4.0" }
```

`engine_version` is the `VERSION` of the engine that created the task. It is
written once, at task creation, and is used for upgrade diagnostics and resume
safety. Historical tasks created before this field existed simply have no
`engine_version`; they are treated as "unknown origin" and are not blocked.

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

The task/state schema is versioned implicitly through the engine's MAJOR
version. There is intentionally **no** migration framework: within a major
version the schema is additive and backward compatible; across a major version
the compatibility check above stops an unsafe resume and asks the operator to
install the matching engine version. This is a guardrail, not an automated
migrator.

## For consuming projects

A consuming project pins the exact engine version it expects (for the incubation
host, in `.specrelay/version`) and verifies the installed engine satisfies that
pin before running a task. See that project's SpecRelay integration
documentation for the host-side pin, bootstrap, and mismatch behavior.
