# SpecRelay Migration & Integration

## M1. Migrating away from a former in-host layout

SpecRelay used to be incubated *inside* a host repository, vendored under a
path such as `tools/specrelay/`, with `.ai/scripts/` compatibility wrappers
and a `.ai-runs/` task runtime. That in-host layout is **no longer a
supported product surface**. This is not a dual-mode compatibility guide —
there is exactly one supported architecture today, described in
docs/architecture.md.

If your project still has the old layout, migrate it:

1. Install SpecRelay from the standalone repository (see
   docs/installation.md).
2. Keep your project configuration under `.specrelay/` (`.specrelay/config.yml`,
   `.specrelay/version`).
3. Invoke source-local SpecRelay with `bin/specrelay` only from inside the
   standalone SpecRelay checkout.
4. Invoke the installed CLI with `specrelay` from your consumer repository.
5. Remove any obsolete `tools/specrelay/` copy.
6. Remove any obsolete `.ai/scripts/` wrappers that existed only to call
   SpecRelay.

No automatic copying of the old source tree is required or supported. Do not
maintain both the former in-host layout and the standalone CLI at the same
time.

## M2. Integrating SpecRelay into a project

A project that wants SpecRelay's executor/reviewer workflow driven from its
own configuration needs only a `.specrelay/config.yml` (see
docs/configuration.md) — SpecRelay itself is never vendored into the
project. The seam is the same for every project: its own
`.specrelay/config.yml`. Project-specific behavior is expressed **as that
project's config**, not baked into SpecRelay's implementation. Nothing in
SpecRelay's engine assumes it is running inside any particular repository —
the executable discovers its own resources relative to its installed
location and treats the project root as a separate concept (`SPECRELAY_HOME`
vs. the consumer project root).

## M3. Project config is preserved — never rewritten

A project chooses its own values in `.specrelay/config.yml` and keeps them.
**Installing or updating the tool never rewrites a project's config.** The
installer and updater copy only tool-owned files and explicitly do not touch
any project's `.specrelay/` directory.

A project may keep values other than the public defaults — for example:

- a **spec root** of its own (`specs.root`, e.g. `docs/sdd` vs. the public
  default `specs`);
- a **task-runs root** of its own (`tasks.runs_root`, vs. the public default
  `.specrelay-runs/tasks`);
- **provider choices** for the executor/reviewer roles
  (`roles.executor.provider`, `roles.reviewer.provider`);
- a **required context adapter** (`context.adapter` + `context.required`, e.g.
  `contextplus` / `required: true`);
- a **validation command** that matches what the project actually runs
  (`validation.full_test_command`);
- the **human gate** (`policy.human_final_review_required: true`).

`specrelay init` only ever *creates* a config from the built-in template when
one is absent (and refuses to overwrite an existing config without an
explicit `--force`). Adopting SpecRelay is a config-in-your-repo decision; it
is not a migration the tool performs on your behalf.

## M4. No historical task-directory migration

Adopting or updating SpecRelay **does not move, rename, or rewrite any
existing task run directory.** A project's historical run/evidence
directories — wherever `tasks.runs_root` points — stay exactly where they
are and remain readable as-is. There is no batch conversion step, no
in-place rewrite of prior task state, and no requirement to relocate old
runs under a new path.

New tasks are written under whatever `tasks.runs_root` the config names; old
ones are left untouched. If a project wants a different runs root going
forward, it changes the config value — SpecRelay does not retroactively
relocate what already exists.

## M4a. Backward-compatible input layout now, full artifact-layout migration later (spec 0023)

Spec 0023 adds a new shared input layout to every **newly created** task —
`01-input-manifest.json`, `01-input-bundle/`, and
`02-resolved-specification.md` — but every other existing artifact filename
and location (`03-executor-log.md`, `07-tests.txt`, `09-consultant-review.md`,
timeline/command-timing files, …) stays exactly where it already was. A task
created before spec 0023 has none of the new files and is fully readable and
resumable as-is (`task show`/`doctor`/completion gates all report the absence
honestly rather than fabricating it — see `docs/jam-capability.md` and
`docs/task-lifecycle.md`, §3a).

A **future** specification is explicitly expected to migrate every task's
artifacts into the fully categorized numbered folder structure described in
spec 0023, section 19 (`00-task/`, `01-input/`, `02-analysis/`, `03-executor/`,
`04-verification/`, `05-reviewer/`, `06-telemetry/`). That complete layout
migration is deliberately **out of scope** for spec 0023 — it must not be
forgotten, but it is a separate, later piece of work.

## M5. Config schema

The project config is versioned. The current schema is:

```yaml
version: 1
```

`version: 1` is the first and current schema version. It is declared at the top
of `.specrelay/config.yml` so that future schema changes can be detected
explicitly rather than guessed. Forward-compatibility intent: a newer
SpecRelay reading a `version: 1` config continues to honor it, and any future
schema bump is an explicit, documented change — not a silent reinterpretation
of existing keys. Keys a project does not set fall back to provider-neutral
defaults; a project is never required to hand-write keys it does not need.

See `templates/project/config.yml` (the template `specrelay init` writes)
and `templates/project-config.yml` (a fuller, annotated example) for every
key.

## M6. History

SpecRelay was originally incubated inside a host repository before being
extracted into this standalone repository. That extraction process is
recorded in docs/extraction.md (historical). See docs/architecture.md for
the current standalone architecture.
