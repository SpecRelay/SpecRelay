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
{ "engine": "specrelay", "engine_version": "0.5.0", "schema_version": 1 }
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

## Releases and Git tags

`VERSION` is the single source of truth; a Git tag is a *reviewed snapshot* of a
particular `VERSION`. The policy below answers the release questions raised in
spec 0007 (section 5).

- **Is the current version releasable as-is?** The engine at `0.5.0` is
  functionally ready as a baseline: `scripts/test` passes, `bin/specrelay
  doctor` reports a clear result, and `bin/specrelay version` reports the
  expected value. **Publication (pushing a release tag) is nonetheless blocked**
  until the open-source license is chosen and committed (see `LICENSE.TODO` and
  `docs/publication.md`). Being *tag-ready* is not the same as *published*.
- **What should the first public tag be?** `v0.5.0`, matching `VERSION` — see
  "Release-impact metadata and release commands"
  ([release-process.md](release-process.md)) for how future bumps beyond this
  baseline are planned and prepared. This remains a human decision to publish.
- **When should `VERSION` be bumped?** Following the semantic-versioning rules
  above, and *before* tagging a release that contains changes since the last
  tag: PATCH for backward-compatible fixes, MINOR for backward-compatible
  features, MAJOR for incompatible engine/state-schema changes. Do not bump
  `VERSION` for docs-only or CI-only changes that add no engine behavior.
- **Who creates tags?** A human maintainer, manually, after review. SpecRelay
  never creates or pushes a Git tag automatically, and this task creates no tag.
- **What local verification must pass before tagging?** All of:
  `scripts/test` (exit 0), `bin/specrelay doctor` (passes, or only intentional
  documented warnings), `bin/specrelay version` (matches `VERSION`), and the
  fresh-clone/install smoke check `scripts/smoke`.
- **What if CI fails after tagging?** Treat the tag as *not yet a release*. Do
  not publish or announce it. Fix forward on `main`, re-run the local
  verification and CI, then either move the unpublished tag to the corrected
  commit or delete it and cut a new patch tag. Never publish a release from a
  commit whose CI is red.

The mechanical push steps a human would later perform (push `main`, push tags
only after review, enable branch protection) are recorded in
`docs/publication.md`. Nothing in this repository performs them automatically.

## Upgrading between versions

How a user moves from one installed version to another — the manual
source-clone/reinstall path, and the safe, atomic `specrelay update` command
family (daily discovery, dismissal, rollback) — is documented in
[updates.md](updates.md) and [upgrading.md](upgrading.md).

## Release-impact metadata for future specs

Every spec after 0022 must declare a `release: { impact, rationale }` block
and the pre-1.0 version-bump policy that follows from it; see
[release-process.md](release-process.md).

## For consuming projects

A consuming project pins the exact engine version it expects (for the incubation
host, in `.specrelay/version`) and verifies the installed engine satisfies that
pin before running a task. See that project's SpecRelay integration
documentation for the host-side pin, bootstrap, and mismatch behavior.
