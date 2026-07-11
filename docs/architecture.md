# SpecRelay Architecture (Incubation)

## H1. Incubation architecture

SpecRelay is being incubated **inside** a real repository that already has a
working, proven AI workflow, rather than being designed from scratch in a new
repository. The existing workflow stays authoritative throughout incubation:

```text
Existing workflow (.ai/, this repository)
        │
        │ remains canonical — unchanged, still runs every real task
        ▼
SpecRelay incubation
tools/specrelay/                 <- reusable engine code lives here (future)
.specrelay/                      <- this repository's SpecRelay policy/config
```

At SDD 0083, `tools/specrelay/` contained only the behavioral contract docs,
a read-only discovery CLI, and a project-config loader — no task lifecycle,
state machine, or executor/reviewer invocation logic (see H4 for that task's
non-goals).

**As of SDD 0084**, `tools/specrelay/` has a real, executable engine (task
lifecycle, state machine, evidence capture, provider/context adapters — see
H5 below and `docs/engine-parity.md` for the full capability comparison).
The existing `.ai/` workflow remains canonical and unchanged; nothing in
`.ai/scripts/` was redirected, and `.ai/`/`.ai-runs/` were not modified.

**As of SDD 0085, SpecRelay is this repository's ACTIVE workflow engine.**
**As of SDD 0085B, SpecRelay is the repository's ONLY active workflow engine
and the legacy `.ai/` engine is frozen (rollback/reference only — see H7 and
H9).**
`.specrelay/config.yml`'s `workflow.current_engine: specrelay` is the single,
machine-detectable source of truth for this (read by
`specrelay doctor` and by every compatibility shim). The public entry points
in `.ai/scripts/` (`start-spec-task.sh`, `start-ai-task.sh`,
`approve-task.sh`, `run-ai-loop.sh`, `show-task.sh`) are now thin
compatibility shims that delegate to `tools/specrelay/bin/specrelay` by
default — see H6 and the "Rollback" section below. The previous engine
implementation is preserved, unmodified in behavior, under
`.ai/scripts/legacy/` (plus the still-shared `.ai/scripts/internal/`
helpers) as an explicit, temporary rollback path — it is frozen (H7,
"Legacy engine freeze") and is not deleted by SDD 0085.

```text
User command
    │
    ▼
SpecRelay CLI (tools/specrelay/bin/specrelay)
    │
    ▼
SpecRelay Core
    ├── Task lifecycle
    ├── State
    ├── Evidence
    ├── Locking
    └── Human gate
    │
    ▼
Role adapters
    ├── Executor
    └── Reviewer
    │
    ▼
Provider adapters
    │
    ▼
Project repository

Compatibility shims (.ai/scripts/*.sh) sit ABOVE this diagram: they resolve
the active engine (SPECRELAY_ENGINE env override, else
.specrelay/config.yml's workflow.current_engine) and either delegate into
the SpecRelay CLI above, or `exec` the frozen .ai/scripts/legacy/ copy —
never both, and never recursively (see docs/dogfood-report.md's
"shim-loop protection" evidence).
```

## H2. Core vs adapters vs project configuration

The target conceptual separation, once the engine itself is migrated
(SDD 0084+):

```text
SpecRelay Core                     Provider Adapters              Project Configuration
tools/specrelay/lib/specrelay/     tools/specrelay/lib/specrelay/  .specrelay/
├── task lifecycle                 adapters/ (future)              ├── paths (specs.root,
├── state machine                  ├── claude                      │   tasks.runs_root)
├── evidence                       ├── future providers             ├── validation
├── orchestration                  └── capability integrations      │   (full_test_command)
└── contracts                      (context-plus, etc.)              ├── policies
                                                                      │   (human_final_review_
                                                                      │    required)
                                                                      └── repository-specific
                                                                          constraints
```

This split is now realized (SDD 0084), not just shaped:

- `lib/specrelay/state.sh` + `py/state_lib.py`, `task.sh`, `lock.sh`,
  `auth.sh`, `transitions.sh`, `git_guard.sh`, `evidence.sh`, `workflow.sh`
  are Core: the task lifecycle, state machine, evidence capture, locking,
  and orchestration, with no Claude/Codex/Sprint-Reports-specific literals.
- `lib/specrelay/providers/{provider,fake,claude}.sh` are Provider Adapters:
  `provider.sh` is the dispatch seam Core calls; `fake.sh` and `claude.sh`
  are concrete adapters behind it. Core never assumes "executor == Claude."
- `lib/specrelay/context/{capability,none,contextplus}.sh` are Capability
  Adapters: `capability.sh` is the dispatch seam; `none.sh` and
  `contextplus.sh` are concrete adapters. Core never assumes "context ==
  Context Plus."
- `.specrelay/config.yml`'s `roles.executor.provider` /
  `roles.reviewer.provider` / `context.adapter` / `context.required` /
  `tasks.max_iterations` select adapters and policy — Project Configuration,
  not Core.
- `lib/specrelay/project.sh`, `discovery.sh`, `config.sh` are unchanged from
  0083 and remain Core-shaped.

## H3. Migration stages

- **0083 — incubate SpecRelay from the existing AI workflow.** Done. Behavioral
  contract + read-only discovery CLI + config loader.
- **0084 — migrate workflow engine into SpecRelay.** Done (this task). A real,
  executable engine exists behind the Core/Adapter/Config separation above;
  `.ai/` remains the production path (see `docs/engine-parity.md`).
- **0085 — compatibility shims and dogfooding.** Done (this task). SpecRelay
  is now the active engine (`workflow.current_engine: specrelay`); the public
  `.ai/scripts/` commands delegate to it by default; the previous engine is
  preserved as an explicit, temporary rollback path
  (`.ai/scripts/legacy/`, `SPECRELAY_ENGINE=legacy`); real Sprint Reports
  tasks were dogfooded through it — see `docs/dogfood-report.md`.
- **0086 — standalone repository extraction.** Not yet started. Once
  dogfooded, extract `tools/specrelay/` into its own repository/package with
  its own versioning, README, and distribution, keeping `.specrelay/`-style
  project configuration as the integration seam for any consuming project.

## H4. Non-goals of 0083 (historical)

SDD 0083 explicitly did **not**: replace the current `.ai/` workflow;
redirect any public `.ai/scripts/` command to SpecRelay; delete `.ai/` or
`.ai-runs/`; run any task-engine execution via SpecRelay; migrate any
provider integration into SpecRelay; extract SpecRelay into a standalone
repository; publish a package. SDD 0084 (this task) lifted the
"no task-engine execution" and "no provider migration" restrictions
specifically — see H5 — while leaving every other 0083 non-goal in place
(SpecRelay still does not replace `.ai/`, redirect its commands, delete it,
extract to a standalone repo, or publish a package).

## H5. Non-goals of 0084

This task explicitly does **not**:

- redirect `start-spec-task.sh` (or any other public `.ai/scripts/` command)
  to SpecRelay — that is SDD 0085's job;
- delete `.ai/` or `.ai-runs/`, or alter the current command contract;
- commit, push, merge, or deploy anything, automatically or otherwise;
- extract SpecRelay into a standalone repository;
- publish a package (no Homebrew formula, no npm/pip/gem distribution);
- migrate the `codex` provider, structured event-stream capture
  (`stream-json`), or desktop-notification integration (see
  `docs/engine-parity.md`, "Known gaps");
- claim full behavioral parity — `docs/engine-parity.md` is explicit about
  what is equivalent, improved, or still a gap.

## H6. Compatibility shims (SDD 0085)

Every public `.ai/scripts/` entry point that has a safe SpecRelay equivalent
is now a thin dispatcher, not a reimplementation:

| Public command | Engine mode `specrelay` (default) delegates to | Engine mode `legacy` execs |
|---|---|---|
| `.ai/scripts/start-spec-task.sh <spec>` | `specrelay run <spec>` | `.ai/scripts/legacy/start-spec-task.sh` |
| `.ai/scripts/show-task.sh <task-ref>` | `specrelay show <task-ref>` | `.ai/scripts/legacy/show-task.sh` |
| `.ai/scripts/approve-task.sh <task-id>` | `specrelay task approve <task-ref>` | `.ai/scripts/legacy/approve-task.sh` |
| `.ai/scripts/run-ai-loop.sh <task-id>` | loops `specrelay resume <task-id>` | `.ai/scripts/legacy/run-ai-loop.sh` |
| `.ai/scripts/start-ai-task.sh <task-id>` | **no safe mapping — refuses cleanly** (SpecRelay is spec-driven throughout; there is no "create an empty, spec-less DRAFT task" command) | `.ai/scripts/legacy/start-ai-task.sh` |

Each shim answers "which engine?" via the shared helper
`.ai/scripts/internal/lib/specrelay-shim.sh`
(`specrelay_shim::engine`): the `SPECRELAY_ENGINE` environment variable if
set (only `specrelay`/`legacy` are accepted — anything else is a hard
error, never a silent fallback), otherwise `.specrelay/config.yml`'s
`workflow.current_engine`. `.ai/scripts/internal/run-workflow.sh` (the
lower-level single-step helper `run-ai-loop.sh`/`daemon.sh` compose) is
**not** a public shim — it is `KEEP_AS_ROLLBACK_INTERNAL`, reachable only
through the frozen legacy path.

## H7. Rollback and legacy engine freeze (SDD 0085 / 0085B)

**Legacy engine freeze (SDD 0085B).** As of SDD 0085B the legacy `.ai/`
engine is FROZEN: no new features are added to it, no new recovery paths are
built into it (interrupted-task recovery is SpecRelay-native only, via
`specrelay task recover` — see H9), no new dogfood/test infrastructure is
built on it, and no new dependencies are taken on it. It remains solely as a
rollback/reference path until a later removal spec retires it. New work must
never be started through `.ai/scripts/*`; the only supported active engine is
SpecRelay.

The legacy engine remains available ONLY as an explicit, temporary rollback:

```
SPECRELAY_ENGINE=legacy .ai/scripts/start-spec-task.sh <spec>
# or, equivalently:
.ai/scripts/legacy/start-spec-task.sh <spec>
```

- **When appropriate:** SpecRelay is unavailable/broken, or a human needs to
  reproduce exact pre-0085 behavior for comparison.
- **Limitations:** frozen — no new workflow features are added to it (bug
  fixes only when required for rollback safety, e.g. the cross-engine
  ownership guard below); it is expected to be removed in a future task.
- **Cross-engine ownership restriction:** every task's `state.json` records
  which engine owns mutating it (`"engine": "specrelay"`, or absent/legacy
  for a pre-0085 task). SpecRelay's `transitions.sh` already refused to
  mutate a non-SpecRelay-owned task (SDD 0084). SDD 0085 adds the
  symmetric guard on the legacy side: `.ai/scripts/internal/{claim-task,
  requeue-task,accept-review,request-changes,block-task,submit-review,
  finish-task}.sh` and `.ai/scripts/legacy/approve-task.sh` all refuse to
  mutate a task whose `state.json` has `"engine": "specrelay"`. Read-only
  inspection (`show-task.sh`, `list-tasks.sh`) is unaffected by ownership on
  either side. See `tools/specrelay/test/rollback_test.sh` and
  `engine_ownership_cases_test.sh`.
- **Temporary nature:** this directory and mechanism exist only to bridge
  the cutover; see `.ai/scripts/legacy/README.md`.

## H9. Interrupted-task recovery and reviewer execution model (SDD 0085B)

### (a) Interrupted-task recovery: `specrelay task recover`

SpecRelay provides a native command to recover a task that was interrupted
while `EXECUTOR_RUNNING` (e.g. the executor process died, the host was
rebooted, or a run was orphaned):

```
specrelay task recover <task-ref> --reason "<reason>" [--to READY_FOR_EXECUTOR]
```

It moves an interrupted `EXECUTOR_RUNNING` task back to
`READY_FOR_EXECUTOR` only, under these guarantees:

- **Liveness-first refusal.** It checks liveness before doing anything: if a
  live process still owns the task, it refuses and never force-removes a live
  lock.
- **Safe stale-lock reclaim.** It reclaims a stale lock only when the lock is
  owned by a same-host, dead pid; it never reclaims a foreign-host lock.
- **Audited metadata.** It writes audited recovery metadata into the task's
  state (`recovered_at`, `recovered_by`, `recovered_from_state`,
  `recovery_reason`).
- **Evidence preserved.** All existing evidence files are left untouched.
- **Never a review/ownership shortcut.** It never moves a task to
  `READY_FOR_HUMAN_REVIEW` and never changes task ownership.

This is the ONLY supported way out of `EXECUTOR_RUNNING`, besides the
runner-owned `EXECUTOR_RUNNING → READY_FOR_REVIEW` transition (which requires
evidence) and `EXECUTOR_RUNNING → BLOCKED`. Because recovery is SpecRelay-
native, no equivalent path is (or will be) added to the frozen legacy engine
(H7).

### (b) Reviewer execution model (SDD 0085B section 3.7, option (a))

The reviewer runs **synchronously** while the task sits in
`READY_FOR_REVIEW`. There is NO distinct reviewer-running state. An
interrupted reviewer therefore needs no new state and no recovery command —
it is simply re-run from `READY_FOR_REVIEW` via `specrelay resume`. This
reuses the existing state names (Strategy A compatible); no new state name is
introduced.

## H8. Non-goals of 0085

This task explicitly does **not**: delete the legacy engine implementation
or the rollback path; extract SpecRelay into a standalone repository;
publish SpecRelay as a package; auto-commit, auto-merge, or auto-deploy any
dogfood task's changes; redesign the Sprint Insights product; auto-adopt an
active (non-terminal) legacy-owned task into SpecRelay. See
`docs/sdd/0085-add-specrelay-compatibility-shims-and-dogfood-real-workflows/spec.md`,
section 64, for the complete out-of-scope list.
