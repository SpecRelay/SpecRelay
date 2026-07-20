# SpecRelay specs (`docs/specs/`)

This directory is the home for **SpecRelay's own executable
implementation/design specs** — the specifications SpecRelay runs against
itself (dogfooding) and the design records that drive its standalone
development.

## Convention

- Every spec lives at:

  ```
  docs/specs/<number>-<slug>/spec.md
  ```

  where `<number>` is a zero-padded, monotonically increasing spec number
  (`0001`, `0002`, …) and `<slug>` is a short kebab-case description.

- The spec file is always named `spec.md`. Supporting material (diagrams,
  fixtures, notes) may live alongside it in the same `<number>-<slug>/`
  directory.

- `docs/specs/0001-establish-docs-specs-convention-and-scrub-standalone-docs/`
  is the **first standalone SpecRelay spec** and defines this convention.

## Why `docs/specs/` (and not other paths)

| Path            | Purpose                                                              |
| --------------- | -------------------------------------------------------------------- |
| `docs/specs/`   | **Executable implementation/design specs** (this directory).         |
| `architecture/decisions/` | Architecture Decision Records — the versioned architecture layer. Do not put feature specs here. (Supersedes the previously-reserved `docs/adr/`.) |
| `docs/updates/` | Update / release notes. Reserved; do not put specs here.             |

Deliberately **not** used for design specs:

- **`spec/`** — in Ruby/RSpec and many other ecosystems `spec/` conventionally
  holds *test* specs. Using it for design specs would be ambiguous, so
  SpecRelay does not use `spec/` for design/implementation specs.
- **`docs/sdd/`** — this was the historical convention inside the origin host
  repository (Sprint-reports). It is **not** the standalone SpecRelay public
  convention. Historical documents may still reference `docs/sdd/` where that
  is a truthful record of past work; new standalone specs use `docs/specs/`.

## Architecture version declaration (mandatory for future specs)

SpecRelay maintains a versioned, repository-authoritative **architecture layer**
under [`architecture/`](../../architecture/) (north star, principles, and
Architecture Decision Records, anchored by
[`architecture/architecture-version.yml`](../../architecture/architecture-version.yml)).

That architecture layer is **ratified** — Architecture Version 1 is **Accepted**
(ratified 2026-07-19, spec 0031). Every spec authored afterward, numbered past
the adoption boundary, MUST declare the architecture version it was designed
against in a dedicated second-level **`Architecture metadata`** section (an
optional numeric section prefix is allowed) whose first fenced YAML block is
exactly:

```yaml
architecture_version: 1
```

The value is a **bare integer** equal to the currently accepted architecture
version; a quoted string, float, list, or boolean fails validation, and a mere
prose mention elsewhere does not satisfy the contract. This states which
coherent set of {north star, principles, accepted ADRs} the spec was written to
satisfy, so a reviewer can ask whether that baseline still holds.

### Adoption boundary (historical specs are exempt)

- The adoption boundary is **`0031`** — the highest spec number that existed at
  ratification (the bootstrap spec 0031 itself), recorded in
  [`architecture-version.yml`](../../architecture/architecture-version.yml)
  (`spec_contract.adoption_boundary`).
- **Specs at or below `0031` are exempt** and are **never rewritten** to add the
  field.
- **Specs numbered after `0031` (the first is `0032`) MUST declare
  `architecture_version`** in the dedicated section above.
- This mirrors the existing **release-metadata** boundary, which requires a
  `release:` block only for specs past a fixed number and never rewrites older
  ones.

### Enforcement status

Enforcement is **machine-validated**. Run:

```sh
specrelay architecture validate        # human-readable; --json for a stable object
```

It validates the architecture-version schema, the document/ADR set, accepted
status coherence, the adoption boundary, and the `architecture_version` metadata
of every spec numbered past the boundary, exiting non-zero with one actionable
diagnostic per problem. The **same canonical validator runs as a preflight on
every source-local `release` command**, so a non-compliant spec cannot enter the
release path. See
[ADR-0001](../../architecture/decisions/ADR-0001-architecture-authority-and-versioning.md).

## Relationship to the configured spec root

SpecRelay's *consumer projects* configure their own spec root in
`.specrelay/config.yml` (`specs.root`, defaulting to `specs/`). That is a
separate, per-consumer setting. `docs/specs/` is specifically the spec root for
**this repository's own** development specs and is documented here so
contributors know where SpecRelay's design specs live.

## Index

| Number | Spec                                                                                                   | Status |
| ------ | ------------------------------------------------------------------------------------------------------ | ------ |
| 0001   | [Establish `docs/specs/` convention and scrub standalone docs](0001-establish-docs-specs-convention-and-scrub-standalone-docs/spec.md) | Draft  |
| 0006   | [Restore Claude semantic live events](0006-restore-claude-semantic-live-events/spec.md) | Draft  |
