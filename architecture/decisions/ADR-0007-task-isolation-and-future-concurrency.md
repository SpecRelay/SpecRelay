# ADR-0007 — Isolation Before Parallel Task Execution

## Status
Accepted. Implementation: **TARGET** (workspace isolation and concurrency are
future direction, not current behavior).

## Architecture version
1.

## Context
Today SpecRelay effectively runs one task at a time. That serialization is not a
designed concurrency model; it is an incidental consequence of a shared working
tree plus a guard that refuses to run against changes it cannot account for. The
roadmap's growth direction includes running multiple tasks — which means
deliberately removing that accidental serialization.

The danger is that concurrency reintroduces, one level up (across tasks), the
working-tree and evidence-interleaving races the current design never had to
solve. The ordering of steps toward concurrency is therefore load-bearing, not a
matter of convenience.

## Decision
1. **Isolation precedes parallelism precedes cross-task coordination.** The
   accepted sequence is: (a) give each task an **isolated workspace** so the
   dirty-tree guard protects *its own* work instead of serializing everything;
   then (b) run isolated tasks **in parallel**; then (c) add **cross-task
   awareness** (overlap, dependency, prioritization). No later step may ship
   before its predecessor. **TARGET.**
2. **Concurrency must not weaken any per-task guarantee.** Each task keeps its
   own unchanged lifecycle, its own lock, and its own evidence. Under real
   concurrency, per-task evidence and timelines must be **proven** never to
   interleave — not assumed.
3. **Cross-task conflict is detected and reported, never silently resolved.**
   When two tasks would touch the same work, the safe default is to surface the
   conflict for a human decision, consistent with "no silent behavior."
4. **Concurrency scales the engine *out*, not the AI's authority.** Running more
   tasks at once does not change the state machine, the human gate, or the
   AI/engine authority boundary; it replicates the existing spine, isolated
   per task.

## Alternatives considered
- **Parallelize first, isolate later.** Rejected: parallel tasks over a shared
  tree reintroduce exactly the races the current guard prevents; isolation is the
  prerequisite, not a follow-up.
- **Build cross-task coordination against the current single-task model.**
  Rejected: there is nothing to coordinate across until real parallelism exists;
  it would be re-derived once concurrency is real.
- **Treat the current one-at-a-time behavior as the permanent design.** Rejected
  as an unnecessary ceiling, but noted as a legitimate option if the maintainers
  decide concurrency is not worth its complexity — in which case that, too,
  should be recorded as an explicit decision.

## Consequences
- The path to concurrency has a fixed, safe order that future specs must follow
  (a dependency edge that may not be skipped).
- Workspace isolation becomes the first concrete deliverable of this direction;
  its mechanism (e.g. per-task working trees vs. scoped clones vs. containers) is
  an open design choice with real cost trade-offs.
- The human gate and evidence guarantees are explicitly preserved per task, so
  concurrency does not become a backdoor around them.

## Compatibility / migration impact
- No change in this pass. The current single-task behavior is unaffected.
- Each step must be additive and opt-in: a project that does not use concurrency
  keeps behaving exactly as it does today.

## Supersedes / superseded by
- Consolidates the concurrency direction from the prior proposal into an ordered
  decision.
- Not superseded.

## Verification or evidence
- Current behavior serializes tasks via the shared working tree and dirty-tree
  guard rather than an explicit concurrency model (consistent with the
  operational orchestration notes; re-confirmed in this pass). This is what
  makes the isolation-first ordering necessary.

## Open questions
- **What isolation mechanism?** Per-task working trees, scoped clones, and
  containers each carry different disk, cleanup, and staleness costs; none is yet
  chosen.
- **What is the concurrency bound and scheduling model** once parallelism exists,
  and how is resource use bounded?
- **Does SpecRelay ever span multiple repositories**, or is "one project" a
  permanent boundary? Undecided; nothing here assumes multi-repo, and nothing
  rules it out.
