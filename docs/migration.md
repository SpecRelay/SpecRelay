# SpecRelay Migration & Integration

## M1. Audience and status

This document is for two audiences:

- **Someone integrating SpecRelay into an existing project** — a project that
  wants SpecRelay's executor/reviewer workflow driven from its own
  `.specrelay/config.yml`.
- **The incubation host repository's maintainers** — the repository that
  currently carries SpecRelay under `tools/specrelay/`.

**Current status:** extraction has **not** happened yet. SpecRelay is
**standalone-repository-*ready*** but still **incubated under `tools/specrelay/`**
in its host repository. The in-repository copy remains the single source of truth
(see `docs/extraction.md`, E5). Nothing in this document requires an extracted
repository to already exist.

## M2. From incubation home to consumer

While incubating, the host repository is SpecRelay's **incubation home**: it is
where SpecRelay's code lives and evolves. The goal of standalone-readiness is to
make the host relationship *clean* — after standalone-readiness the host becomes
**just one consumer** of SpecRelay, exactly like any other project:

```text
Incubation (today)                     Standalone-ready (the goal)
------------------                     ---------------------------
Host repo                              SpecRelay (its own root, portable)
└── tools/specrelay/  (the engine)              ▲  integrated via
    + host's .specrelay/ config                 │  .specrelay/config.yml
                                        ┌────────┼───────────┐
                                     Host repo   Project B   Project C
                                     (a consumer)(a consumer)(a consumer)
```

The seam is the same for every consumer: a project's own
`.specrelay/config.yml`. Host-specific behavior is expressed **as that project's
config**, not baked into SpecRelay's implementation. Nothing in SpecRelay's engine
should assume it is running inside the host — the executable already discovers its
own resources relative to its location and treats the project root as a separate
concept (`SPECRELAY_HOME` vs. the consumer project root).

## M3. Host / consumer config is preserved — never rewritten

A consumer (including the host) chooses its own values in `.specrelay/config.yml`
and keeps them. **Installing or updating the tool never rewrites a project's
config.** The installer and updater copy only tool-owned files and explicitly do
not touch any consumer's `.specrelay/` directory.

A consumer may keep host/project-specific values rather than adopting the public
defaults — for example:

- a **spec root** of its own (`specs.root`, e.g. `docs/sdd` in the host vs. the
  public default `specs`);
- a **task-runs root** of its own (`tasks.runs_root`, e.g. `.ai-runs/tasks` in
  the host vs. the public default `.specrelay-runs/tasks`);
- **provider choices** for the executor/reviewer roles
  (`roles.executor.provider`, `roles.reviewer.provider`);
- a **required context adapter** (`context.adapter` + `context.required`, e.g.
  `contextplus` / `required: true`);
- a **validation command** that matches what the project actually runs
  (`validation.full_test_command`);
- the **human gate** (`policy.human_final_review_required: true`).

`specrelay init` only ever *creates* a config from the built-in template when one
is absent (and refuses to overwrite an existing config without an explicit
`--force`). Adopting SpecRelay is a config-in-your-repo decision; it is not a
migration the tool performs on your behalf.

## M4. No historical task-directory migration

Adopting or updating SpecRelay **does not move, rename, or rewrite any existing
task run directory.** A project's historical run/evidence directories — wherever
`tasks.runs_root` points, such as the host's `.ai-runs/tasks` — stay exactly where
they are and remain readable as-is. There is no batch conversion step, no
in-place rewrite of prior task state, and no requirement to relocate old runs
under a new path.

New tasks are written under whatever `tasks.runs_root` the config names; old ones
are left untouched. If a project wants a different runs root going forward, it
changes the config value — SpecRelay does not retroactively relocate what already
exists.

## M5. Config schema

The project config is versioned. The current schema is:

```yaml
version: 1
```

`version: 1` is the first and current schema version. It is declared at the top of
`.specrelay/config.yml` so that future schema changes can be detected explicitly
rather than guessed. Forward-compatibility intent: a newer SpecRelay reading a
`version: 1` config continues to honor it, and any future schema bump is an
explicit, documented change — not a silent reinterpretation of existing keys. Keys
a project does not set fall back to provider-neutral defaults; a project is never
required to hand-write keys it does not need.

See `templates/project/config.yml` (the built-in template `specrelay init` writes)
and `templates/project-config.yml` (a fuller, annotated example) for every key.

## M6. What migration does NOT mean here

- It does **not** mean extraction has happened — SpecRelay is standalone-*ready*,
  still incubated under `tools/specrelay/` (M1).
- It does **not** rewrite, move, or convert any consumer's config or historical
  task directories (M3, M4).
- It does **not** push anything anywhere or publish a package — see
  `docs/extraction.md`, which is local/history-preserving only.

For the mechanics of turning `tools/specrelay/` into a standalone repository on
disk, see `docs/extraction.md`. For the incubation-vs-standalone framing and
migration stages, see `docs/architecture.md`.
