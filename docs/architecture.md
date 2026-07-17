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

### Two-layer project configuration (spec 0027)

Project Configuration is no longer a single file read at run time.
`lib/specrelay/config_local.sh` is the ONE merge engine: it reads
`.specrelay/config.yml` (shared, committed) and the optional, Git-ignored
`.specrelay/config.local.yml` (personal, sparse overrides) exactly once per
invocation, deep-merges them (mappings recurse; lists replace wholesale,
never concatenate; an explicit YAML `null` in the local file deletes an
inherited key; a mapping/scalar type conflict at the same path fails with a
path-specific error), and retains per-leaf provenance — which layer
supplied each value, and what (if anything) it overrode — rather than
reconstructing that after the fact.

Every existing `config.sh` accessor that must honor the overlay
(`get`, `role_context`, `role_model_selection`, `verification_policy`,
`phase_budgets`, `execution_efficiency_policy`, `coordinator_policy`, ...)
reads through this SAME merged data
(`specrelay::config::effective_data_yaml`) instead of reading
`.specrelay/config.yml` directly — there is no separate, reduced "local
schema" and no second code path that only some accessors honor. This keeps
the full precedence order (`built-in defaults < .specrelay/config.yml <
.specrelay/config.local.yml < environment-variable overrides < CLI flags`)
uniform everywhere a configuration value is read, from `doctor` and
`project inspect` to `run`/`resume` to the read-only `config show`/`config
explain` commands. See [docs/configuration.md](configuration.md), "Local
developer configuration overlay (spec 0027)," for the full merge contract,
secret redaction, and task-capture/resume behavior.

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

## 9. Verification-policy engine (spec 0026)

Verification is an engine-owned capability, not an AI-invented command. AI
roles (Executor, Reviewer, Coordinator) may request or recommend a
verification level or a named check set; the deterministic engine alone
resolves what actually runs and executes it:

```text
AI role requests level/check set
              │
              ▼
Deterministic verification planner
  changed paths + config + risk rules
              │
              ▼
Selected service/check dependency graph
              │
              ▼
Bounded parallel executor
              │
              ▼
Per-check durable evidence
              │
              ▼
Deterministic verification gate
```

The engine (`lib/specrelay/verification_policy.sh` for configuration/
planning/reporting, `lib/specrelay/verification_runner.sh` for execution,
both backed by `lib/specrelay/py/verification_policy_lib.py`) owns:
configuration parsing/validation, changed-path matching, service/check
selection for the `changed`/`full`/`flexible` levels, dependency-graph
validation and ordering, bounded parallel execution with per-check
timeouts, required/optional result classification, and durable per-check
evidence (`26-verification-plan.json`, `27-verification-summary.json`,
`28-verification-summary.md`, and `verification/services/<service>/<check>/
{command.json,stdout.txt,stderr.txt,result.json}` in the task directory).
A project's existing single-command `validation.full_test_command` continues
to work unmodified, translated internally to an equivalent one-service,
one-check configuration (`project.full-test`); a project may not configure
both at once (an ambiguity error, not a silently-resolved default). The
`kind: ui` check this specification reserved in the schema is implemented by
spec 0028 (below): its `command:` runs exactly like any other check here —
the UI-specific detection/scenario/evidence engine lives entirely in
`lib/specrelay/py/ui_verification_lib.py`.

See docs/verification-and-timeline.md ("Verification-policy engine") and
docs/configuration.md ("`verification.*`, spec 0026") for the full
configuration contract, and docs/task-lifecycle.md for the artifact layout.

## 10. UI runtime verification (spec 0028)

A passing unit test is never proof the user interface works. For a task
that changes user-visible behaviour, `verification.ui` adds a first-class,
deterministic UI-verification capability alongside the engine above:

```text
verification.ui.enabled: true | false | auto
              │
              ▼
UI-impact detection (changed paths, spec-language keywords,
supplied expected references, explicit metadata) — recorded WITH reasons
              │
              ▼
Scenario selection (manifest / bundle / acceptance criteria) + coverage check
              │
              ▼
Runtime readiness (start command or external, ready URL, provider/browser)
              │
              ▼
Playwright (or the deterministic fake provider) executes each scenario
              │
              ▼
Screenshot crop/dedup/size policy + console/network capture+redaction
+ optional expected-reference comparison
              │
              ▼
PASS | FAIL | BLOCKED per scenario, never silently skipped
              │
              ▼
Reviewer evidence validation → compact publication (verification/ui/)
```

`lib/specrelay/ui_verification.sh` (bash wrapper) and
`lib/specrelay/py/ui_verification_lib.py` (the deterministic engine, mirroring
`verification_policy_lib.py`'s division of labor: Ruby parses the
`verification.ui` config section and the scenario manifest YAML; Python owns
schema validation, detection, selection, execution, screenshot policy,
redaction, comparison, artifact writing, and publication) own: UI-impact
detection with recorded reasons, scenario-manifest schema validation,
scenario selection and acceptance-criterion coverage, runtime-readiness
checks, PASS/FAIL/BLOCKED classification, compact checkpoint-screenshot
evidence (locator/region capture preferred, exact-digest dedup, size/
dimension limits with a bounded optimization attempt, no retained source
image by default), browser-console/network capture with secret redaction,
expected-reference comparison (sha256-exact, since this reference
implementation adds no new image-diff dependency), and the compact
publication package.

Runtime diagnostics live at `<task-dir>/29-ui-verification/` (never
committed); compact, Reviewer-validated evidence publishes to
`<spec-directory>/verification/ui/` only after `specrelay ui publish`
confirms a Reviewer '## UI Verification Evidence Review' section exists
(publication refuses otherwise, even with `--dry-run`). The completion gate
lives in `transitions.sh::accept` — the ONLY path into
`READY_FOR_HUMAN_REVIEW` — so neither an automated Reviewer nor the AI
Coordinator (spec 0025) can bypass it; the Coordinator's `dispatch()` never
enacts `SEND_TO_REVIEW` in the first place (see coordinator.sh).

Playwright is the initial real provider (`lib/specrelay/js/
ui_playwright_runner.js`, invoked over stdin/stdout JSON, never given
repository tool access beyond browser automation); `provider: fake` is a
deterministic, no-browser-required substitute this project's OWN test suite
always uses (SpecRelay itself has no web UI to point a real browser at — a
consuming project supplies its own Playwright installation and application
runtime).

See docs/verification-and-timeline.md ("UI runtime verification") and
docs/configuration.md ("`verification.ui.*`, spec 0028") for the full
configuration contract, and docs/task-lifecycle.md for the artifact layout.

## 11. History

SpecRelay was originally incubated inside a host repository before being
extracted into this standalone repository. That former in-host layout
(`tools/specrelay/`, `.ai/scripts/` compatibility shims, `.ai-runs/` task
runtime) is no longer a supported product surface — see docs/migration.md if
you are migrating a project away from it. The historical incubation and
dogfooding record is preserved in CHANGELOG.md and the historical reports
under docs/ (each labelled as historical).

## Engine-owned executor finalization (spec 0029)

Executor finalization and required-verification execution are owned by the
deterministic engine, not the AI Executor process — closing the "provider
exited successfully but the round was never finished" failure class (specs
0027/0028's dirty-tree/requeue and UI-verification-timing limitations
compound directly into this one). New modules, each with a narrow,
non-overlapping responsibility (no module reaches across these boundaries
by directly mutating another's private files):

- `lib/specrelay/finalization.sh` / `py/finalization_lib.py` — phase
  orchestration, the durable finalization record, digest comparisons, and
  human-readable artifact rendering (`03-executor-log.md`, `07-tests.txt`,
  the operator card).
- `lib/specrelay/py/proc_supervisor.py` — portable process/session-group
  supervision only (spec 0029, section 22).
- `lib/specrelay/lock.sh` — extended with the execution-owner lease and
  heartbeat (section 21); still owns leases/liveness classification only.
- `lib/specrelay/git_guard.sh` — extended with the round-change ledger and
  pre-provider snapshot/reconstruction (section 23); still owns provenance/
  ownership derivation only.
- `lib/specrelay/workflow.sh` — coordinates lifecycle order only: it calls
  into `finalization.sh` for each phase rather than implementing artifact
  rendering, lease parsing, process-group termination, or ledger
  reconstruction itself.

See `docs/task-lifecycle.md` ("Engine-owned executor finalization"),
`docs/verification-and-timeline.md` ("Engine-owned verification execution"),
`docs/operator-recovery.md` ("Execution-owner lease and natural resume"),
and `docs/providers.md` for the full detail.
