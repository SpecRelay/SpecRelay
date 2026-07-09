# SpecRelay

SpecRelay is a file-based workflow for turning an approved specification into
a reviewed, evidence-backed code change with two cooperating AI roles — an
**executor** and a **reviewer** — and a human who stays in control at every
gate.

## The problem it solves

Handing a specification to an AI agent and trusting its own summary of what
it did does not scale: agents can drift from scope, skip verification, or
quietly approve their own work. SpecRelay's answer is a durable, file-based
task record that is **restartable from disk only** (never from session
memory), a strict separation between the agent that *implements* a task and
the agent that *reviews* it, and a set of state transitions where the
highest-risk step — an executor moving its own task to "ready for review" —
is authorized out-of-band rather than trusted to the agent's good behavior.

## Executor / reviewer concept

- **Executor** — implements one approved task, writes an implementation log,
  tests, and a summary. Never creates the next task, never continues
  automatically, and never decides that its own work is done.
- **Reviewer** — a fresh, isolated context (never a continuation of the
  executor) that verifies the executor's evidence against the real working
  tree and the original task, then decides exactly one of: accept, or
  request changes.
- **Role vs. provider** are distinct: which concrete tool plays the executor
  or reviewer role is swappable configuration, not something baked into the
  task lifecycle.

## Evidence-driven review

Every task accumulates a durable evidence packet — git status/diff
snapshots, the executor's log/tests/summary, the reviewer's notes — captured
independently of whichever provider produced the work. The reviewer is
expected to verify against the real working tree and evidence, not just trust
a narrative summary.

## Human final gate

Nothing in SpecRelay commits, pushes, merges, publishes, or deploys anything,
at any stage. A human approves before execution starts, and a human performs
final review and decides what happens next after a task is accepted. This is
a hard design boundary, not a missing feature.

## Current status (SDD 0084)

SpecRelay is being incubated **inside** the Sprint Reports repository, which
already has a working, production AI workflow built directly as shell
scripts (see `tools/specrelay/docs/current-workflow-contract.md` for its full
behavioral contract). As of SDD 0084, SpecRelay has a **real, executable
workflow engine**:

- a durable task lifecycle (create → approve → executor round → evidence
  capture → reviewer round → accept/request-changes → requeue → ... →
  human-review gate), implemented in `tools/specrelay/lib/specrelay/`;
- executor/reviewer provider adapters (a deterministic `fake` provider for
  tests, and a real `claude`/`claude-subagent` adapter);
- a context-capability adapter seam (`none`, `contextplus`);
- runner-owned transition authorization, task locking, and a dirty-tree/
  rework-loop guard that fixes a known limitation of the legacy engine (see
  `docs/engine-parity.md`).

**This is NOT yet the repository's cutover.** The existing `.ai/` workflow
remains the authoritative engine for real Sprint Reports tasks; no public
`.ai/scripts/` command has been redirected to SpecRelay, and none of `.ai/`
or `.ai-runs/` has been touched. See `docs/engine-parity.md` for the detailed
capability-by-capability comparison and `docs/architecture.md` for the
planned migration stages (SDD 0085 is the compatibility-shim/dogfooding
cutover).

## Quick CLI examples

```bash
tools/specrelay/bin/specrelay version
# specrelay 0.1.0

tools/specrelay/bin/specrelay help

tools/specrelay/bin/specrelay project root
# /path/to/your/project

tools/specrelay/bin/specrelay project inspect
# Project root: /path/to/your/project
# Config file (.specrelay/config.yml): present
# Project name: ...
# Configured spec root: ...
# Configured task-run root: ...
# Configured validation command: ...
# Detected legacy/current AI workflow location: ...

tools/specrelay/bin/specrelay workflow inspect
# Legacy/current AI workflow root: ...
# Public workflow entry points: ...
# Internal helper root: ...
# Protocol file: ...
# Reviewer contract file: ...
# Task run root: ...
# Detected provider integration locations: ...
```

`project inspect` and `workflow inspect` remain strictly read-only: they
never create, modify, or delete a task, a config file, or any workflow state.

## Workflow engine examples

```bash
# Run a spec through the full lifecycle (create, approve, executor/reviewer
# rounds, up to the configured maximum iterations):
tools/specrelay/bin/specrelay run docs/sdd/<task-id>/spec.md

# Inspect one task or every known task:
tools/specrelay/bin/specrelay show <task-id>
tools/specrelay/bin/specrelay status
tools/specrelay/bin/specrelay list

# Resume a task from wherever it is (never restarts from the beginning):
tools/specrelay/bin/specrelay resume <task-id>

# Lower-level, single-purpose commands (manual recovery / decoupled flows):
tools/specrelay/bin/specrelay task create <spec-path>
tools/specrelay/bin/specrelay task approve <task-id>
tools/specrelay/bin/specrelay task accept <task-id>
tools/specrelay/bin/specrelay task request-changes <task-id> "<reason>"
tools/specrelay/bin/specrelay task requeue <task-id>
tools/specrelay/bin/specrelay task block <task-id> "<reason>"
```

`<task-id>` also accepts a unique numeric prefix or partial slug (e.g. `show
0084`); an ambiguous reference fails clearly rather than guessing.

Provider and context-capability adapters are project configuration
(`.specrelay/config.yml`'s `roles.executor.provider` /
`roles.reviewer.provider` / `context.adapter`), never hardcoded — see
`templates/project-config.yml` and `docs/engine-parity.md`.

`review` and any other not-yet-implemented command still fail clearly rather
than pretending to work.

## Future direction

See `docs/architecture.md` for the full picture: migrating the task
lifecycle/state machine/evidence engine into SpecRelay behind a
core/adapter/project-configuration split, dogfooding it on real tasks
alongside the existing workflow, and eventually extracting it into a
standalone repository with its own distribution.
