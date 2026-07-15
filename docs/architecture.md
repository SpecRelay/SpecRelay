# SpecRelay Architecture

SpecRelay is a standalone tool with exactly one coherent supported
architecture: a versioned source-local/installed CLI, its own reusable engine
code, and a thin project-configuration seam for whatever repository it
inspects.

## 1. Supported execution modes

**Source-local execution.** Inside the standalone SpecRelay checkout:

```
bin/specrelay <command>
```

Source-local execution always uses the current checkout and never performs
installed-CLI update checks.

**Installed execution.** Inside a consumer repository (or any compatible
working directory):

```
specrelay <command>
```

The installed CLI resolves its installed resources according to the current
installation contract (see docs/installation.md) and may perform update
behavior according to existing policy.

## 2. Ownership boundaries

A **consumer project** may own:

- `.specrelay/config.yml`, `.specrelay/version`
- `.specrelay-runs/` (its task runtime)
- its own specs and its own source code

A consumer project must not own or vendor the SpecRelay source tree.

The **standalone SpecRelay repository** owns:

- `bin/`, `lib/`, `install/`, `templates/`, `test/`, `docs/`
- `VERSION` and release metadata

## 3. Core vs Adapters vs Project Configuration

```text
SpecRelay Core                Provider Adapters              Project Configuration
lib/specrelay/                lib/specrelay/providers/        .specrelay/
├── task lifecycle             ├── fake                       ├── paths (specs.root,
├── state machine              ├── claude                     │   tasks.runs_root)
├── evidence                   └── future providers           ├── validation
├── orchestration               lib/specrelay/context/         │   (full_test_command)
└── contracts                   ├── none                       ├── policies
                                └── contextplus                │   (human_final_review_
                                                                │    required)
                                                                └── project-specific
                                                                    constraints
```

- `lib/specrelay/state.sh` + `py/state_lib.py`, `task.sh`, `lock.sh`,
  `auth.sh`, `transitions.sh`, `git_guard.sh`, `evidence.sh`, `workflow.sh`
  are Core: the task lifecycle, state machine, evidence capture, locking,
  and orchestration, with no provider- or project-specific literals.
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
- `lib/specrelay/project.sh`, `discovery.sh`, `config.sh` are Core-shaped:
  project-root discovery, migration-assistance discovery, and config
  loading.

## 4. Command flow

```text
User command
    │
    ▼
SpecRelay CLI (bin/specrelay, or the installed `specrelay`)
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
```

## 5. Task ownership

Every task's `state.json` records which engine owns mutating it
(`"engine": "specrelay"`). Read-only inspection commands (`show`/`status`/
`list`) work regardless of ownership, including for a historical task that
predates this field entirely; mutating commands refuse a task they do not
own, naming the reason explicitly.

## 6. Interrupted-task recovery

SpecRelay provides a native command to recover a task that was interrupted
while `EXECUTOR_RUNNING` (e.g. the executor process died, the host was
rebooted, or a run was orphaned):

```
specrelay task recover <task-ref> --reason "<reason>" [--to READY_FOR_EXECUTOR]
```

It moves an interrupted `EXECUTOR_RUNNING` task back to `READY_FOR_EXECUTOR`
only, under these guarantees:

- **Liveness-first refusal.** It checks liveness before doing anything: if a
  live process still owns the task, it refuses and never force-removes a
  live lock.
- **Safe stale-lock reclaim.** It reclaims a stale lock only when the lock is
  owned by a same-host, dead pid; it never reclaims a foreign-host lock.
- **Audited metadata.** It writes audited recovery metadata into the task's
  state (`recovered_at`, `recovered_by`, `recovered_from_state`,
  `recovery_reason`).
- **Evidence preserved.** All existing evidence files are left untouched.
- **Never a review/ownership shortcut.** It never moves a task to
  `READY_FOR_HUMAN_REVIEW` and never changes task ownership.

This is the only supported way out of `EXECUTOR_RUNNING`, besides the
runner-owned `EXECUTOR_RUNNING → READY_FOR_REVIEW` transition (which requires
evidence) and `EXECUTOR_RUNNING → BLOCKED`.

## 7. Reviewer execution model

The reviewer runs synchronously while the task sits in `READY_FOR_REVIEW`.
There is no distinct reviewer-running state. An interrupted reviewer
therefore needs no new state and no recovery command — it is simply re-run
from `READY_FOR_REVIEW` via `specrelay resume`.

## 8. Hybrid AI coordination model (spec 0025)

SpecRelay's engine is, and remains, a deterministic state machine. Spec 0025
adds one advisory AI role — the **coordinator** — above the Executor and
Reviewer, without changing that fact. The central rule, enforced
structurally (not merely by prompt wording):

```text
AI roles interpret and recommend.
The deterministic engine validates and transitions.
```

```text
User
  │
  ▼
Coordinator (advisory: interprets context, recommends ONE next action)
  │  structured decision, validated deterministically
  ▼
Deterministic SpecRelay Engine (computes allowed actions, validates, transitions)
  │
  ▼
Executor ──▶ Deterministic Validation ──▶ Reviewer ──▶ Coordinator ──▶ Human Decision
```

The coordinator is never the owner of the state machine. It cannot:

- edit `state.json`, transition metadata, or any task artifact;
- mint or consume authorization tokens, or manage locks;
- call a transition function, `specrelay run`/`resume`, or any `task
  <transition>` command directly;
- run shell commands or fabricate verification evidence;
- decide human acceptance, or reinterpret a Reviewer's ACCEPT/REQUEST_CHANGES.

Concretely: the engine computes an `allowed_next_actions` allowlist for each
bounded invocation point (`before_executor`, `executor_completion_failed`,
`executor_completed`, `reviewer_completed`, `changes_requested`,
`recovery_requested`, `human_handoff_preparation`); the coordinator selects
exactly one value from that list and returns it as a single structured JSON
object; `lib/specrelay/py/coordinator_lib.py` validates every field
deterministically (schema, task/invocation-point match, path safety,
constraints, vocabulary) before `lib/specrelay/coordinator.sh` dispatches it.
Dispatch itself only ever calls **pre-existing, independently-guarded**
transition functions (e.g. `specrelay::transitions::block`, which
re-validates the current state on its own) — an invalid or out-of-policy
coordinator response can never mutate task state. See docs/task-lifecycle.md
("AI Coordinator invocation points") and docs/configuration.md
("`roles.coordinator`") for the full contract.

Coordinator support is additive and disabled by default
(`roles.coordinator.enabled: false`); every project without it configured
behaves exactly as before spec 0025.

## 9. History

SpecRelay was originally incubated inside a host repository before being
extracted into this standalone repository. That former in-host layout
(`tools/specrelay/`, `.ai/scripts/` compatibility shims, `.ai-runs/` task
runtime) is no longer a supported product surface — see docs/migration.md if
you are migrating a project away from it. The historical incubation and
dogfooding record is preserved in CHANGELOG.md and the historical reports
under docs/ (each labelled as historical).
