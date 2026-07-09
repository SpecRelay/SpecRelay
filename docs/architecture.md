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

At this stage (SDD 0083), `tools/specrelay/` contains only:

- the behavioral contract and knowledge-boundary docs that ground everything
  that comes after (`docs/current-workflow-contract.md`,
  `docs/knowledge-boundaries.md`);
- a read-only discovery/inspection CLI (`bin/specrelay`) that can describe a
  project's SpecRelay configuration and the legacy workflow it finds on disk;
- a minimal, safe project-config loader.

It does **not** yet contain a task lifecycle, a state machine, or any
executor/reviewer invocation logic — those still live entirely in `.ai/` and
are explicitly out of scope for this task (see H4).

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

Today's incubation already reflects the shape of this split, even though
Core is thin:

- `lib/specrelay/project.sh` and `lib/specrelay/discovery.sh` are Core-shaped:
  generic, filesystem-driven discovery with no Sprint-Reports-specific
  literals.
- `lib/specrelay/config.sh` is Core-shaped: it knows the generic
  `.specrelay/config.yml` schema, not this repository's specific values.
- `.specrelay/config.yml` is Project Configuration: the only place the real
  paths/commands/policy for *this* repository are written down.
- There are no Provider Adapters yet because there is no execution engine
  yet; `docs/knowledge-boundaries.md` (C2) records what a Claude adapter
  would need to encode once one exists.

## H3. Future migration stages

These are roadmap items, not requirements of this task:

- **0084 — migrate workflow engine into SpecRelay.** Port the task lifecycle,
  state machine, and evidence-capture logic described in
  `docs/current-workflow-contract.md` into `tools/specrelay/lib/specrelay/`,
  behind the same Core/Adapter/Config separation, while `.ai/` remains the
  production path until the port is proven equivalent.
- **0085 — compatibility shims and dogfooding.** Introduce a way for
  `.ai/scripts/` to optionally delegate to the SpecRelay engine, and begin
  running real Sprint Reports tasks through it to validate behavioral parity
  (including the known dirty-tree/requeue gap recorded in
  `current-workflow-contract.md` §9, which the migrated engine should fix).
- **0086 — standalone repository extraction.** Once dogfooded, extract
  `tools/specrelay/` into its own repository/package with its own
  versioning, README, and distribution, keeping `.specrelay/`-style
  project configuration as the integration seam for any consuming project.

## H4. Non-goals of 0083

This task explicitly does **not**:

- replace the current `.ai/` workflow;
- redirect `start-spec-task.sh` (or any other public `.ai/scripts/` command)
  to SpecRelay;
- delete `.ai/` or `.ai-runs/`;
- run any task-engine execution via SpecRelay (`specrelay run` and similar
  commands intentionally fail with a clear "not available in incubation
  version 0.1" message — see `README.md`);
- migrate any provider (Claude, Codex) integration into SpecRelay;
- extract SpecRelay into a standalone repository;
- publish a package (no Homebrew formula, no npm/pip/gem distribution).
