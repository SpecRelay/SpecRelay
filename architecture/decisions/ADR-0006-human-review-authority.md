# ADR-0006 — Human Review Authority Boundary

## Status
Accepted. Implementation: **ENFORCED** (the automated run halts at the
human-review handoff).

## Architecture version
1.

## Context
SpecRelay's foundational promise is that a human keeps the final word. This must
be expressed precisely, because two different acceptances are easily conflated:

- **Automated reviewer acceptance** — an AI reviewer judged the executor's work
  acceptable.
- **Final human acceptance** — a person approved the change for whatever comes
  next (merge, ship, close).

An earlier draft blurred these by implying the human-review state records final
human approval. It does not. That state records that the *automated* reviewer
accepted and a human decision is *pending*.

## Decision
1. **A successful automated run halts at the human-review handoff and performs
   no transition past it, by code**, regardless of how the task reached that
   state. This is the structural human gate. **ENFORCED.**
2. **The human-review state is a handoff, not a verdict.** Reaching it means:
   the automated reviewer accepted, and a human decision is still required. It
   **does not** record final human approval, and the engine never fabricates or
   infers that approval.
3. **Final acceptance is out-of-band.** The human's approval, and any outward
   action that follows it (merge, ship, release, deploy), are human-controlled
   acts the engine does not perform on its own. The engine prepares the evidence
   a human needs and stops.
4. **The gate must stay *meaningful*, not merely present.** As evidence grows
   richer and more automated, the human must retain a real ability to judge at
   the gate. Any change that reduces pre-gate human touchpoints must
   correspondingly strengthen — never weaken — the human's ability to review at
   the gate. Preserving the gate *in code* is necessary but not sufficient.
5. **Amending this boundary is not a routine step.** A proposal to automate
   *past* the human handoff is a change to SpecRelay's foundational premise. It
   requires an explicit, standalone maintainer decision that acknowledges it as
   such, and may never be framed as "just the next phase."

## Alternatives considered
- **Treat the human-review state as final approval to simplify the model.**
  Rejected: false, and it would let the engine imply a human decision that never
  happened — a direct violation of "evidence over claims."
- **Allow an opt-in to auto-advance past the handoff for low-risk changes.**
  Rejected at this layer: it is precisely the foundational change this ADR
  reserves for an explicit, standalone decision — not something enabled by a
  configuration default.

## Consequences
- The distinction between AI acceptance and human acceptance is unambiguous in
  the architecture, preventing a subtle but serious misrepresentation.
- Autonomy work is bounded: it may reduce supervision *before* the handoff, never
  automate *through* it, and must actively keep the final review meaningful.
- Downstream tooling (summaries, operator surfaces) inherits a clear obligation:
  make the human's judgment at the gate genuinely possible.

## Compatibility / migration impact
- No change in this pass; it documents and sharpens an existing guarantee.
- Any future spec touching the gate must treat this ADR as the boundary it is
  amending, with an explicit human decision.

## Supersedes / superseded by
- Corrects the prior proposal's implication that the human-review state records
  final human approval.
- Not superseded.

## Verification or evidence
- The automated run halts at the human-review state and advances no further on
  its own; the automated reviewer's acceptance is recorded distinctly from any
  human decision (re-confirmed against the lifecycle behavior in this pass).

## Open questions
- What is the minimum operator-facing summary that makes the gate genuinely
  meaningful as pre-gate automation increases (related to the risk that the gate
  stays present but becomes a rubber stamp)?
- Should "final human acceptance" itself become a recorded, first-class evidence
  event, so the out-of-band decision is auditable in the same convention as the
  rest of the task history?
