# SpecRelay Architecture Roadmap

**Status:** living document — the single architectural source of truth for
where SpecRelay is headed.
**Audience:** anyone writing a new spec, reviewing one, or deciding what
SpecRelay should become next.
**Not:** a release plan, a feature backlog, or a sprint board. Those change
weekly; this document should not.

This roadmap is built entirely from repository evidence — the shipped engine
(`lib/specrelay/`), the 25 specs under `docs/specs/`, and the architecture,
provider, context-adapter, verification, and lifecycle documentation under
`docs/`. Where the repository does not yet say what comes next, this document
says so explicitly in [§8, Open architecture questions](#8-open-architecture-questions)
rather than inventing an answer.

---

## 1. Vision

SpecRelay exists to make AI-driven software delivery **trustworthy enough to
run with decreasing human supervision, without ever trading away
auditability or the human's final word.**

Today that means a rigid, fully-supervised loop: one task, one AI executor,
one independent AI reviewer, one human gate, evidence captured at every step.
That rigidity was earned, not assumed — 24 of SpecRelay's first 25 specs were
spent hardening exactly this loop (state machine correctness, provider
neutrality, context-capability adapters, bounded verification, execution
timelines, specification-bundle analysis) before spec 0025 added the first AI
role — the **coordinator** — that recommends rather than implements.

The long-term direction is not "add more autonomy" for its own sake. It is:
**every increase in what AI is allowed to decide must be matched by an
equal or greater increase in what the deterministic engine verifies before
acting on that decision.** SpecRelay's bet is that this discipline — advisory
AI, deterministic validation, durable evidence, an un-skippable human gate —
scales further than either "AI does everything" or "AI does nothing"
architectures, because it lets autonomy grow one narrowly-scoped, reversible,
independently-tested capability at a time, on a substrate that never has to
be re-trusted from scratch.

Where this leads, concretely, over the roadmap's horizon: from one
human-supervised task at a time, to an advisory coordinator that recommends
without deciding, to a verification substrate mature enough to cover
multi-service checks and real UI behavior (not just unit tests), to bounded
self-repair of an AI's own artifacts, to reduced human touchpoints across a
task's full lifecycle, to several tasks running in parallel without racing
each other, to those tasks being aware of one another, to a durable memory of
what past tasks learned — each layer built on top of the one before it, none
of them removing the human final gate. See [§5](#5-architectural-evolution)
for the exact phase order and why verification/UI maturity comes *before*
deeper autonomy, not after.

## 2. Core architectural principles

These are evaluated from what the engine code and specs actually enforce,
not aspirational statements. Each is load-bearing: a future spec that
violates one should be treated as a proposal to change this roadmap, not as
routine implementation.

1. **AI recommends; the deterministic engine decides and acts.**
   Every AI role — Executor, Reviewer, and now Coordinator — produces an
   artifact or a structured decision. Only `lib/specrelay/transitions.sh` (via
   `py/state_lib.py`) ever writes `state.json`. The Coordinator's entire
   contract (spec 0025) is a formalization of this principle for a *third*
   role: the engine computes `allowed_next_actions` before the Coordinator is
   even invoked, and validates its response (`coordinator_lib.py`) before
   dispatch. An invalid or out-of-policy decision has **zero** effect on task
   state, and the Coordinator has no source-edit or task-artifact-edit
   operation in its adapter surface at all (spec 0025 §17–§18) — this is not
   merely a prompt instruction, it is the absence of a capability. This is
   the one principle every other phase of this roadmap must preserve.

2. **Evidence over claims, and no silent skipping.** Nothing is accepted on
   an AI's word. The Executor's completion is gated on non-empty required
   artifacts (`03`/`07`/`08`), not exit code alone (spec 0021's completion
   gate). The Reviewer must end with an exact, uppercase, final-line decision
   marker (spec 0019) — prose is never inferred as a decision. The
   Coordinator's `reason` field is an auditable explanation, never treated as
   proof; its decision is checked against engine-computed facts, not trusted
   narrative. Capability adapters report freshness/availability honestly and
   never claim a level they cannot verify (`docs/context-adapters.md`). The
   corollary this roadmap adds explicitly for verification and UI evidence
   (Phases 3–4): an unavailable environment, credential, test fixture, or
   expected reference must produce an explicit `BLOCKED` outcome, never a
   quietly-passed or silently-omitted check.

3. **Durable, restartable execution history.** Every task is a directory of
   files on disk (`state.json` plus numbered artifacts), never session
   memory. `specrelay resume` reconstructs everything from files. Round
   history is archived (`iterations/round-N/`), never overwritten. The
   execution-events log (spec 0019) and coordinator decision log (spec 0025,
   `23-coordinator-decisions.jsonl`) are both append-only. This is what makes
   every later phase auditable rather than merely plausible.

4. **Safe recovery over unsafe automation.** When something goes wrong,
   SpecRelay's answer is a narrow, audited, liveness-checked recovery command
   (`specrelay task recover`) — never a fabricated success, never a silent
   state edit, never an inferred acceptance at the iteration cap. The
   Coordinator's own failure modes (timeout, invalid JSON, forbidden decision)
   fall back to "request human decision or preserve existing behavior" (spec
   0025 §27), not to a best-effort guess.

5. **The human final gate is structural, not a convention.** `run`/`resume`
   halt at `READY_FOR_HUMAN_REVIEW` and perform no transition past it, by
   code, regardless of how the task got there. No phase in this roadmap
   proposes removing this — see [§9, Guiding rules](#9-guiding-rules).

6. **Role, provider, and capability are three separate axes.** *What* needs
   doing (a role: executor/reviewer/coordinator) is independent of *who* does
   it (a provider adapter: `fake`/`claude`/future adapters) and independent of
   *what capability helps it* (a context adapter: `none`/`contextplus`/`jam`).
   Core workflow code contains no `if provider == claude` or `if adapter ==
   contextplus` branches outside their single dispatch seams
   (`providers/provider.sh`, `context/capability.sh`). This is why a new
   provider or adapter has never required a state-machine change.

7. **No silent behavior.** Every degraded or failed state is logged with an
   explicit reason: a `required: false` context failure prints why it's
   continuing anyway; an unsupported model fails before launch, not silently;
   a Coordinator rejection is recorded, not swallowed. "Not recorded" is an
   honest, permitted answer; a fabricated value never is.

8. **Additive, opt-in evolution.** Every capability added since the
   standalone repository was created ships disabled-by-default or
   backward-compatible: context adapters default to `none`, Jam is optional
   until referenced, the Coordinator defaults to `enabled: false` and, when
   disabled, "existing deterministic workflow behavior must continue" (spec
   0025 §32). A project that ignores every roadmap phase below keeps working
   exactly as it does today.

9. **Repository-specific policy never leaks into core.** `knowledge-boundaries.md`'s
   C1/C2/C3 split (generic engine behavior vs. provider-specific adapter
   behavior vs. one project's own policy) is still the operative test for
   where new code belongs: core (`lib/specrelay/`) vs. an adapter vs. a
   consumer's `.specrelay/config.yml`. This roadmap applies the same test to
   itself — every phase below is a capability of the *engine*, not a
   description of any one consumer's workflow.

## 3. Current architecture

SpecRelay today (`v0.6.0`; spec 0025 implemented, reviewed, committed, and
pushed — a separate, later *release* decision governs when `CHANGELOG.md`/
`VERSION` move, see [current-plan.md](current-plan.md)) is a **single-task,
single-working-tree, mostly-supervised** engine.

```text
                              specrelay run/resume <spec>
                                        │
                                        ▼
                              SpecRelay CLI (bin/specrelay)
                                        │
                                        ▼
                  ┌─────────────────────────────────────────┐
                  │              SpecRelay Core              │
                  │  task lifecycle · state machine · locks  │
                  │  evidence capture · human gate · timeline│
                  └───────────────────┬───────────────────────┘
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        ▼                             ▼                             ▼
  ┌───────────┐               ┌──────────────┐              ┌───────────────┐
  │  Executor  │               │   Reviewer   │              │  Coordinator   │
  │  (role)    │               │   (role)     │              │  (role, spec   │
  │            │               │              │              │   0025, OPT-IN)│
  └─────┬──────┘               └──────┬───────┘              └──────┬────────┘
        │ provider adapter            │ provider adapter            │ read-only
        ▼                             ▼                             │ adapter
  ┌───────────┐               ┌──────────────┐                      ▼
  │fake│claude│               │fake│claude(-  │              engine-computed
  └───────────┘               │subagent)│man- │              allowed_next_actions
                              │ual       │     │              → validated decision
                              └──────────────┘                → dispatch via the
                                                                SAME guarded
                                                                transition fns
        context adapters (none | contextplus | jam) — per role, independent
                                        │
                                        ▼
                          One project's working tree (shared)
```

Key properties, all evidenced above:

- **One task at a time, effectively.** `lock.sh` locks per-task-id, so two
  *different* task IDs could technically hold separate locks, but
  `git_guard.sh`'s dirty-tree guard and the shared single working tree mean a
  second task's executor would immediately see the first task's uncommitted
  diff as "unrelated changes" and refuse to run. `docs/dogfood-orchestration.md`
  states this outright: scenarios "run sequentially... to avoid working-tree
  races." There is no workspace isolation model.
- **The lifecycle is linear and mostly synchronous.** `DRAFT →
  READY_FOR_EXECUTOR → EXECUTOR_RUNNING → READY_FOR_REVIEW → {READY_FOR_HUMAN_REVIEW |
  CHANGES_REQUESTED → …}`, capped at `BLOCKED`. `run`/`resume` drive it forward
  invocation by invocation; nothing runs in the background unsupervised.
- **The Coordinator is advisory and narrow.** It runs only at seven bounded
  invocation points, never continuously; most of its decisions (everything
  except `BLOCK_TASK`/`REQUEST_HUMAN_DECISION`) are currently recorded as
  recommendations for a human or a future spec to act on, not yet dispatched
  automatically (spec 0025 §8, "Initial scope").
- **Context/knowledge is per-role, per-task, and mostly ephemeral.**
  `contextplus` proves one bounded retrieval per role invocation; nothing
  persists across tasks. The Coordinator explicitly "must not independently
  crawl the entire repository" and receives only a deterministic snapshot the
  engine chooses to hand it (spec 0025 §14).
- **Distribution is pre-1.0.** No package manager release, no license
  granted yet (`LICENSE.TODO`), one real provider (`claude`) plus the
  deterministic `fake` test adapter.
- **Verification is single-suite-shaped, not multi-service-shaped.** Spec
  0019's levels (`focused`/`targeted`/`full`/`smoke`) select *how much* of one
  configured test command to run; there is no first-class concept of several
  independently-configured services or checks (unit/lint/type-check/
  integration/contract/smoke) each with their own command, working directory,
  timeout, and required/optional status. `validation.full_test_command` is a
  single string (`docs/configuration.md`).
- **There is no UI or visual verification of any kind.** No Playwright, no
  screenshot capture/comparison, no trace/video/console/network evidence.
  Spec 0025 §9 names this out of scope explicitly ("do not add Playwright or
  UI verification"), consistent with the rest of the repository: no test,
  doc, or template anywhere references a browser.

## 4. Target architecture

The target is the same core invariants (§2) scaled across four axes that are
each independently evidenced as gaps today, not scaled by removing any
existing guard. The diagram below shows the *execution-scaling* axis
(workspace isolation → parallel execution → cross-task awareness → memory);
the *evidence-maturity* axis (multi-service verification, UI/visual
evidence, bounded repair, the artifact-layout migration) is orthogonal —
it deepens what happens **inside** a single task's `Executor → Reviewer →
Coordinator → Human` lifecycle, shown as one unchanged box in this diagram,
and is detailed per-phase in [§5](#5-architectural-evolution).

```text
                    ┌─────────────────────────────────────────────┐
                    │        Cross-task coordination layer         │
                    │  (dependency/conflict awareness across tasks) │
                    └───────────────────┬───────────────────────────┘
                                        │
        ┌───────────────────────────────┼───────────────────────────────┐
        ▼                               ▼                               ▼
  ┌───────────┐                  ┌───────────┐                  ┌───────────┐
  │  Task A     │                  │  Task B     │                  │  Task C     │
  │  isolated   │                  │  isolated   │                  │  isolated   │
  │  workspace  │                  │  workspace  │                  │  workspace  │
  │(own worktree│                  │(own worktree│                  │(own worktree│
  │ or clone)   │                  │ or clone)   │                  │ or clone)   │
  └─────┬──────┘                  └─────┬──────┘                  └─────┬──────┘
        │  each task still runs its OWN unchanged Executor→Reviewer→   │
        │  Coordinator→Human lifecycle, per-task lock, per-task evidence│
        ▼                               ▼                               ▼
  Deterministic SpecRelay engine (unchanged ownership of state/evidence/gate)
                                        │
                                        ▼
                        Durable, cross-task knowledge/memory layer
              (what did past reviews/repairs/rejections establish —
               read-only input to future Coordinator & Reviewer context,
               never a second source of state truth)
```

What changes vs. today, precisely:

- **Workspace isolation** replaces "one shared working tree" so that
  `git_guard.sh`'s dirty-tree protection stops being the thing that
  *prevents* concurrency (§3) and instead protects each task's own isolated
  workspace as it does today.
- **The Coordinator's role widens along the axis spec 0025 already named and
  deliberately deferred** — `REPAIR_ARTIFACTS` becoming a real, narrow,
  reversible action; more invocation points chained without a human touch
  when risk is low — never by loosening decision validation, only by adding
  more validated, narrowly-scoped actions to the closed vocabulary.
- **A cross-task layer** becomes necessary only once multiple tasks can be
  in-flight at once (workspace isolation is its prerequisite, not the other
  way around) — to know two tasks touch overlapping files, or that one
  depends on another's outcome.
- **A knowledge/memory layer** is read-only input to Coordinator/Reviewer
  context, exactly like `contextplus` is today for a single task — it is not
  a second place task state can be mutated from, and it does not weaken
  principle 3 (durable per-task evidence remains the record of what actually
  happened).
- **The human final gate is unchanged** in every one of these target states.
  Nothing above removes `READY_FOR_HUMAN_REVIEW` as the mandatory stopping
  point of a successful run.
- **Verification and visual evidence become first-class, multi-shaped
  inputs** to that unchanged lifecycle box: multiple configured
  services/checks running in parallel where independent, a UI-evidence
  bundle (screenshots, diffs, traces, videos, console/network logs) sitting
  alongside the existing git-diff evidence, and the Reviewer independently
  verifying both — before any of C2's self-repair or C6's reduced-touchpoint
  autonomy is trusted to act on "verification passed" as a fact.

## 5. Architectural evolution

The user-facing example phase list ("self-repair," "autonomous
orchestration," "parallel workspaces," "cross-task coordination," "knowledge
and memory," "platform scale") is directionally right, but the repository's
own history shows it undersells how much foundational work Phase 1 actually
was, and it originally collapsed several distinct pieces of agreed work —
recommending a repair vs. executing it, configurable multi-service
verification, UI/visual verification, and the artifact-layout migration —
into either nothing or a single "self-repair" phase. **This section was
revised to correct that**: two previously-agreed capabilities (configurable
verification, UI verification) were missing entirely, and the artifact-layout
migration's dependencies were underspecified. The phases below reflect the
corrected near-term order; each phase states explicitly why it must come
before the one after it.

Maturity labels used below (see [§6](#6-capabilities) for the full
definition of each): **implemented**, **committed next milestone**,
**planned**, **exploratory**, **blocked by human decision**.

### Phase 1 — Reliable deterministic single-task execution
**implemented.** Specs 0001–0024. State machine, provider adapters,
context-capability adapters, bounded verification, execution timeline,
completion gates, specification-bundle/Jam evidence, legacy-engine retirement.
This phase exists because nothing above it is trustworthy without it: an
advisory AI role is only as safe as the deterministic substrate validating
its recommendations.

### Phase 2 — AI Coordinator and deterministic decision contract
**implemented.** Spec 0025 — implemented, reviewed, committed, and pushed.
Introduces the Coordinator as a fourth role that recommends — never
performs — a next action, validated against an engine-computed allowlist
before any dispatch. Builds directly on Phase 1's evidence artifacts
(completion-gate results, verification ledger, Reviewer decision) as its
entire input contract. *Whether/when this is packaged into a version release
is a separate, later operational decision — see
[current-plan.md](current-plan.md) — not an architectural milestone in its
own right; this roadmap does not treat "release spec 0025" as a phase.*

### Phase 3 — Configurable test levels and multi-service verification
**implemented (spec 0026).** Replaces the single
`validation.full_test_command` string and the fixed `focused`/`targeted`/
`full`/`smoke` levels (spec 0019) with a first-class multi-service,
multi-check verification policy — `changed` / `full` / `flexible` (rule-based,
never an arbitrary AI choice) — configurable per service and per check
(unit/lint/type-check/integration/contract/smoke), with independent checks
able to run in parallel while their evidence stays deterministic and
separated by service and command. This phase exists **before** UI
verification (Phase 4) because UI verification needs somewhere to declare
itself as one more check kind inside this same policy, not as a bolted-on
special case; it exists **before** bounded repair (Phase 5) and the
artifact-layout migration (Phase 6) because both need a mature, closed
picture of what "verification evidence" looks like before they can safely
act on or reorganize it.

### Phase 4 — UI runtime and visual verification
**committed next milestone.** Adds detection of UI-impacting change, real
application startup, Playwright-driven flows, screenshot capture, and
comparison against supplied expected references (designs, Figma exports,
prototypes, click dummies, or a prior accepted screenshot) — plus traces,
video, console/network error capture, and independent Reviewer verification
of that evidence. An unavailable application, browser flow, credential, test
data, or expected reference is an explicit `BLOCKED` outcome (§2.2's "no
silent skipping" corollary), never a quietly-skipped check. Builds on Phase
3: UI verification is one configured check kind (with its own command,
working directory, timeout, required/optional status) inside the same
multi-service policy, not a parallel, differently-shaped system.

### Phase 5 — Bounded artifact repair
**planned.** Turns `REPAIR_ARTIFACTS` from "record a recommendation, route to
human or existing recovery" (spec 0025 §11.2, explicitly deferred at §8) into
a real, narrowly-scoped, engine-executed repair (e.g. regenerating one
missing report section) — never a source-code edit, never a second
implementation attempt. Sequenced after Phases 3–4, not before, because a
repair action needs the *mature* shape of verification/UI evidence to know
what "artifact-only, no re-implementation needed" actually looks like across
every check kind — repairing against an immature evidence model would mean
re-deciding this phase's own contract twice.

### Phase 6 — Full numbered artifact-layout migration
**planned.** Replaces the flat, ever-growing numbered-file evidence layout
(`00-user-request.md` … `24-human-decision-request.md`) with the categorized
directory structure specs 0023 §19 and 0024 §9 both name as pending future
work:

```text
<task-runtime>/
├── 00-task/
├── 01-input/
├── 02-analysis/
├── 03-executor/
├── 04-verification/
├── 05-reviewer/
└── 06-telemetry/
```

Deliberately sequenced **last** among the near-term evidence-maturity work —
after specification-bundle analysis (Phase 1, done), Coordinator decisions
(Phase 2, done), configurable verification (Phase 3), and UI verification
(Phase 4) — because the whole point of this migration is that the folder
design should reflect the *real* artifact types SpecRelay produces, not force
Phases 3–5's still-unknown artifact shapes into a structure decided before
they existed. `04-verification/` in particular is sized for both the
multi-service ledger (Phase 3) and the UI-evidence bundle (Phase 4):

```text
04-verification/
├── ui/
│   ├── playwright-report/
│   ├── screenshots/
│   │   ├── actual/
│   │   ├── expected/
│   │   └── diff/
│   ├── traces/
│   ├── videos/
│   ├── console-errors.json
│   ├── network-errors.json
│   └── ui-verification-summary.md
└── ... (multi-service/multi-check ledger from Phase 3)
```

### Phase 7 — Reduced-touchpoint autonomous routing
**planned.** Chains multiple Coordinator invocation points across a task's
lifecycle (e.g. `executor_completed → SEND_TO_REVIEW → reviewer_completed →
…`) without a human resuming the CLI between every one, for the narrow set of
paths where every completion gate — now including the mature, multi-service
and UI checks from Phases 3–4 — already passed deterministically.
Deliberately sequenced **after** Phases 3–6, not before: routing decisions
that treat "verification passed" as a trustworthy fact are only safe once
verification itself (including UI evidence) is mature enough that "passed"
actually means what it claims. Builds on Phase 5: a Coordinator trusted to
fix one narrow artifact defect is a precondition for trusting it to sequence
more steps unattended. Does **not** touch the human final gate (§2.5) — it
only reduces supervision *before* `READY_FOR_HUMAN_REVIEW`, never after.

### Phase 8 — Per-task isolated workspaces
**planned.** Gives each task its own isolated workspace (most plausibly a
Git worktree or scoped clone per task, given `lock.sh` already keys locks
per-task-id) so `git_guard.sh`'s protection stops being the reason only one
task can run at a time. Builds on Phase 1's locking primitive; does not
require Phases 2–7 to exist first — it is an independent execution-scaling
track — but it is the hard prerequisite for Phase 9. Spec 0011 already faced
this question one level down (parallel *reviewers* within a single task) and
explicitly declined it as a non-goal ("introduce multiple reviewer stages,"
"support parallel reviewers") — evidence that concurrency has been a
recognized, deliberately-deferred question since early in Phase 1, not an
oversight this roadmap is introducing for the first time.

### Phase 9 — Parallel task execution
**planned.** Actually runs multiple isolated-workspace tasks concurrently.
Meaningless without Phase 8 — isolation with no concurrency to protect — and
is therefore never sequenced ahead of it.

### Phase 10 — Cross-task dependency and conflict coordination
**planned.** Once multiple tasks can be genuinely in-flight (Phase 9),
something needs to know whether two tasks touch overlapping files, whether
one blocks another, or how to prioritize a shared backlog. Deliberately
sequenced **after** Phases 8–9, never before: there is nothing to coordinate
across if only one task ever runs, and building conflict detection against a
single-task model would mean re-deriving it once real concurrency exists.

### Phase 11 — Durable cross-task knowledge and memory
**exploratory.** No code or spec language points at this yet; included
because Phases 2, 5, and 7 will otherwise keep re-deriving the same context
every task. A durable, cross-task record of what past reviews/repairs/
rejections established, offered as read-only input to future Coordinator and
Reviewer context — extending the existing context-adapter contract
(`docs/context-adapters.md`) rather than inventing a second state store. See
[§8](#8-open-architecture-questions) for the open design tension this creates
with the "coordinator must not independently crawl the repository" and "no
secrets persisted" rules. Its exploratory status (vs. "planned") reflects
that, unlike Phases 3–10, no capability here has an agreed shape yet.

### Phase 12 — Platform and ecosystem maturity
**planned, partially blocked by human decision.** Package-manager
distribution (`docs/homebrew.md`'s phased tap plan) and additional
first-class provider adapters beyond `fake`/`claude` (Codex is described as
provider-neutral in `docs/providers.md` but not implemented) are **planned**.
A granted open-source license is **blocked by human decision** — see
`LICENSE.TODO` — and gates real-world distribution regardless of how far
every other phase goes. This phase is largely orthogonal to Phases 2–11 — it
is about who can adopt SpecRelay and with which providers, not about what the
engine is capable of deciding.

```text
Phase 1 ──▶ Phase 2 ──▶ Phase 3 ──▶ Phase 4 ──▶ Phase 5 ──▶ Phase 6 ──▶ Phase 7
 (done)      (done)      (next)      (next)      (planned)   (planned)   (planned)

Phase 1 ──▶ Phase 8 ──▶ Phase 9 ──▶ Phase 10 ──▶ Phase 11
 (done)      (planned)   (planned)   (planned)     (exploratory)

Phase 1 ──▶ Phase 12 (planned; licensing sub-item blocked by human decision)
 (done)
```

Phases 2→7 (advisory intelligence and evidence maturity deepening) and
8→11 (execution scaling out) are two largely independent evolution tracks
that both depend on Phase 1 and eventually compose — a Phase-7 Coordinator
making routing decisions *across* Phase-10 concurrent tasks is a plausible
later convergence point, not a phase of its own. Phase 12 depends only on
Phase 1 and proceeds on its own clock, gated by the licensing decision, not
by either track.

## 6. Capabilities

Each capability below is the smallest independently-shippable unit inside its
phase, numbered to match its phase in §5 (C1 = Phase 2, C2 = Phase 3, … C11 =
Phase 12). Every capability is labeled with exactly one maturity term:

| Label | Meaning |
|---|---|
| **implemented** | Shipped in code today, whether or not it has been released/versioned. |
| **committed next milestone** | Agreed architecture work, sequenced immediately next; not yet started. |
| **planned** | Agreed architecture work, sequenced later; dependencies must land first. |
| **exploratory** | Directionally justified but no agreed design exists yet. |
| **blocked by human decision** | Technically ready to proceed but waiting on a decision only a human/maintainer can make. |

### C1 — AI Coordinator and deterministic decision contract (Phase 2)
- **Maturity: implemented.**
- **Objective:** Give SpecRelay an advisory role that recommends the next
  workflow action at bounded decision points, closing the "obvious next step,
  no automation for it" gap spec 0025 §5 documents.
- **Architectural value:** Proves the "AI recommends, engine decides" pattern
  (principle 1) can extend to a third role without weakening any existing
  guard — the template every later phase reuses.
- **Dependencies:** Phase 1 in full (completion gates, verification ledger,
  Reviewer decision contract, execution timeline — all consumed as
  Coordinator input).
- **Expected specification(s):** 0025 (this capability).
- **Exit criteria:** Coordinator role configurable and disabled by default;
  closed decision vocabulary; engine-computed `allowed_next_actions`;
  deterministic validation rejecting any out-of-policy decision without state
  mutation; durable append-only decision log; safe failure fallback; doctor
  and task-report integration; full test suite (including adversarial/prompt-
  injection cases) passing.
- **Implementation status:** **Implemented** — `lib/specrelay/coordinator.sh`,
  `py/coordinator_lib.py`, `templates/claude/agents/ai-coordinator.md`, and
  `test/coordinator_test.sh` all exist; the spec has been implemented,
  reviewed, committed, and pushed. Whether/when `CHANGELOG.md`/`VERSION` are
  updated to formally release it is a separate, later **operational**
  decision (see [current-plan.md](current-plan.md)), not an open item on this
  architectural roadmap.

### C2 — Configurable test levels and multi-service verification (Phase 3)
- **Maturity: implemented (spec 0026).**
- **Objective:** Replace the single `validation.full_test_command` string and
  the fixed focused/targeted/full/smoke levels (spec 0019) with a
  first-class, multi-service, multi-check verification policy.
- **Architectural value:** Every later evidence-maturity capability (UI
  verification, bounded repair, the artifact-layout migration) and every
  later autonomy capability (reduced-touchpoint routing) needs "verification
  passed" to mean something precise and multi-shaped, not one opaque command.
  This capability is what makes that true.
- **Levels** (closed vocabulary — `flexible` is deterministic rule selection,
  never an arbitrary AI choice):
  - `changed` — run tests for affected files, components, or services only.
  - `full` — run the complete configured suite.
  - `flexible` — deterministically select the appropriate level from explicit,
    engine-evaluated rules (e.g. "if only docs changed, run `changed`"; never
    "ask the AI which level to run").
- **Per-service, per-check configuration.** Multiple services, each with
  multiple checks (unit, lint, type-check, integration, contract, smoke, …).
  Each configured check may specify: service name; command; working
  directory; timeout; required/optional status; affected-path patterns;
  dependencies (on other checks); parallel-execution group. Independent
  checks (no declared dependency, compatible group) may run in parallel while
  their evidence remains deterministic and kept separate by service and
  command — never merged into one ambiguous log.
- **Where the full suite runs** is itself configurable: `executor` / 
  `reviewer` / `both` / `final gate only`. The recommended default policy —
  matching spec 0019's existing "Preferred Executor workflow" precedent — is
  **changed/targeted checks during Executor work, independent targeted
  Reviewer checks, and exactly one full suite run at the final deterministic
  gate.** A configuration that reruns the full suite in every phase is
  wasteful and should be flagged, not treated as merely a valid choice — this
  roadmap explicitly warns against it.
- **Dependencies:** Phase 1's verification/evidence infrastructure (spec
  0019–0021); independent of C1.
- **Expected specification(s):** spec 0026 ("Configurable Verification Policy
  and Multi-Service Execution").
- **Exit criteria:** multiple services/checks configurable and independently
  reported; `changed`/`full`/`flexible` all deterministic and testable with
  the `fake` provider; parallel execution of independent checks proven not to
  interleave evidence; the wasteful-repeated-full-suite anti-pattern
  detectable and warned about, mirroring spec 0019's duplicate-work reporting.
- **Implementation status:** **Implemented.** `lib/specrelay/verification_policy.sh`
  / `verification_runner.sh` / `py/verification_policy_lib.py`; legacy
  `validation.full_test_command` translated automatically; Coordinator's
  `RUN_TARGETED_VERIFICATION` wired to the engine's own `placement.reviewer`
  resolution; `specrelay doctor`/`task show`/`task report`/`verification
  plan`/`verification run` all integrated. UI-runtime behavior (Phase 4,
  below) remains unimplemented — only `kind: ui` is reserved in the schema.

### C3 — UI runtime and visual verification (Phase 4)
- **Maturity: committed next milestone.**
- **Objective:** Give SpecRelay a first-class way to verify UI-impacting
  changes against real browser behavior and supplied visual references,
  instead of having no UI verification at all (the current state — spec
  0025 §9 names this out of scope for that spec specifically, not for the
  roadmap as a whole).
- **Architectural value:** Closes the largest evidence gap in the current
  architecture (§3): today nothing distinguishes "tests passed" from "the
  actual rendered UI is correct." This is a prerequisite for ever trusting a
  Reviewer's ACCEPT on a UI-touching change as strongly as its trust on a
  backend-only change.
- **Required behavior:**
  - automatic or explicit detection of UI-impacting work;
  - starting the real application;
  - running the relevant Playwright flow(s);
  - capturing final screenshots;
  - comparing actual output against expected screenshots, designs, Figma
    exports, prototypes, or click dummies **when supplied**;
  - storing actual, expected, and diff images;
  - storing traces, videos, console errors, and network errors;
  - independent Reviewer verification of the UI evidence (the Reviewer
    inspects the diff/trace/video itself — it does not trust the Executor's
    narrative, exactly as principle 2 already requires for code evidence);
  - explicit `BLOCKED` behavior when the application, browser flow,
    credentials, test data, environment, or expected reference is
    unavailable;
  - no code path that silently skips UI verification when it was required.
- **Suggested future artifact area** (realized concretely once Phase 6's
  migration lands — see §5, Phase 6):
  ```text
  04-verification/ui/
  ├── playwright-report/
  ├── screenshots/
  │   ├── actual/
  │   ├── expected/
  │   └── diff/
  ├── traces/
  ├── videos/
  ├── console-errors.json
  ├── network-errors.json
  └── ui-verification-summary.md
  ```
- **Dependencies:** C2 (UI verification is one configured check kind inside
  the same multi-service policy, not a separate system).
- **Expected specification(s):** none yet — a new spec, no number reserved.
- **Exit criteria:** a UI-impacting task can be detected deterministically or
  declared explicitly; a full actual/expected/diff/trace/video/console/network
  evidence set is produced and stored; the Reviewer independently verifies it;
  every documented unavailability case produces `BLOCKED`, never a silent
  pass; a fake/deterministic UI-check fixture exists so this is testable
  without a real browser or real credentials.
- **Implementation status:** **Not started.** No test, doc, or template in
  the repository references a browser or Playwright today.

### C4 — Bounded artifact repair (Phase 5)
- **Maturity: planned.**
- **Objective:** Make `REPAIR_ARTIFACTS` a real, narrow, engine-performed
  action instead of a recorded recommendation.
- **Architectural value:** First test of whether a validated AI decision can
  be *dispatched to a real, bounded engine action* (not just logged) without
  expanding the Coordinator's authority boundaries in spec 0025 §17.
- **Dependencies:** C1 (the decision contract), C2 and C3 (a mature,
  multi-shaped verification/UI evidence model to repair against — see §5,
  Phase 5, for why this ordering is load-bearing, not incidental).
- **Expected specification(s):** none yet.
- **Exit criteria:** the set of repairable artifact defects is closed and
  enumerated (not "repair anything"); a repair never touches source code;
  every repair is independently reviewable evidence, not indistinguishable
  from the original Executor output; a repair failure falls back to existing
  `REVIEWER_RUNNING`/human-decision behavior, never a second silent attempt.
- **Implementation status:** **Not started.** Spec 0025 §8 explicitly defers
  it ("does not yet implement unrestricted automatic artifact repair").

### C5 — Full numbered artifact-layout migration (Phase 6)
- **Maturity: planned.**
- **Objective:** Replace the flat, numbered-file evidence layout
  (`00-user-request.md` … `24-human-decision-request.md`) with the fully
  categorized directory structure specs 0023 §19 and 0024 §9 both explicitly
  name as still-pending future work (`00-task/ 01-input/ 02-analysis/
  03-executor/ 04-verification/ 05-reviewer/ 06-telemetry/`).
- **Architectural value:** Housekeeping with real payoff — every later
  capability (especially C10's memory layer) is easier to build against a
  categorized layout than an ever-growing flat numbered sequence. Sequencing
  it after C2–C4 (not before, and not as a "Phase 1 residual" as an earlier
  draft of this roadmap had it) means the folder design reflects the real
  artifact types those capabilities actually produce, instead of guessing at
  them in advance.
- **Dependencies:** specification-bundle analysis (Phase 1, done),
  Coordinator decisions (C1, done), configurable verification (C2), UI
  verification (C3).
- **Expected specification(s):** none yet — named as future work by 0023 and
  0024 but never scheduled.
- **Exit criteria:** existing numbered artifacts are reachable from the new
  layout without breaking any historical task's readability (principle 3);
  no consumer-visible tooling (`task show`, `task report`) regresses;
  `04-verification/` demonstrably holds both the C2 multi-service ledger and
  the C3 UI-evidence bundle without either forcing an awkward shape on the
  other.
- **Implementation status:** **Not started.** Explicitly deferred twice
  (0023, 0024) and not picked up since.

### C6 — Reduced-touchpoint autonomous routing (Phase 7)
- **Maturity: planned.**
- **Objective:** Let the Coordinator's decisions chain across more than one
  invocation point per human touch, for paths where every completion gate
  already passed.
- **Architectural value:** Tests whether "advisory AI + deterministic
  validation" scales to *sequences* of decisions, not just single ones,
  without ever letting the Coordinator itself decide to skip
  `READY_FOR_HUMAN_REVIEW`.
- **Dependencies:** C1, C2, C3, C4 — explicitly **not** sequenced before
  verification (C2) and UI verification (C3) are mature: a Coordinator that
  routes on "verification passed" is only trustworthy once that phrase covers
  the real multi-service and UI checks a change might need, not just the
  single legacy test command.
- **Expected specification(s):** none yet.
- **Exit criteria:** demonstrable multi-invocation-point runs with zero
  additional decision-vocabulary entries beyond spec 0025's closed set; every
  chained decision still individually validated and logged; human final gate
  untouched; a regression test proving the Coordinator cannot use chaining to
  reach a state a single decision could not reach alone.
- **Implementation status:** **Not started.** Spec 0025 §8 explicitly defers
  "full autonomous routing" to a later specification.

### C7 — Per-task workspace isolation (Phase 8)
- **Maturity: planned.**
- **Objective:** Give each task its own working tree (worktree or scoped
  clone) so the dirty-tree guard protects a task's *own* workspace instead of
  gatekeeping the single shared one.
- **Architectural value:** Removes the structural reason (§3) only one task
  can safely execute at a time — the actual prerequisite for any real
  parallelism, not a cosmetic scheduling change.
- **Dependencies:** none beyond Phase 1's existing per-task lock (`lock.sh`);
  independent of C2–C6's evidence-maturity track.
- **Expected specification(s):** none yet.
- **Exit criteria:** two tasks with overlapping file changes can both run to
  completion without either seeing the other's diff as "unrelated changes";
  evidence capture (`evidence.sh`) and the dirty-tree guard both operate
  correctly inside an isolated workspace; a documented, tested cleanup story
  for abandoned/failed workspaces.
- **Implementation status:** **Not started.** No spec, code, or test
  references workspace isolation; `docs/dogfood-orchestration.md` documents
  the current one-at-a-time workaround as a live limitation, not a design
  choice.

### C8 — Parallel task execution (Phase 9)
- **Maturity: planned.**
- **Objective:** Actually run multiple isolated-workspace tasks concurrently
  under one SpecRelay installation.
- **Architectural value:** The payoff of C7; without it, workspace isolation
  is isolation with no concurrency to protect.
- **Dependencies:** C7.
- **Expected specification(s):** none yet.
- **Exit criteria:** a documented concurrency model (how many tasks, how
  scheduled, how resource-bounded); no task's evidence or timeline data ever
  interleaves with another's; `specrelay doctor`/`list` remain accurate under
  concurrent execution.
- **Implementation status:** **Not started.**

### C9 — Cross-task dependency and conflict coordination (Phase 10)
- **Maturity: planned.**
- **Objective:** Detect when two in-flight tasks touch overlapping files or
  when one task's outcome should gate another's start.
- **Architectural value:** Prevents Phase 9's concurrency from silently
  reintroducing the working-tree races Phase 1's dirty-tree guard was built
  to prevent, just one level up (across tasks instead of within one).
- **Dependencies:** C8 — explicitly not sequenced before workspace isolation
  and real parallel execution exist (there is nothing to coordinate across
  if only one task ever runs).
- **Expected specification(s):** none yet.
- **Exit criteria:** a deterministic conflict-detection check runs before a
  second task's Executor claims overlapping files; conflicts are reported,
  never silently resolved; no new implicit coupling between tasks' evidence
  or state.
- **Implementation status:** **Not started.**

### C10 — Durable cross-task knowledge/memory layer (Phase 11)
- **Maturity: exploratory.**
- **Objective:** Let the Coordinator and Reviewer draw on what earlier
  tasks' reviews, rejections, and repairs established, instead of every task
  starting from zero context.
- **Architectural value:** Potentially the highest-leverage capability for
  Coordinator decision quality, but also the one most in tension with
  existing principles (§2.9's "no secrets persisted," spec 0025's "must not
  independently crawl the entire repository") — see
  [§8](#8-open-architecture-questions).
- **Dependencies:** conceptually independent of C7–C9, but low architectural
  value without a mature Coordinator (C1, C4, C6) to consume it.
- **Expected specification(s):** none yet.
- **Exit criteria:** not yet defined — this capability cannot have concrete
  exit criteria until its open design questions (§8) are resolved. This is
  the defining difference between "exploratory" and "planned": every other
  future capability in this section has agreed exit criteria today; this one
  does not.
- **Implementation status:** **Not started; no design exists.** Included
  because its absence is a real, foreseeable ceiling on Coordinator quality,
  not because any spec or code gestures at it.

### C11 — Platform and ecosystem maturity (Phase 12)
- **Maturity: planned, with one item blocked by human decision.**
- **Objective:** Make SpecRelay installable via a package manager, legally
  usable (a granted license), and usable with providers beyond `claude`.
- **Architectural value:** Adoption reach, not decision-making capability —
  included because the roadmap would be dishonest about "where SpecRelay is
  heading" without it.
- **Dependencies:** the existing provider-adapter contract
  (`docs/providers.md`) already supports new adapters without core changes
  (planned, unblocked); a granted license is **blocked by human decision**
  (`LICENSE.TODO` records two candidates, Apache-2.0 and MIT, awaiting a
  maintainer decision) and gates the package-manager item in practice even
  though packaging itself is technically ready to proceed.
- **Expected specification(s):** 0007, 0008, 0022 (partial groundwork
  already shipped: CI license readiness, installation/upgrade, release
  versioning); a license decision and a first non-`claude` real provider
  remain unspecified.
- **Exit criteria:** a granted `LICENSE`; at least one published package
  manager release; at least one additional real (non-`fake`, non-`claude`)
  provider adapter with its own doctor/availability reporting.
- **Implementation status:** **Partially implemented.** Installation/update/
  release-versioning machinery exists and works; the license decision is
  explicitly pending (`LICENSE.TODO`); no package is published; no second
  real provider exists.

## 7. Specification map

No specification numbers are assigned below except where the repository
already reserves one (0001–0025). Future rows are explicit placeholders —
"—" in the Spec column — not a claim that a number has been allocated.

| Spec | Title | Roadmap capability / phase | Maturity |
|---|---|---|---|
| 0001 | Establish `docs/specs/` convention and scrub standalone docs | Phase 1 (foundational) | Completed |
| 0002 | Fix non-ASCII shell hook noise | Phase 1 (reliability) | Completed |
| 0003 | Restore live provider terminal output | Phase 1 (operator visibility) | Completed |
| 0004 | Fix duplicate transition after human-ready | Phase 1 (correctness) | Completed |
| 0005 | Clarify AI-review state names and schema compatibility | Phase 1 (state machine) | Completed |
| 0006 | Restore Claude semantic live events | Phase 1 (operator visibility) | Completed |
| 0007 | Release/CI license readiness | C11 (Phase 12, partial) | Completed |
| 0008 | Public installation and upgrade readiness | C11 (Phase 12, partial) | Completed |
| 0009 | Provider/model/agent selection | Phase 1 (provider abstraction, principle 6) | Completed |
| 0010 | Automated reviewer continuation contract | Phase 1 (lifecycle) | Completed |
| 0011 | Add reviewer-running state | Phase 1 (state machine; explicit non-goal precedent for C7/C8) | Completed |
| 0012 | Explicit role/model configuration | Phase 1 (provider abstraction) | Completed |
| 0013 | Stream-friendly CLI presentation | Phase 1 (operator visibility) | Completed |
| 0014 | Guided model selection and validation | Phase 1 (provider abstraction) | Completed |
| 0015 | First-class context capability adapters | Phase 1 (capability abstraction; precedent for C10) | Completed |
| 0016 | Parallel test runner and timing profiler | Phase 1 (verification infra — **test-execution** parallelism; not task parallelism / Phase 9) | Completed |
| 0017 | Change-aware test selection | Phase 1 (verification infra; direct precedent for C2's `changed` level) | Completed |
| 0018 | ContextPlus runtime readiness and config source | Phase 1 (capability abstraction) | Completed |
| 0019 | Bounded verification, reviewer policy v2, execution timeline | Phase 1 (evidence maturity; direct precedent for C2; C1's input contract) | Completed |
| 0020 | Agent command timing ledger | Phase 1 (evidence maturity) | Completed |
| 0021 | Agent execution efficiency and completion gate | Phase 1 (evidence maturity; C1's input contract) | Completed |
| 0022 | Operator summary, safe update, release versioning | C11 (Phase 12, partial) | Completed |
| 0023 | Specification-bundle analysis, Jam evidence, resolved executor input | Phase 1 (richer evidence input; §19 names the C5 migration as future work) | Completed |
| 0024 | Remove obsolete in-host legacy surfaces | Phase 1 (retire legacy engine; §9 names the C5 migration as future work) | Completed |
| 0025 | AI Coordinator and decision contract | C1 (Phase 2) | **Implemented** — implemented, reviewed, committed, pushed; release timing is a separate operational decision (see [current-plan.md](current-plan.md)), not a pending architecture item |
| — | Configurable test levels and multi-service verification | C2 (Phase 3) | Committed next milestone — no spec number reserved |
| — | UI runtime and visual verification | C3 (Phase 4) | Committed next milestone — no spec number reserved |
| — | Bounded artifact repair | C4 (Phase 5) | Planned — no spec number reserved |
| — | Full numbered artifact-layout migration | C5 (Phase 6) | Planned — named as pending future work by specs 0023 §19 and 0024 §9; no spec number reserved |
| — | Reduced-touchpoint autonomous routing | C6 (Phase 7) | Planned — no spec number reserved |
| — | Per-task isolated workspaces | C7 (Phase 8) | Planned — no spec number reserved |
| — | Parallel task execution | C8 (Phase 9) | Planned — no spec number reserved |
| — | Cross-task dependency and conflict coordination | C9 (Phase 10) | Planned — no spec number reserved |
| — | Durable cross-task knowledge and memory | C10 (Phase 11) | Exploratory — no design, no spec number reserved |
| — | Package-manager release, additional providers | C11 (Phase 12) | Planned |
| — | Granted open-source license | C11 (Phase 12) | Blocked by human decision (`LICENSE.TODO`) |

## 8. Open architecture questions

These are unresolved as of this document — repository evidence points at the
need for a decision, not at the decision itself. New specs touching these
areas should resolve the question explicitly rather than deciding it
implicitly through implementation.

1. **What does a "narrow, engine-performed repair" (C4) mean mechanically?**
   Spec 0025 says the Coordinator "must not edit artifacts itself" and that
   `REPAIR_ARTIFACTS` may "route to an existing safe recovery path" or
   "request human confirmation" — but no spec defines what a *new*,
   engine-performed repair action would actually touch, how it differs from
   re-running the Executor, or how its own output would be evidenced.
2. **What bounds "full autonomous routing" (C6)?** Spec 0025 §8 names this as
   future work but gives no shape to it — how many invocation points may
   chain unattended, what risk classification (borrowing the Reviewer's
   low/medium/high/critical model?) would gate that, and whether a
   Coordinator confidence threshold (mentioned in spec 0025 §19 as
   configurable "if configured," but never specified) should factor in.
3. **What is the workspace-isolation mechanism (C7)?** Git worktrees, scoped
   clones, and containers are all plausible given `lock.sh`'s existing
   per-task-id keying, but nothing in the repository commits to one. This
   choice has real consequences (worktree disk/cleanup cost vs. clone
   staleness vs. container overhead) that the roadmap cannot resolve from
   evidence alone.
4. **How does a licensing decision interact with distribution timing (C11)?**
   `LICENSE.TODO` records two candidate licenses under consideration
   (Apache-2.0, MIT) but explicitly defers the decision to a maintainer. This
   roadmap cannot and does not make that decision, but part of Phase 12 is
   blocked on it in practice.
5. **Is multi-provider support (Codex or others) an active goal or a
   documented placeholder?** `docs/providers.md` describes Codex in
   provider-neutral terms as a demonstration that the model/agent contract
   generalizes, but explicitly states "no Codex adapter is implemented until
   one exists and can be tested deterministically." Whether a second real
   provider is a near-term priority or a someday-capability is undecided.
6. **How should the closed decision vocabulary (reason codes, invocation
   points, decision values) evolve as Phases 5–7 add capabilities?** Spec
   0025 §13.2 requires "documented schema evolution" for new reason codes but
   does not define a governance process — who approves an addition, and how
   is backward compatibility with historical `23-coordinator-decisions.jsonl`
   records preserved when the vocabulary grows?
7. **Can a knowledge/memory layer (C10) exist without contradicting the
   Coordinator's "must not independently crawl the entire repository" rule
   and the "no secrets persisted" security rule (spec 0025 §38)?** A durable
   cross-task memory is, definitionally, something built from crawling past
   tasks' evidence at some point. Whether that crawl happens once (at write
   time, by a different, more heavily-scoped process) or never, and what
   categorically cannot enter that memory, is entirely open.
8. **Does SpecRelay commit to "one project, one working tree" as a permanent
   invariant, or could Phase 10+ eventually span multiple consumer repos?**
   Nothing in the current architecture or specs addresses multi-repository
   orchestration in either direction — this roadmap does not assume it is a
   goal, only notes that no evidence rules it out either.
9. **What is the conflict-resolution policy for C9 when two tasks genuinely
   do need to touch the same file?** "Detect and report" is the only
   evidenced-safe default (per principle 7); whether a future spec should add
   automatic sequencing, priority rules, or remain purely advisory-to-a-human
   is unresolved.
10. **What counts as an "expected reference" for UI verification (C3), and is
    one mandatory?** The requirement covers designs, Figma exports,
    prototypes, click dummies, or prior screenshots — but not every
    UI-impacting task will have one supplied. Whether a missing expected
    reference means `BLOCKED`, means "capture-only, no comparison, flagged as
    such," or is itself a per-task configuration choice is undecided; getting
    this wrong risks either false blocking or the silent-skip this roadmap's
    principles forbid.
11. **Who owns the per-service/per-check registry for C2, and how does it
    stay accurate as a consumer project's real services change?** Unlike
    today's single `full_test_command` (one string, trivially kept current),
    a multi-service configuration can drift out of sync with the actual
    repository (a service renamed, a check removed) with no obvious detector.
    Whether `specrelay doctor` should validate configured services/paths
    still exist, and what "stale configuration" should mean here, is open.

## 9. Guiding rules

How a future specification should relate to this roadmap:

1. **State which phase and capability the spec advances**, in its own
   background/objective section, using this document's phase numbers and
   capability IDs (or explicitly proposing a new one, with the same evidence
   standard this document held itself to — repository-grounded, not
   invented).
2. **Do not skip a dependency edge.** A spec proposing cross-task
   coordination (Phase 10) without workspace isolation and parallel execution
   (Phases 8–9) already shipped, or full autonomous routing (Phase 7) before
   configurable verification and UI verification (Phases 3–4) are mature, or
   the artifact-layout migration (Phase 6) before the capabilities that
   define its own folder contents exist, is building on a phase that does
   not exist yet — per §5's dependency graph, that ordering is load-bearing,
   not arbitrary.
3. **Any expansion of what an AI role may decide must keep the three-part
   contract from principle 1 intact**: the engine computes the allowed set
   before invocation, the AI selects from within it, the engine validates
   before dispatch. No spec may let Executor, Reviewer, or Coordinator call a
   transition function, mint authorization, or edit `state.json` directly —
   regardless of how much smarter the underlying model becomes.
4. **New automation ships disabled-by-default or additive**, matching every
   precedent set so far (context adapters, Jam, the Coordinator itself). A
   spec that flips an existing default without an explicit, separately
   justified human decision to do so is out of step with this roadmap.
5. **Evidence artifacts are additive-only.** Extend the numbered-file
   convention and the append-only event/decision logs; never repurpose,
   rename, or overwrite an existing artifact's meaning.
6. **Repository-specific policy stays out of core**, per
   `knowledge-boundaries.md`'s C1/C2/C3 test — applied now at the
   SpecRelay-standalone-repo boundary: a *consumer* project's policy belongs
   in its own `.specrelay/config.yml`, never hardcoded into `lib/specrelay/`.
7. **The human final gate (principle 5) is out of scope for any phase to
   remove.** A spec that proposes automating past `READY_FOR_HUMAN_REVIEW` is
   proposing a change to this roadmap's foundational premise, not an
   implementation of it — it needs its own explicit human decision and
   should not be framed as "just the next phase."
8. **When a spec needs to exceed an explicit boundary an earlier spec set**
   (e.g. spec 0025 §9's "does not... create a free-form agent loop"), it must
   say so and justify it, not quietly reinterpret the boundary. Silent scope
   creep across specs is exactly what the deterministic-validation principle
   exists to prevent at the code level — the same discipline applies to how
   specs relate to each other.
9. **When evidence is missing, say so in [§8](#8-open-architecture-questions)
   rather than deciding by omission.** This document was written by
   preferring "this is unresolved" over inventing a plausible-sounding
   answer; every spec that builds on it should hold itself to the same
   standard.
10. **Verification and UI evidence must never be silently skippable.** Any
    spec implementing C2 (configurable verification) or C3 (UI verification)
    must make every unavailability case — missing environment, credential,
    browser flow, test data, or expected reference — an explicit `BLOCKED`
    outcome with a recorded reason, never a quietly-passed or
    quietly-omitted check. This is principle 2's "no silent skipping"
    corollary applied concretely, and it is a completion-gate requirement,
    not a stylistic preference.
11. **A capability is "committed" or "planned" only while its stated
    dependencies remain satisfied.** If a later spec changes what an earlier
    phase actually shipped (e.g. C2 lands with a materially different shape
    than described in §6), the specs depending on it (C3, C4, C6) must
    re-confirm their own dependency assumptions still hold before proceeding
    — this roadmap's maturity labels are a snapshot, not a guarantee that
    survives every implementation surprise upstream.
