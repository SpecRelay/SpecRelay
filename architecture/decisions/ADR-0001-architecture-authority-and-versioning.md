# ADR-0001 — Architecture Authority and Versioning

## Status
Accepted. Implementation: **ESTABLISHED** (the documentation architecture layer
itself — now ratified and repository-tracked) / **ENFORCED** (machine validation
of the spec field, via `specrelay architecture validate` and the release
preflight, covered by tests). The layer became an established, authoritative
baseline when the maintainer completed the ratification recorded in
[`decisions/README.md`](README.md#ratification-checklist) (spec 0031).

## Architecture version
1 (this ADR is part of the version-1 set).

## Context
SpecRelay reached a mature engine through many additive specs, but its
architectural invariants were expressed *implicitly* — scattered across spec
documents, operational docs, and a roadmap. There was no single, versioned,
repository-authoritative statement of intended architecture, and no way for a
spec to declare which architectural baseline it was designed against.

A prior attempt (a single large "constitution" file under
`docs/architecture-constitution/`) concentrated all decisions in one place and,
in several spots, described intended behavior as if it were already enforced.
That conflated three distinct things that must stay separate:

- **Normative architecture** — the accepted north star, principles, and ADRs.
- **As-built implementation** — the current code and operational docs.
- **Proposed future direction** — explicit targets and open questions.

## Decision
1. Establish a **versioned architecture layer** at `architecture/`: a machine-
   readable version file, a compact north star, a principles document with
   explicit status per principle, and an ADR directory.
2. Adopt a single **integer architecture version** identifying the coherent set
   of {north star, principles, accepted ADRs}. Increment rules live in
   [`architecture-version.yml`](../architecture-version.yml): editorial changes
   do not increment; an additive ADR, a superseding ADR, or an incompatible
   principle/north-star change each increment by one.
3. Define the **authority relationship** between documents and code, replacing
   the earlier, misleading "the code wins" framing:
   - The **code is authoritative evidence of *current behavior*.**
   - The **accepted architecture documents and ADRs are authoritative for
     *intended architecture*.**
   - A disagreement between them is **architectural drift**, to be resolved
     explicitly — by fixing the code, amending the architecture, or recording an
     accepted exception. **Neither side silently overwrites the other.**
4. Require every **future spec** (authored after ratification) to declare
   `architecture_version:` in its metadata. Historical specs are exempt and are
   never rewritten. The adoption boundary is documented in
   [`docs/specs/README.md`](../../docs/specs/README.md) and in the version file.
5. **Ratify via one coherent change.** Adopting this layer is a single
   human-approved action — version file `status`/`ratified_at`/boundary, every
   ADR's `Status`, and the specs-README boundary, changed together. The exact
   steps are the [ratification checklist](README.md#ratification-checklist),
   which the maintainer completed in spec 0031: `status: accepted`, the adoption
   boundary set to `0031`, and machine enforcement of the spec field.

## Alternatives considered
- **Keep the single constitution file.** Rejected: one giant file mixes stable
  identity with volatile detail, is hard to amend surgically, and encouraged the
  "enforced today" overstatements this pass corrects.
- **Semantic `MAJOR.MINOR.PATCH` for the architecture version.** Rejected: the
  architecture version identifies a *set*, not a compatibility gradient. An
  integer conveys "which coherent baseline" without implying a false
  compatibility algebra.
- **"The code wins" as the tie-break rule.** Rejected as a *general* rule: it
  makes architecture descriptive-only and lets drift silently redefine intent.
  The code remains authoritative for *what currently happens*, but not for *what
  should*.
- **Implement `architecture_version` validation in the runtime now.** Deferred:
  the field is meaningless before ratification (`status: proposed`), and wiring a
  validator now would enforce an unratified contract. Documentation-first is
  safer.

## Consequences
- A newcomer can read one small layer to learn the rules a change must respect.
- Specs gain a stable anchor; reviewers can ask "which architecture version was
  this designed against, and does it still hold?"
- The maintainer must ratify (`status: accepted`, set `ratified_at` and the
  adoption boundary) before the spec field becomes mandatory.
- A small amount of process is added: meaningful architecture changes now touch
  the version file and an ADR together.

## Compatibility / migration impact
- Purely additive. No code, `VERSION`, spec, or test is required to change for
  this ADR to hold.
- Historical specs are untouched and exempt from the spec field.
- The previous `docs/architecture-constitution/` proposal is removed after its
  durable content is relocated here; it was unratified and unreferenced, so no
  external contract depends on it.

## Supersedes / superseded by
- Supersedes the unratified `docs/architecture-constitution/` proposal.
- Not superseded.

## Verification or evidence
- The existing repository already carries a precedent for spec-metadata
  boundaries: release-impact metadata is required only for specs past a fixed
  number and historical specs are explicitly never rewritten. The
  `architecture_version` boundary mirrors that proven pattern.
- `architecture-version.yml` is valid YAML (verified during this pass).
- No "enforced" claim is made for the validator; it is marked TARGET.

## Open questions
- **Where should the machine validator live once ratified?** *Resolved by spec
  0031.* It lives as a canonical Ruby validator (`architecture_validate.rb`)
  behind `specrelay architecture validate [--json]`, and the same validator is a
  preflight on every source-local release command, with focused tests.
- **What is the exact adoption boundary number?** *Resolved by spec 0031:* the
  highest spec number existing at ratification was `0031` (the ratification spec
  itself), so the boundary is `31` and the first governed spec is `0032`.
- **Should ratification itself be recorded as a spec?** *Resolved: yes.* Spec
  0031 records the boundary and the ratification act in the same convention as
  every other change.
