# Architecture Decision Records

**Architecture version:** 1 · **Status:** accepted (ratified
2026-07-19; see [`../architecture-version.yml`](../architecture-version.yml))

This directory holds SpecRelay's **Architecture Decision Records (ADRs)** — the
consequential, hard-to-reverse decisions and their trade-offs. The north star
and principles state *what* is true; ADRs record *why a decision was made, what
was rejected, and what it costs*.

An ADR is not a status report on the code. It is a normative decision. Where an
ADR's intended state and the current code differ, the ADR marks that explicitly
(current vs. target) rather than pretending the code already conforms.

## Conventions

- One decision per file, named `ADR-NNNN-short-slug.md`.
- Every ADR contains, at minimum, these headings:
  **Title · Status · Architecture version · Context · Decision ·
  Alternatives considered · Consequences · Compatibility / migration impact ·
  Supersedes / superseded by · Verification or evidence · Open questions.**
- ADR status vocabulary: **Proposed · Accepted · Superseded**. Independently,
  a decision's *implementation* maturity uses the principle vocabulary
  (ENFORCED / ESTABLISHED / TARGET / PROPOSED) so intent is never confused with
  current enforcement.
- ADRs are append-only in spirit: a decision is changed by adding a new ADR that
  *supersedes* the old one, not by rewriting the old one's decision. Editorial
  fixes to an existing ADR are allowed and do not change the architecture
  version; a superseding ADR does (see the version file's increment policy).

## Index

| ADR | Title | Status | Implementation |
|---|---|---|---|
| [0001](ADR-0001-architecture-authority-and-versioning.md) | Architecture authority and versioning | Accepted | ESTABLISHED (docs layer) / ENFORCED (validator) |
| [0002](ADR-0002-ai-engine-authority-boundary.md) | AI recommendation vs. deterministic engine authority | Accepted | ENFORCED (state authorship) / TARGET (reviewer trigger) |
| [0003](ADR-0003-evidence-and-history-preservation.md) | Evidence and non-destructive history preservation | Accepted | ESTABLISHED / TARGET (migration path) |
| [0004](ADR-0004-runtime-bootstrap-and-engine-boundary.md) | Runtime bootstrap and mutable-engine boundary | Accepted | TARGET (bootstrap split; active-run update exclusion) / ESTABLISHED (atomic update) |
| [0005](ADR-0005-extension-seams-and-provider-neutrality.md) | Extension seams and provider neutrality | Accepted | ESTABLISHED (seams) / unexercised (2nd provider) |
| [0006](ADR-0006-human-review-authority.md) | Human review authority boundary | Accepted | ENFORCED (halt) |
| [0007](ADR-0007-task-isolation-and-future-concurrency.md) | Isolation before parallel task execution | Accepted | TARGET |

## Ratification record — Architecture Version 1

Architecture Version 1 was **ratified on 2026-07-19** by an explicit maintainer
decision (spec 0031), as one coherent change:

- **`architecture/architecture-version.yml`:** `status: accepted`, `ratified_at`
  set to the ratification timestamp, `spec_contract.enforcement:
  machine-validated`, and `spec_contract.adoption_boundary.exempt_specs_up_to_and_including:
  31` (the highest spec number — the bootstrap spec `0031` — that existed at
  ratification time).
- **Every ADR (0001–0007):** `## Status` is `Accepted`; each ADR's *implementation*
  maturity label is unchanged by ratification (except ADR-0001, whose own
  deliverables — the docs layer and the validator — became ESTABLISHED/ENFORCED).
- **`docs/specs/README.md`:** records the concrete boundary `0031` and that specs
  numbered after it must declare `architecture_version`.
- **Machine enforcement:** `specrelay architecture validate` (and the release
  preflight) now checks the contract; it is no longer documentation-only.

## Ratification checklist (reusable for a future architecture version)

Ratifying a *new* architecture version is a single, coherent human-approved
change that does **all** of the following together — it is not complete if any
step is missing:

1. **`architecture/architecture-version.yml`:**
   - `status` becomes `accepted`;
   - `ratified_at` receives an ISO-8601 UTC timestamp;
   - `spec_contract.enforcement` names machine enforcement (`machine-validated`);
   - `spec_contract.adoption_boundary.exempt_specs_up_to_and_including` is set to
     the **highest historical spec number that exists at the ratification
     boundary** — computed by scanning `docs/specs/NNNN-*/spec.md`, never assumed
     in advance.

2. **Every ADR in the architecture-version decision set** (the `decisions:` list
   in `architecture-version.yml`):
   - its `## Status` line changes from `Proposed` to `Accepted`. (Each ADR's
     *implementation* maturity — ENFORCED / ESTABLISHED / TARGET / PROPOSED —
     is independent and does not change merely because the decision is accepted.)

3. **`docs/specs/README.md`:**
   - records the **concrete** adoption boundary number;
   - states that specs numbered after that boundary must declare
     `architecture_version`.

4. **The full coherent architecture set changes together** — the version file,
   all ADR status changes, and the specs-README boundary in one change, so the
   layer is never half-ratified. Run `specrelay architecture validate` to confirm
   coherence before considering ratification complete.

Until every step above is done by a human, treat the new version as proposed: its
ADRs are Proposed, the version file is `status: proposed`, and
`architecture_version` enforcement for it is inactive.

## Relationship to `docs/specs/` and `docs/adr/`

- `docs/specs/` holds **implementation/design specs** (what to build next).
- This `architecture/decisions/` directory holds **architecture decisions**
  (the durable rules a spec must respect). The historically-reserved
  `docs/adr/` path is superseded by this location for the versioned
  architecture layer; see [`docs/specs/README.md`](../../docs/specs/README.md).
