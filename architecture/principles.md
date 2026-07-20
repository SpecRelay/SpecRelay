# SpecRelay — Architectural Principles

**Architecture version:** 1 · **Status:** accepted (ratified 2026-07-19; see
[`architecture-version.yml`](architecture-version.yml))

> **Normative document.** These are the intended durable rules. Each carries an
> honest *status* so a reader never mistakes an aspiration for a guarantee. The
> statements are kept free of volatile implementation detail (exact commands,
> artifact names, module internals); those belong in the operational docs and in
> ADR context.

## Status vocabulary

| Status | Meaning |
|---|---|
| **ENFORCED** | Demonstrably enforced by current code and covered by tests; a violation would fail. |
| **ESTABLISHED** | Documented and consistently implemented, but not *universally* machine-enforced — discipline plus partial checks, not an airtight gate. |
| **TARGET** | Accepted intended architecture, not yet fully implemented. |
| **PROPOSED** | Direction under consideration; not yet accepted. |

A single principle may be *enforced* in one respect and *target* in another;
where so, it says which is which. This honesty is itself required by P2.

---

## P1 — AI recommends; the deterministic engine decides and acts
**The engine is the sole author of task state. AI roles produce artifacts and
recommendations; the engine validates and performs every state change.**

- **ENFORCED:** exactly one component writes task state, and every transition
  re-validates its own preconditions independently of any caller. The
  executor's one dangerous transition (the handoff that could be used to
  self-approve) is gated by a single-use authorization minted only after the
  executor process has exited and stored outside the reviewed tree.
- **Intended boundary (stated precisely):** *No AI process may directly invoke,
  or possess authority to invoke, canonical transition commands, and no AI
  process may possess authority to mutate canonical task state. AI output is
  data; the deterministic runner interprets, validates, and enacts it.* An AI
  decision may *semantically* prompt the engine to **consider** a transition —
  that is expected — but the AI must not be the thing that *invokes* the
  canonical transition.
- **ESTABLISHED / TARGET (important honesty correction):** this boundary is **not
  fully met today.** The automated reviewer path can itself invoke the accept /
  request-changes transition when the reviewer provider runs with elevated
  permissions — the transition is still engine-validated, but the reviewer
  process is the direct invoker, which the boundary forbids. The advisory
  coordinator, by contrast, already matches the boundary: it selects from an
  engine-computed allow-list and does not directly invoke most transitions.
  Closing (or explicitly ratifying) the reviewer exception is a **TARGET**
  requiring a follow-up spec (see
  [ADR-0002](decisions/ADR-0002-ai-engine-authority-boundary.md)).

## P2 — Evidence over claims; no silent skipping
**Nothing is accepted on an AI's word; every gate checks a durable artifact or a
deterministically-computed fact, and every unavailable prerequisite is an
explicit blocked outcome with a recorded reason.**

- **ENFORCED:** completion is gated on required non-empty artifacts, not exit
  code alone; a review decision is a machine-checked marker, never inferred from
  prose; unavailability produces an explicit blocked result rather than a quiet
  pass.

## P3 — Durable, restartable execution history
**A task is files on disk, never session memory; the engine reconstructs
everything from those files, and append-only records are never truncated.**

- **ENFORCED:** resume rebuilds task state from disk; append-only event and
  decision logs and archived prior rounds are covered by tests.

## P4 — Preserve history; regenerate views, never rewrite records
**Source-of-truth records are written once and appended to, never mutated in
place; derived views are regenerated wholesale from those records. Any future
evolution of stored evidence is explicit, versioned, and provenance-preserving
— silent in-place rewriting of history is forbidden.**

- **ESTABLISHED:** append-only logs and captured snapshots are treated as
  immutable; derived summaries/timelines are regenerated atomically. This is
  consistent practice reinforced by tests, though not a single global
  machine-check.
- **TARGET:** a general, versioned, provenance-preserving *migration* path for
  stored evidence does not exist yet (today the engine refuses an incompatible
  resume rather than transforming state). Non-destructiveness is the invariant;
  a safe migration mechanism, if ever needed, is future work (see
  [ADR-0003](decisions/ADR-0003-evidence-and-history-preservation.md)).

## P5 — Safe recovery over unsafe automation
**When something goes wrong, the response is a narrow, audited, liveness-checked
recovery path — never a guess, a fabricated success, or a silent state edit.**

- **ENFORCED:** interruption has a bounded recovery path; a hung or foreign
  owner is never treated as dead; an ambiguous crash window blocks rather than
  adopting unprovable ownership; failure falls back to requesting a human
  decision.

## P6 — Human review authority is structural
**A successful run halts at the human-review handoff and performs no transition
past it, by code. Automated reviewer acceptance is a handoff to a human, not a
record of final human approval.**

- **ENFORCED (the halt):** the run stops at the human-review state and advances
  no further on its own, regardless of how the task arrived there.
- **Clarification (not a weakening):** reaching the human-review state records
  that the *automated* reviewer accepted and a human decision is *pending*. It
  does **not** record final human approval; that approval is an out-of-band act
  the engine never performs or fabricates (see
  [ADR-0006](decisions/ADR-0006-human-review-authority.md)).

## P7 — Role, provider, and capability are independent axes
**What needs doing (role), who does it (provider), and what assists it (context
capability) are three separate axes, each behind its own dispatch seam; adding
one never requires changing the state machine.**

- **ESTABLISHED:** the seams exist and are exercised; a deterministic non-AI
  provider and context adapter drive the full lifecycle, structurally
  demonstrating the core is not coupled to a vendor.

## P8 — Engine neutrality and provider abstraction
**The engine never assumes a specific AI vendor or context tool; every provider
and adapter is reached through a stable contract, and a deterministic substitute
keeps the whole system testable with no real AI.**

- **ESTABLISHED, but unexercised by a second real provider:** neutrality is
  proven by the deterministic fake, yet only one real provider exists today.
  Until a second real provider exists, neutrality is *proven-by-fake but
  unexercised-in-reality* — treat vendor-specific assumptions with suspicion
  (see [ADR-0005](decisions/ADR-0005-extension-seams-and-provider-neutrality.md)).

## P9 — Repository-specific policy never leaks into core
**Generic engine behavior lives in core; provider-specific behavior lives in a
clearly-labeled adapter; one project's policy lives in that project's
configuration and nowhere else.**

- **ESTABLISHED:** the core/provider/project split is a standing review
  criterion and is consistently honored; it is discipline-plus-review, not a
  single automated gate.

## P10 — Additive, opt-in, backward-compatible evolution
**Every new capability ships disabled-by-default or backward-compatible;
evidence and logs are extended, never repurposed or overwritten; a project that
ignores a new capability keeps working exactly as before.**

- **ENFORCED (compatibility guard):** an incompatible engine/schema resume is
  refused with an explicit, overridable, logged guard; read-only inspection is
  never blocked.
- **ESTABLISHED (additive convention):** capabilities have consistently shipped
  opt-in/additive; this is convention reinforced by tests rather than a single
  machine-check.

---

## The meta-principle

*Every increase in what AI is allowed to decide must be matched by an equal or
greater increase in what the deterministic engine verifies before acting on
that decision.* — **ESTABLISHED as a design discipline.** It is the standard
against which every autonomy-related change is judged; it is enforced by review
and by the per-change status classification above, not by a single test.

## Using this document

- A new spec states which principles it upholds and — if it changes a
  principle's status (e.g. moving a TARGET to ENFORCED) — says so explicitly.
- A claim of "enforced" must be backed by a test. If it is only convention,
  it is **ESTABLISHED**, not **ENFORCED**. Overstating status is itself a P2
  violation.
