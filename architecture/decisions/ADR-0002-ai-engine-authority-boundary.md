# ADR-0002 — AI Recommendation vs. Deterministic Engine Authority

## Status
Proposed. Implementation: **ENFORCED** (engine is sole author of state;
executor self-approval gap closed) / **TARGET** (reviewer-triggered transitions
brought fully under the boundary).

## Architecture version
1.

## Context
SpecRelay's core bet is that AI roles should *interpret and recommend* while the
deterministic engine *validates and acts*. The value of the whole system rests
on this boundary holding.

An earlier draft overstated it, claiming that **all** AI roles are structurally
unable to trigger a state transition. A review of current behavior contradicts
that:

- The **executor's** one risky transition — the handoff that could be abused to
  self-approve its own work — **is** protected: it requires a single-use
  authorization created only after the executor process exits and kept outside
  the reviewed working tree. The executor cannot self-approve.
- The **automated reviewer**, however, can itself enact the accept /
  request-changes transition. When the reviewer provider runs with elevated
  permissions, the reviewer process invokes the transition; the engine still
  *re-validates* the transition's preconditions, but the *trigger* is the AI
  role, not an out-of-band engine step. So "no AI role can call a transition" is
  **false today** for the reviewer.
- The **advisory coordinator** is the closest to the intended boundary: it
  selects one action from an engine-computed allow-list, its response is
  validated before any effect, and most decisions are recorded as
  recommendations rather than enacted.

This ADR records the boundary honestly: what is enforced, what is intended, and
the gap between them.

## Decision
1. **The deterministic engine is the sole author of task state.** Every
   transition re-validates its own preconditions regardless of who triggered it;
   an invalid trigger cannot produce an invalid state. This is the invariant
   that must always hold and is **ENFORCED**.
2. **The executor self-approval gap stays closed** via out-of-band, single-use
   authorization minted post-exit. **ENFORCED.**
3. **Desired authority boundary (TARGET), stated precisely:** *No AI process may
   directly invoke, or possess authority to invoke, canonical transition
   commands, and no AI process may possess authority to mutate canonical task
   state. AI output is data; the deterministic runner interprets, validates, and
   enacts it.* An AI decision may *semantically* prompt the engine to **consider**
   a transition — that is expected and fine — but the AI must never be the thing
   that *invokes* the canonical transition or holds the authority to mutate state
   directly. The coordinator model already matches this boundary. Bringing the
   **reviewer** under it — so an accept/request-changes decision is
   engine-validated *data the runner enacts*, rather than a transition the
   reviewer process invokes directly — is accepted intended architecture but
   **not yet implemented**.
4. **Required follow-up:** a spec that either (a) routes the reviewer decision
   through the same recommend-then-engine-enacts path as the coordinator, or (b)
   explicitly accepts and documents the reviewer-triggered transition as a
   permanent, adequately-guarded exception. Until one of those is decided, the
   gap is live and must not be described as closed.

## Alternatives considered
- **Declare the boundary already fully enforced.** Rejected: false for the
  reviewer; it is exactly the overstatement this pass exists to correct.
- **Immediately re-implement the reviewer path in this pass.** Out of scope:
  this is an architecture pass, not a runtime change; the correction is to
  document intent and require a follow-up spec.
- **Rely on prompt instructions to keep AI roles from transitioning.** Rejected:
  prompt text is not a security or authority boundary (see also ADR on
  coordinator permissions within ADR-0005). Authority must rest on capability
  restriction and engine validation, not wording.

## Consequences
- The genuine, strong guarantee — engine re-validates every transition — is
  stated clearly and is not diluted by the weaker reviewer-trigger reality.
- A concrete follow-up is on record; the boundary's completion is tracked rather
  than assumed.
- Future autonomy work (e.g. widening what the coordinator may enact) inherits
  the correct rule: expand the *validated allow-list*, never the AI's raw
  capability to write state.

## Compatibility / migration impact
- No behavior changes in this pass. Documenting the boundary does not alter the
  reviewer path.
- A future spec closing the reviewer gap must remain backward-compatible for
  historical tasks and additive per P10.

## Supersedes / superseded by
- Corrects and supersedes the prior proposal's claim that AI roles are
  structurally unable to call transition functions.
- Not superseded.

## Verification or evidence
- Current code shows the executor handoff consumes a single-use token and is
  attributed to the runner, while the accept / request-changes transitions are
  attributed to the reviewer agent and are **not** token-gated — confirming the
  reviewer can trigger them. (Re-verified against the transitions module during
  this pass.)
- The coordinator's response is validated against an engine-computed allow-list
  before any dispatch, and most decisions are recorded, not enacted.

## Open questions
- Should the reviewer decision become a coordinator-style validated
  recommendation, or should the reviewer-triggered transition be ratified as a
  permanent guarded exception? (Decision deferred to the follow-up spec.)
- As coordinator authority widens over time, what governance controls additions
  to its allow-list so the closed vocabulary does not erode into a de-facto
  open one?
