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
- **0085 — compatibility shims and dogfooding.** Not yet started. Introduce a
  way for `.ai/scripts/` to optionally delegate to the SpecRelay engine, and
  begin running real Sprint Reports tasks through it to validate behavioral
  parity end-to-end on real (not fixture) specs.
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
