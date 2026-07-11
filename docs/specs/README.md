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
| `docs/adr/`     | Architecture Decision Records. Reserved; do not put feature specs here. |
| `docs/updates/` | Update / release notes. Reserved; do not put specs here.             |

Deliberately **not** used for design specs:

- **`spec/`** — in Ruby/RSpec and many other ecosystems `spec/` conventionally
  holds *test* specs. Using it for design specs would be ambiguous, so
  SpecRelay does not use `spec/` for design/implementation specs.
- **`docs/sdd/`** — this was the historical convention inside the origin host
  repository (Sprint-reports). It is **not** the standalone SpecRelay public
  convention. Historical documents may still reference `docs/sdd/` where that
  is a truthful record of past work; new standalone specs use `docs/specs/`.

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
