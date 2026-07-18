# Architecture Decision Records

**Architecture version:** 1 · **Status:** proposed (see
[`../architecture-version.yml`](../architecture-version.yml))

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
| [0001](ADR-0001-architecture-authority-and-versioning.md) | Architecture authority and versioning | Proposed | PROPOSED (docs layer) / TARGET (validator) |
| [0002](ADR-0002-ai-engine-authority-boundary.md) | AI recommendation vs. deterministic engine authority | Proposed | ENFORCED (state authorship) / TARGET (reviewer trigger) |
| [0003](ADR-0003-evidence-and-history-preservation.md) | Evidence and non-destructive history preservation | Proposed | ESTABLISHED / TARGET (migration path) |
| [0004](ADR-0004-runtime-bootstrap-and-engine-boundary.md) | Runtime bootstrap and mutable-engine boundary | Proposed | TARGET (bootstrap split; active-run update exclusion) / ESTABLISHED (atomic update) |
| [0005](ADR-0005-extension-seams-and-provider-neutrality.md) | Extension seams and provider neutrality | Proposed | ESTABLISHED (seams) / unexercised (2nd provider) |
| [0006](ADR-0006-human-review-authority.md) | Human review authority boundary | Proposed | ENFORCED (halt) |
| [0007](ADR-0007-task-isolation-and-future-concurrency.md) | Isolation before parallel task execution | Proposed | TARGET |

## Ratification checklist

This architecture layer is currently **proposed** and **not ratified**. Nothing
in this pass ratifies it. Ratification is a single, coherent human-approved
change that does **all** of the following together — it is not complete if any
step is missing:

1. **`architecture/architecture-version.yml`:**
   - `status` becomes `accepted`;
   - `ratified_at` receives an ISO-8601 timestamp;
   - `spec_contract.adoption_boundary.exempt_specs_up_to_and_including` is set to
     the **highest historical spec number that exists at the ratification
     boundary**. Do not assume `0030` in advance — use whatever the highest spec
     number actually is at ratification time (it may be `0030` if no newer spec
     exists then, or higher if one does).

2. **Every ADR in the architecture-version decision set** (the `decisions:` list
   in `architecture-version.yml`):
   - its `## Status` line changes from `Proposed` to `Accepted`. (Each ADR's
     *implementation* maturity — ENFORCED / ESTABLISHED / TARGET / PROPOSED —
     is independent and does not change merely because the decision is accepted.)

3. **`docs/specs/README.md`:**
   - records the **concrete** adoption boundary number (no longer "null");
   - states that specs numbered after that boundary must declare
     `architecture_version`.

4. **The full coherent architecture set is committed together** — the version
   file, all ADR status changes, and the specs-README boundary in one change, so
   the layer is never half-ratified.

Until every step above is done by a human, treat the layer as proposed: the ADRs
are Proposed, the version file is `status: proposed`, and `architecture_version`
is documentation-only, not mandatory.

## Relationship to `docs/specs/` and `docs/adr/`

- `docs/specs/` holds **implementation/design specs** (what to build next).
- This `architecture/decisions/` directory holds **architecture decisions**
  (the durable rules a spec must respect). The historically-reserved
  `docs/adr/` path is superseded by this location for the versioned
  architecture layer; see [`docs/specs/README.md`](../../docs/specs/README.md).
