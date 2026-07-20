# SpecRelay Current Plan

**Last reconciled with the repository:** 2026-07-19

**Architecture status:** version 1 is **ACCEPTED** (ratified 2026-07-19, spec
0031); adoption boundary `0031`, `architecture_version` machine-validated from
`0032` onward

**Product scope:** Core is current; Platform is a separate Target product whose
repository does not yet exist

For product boundaries, dependency reasoning, and the longer backlog, see
[`architecture-roadmap.md`](architecture-roadmap.md).

## Completed planning step

The repository roadmap has been reconciled with the current architecture layer
and the `0001`–`0030` repository baseline. This documentation pass:

- separates SpecRelay Core from the future SpecRelay Platform;
- removes stale claims that only 25 specs exist or that implemented work is
  still an unnumbered future milestone;
- records the Architecture Version 1 state (now Accepted);
- distinguishes Current behavior from Target architecture;
- reserves Core roadmap order `0031`–`0040`; and
- defines Platform M000/M001 without claiming a Platform repository exists.

This pass changes no consumer runtime behavior.

## Completed objective

**Spec 0031 — Ratify Architecture Version 1 (done, 2026-07-19).**

Architecture Version 1 was ratified by an explicit maintainer decision. The
coherent change set `status: accepted` with a `ratified_at` timestamp, moved
every ADR (0001–0007) to `Accepted`, computed the adoption boundary as `0031`
(the highest spec that existed at ratification), and made `architecture_version`
**machine-validated** for specs numbered past the boundary. The delivered scope:

1. re-checked every document and ADR included by
   `architecture/architecture-version.yml` against current code and tests
   (finding and correcting only a dropped ADR-0004 heading; no Current/Target
   claim was altered);
2. obtained explicit maintainer ratification before any status mutation;
3. changed the architecture version and included ADR statuses consistently;
4. set `ratified_at` and the adoption boundary (`0031`, computed by scanning the
   spec directories, not assumed);
5. requires `architecture_version` only for specs beyond that boundary (`0032`+);
6. implemented the canonical validator (`specrelay architecture validate`, also a
   release preflight) with a focused test suite; and
7. left historical specs unchanged.

### Exit criteria (met)

- no document called Architecture Version 1 accepted before the maintainer
  ratified it;
- all architecture status surfaces now agree;
- the adoption boundary is explicit and tested;
- a post-boundary spec without `architecture_version` fails validation;
- an exempt historical spec remains valid; and
- the validator's focused tests pass.

## Current objective

**Core 0032 — Reviewer Decision as Data**, the next Core safety objective: close
the known AI/engine authority gap so the Reviewer emits a structured decision
that the deterministic runner alone validates and enacts (see ADR-0002's
documented Target). This gap remains honest and open after ratification.

## Next objectives

After 0031, sequence work by safety and integration value:

1. **Platform M000 — Product and Architecture Foundation** in a separate
   repository, documentation-only.
2. **Core 0032 — Reviewer Decision as Data** to close the known AI/engine
   authority gap.
3. **Core integration contracts:** 0035 structured events, 0036 external run
   identity, and 0037 machine-readable status/result.
4. **Platform foundation:** P001–P006 may proceed alongside the Core contract
   work.
5. **Platform P007 — Core Invocation Adapter** only after the Core contracts it
   consumes are defined.

Core 0033 (baseline integrity) and 0034 (consumer version pinning) remain
stabilization priorities and may be scheduled before P007 if they do not delay
or destabilize its public contracts.

## Decision gates

- **0031 ratification:** complete (2026-07-19) — it required, and received,
  explicit maintainer approval before any status mutation.
- **Platform repository creation:** is a separate product/repository action;
  this Core documentation pass does not create it.
- **Workspace ownership:** Platform provisions isolated workspaces; Core later
  enforces the workspace boundary under 0039.
- **Multi-repository publication:** Core reports repository-aware result data;
  Platform owns branch, commit, push, and pull-request publication.
- **Parallel execution:** blocked until isolated workspaces are implemented and
  verified.

## Not now

Do not start polished UI, multi-tenant SaaS, billing, full RBAC, autonomous
deployment, a generic workflow builder, a memory layer, or parallel workers as
part of the current objective. None is required to ratify the architecture or
prove the first single-task Platform vertical slice.
