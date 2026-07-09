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

## Current incubation status (v0.1)

SpecRelay is being incubated **inside** the Sprint Reports repository, which
already has a working, production AI workflow built directly as shell
scripts (see `tools/specrelay/docs/current-workflow-contract.md` for its full
behavioral contract). This incubation:

- documents that existing workflow's actual behavior and separates what is
  generic from what is provider-specific or repository-specific
  (`docs/knowledge-boundaries.md`);
- provides an initial, **read-only** discovery/inspection CLI;
- provides a minimal, safe project-configuration format and loader
  (`.specrelay/config.yml`).

**Workflow execution is explicitly not migrated yet.** The existing
production workflow remains authoritative; see `docs/architecture.md` for the
planned migration stages.

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

Both `project inspect` and `workflow inspect` are strictly read-only: they
never create, modify, or delete a task, a config file, or any workflow state.

## Not yet available (v0.1)

Task lifecycle and execution commands are intentionally unimplemented and
fail clearly rather than pretending to work:

```bash
tools/specrelay/bin/specrelay run
# specrelay: command 'run' is not implemented.
# SpecRelay workflow execution is not available in incubation version 0.1.
# Use the existing repository workflow for execution.
```

The same honest failure applies to `task create`, `review`, and any other
workflow-execution command. Use the existing repository workflow
(`.ai/scripts/`) for actual task execution today.

## Future direction

See `docs/architecture.md` for the full picture: migrating the task
lifecycle/state machine/evidence engine into SpecRelay behind a
core/adapter/project-configuration split, dogfooding it on real tasks
alongside the existing workflow, and eventually extracting it into a
standalone repository with its own distribution.
