# ADR-0004 — Runtime Bootstrap and Mutable-Engine Boundary

## Status
Proposed. Implementation:
- **TARGET** — a real immutable-bootstrap split.
- **TARGET** — cross-operation exclusion between an update and an active task
  runtime (an update must not begin while a run/resume owns a task runtime).
  This is **not** proven to be enforced today.
- **ESTABLISHED** — atomic, verified, rollback-capable self-update of the engine
  payload (supported by the existing update code).

## Architecture version
1.

## Context
SpecRelay installs its own engine and can update itself. Two safety questions
follow: (1) can an update leave the tool in a broken, half-swapped state, and
(2) can the engine replace itself *while it is actively running a task*?

An earlier draft implied an "immutable bootstrap vs. mutable engine" split
already exists. It does not. Today the launcher and the engine it loads are
effectively one payload; the launcher happens to remain stable across an update
only as an incidental consequence of the install layout, not as a designed trust
boundary. Overstating this hides a real, currently-unmet safety goal.

## Decision
1. **Direction (TARGET): a minimal, rarely-changing immutable bootstrap** whose
   only job is to locate, integrity-check, and invoke a versioned, replaceable
   engine payload. Its value is a specific safety property: a self-update that
   fails can always fall back to a known-good engine, so the tool cannot brick
   itself. This split is pursued **only** when it buys that property — not for
   its own sake. **It does not exist today; do not describe it as present.**
2. **REQUIRED TARGET INVARIANT — active-run update exclusion.** A repository or
   installed-engine update MUST NOT begin while a SpecRelay run or resume owns an
   active task runtime; the engine must not orchestrate replacement of itself
   during an active run. This is accepted intended architecture and **must**
   hold — but it is **not yet proven to be enforced**. The current update path
   has its own update lock (it serializes concurrent *updates*), but that lock is
   **not** evidence of any coordination with task-execution ownership: the update
   lock and the task-execution lease are separate namespaces, and nothing
   currently proves an update is refused while a run/resume holds the execution
   lease. **A focused follow-up specification and test are required** to
   establish and verify this cross-operation exclusion. Until then, do not
   describe it as enforced.
3. **Self-update stays atomic and reversible (ESTABLISHED):** stage beside the
   live payload → verify the staged copy in place → activate by atomic swap →
   re-verify against the now-live path → roll back automatically on any failure.
   An update never leaves the tool in a state that is neither the old version
   nor the new one.
4. **Permanent self-update limits (by design):** self-update does not run in a
   source checkout (a checkout is updated by version control, not by the tool
   overwriting its own tree); it refuses to run unattended without explicit
   consent; and it never touches a consumer project's own state.

## Alternatives considered
- **Claim the bootstrap/engine split already exists.** Rejected: false;
  documenting an aspiration as a fact is precisely the error this pass corrects.
- **Build the immutable bootstrap now.** Deferred: this is an architecture pass,
  not a runtime change, and the split is only worth building against a concrete
  un-brickable-update requirement.
- **Allow in-run self-replacement with careful locking.** Rejected: a running
  engine swapping the code it is executing is inherently fragile; forbidding
  in-run replacement is simpler and safer than trying to make it safe.

## Consequences
- The genuinely strong property today — atomic, verified, rollback-capable
  update — is stated plainly, while the missing property (guaranteed
  un-brickable fallback) is marked as a target, not implied to exist.
- The active-run update-exclusion invariant (currently a TARGET) constrains any
  future auto-update or scheduling feature: it must gate on task-runtime
  ownership, and that gate must be built and tested — it cannot be assumed from
  the existence of the separate update lock.
- If the immutable bootstrap is later built, it becomes the natural enabler of a
  single-binary distribution and stronger cross-platform packaging.

## Compatibility / migration impact
- No change in this pass. The current update mechanism is unaffected.
- A future bootstrap split must preserve the atomic-update guarantee, must
  implement (not merely assume) the active-run update-exclusion invariant, and
  be introduced without breaking existing installs.

## Supersedes / superseded by
- Corrects the prior proposal's implication that an immutable-bootstrap boundary
  already exists.
- Not superseded.

- Current self-update performs a stage → verify → activate → re-verify →
  rollback sequence and refuses to run in a source checkout (re-confirmed in this
  pass) — supporting the **ESTABLISHED** atomic-update classification.
- The update path has its **own** update lock, but that lock does not reference
  or coordinate with the task-execution lease; they are separate namespaces
  (re-confirmed in this pass). This is why active-run update exclusion is marked
  **TARGET** and explicitly **not** claimed as enforced — the update lock is not
  evidence of cross-operation exclusion.
- The launcher's stability across update was confirmed to be a side effect of
  the install layout (the update swaps only the engine payload), not a designed
  boundary — which is exactly why the bootstrap split is marked TARGET.

## Open questions
- Does the immutable bootstrap require a compiled launcher, or can a minimal
  integrity-checking script achieve the fall-back-to-known-good property at far
  lower cost? (See the technology-independence considerations.)
- How is "an execution or resume owns the runtime" detected robustly enough to
  gate an update against it in all interruption cases?
