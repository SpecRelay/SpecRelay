# ADR-0003 — Evidence and Non-Destructive History Preservation

## Status
Accepted. Implementation: **ESTABLISHED** (immutable records + regenerated
views) / **TARGET** (a general versioned migration path).

## Architecture version
1.

## Context
SpecRelay's value is *trust that survives inspection*. That depends entirely on
a task's recorded history being credible: if the record could be quietly
rewritten, it would be worthless. The system therefore treats evidence as the
point of the workflow, not a byproduct.

Two questions must be answered permanently: **what may never be rewritten**, and
**what may legitimately be regenerated or, in future, migrated** — without an
absolute prohibition that would make any future evolution of the evidence format
impossible.

An earlier draft framed this as "migration is never allowed," which is too
strong: it would forbid ever reorganizing the evidence layout even in a safe,
auditable way.

## Decision
1. **Source-of-truth records are immutable.** Append-only logs, captured
   point-in-time snapshots, per-check raw output, and durable result records are
   written once and appended to — never mutated in place. **ESTABLISHED.**
2. **Derived views are regenerated, never authored.** Human-readable summaries,
   timelines, and rendered reports are rebuilt wholesale from the immutable
   records with atomic writes, so an interrupted regeneration can fail to update
   but never corrupt, and a derived view is never the source of any fact.
   **ESTABLISHED.**
3. **Non-destructive evolution is permitted; silent rewriting is not.** Any
   future migration of stored evidence MUST be:
   - **explicit** (a deliberate, invoked operation, never a side effect of a
     normal run or resume);
   - **versioned** (tied to a schema/architecture version);
   - **provenance-preserving** (retains or references the original
     representation, so the pre-migration record remains recoverable);
   - **auditable** (records that, when, and by what a migration occurred).
   In-place destructive rewriting of historical evidence is **forbidden**.
   **TARGET** — no such migration mechanism exists yet.
4. **Today's stance is refuse-not-transform.** The current engine does not
   migrate; on an incompatible resume it refuses and asks for a matching engine,
   with read-only inspection always permitted. This is a valid expression of the
   invariant (it never rewrites history) and remains the default until a
   migration mechanism meeting (3) is specified.

## Alternatives considered
- **"Never migrate anything, ever."** Rejected: it forbids safe, auditable
  evolution (e.g. reorganizing the evidence layout) and would ossify the format.
- **Allow in-place transformation on resume.** Rejected: transforming durable
  evidence to fit a new engine is exactly the history-rewriting this ADR
  forbids; it destroys the credibility of the record.
- **Only ever add, never reorganize.** Rejected as unnecessarily rigid: a
  provenance-preserving migration that keeps the original is compatible with the
  invariant; the requirement is non-destructiveness, not non-evolution.

## Consequences
- The record stays credible: nothing a task recorded can be silently altered.
- Evolution remains possible, but only through a deliberate, auditable,
  reversible-by-provenance path — raising the bar for any format change without
  banning it.
- Until that path exists, some cross-version operations require installing a
  matching engine rather than auto-upgrading old tasks; this is an accepted cost
  of not rewriting history.

## Compatibility / migration impact
- No change in this pass. Historical tasks remain readable and are never
  rewritten.
- A future migration mechanism must itself satisfy the four requirements above
  and be introduced additively.

## Supersedes / superseded by
- Corrects the prior proposal's "migration is never allowed" framing.
- Not superseded.

## Verification or evidence
- Current behavior: append-only logs and captured snapshots are treated as
  immutable; summaries/timelines are regenerated from them atomically;
  evidence-finalizing steps that must touch AI output operate over read-only
  copies and are rejected if they mutate what they were only meant to read;
  secrets are redacted before durable evidence is written. (Consistent with the
  operational verification/timeline docs and re-confirmed in this pass.)
- The engine refuses an incompatible resume rather than transforming state,
  demonstrating the non-destructive default.

## Open questions
- What is the first concrete driver for an evidence migration (e.g. a
  categorized artifact layout), and does it justify building the migration
  mechanism, or can it be introduced additively without migrating old tasks?
- Where is provenance of a migration stored so it is itself immutable and
  auditable?
