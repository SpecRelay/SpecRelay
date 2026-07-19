# SpecRelay Architecture Roadmap

**Status:** planning document

**Last reconciled with the repository:** 2026-07-19

**Architecture baseline:** version 1, **PROPOSED**

**Scope:** SpecRelay Core and its future integration boundary with a separate
SpecRelay Platform product

This roadmap is not a normative architecture document. The proposed
architecture layer under [`architecture/`](../../architecture/) defines the
intended architectural baseline, and
[`architecture-version.yml`](../../architecture/architecture-version.yml) is
its machine-readable anchor. Until that file is ratified, neither Architecture
Version 1 nor its ADRs are accepted.

The roadmap distinguishes three kinds of statements:

- **Current:** verified in this repository's code, tests, documentation, or
  history.
- **Target:** intended future behavior that is not fully implemented.
- **Proposed:** a direction that still requires an explicit architecture or
  product decision.

No Target or Proposed statement below should be read as Current behavior.

## 1. Product boundary

The roadmap now treats SpecRelay as two products with a strict boundary.

### SpecRelay Core

**Current:** this repository contains the execution engine. Core owns the task
lifecycle, Executor and Reviewer loop, deterministic transitions, verification,
evidence, recovery, provider and context-capability seams, CLI, and local
on-disk task history.

Core must remain independent of Jira, external databases, queueing systems,
pull-request publication, and a Platform UI.

### SpecRelay Platform

**Target:** Platform is a separate control-plane product. It will own project
configuration, Jira discovery and claiming, isolated workspace provisioning,
queueing, persistent cross-run state, Core process orchestration, Git/PR
publication, Jira result publication, and operational UI.

**Current:** no Platform repository or Platform implementation exists in this
workspace. The milestones in this document are therefore a proposed product
plan, not shipped behavior.

Platform must invoke Core through explicit contracts. It must not reimplement
the Executor/Reviewer workflow or become a second owner of Core's canonical
task state.

## 2. Repository-verified Core baseline

The repository contains numbered specifications `0001` through `0030`. Git
history and the implementation show that the engine has moved beyond a simple
Executor/Reviewer prototype. Its established surface includes:

- a durable task lifecycle and state machine;
- separate Executor and Reviewer roles with a bounded rework loop;
- provider/model abstraction and context-capability adapters;
- change-aware, multi-service, policy-driven verification;
- execution events, timing, and evidence artifacts;
- an advisory AI Coordinator with a validated decision contract;
- local developer configuration overlays;
- UI-runtime verification and compact Playwright evidence;
- engine-owned executor finalization and interrupted-run recovery; and
- task-level archival for completed runs.

This list describes capabilities present in the repository. It does not imply
that every historical spec's embedded status metadata has been normalized, that
every capability has been released beyond repository version `0.6.0`, or that
the proposed architecture has been ratified.

## 3. Known Core gaps

The next Core work is architecture stabilization and Platform-readiness, not a
new autonomous agent layer.

1. **Architecture governance is proposed, not ratified.** Architecture Version
   1, its ADRs, the adoption boundary, and machine validation for
   `architecture_version` are not active requirements.
2. **Reviewer authority does not yet meet the target boundary.** The engine
   validates state transitions, but the automated Reviewer can directly invoke
   accept/request-changes transitions. The Target is Reviewer output as
   structured data that the deterministic runner validates and enacts.
3. **Baseline and documentation truth are uneven.** Historical status metadata
   and older roadmap claims can lag implementation. `REVIEWER_RUNNING` and
   other lifecycle details must be checked across code, tests, and operational
   docs rather than assumed from one document.
4. **Consumer version expectations are not a complete enforced contract.** A
   consumer can run a different SpecRelay version from the one it expected
   without a single, explicit compatibility gate covering installed and
   source-local modes.
5. **Platform integration contracts do not exist yet.** Platform cannot safely
   rely on a stable structured event stream, external run identity,
   machine-readable status/result contract, or cancellation/recovery API.
6. **Workspace and multi-repository boundaries remain targets.** Current
   multi-service verification is not the same as isolated workspace
   provisioning or multi-repository publication.

## 4. Core roadmap

Spec 0031 now has an implementation spec. Numbers 0032–0040 reserve roadmap
order and do not claim those spec files or implementations already exist. A
capability becomes Current only after its repository implementation and
verification are present.

| Spec | Target | Required outcome |
|---|---|---|
| **0031** | Ratify Architecture Version 1 | Explicit maintainer ratification; architecture and ADR status updates; adoption boundary; `architecture_version` validator and focused tests. Ratification must not be inferred from implementation work. |
| **0032** | Reviewer Decision as Data | Reviewer emits a structured decision; runner validates it and alone invokes the canonical transition; historical-task compatibility is preserved. |
| **0033** | Baseline Integrity and Documentation Drift | Define baseline-health evidence, record pre-existing failures honestly, and reconcile lifecycle documentation with code and tests. |
| **0034** | Consumer Version Pin Contract | Declare expected Core version; detect mismatch in `doctor`; define run/resume behavior consistently for installed and source-local modes; preserve historical projects without a pin. |
| **0035** | Structured Runtime Event Contract | Emit versioned, machine-readable lifecycle events so consumers never parse terminal prose. Core's durable on-disk records remain its source of truth. |
| **0036** | External Run Identity and Invocation Contract | Accept and evidence `platform_run_id`, external task identity, workspace identity, and project identity; define duplicate invocation and resume correlation without teaching Core about Jira or a Platform database. |
| **0037** | Machine-Readable Status and Result | Provide stable JSON status/result commands covering canonical state, phase, roles, iteration, verification, blockers, timestamps, human-review readiness, changed scope, and evidence paths. |
| **0038** | Safe Cancellation and Recovery | Define graceful cancellation, bounded hard-stop fallback, durable cancellation evidence, liveness/ownership checks, and resume/requeue semantics. |
| **0039** | Workspace Boundary Contract | Require an explicit workspace/project/repository boundary; reject path and symlink escapes; evidence workspace identity; protect shared developer workspaces. Core defines and enforces the boundary but does not provision workspaces. |
| **0040** | Multi-Repository Execution Contract | Define repository-aware input, verification, changed-scope reporting, and evidence. Branch, commit, push, and PR publication remain Platform responsibilities. |

### Core dependency order

The immediate safety and integration spine is:

```text
0031 architecture governance
  -> 0032 reviewer authority boundary
  -> 0035 structured events
  -> 0036 external identity
  -> 0037 machine-readable status/result
  -> Platform P007 integration
```

Specs `0033` and `0034` are stabilization work and may proceed before the
integration spine reaches P007 if they do not change its contracts. Specs
`0038`–`0040` must be designed before Platform relies on cancellation,
workspace enforcement, or multi-repository execution respectively.

## 5. Platform roadmap

All Platform items are **Target** until a separate Platform repository exists
and contains evidence of implementation.

### M000 — Product and Architecture Foundation

Documentation only:

- product vision, problem statement, principles, and glossary;
- Core/Platform responsibility boundary;
- architecture overview and initial ADRs;
- workspace isolation architecture;
- state, event, and data models;
- Jira and Git integration boundaries;
- milestone definitions and acceptance criteria; and
- risk register.

M000 must precede Platform feature implementation. It must reference Core's
published contracts rather than inventing parallel lifecycle semantics.

### M001 — Single-task vertical slice

The first implementation milestone is one real task moving from Jira readiness
to isolated Core execution, verification, publication, and human review.

| Platform spec | Target |
|---|---|
| **P001** | Project configuration: Jira project, repository set, Git provider, discovered default branches, Core configuration, workspace policy, and credential references. |
| **P002** | Jira task discovery, initially by polling, with no execution side effect. |
| **P003** | Atomic task claiming with a recoverable/expiring lease so two workers cannot execute one ticket. |
| **P004** | Specification readiness gate producing `READY`, `BLOCKED`, or `NEEDS_CLARIFICATION` before Core starts. |
| **P005** | Per-run isolated workspace manager with default-branch discovery, cleanup/retention/recovery policy, and protection of developer workspaces. |
| **P006** | Persistent `TaskRun` model surviving process and Platform restarts. |
| **P007** | Core invocation adapter for start, resume, cancel, events, status/result, and crash recovery; no duplicate Executor/Reviewer workflow. |
| **P008** | Idempotent structured-event ingestion with ordering, deduplication, replay, and external-run correlation. |
| **P009** | Minimal operational UI: state, elapsed time, active role, latest event, blocker, verification, evidence, and PR links. |
| **P010** | Changed-repository detection and run-owned dirty/untracked-state validation. |
| **P011** | Idempotent branch, commit, and push for changed repositories; no force push by default. |
| **P012** | One pull request per changed repository, cross-linked by Jira key and Platform run. |
| **P013** | Structured Jira result publication and transition to human review; failures publish phase, reason, missing input, and recovery guidance without claiming human-review readiness. |

The M001 acceptance path is:

```text
discover -> claim -> readiness gate -> isolated workspace -> Core run
-> ingest result -> detect changed repositories -> branch/commit/push
-> publish PRs -> update Jira -> human review
```

The UI remains deliberately thin until this backend path is reliable.

### Later Platform milestones

- **M002 — Runtime Observability:** live logs, structured timeline,
  retry/recovery visibility, metrics, token/cost, provider latency, and
  verification duration.
- **M003 — Reliable Publication:** idempotent partial-publication recovery,
  multi-repository consistency, duplicate-PR prevention, and publication audit
  trail.
- **M004 — Parallel Execution:** worker pool, queue policy, concurrency and
  resource limits, cancellation, prioritization, and overlap reporting.

The required sequence is **workspace isolation -> parallel execution ->
cross-task coordination**. Parallel execution over a shared developer workspace
is outside the architecture target.

## 6. Cross-track delivery plan

Core and Platform do not need to be completed serially.

```text
Core prerequisite track       Platform foundation track
-----------------------       -------------------------
0031 architecture             M000 documentation
0032 reviewer boundary        P001 project config
0035 runtime events           P002 Jira discovery
0036 external identity        P003 claiming
0037 JSON status/result       P004 readiness gate
                              P005 workspace manager
                              P006 persistent TaskRun
             \                /
              ---- P007 Core adapter ----
```

The tracks may proceed independently only while they preserve the Core/Platform
boundary. P007 is the integration gate: it must consume contracts already
defined by Core rather than stabilizing itself around terminal-output parsing or
private Core files.

## 7. Explicit non-goals for the first vertical slice

Do not pull the following into Core stabilization, M000, or M001:

- multi-tenant SaaS, billing, or full RBAC;
- team management or a generic workflow builder;
- polished executive dashboards or advanced analytics;
- Kubernetes-heavy deployment architecture;
- autonomous merge or deployment;
- a large memory layer or cross-task AI planning;
- many new agent roles; or
- parallel task execution before workspace isolation is proven.

These ideas are not rejected forever. They are intentionally outside the first
end-to-end proof and must not dilute it.

## 8. Roadmap governance

1. Every future Core spec declares whether it changes **Current behavior**, a
   **Target**, or a **Proposed** decision.
2. Once Architecture Version 1 is ratified, specs beyond the recorded adoption
   boundary declare `architecture_version: 1`; before ratification, this remains
   documentation-only and is not silently enforced.
3. A roadmap number is a planning reservation, not evidence of a spec or
   implementation.
4. Core never gains Jira, queue, PR-publication, or Platform persistence logic.
5. Platform never writes Core canonical task state or duplicates its
   Executor/Reviewer lifecycle.
6. Architecture drift is documented as **Current vs Target** and then resolved;
   implementation is not treated as automatically overriding architecture.
7. Human review remains the final authority. Neither track may silently turn a
   Core automated-review result into final human approval.
