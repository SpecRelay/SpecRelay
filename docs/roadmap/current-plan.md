# SpecRelay Current Plan

**Last reconciled with the repository:** 2026-07-19

**Architecture status:** version 1 is **PROPOSED**, not ratified

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
- records the Architecture Version 1 state as Proposed;
- distinguishes Current behavior from Target architecture;
- reserves Core roadmap order `0031`–`0040`; and
- defines Platform M000/M001 without claiming a Platform repository exists.

This pass changes no runtime behavior and performs no architecture
ratification.

## Current objective

**Spec 0031 — Ratify Architecture Version 1.**

**Current state:** the implementation spec is authored but has not been run.
Architecture Version 1 remains Proposed until its explicit authorization gate
and implementation complete.

The first action is to author and review the spec. Ratification itself is an
explicit maintainer decision; preparing validator code or documentation does
not imply consent.

Required scope:

1. re-check every document and ADR included by
   `architecture/architecture-version.yml` against current code and tests;
2. obtain explicit maintainer ratification;
3. change the architecture version and included ADR statuses consistently;
4. set `ratified_at` and the adoption boundary to the highest spec that exists
   at ratification time, rather than assuming `0030` in advance;
5. require `architecture_version` only for specs beyond that boundary;
6. implement a small validator and focused tests; and
7. keep historical specs unchanged.

### Exit criteria

- no document calls Architecture Version 1 accepted before the maintainer
  ratifies it;
- after ratification, all architecture status surfaces agree;
- the adoption boundary is explicit and tested;
- a post-boundary spec without `architecture_version` fails validation;
- an exempt historical spec remains valid; and
- repository tests relevant to the validator pass.

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

- **0031 ratification:** requires explicit maintainer approval.
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
