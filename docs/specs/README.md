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

Once that architecture layer is **ratified** (its version file moves from
`status: proposed` to `status: accepted`), every spec authored afterward MUST
declare the architecture version it was designed against, using a metadata block
alongside the existing `status` / `release` blocks:

```yaml
architecture_version: 1
```

This states which coherent set of {north star, principles, accepted ADRs} the
spec was written to satisfy, so a reviewer can ask whether that baseline still
holds.

### Adoption boundary (historical specs are exempt)

- **Specs at or below the adoption boundary are exempt** and are **never
  rewritten** to add the field. The boundary is the highest spec number existing
  at ratification and is recorded in
  [`architecture-version.yml`](../../architecture/architecture-version.yml)
  (`spec_contract.adoption_boundary`); it is `null` until ratification.
- **Specs authored after ratification, numbered past the boundary, MUST declare
  `architecture_version`.**
- This mirrors the existing **release-metadata** boundary, which requires a
  `release:` block only for specs past a fixed number and never rewrites older
  ones.

### Enforcement status

Enforcement is currently **documentation-only**. A machine validator is a
documented follow-up (see
[ADR-0001](../../architecture/decisions/ADR-0001-architecture-authority-and-versioning.md),
"Open questions"): once ratified, `architecture_version` can be validated
alongside the existing spec-metadata scanner for specs past the adoption
boundary, with focused tests. Until that validator exists and this note says
otherwise, do **not** treat the field as machine-enforced.

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
