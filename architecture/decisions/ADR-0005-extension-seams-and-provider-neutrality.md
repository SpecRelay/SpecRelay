# ADR-0005 — Extension Seams and Provider Neutrality

## Status
Proposed. Implementation: **ESTABLISHED** (the seams exist and are exercised by
a deterministic substitute) / neutrality **unexercised by a second real
provider**.

## Architecture version
1.

## Context
Every capability SpecRelay has added — new roles, new context tools, new
verification kinds, an advisory coordinator — arrived without changing the state
machine, because each plugs into a stable seam. Preserving that property is how
the engine grows without being destabilized.

Two corrections to an earlier draft are needed:

- **UI verification is not "just a normal check."** It is a *specialized*
  verification capability with its own impact detection, scenario/runtime
  orchestration, evidence layout, a publication gate, and acceptance
  integration — while still being *integrated into* the common verification
  policy and gating architecture. Describing it as an ordinary generic check
  understates its real surface.
- **The coordinator's read-only posture is not proven by a missing CLI flag.**
  The coordinator adapter deliberately does not request bypassed permissions,
  which removes the interactive channel a tool call would need — but "does not
  request bypass" is not the same as "structurally incapable." The boundary must
  rest on explicit tool/permission restriction plus adapter tests, not on the
  absence of a flag and not on prompt text.

## Decision
1. **Four extension seams are the sanctioned way to add capability**, and adding
   through a seam must never require changing the state machine:
   - **Provider adapters** — *who* performs a role. A provider checks its own
     availability, writes the role's required artifacts, returns true exit
     codes, and emits a machine-readable decision (never inferred from prose).
   - **Context capability adapters** — *what knowledge assists a role*. Reached
     through a seam independent of provider selection; must report its
     capability level honestly and never claim a level it cannot prove.
   - **Verification kinds** — *what counts as proof*. A new kind declares itself
     inside the one verification policy and is gated uniformly. A kind MAY be
     **specialized** (its own detection, runtime orchestration, and evidence
     model) while remaining integrated into the common policy/gate — UI
     verification is the reference example, not a bolted-on parallel system.
   - **The coordinator's decision vocabulary** — *what may be recommended*. A
     **closed** set the engine computes per decision point; autonomy grows by
     adding an individually-validated, narrow entry, never by opening the set to
     free-form action.
2. **Provider neutrality is a first-class invariant.** The engine assumes no
   specific vendor; a deterministic non-AI provider drives the full lifecycle,
   structurally proving the core is not coupled to a vendor. Every seam that
   reaches an external system must ship such a deterministic substitute.
3. **Read-only / restricted-authority adapters must be *enforced and tested*,
   not asserted.** For any adapter intended to operate within a restricted
   authority boundary (the coordinator today):
   - the adapter does not request bypassed permissions;
   - the intended boundary is *read-only / no repository-mutating tools*;
   - that boundary MUST be enforced through explicit tool/permission
     restrictions and covered by adapter tests that would fail if the adapter
     could mutate;
   - **prompt text alone is never treated as the security boundary.**

## Alternatives considered
- **Describe UI verification as an ordinary check for simplicity.** Rejected:
  inaccurate; it hides real complexity that reviewers and future authors must
  account for.
- **Treat the coordinator's missing bypass flag as proof of safety.** Rejected:
  defense-in-depth, not a proof; a future change to the permission model could
  silently weaken it if there were no explicit restriction and test.
- **Let capabilities extend the core directly instead of via seams.** Rejected:
  that is exactly what destabilizes the state machine; a capability that fits no
  seam should motivate a deliberate *new seam*, not a wider core.

## Consequences
- New vendors, context tools, and check kinds have a clear, low-risk path in.
- "Specialized but integrated" is an explicitly allowed shape, so future
  rich-evidence capabilities (visual, performance, security) know how to plug in.
- Restricted-authority adapters carry an explicit testing obligation; a boundary
  without a test is not considered enforced.

## Compatibility / migration impact
- Additive. Existing adapters and checks are unaffected.
- A new seam is a deliberate architectural act (a superseding/additive ADR),
  not a routine change.

## Supersedes / superseded by
- Corrects the prior proposal's "UI verification is only a normal check" and its
  "missing flag proves incapability" claims.
- Not superseded.

## Verification or evidence
- The dispatch seams for provider, context, and coordinator exist and are
  exercised; a deterministic non-AI provider and context adapter run the full
  lifecycle in the test suite (re-confirmed in this pass).
- UI verification has a dedicated engine, its own evidence layout, a publication
  gate, and an acceptance-time check — confirming its specialized-but-integrated
  nature.
- The coordinator adapter omits the permission-bypass flag; the code's own notes
  frame the read-only posture as something to enforce, consistent with marking
  it a boundary-to-be-tested rather than a proven incapability.

## Open questions
- **Provider neutrality is unexercised by a second real provider.** Until one
  exists, neutrality is proven-by-substitute but untested against a real second
  vendor; every "vendor-neutral" claim carries this caveat.
- What explicit permission-restriction and adapter-test standard should any
  restricted-authority adapter be held to, and should it be a completion-gate
  requirement for such adapters?
