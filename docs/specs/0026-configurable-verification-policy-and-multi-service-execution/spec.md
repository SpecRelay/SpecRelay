# Spec 0026 — Configurable Verification Policy and Multi-Service Execution

## 1. Status

```yaml
status: proposed
```

## 2. Release metadata

```yaml
release:
  impact: minor
  rationale: Adds a backward-compatible verification-policy engine with multi-service, multi-check, level-aware, dependency-aware, and evidence-producing execution.
```

## 3. Task identity

```text
0026-configurable-verification-policy-and-multi-service-execution
```

## 4. Purpose

SpecRelay currently treats verification primarily as one project-level command.
That model is too limited for real repositories containing multiple services,
languages, toolchains, and verification types.

This specification introduces a first-class verification-policy engine that can:

- define multiple services;
- define multiple checks per service;
- select verification by level;
- select affected services from changed paths;
- execute independent checks in parallel;
- enforce declared dependencies;
- record deterministic evidence per service and command;
- expose results to Executor, Reviewer, Coordinator, task reports, and later UI verification specifications.

This specification is the required architectural foundation for later browser,
Playwright, screenshot, and scenario-evidence capabilities.

## 5. Product decision

Verification is an engine-owned capability.

AI roles may recommend a verification level or inspect verification evidence,
but they must not invent commands, bypass required checks, silently skip failed
checks, or decide that an unavailable required check passed.

The deterministic engine owns:

- configuration parsing and validation;
- changed-path matching;
- service/check selection;
- dependency ordering;
- parallel execution;
- timeout enforcement;
- required/optional semantics;
- result classification;
- durable evidence;
- final verification status.

## 6. Architectural principles

This specification must preserve the following invariants.

### 6.1 Evidence over claims

A check is passed only when its recorded command exits successfully under the
configured policy.

### 6.2 No silent skipping

A required check that cannot run is not skipped. It must become `BLOCKED` or
`FAILED` with an explicit reason.

### 6.3 Deterministic selection

`changed`, `full`, and `flexible` must produce explainable, reproducible check
selection from configuration and repository facts.

### 6.4 AI recommends, engine executes

Executor, Reviewer, and Coordinator may request or recommend a level. The
engine validates the request and runs only configured checks.

### 6.5 Backward compatibility

Existing projects using the current single-command verification configuration
must continue to work without mandatory migration.

### 6.6 Durable and separated evidence

Evidence must be stored per service and per check. Output from concurrent checks
must never be mixed into one ambiguous file.

## 7. Current limitation

The current configuration model is centered around a single command such as:

```yaml
validation:
  full_test_command: bundle exec rspec
```

This cannot accurately model a repository containing, for example:

- a Rails application;
- a Java service;
- a frontend application;
- Terraform infrastructure;
- documentation checks;
- separate unit, lint, type-check, integration, contract, smoke, and UI checks.

It also cannot express:

- which service is affected by a changed file;
- which checks may run in parallel;
- which checks depend on another check;
- which checks are required or optional;
- where a command must run;
- a command-specific timeout;
- whether the full suite belongs in Executor, Reviewer, both, or a final gate;
- separate evidence for each command.

## 8. Scope

This specification introduces:

1. a new `verification:` configuration contract;
2. verification levels `changed`, `full`, and `flexible`;
3. multiple services;
4. multiple checks per service;
5. check kinds;
6. affected-path matching;
7. dependency-aware execution;
8. bounded parallel execution;
9. required and optional checks;
10. per-check timeout handling;
11. per-check durable evidence;
12. verification selection reports;
13. verification result reports;
14. Executor/Reviewer/Coordinator integration;
15. migration support for the legacy single-command configuration;
16. doctor validation and readiness reporting;
17. fake-provider and deterministic tests.

## 9. Out of scope

This specification does not implement:

- application startup orchestration for browser tests;
- Playwright integration;
- screenshot capture;
- screenshot cropping;
- visual comparison;
- scenario-based Markdown evidence packs;
- videos or browser traces;
- artifact repair;
- source-code repair;
- fully autonomous routing;
- full numbered task-artifact directory migration;
- cross-task execution;
- workspace isolation;
- distributed execution;
- remote CI runners.

Those capabilities may build on the verification-policy model introduced here.

## 10. Terminology

### 10.1 Service

A logical repository component with its own working directory and checks.

Examples:

```text
backend
frontend
rules-engine
pdf-factory
infrastructure
shared-docs
```

### 10.2 Check

One configured verification operation.

Examples:

```text
unit
lint
typecheck
integration
contract
smoke
security
custom
```

### 10.3 Verification level

The requested breadth of verification.

Supported values:

```text
changed
full
flexible
```

### 10.4 Required check

A selected check that must pass before the relevant verification gate can pass.

### 10.5 Optional check

A selected check whose failure is recorded and reported but does not by itself
fail the verification gate.

### 10.6 Final gate

The deterministic verification stage that decides whether the selected policy
has passed before human review readiness.

## 11. Verification levels

### 11.1 `changed`

Run checks for services affected by changed files.

Selection must be based on configured path rules and actual changed paths.

The engine must explain:

- which files changed;
- which service each file matched;
- which checks were selected;
- which checks were not selected;
- why the selection was safe.

If changed-path selection is inconclusive, the engine must use a configured safe
fallback. The default safe fallback is `full`.

### 11.2 `full`

Run all checks configured for the full level.

The engine must not silently omit a required service or required check.

### 11.3 `flexible`

`flexible` is policy-driven, not arbitrary AI freedom.

The engine resolves `flexible` using deterministic rules from configuration and
repository facts.

Possible deterministic inputs include:

- changed path count;
- changed service count;
- high-risk path patterns;
- migration/schema changes;
- shared-library changes;
- configuration changes;
- previously failed checks;
- reviewer risk classification;
- coordinator recommendation that remains within configured bounds.

The engine must record why `flexible` resolved to a specific effective level or
check set.

The AI must not be allowed to create a command or remove a required configured
check.

## 12. Configuration contract

The new configuration must live under:

```yaml
verification:
```

A representative configuration:

```yaml
verification:
  version: 1

  defaults:
    level: changed
    changed_fallback: full
    concurrency: 4
    timeout_seconds: 900
    shell: bash

  placement:
    executor: changed
    reviewer: targeted
    final_gate: full

  services:
    - name: backend
      root: services/backend
      affected_paths:
        - services/backend/**
        - shared/contracts/**
      checks:
        - name: unit
          kind: unit
          command: bundle exec rspec
          cwd: services/backend
          timeout_seconds: 1200
          required: true
          levels: [changed, full]
          parallel_group: backend-fast

        - name: lint
          kind: lint
          command: bundle exec rubocop
          cwd: services/backend
          timeout_seconds: 600
          required: true
          levels: [changed, full]
          parallel_group: backend-fast

        - name: integration
          kind: integration
          command: bundle exec rspec spec/integration
          cwd: services/backend
          timeout_seconds: 1800
          required: true
          levels: [full]
          depends_on:
            - backend.unit

    - name: frontend
      root: services/frontend
      affected_paths:
        - services/frontend/**
        - shared/ui/**
      checks:
        - name: unit
          kind: unit
          command: npm test -- --runInBand
          cwd: services/frontend
          required: true
          levels: [changed, full]

        - name: typecheck
          kind: typecheck
          command: npm run typecheck
          cwd: services/frontend
          required: true
          levels: [changed, full]

        - name: build
          kind: build
          command: npm run build
          cwd: services/frontend
          required: true
          levels: [full]
          depends_on:
            - frontend.typecheck
```

## 13. Configuration schema

### 13.1 Top-level fields

Supported top-level fields under `verification:`:

```text
version
defaults
placement
services
risk_rules
```

Unknown fields must fail validation with an actionable message.

### 13.2 Defaults

Supported defaults:

```text
level
changed_fallback
concurrency
timeout_seconds
shell
```

### 13.3 Placement

Placement controls where levels are used.

Supported keys:

```text
executor
reviewer
final_gate
```

Supported values:

```text
none
changed
targeted
full
flexible
```

`targeted` is a Reviewer-facing selection mode that must be resolved to named
configured checks, never arbitrary commands.

### 13.4 Service fields

Each service supports:

```text
name
root
affected_paths
always_affected_by
checks
```

`name` must be unique.

`root` must be repository-relative and must not contain path traversal.

### 13.5 Check fields

Each check supports:

```text
name
kind
command
cwd
timeout_seconds
required
levels
parallel_group
depends_on
enabled
environment
evidence
```

Check identity is:

```text
<service>.<check>
```

Example:

```text
backend.unit
frontend.typecheck
```

Check identities must be unique.

## 14. Check kinds

The engine must recognize at least:

```text
unit
lint
typecheck
build
integration
contract
smoke
security
custom
```

`ui` may be reserved in the schema for the next specification, but this
specification must not implement UI-runtime behavior.

Unknown kinds must fail configuration validation unless `kind: custom` is used.

## 15. Path matching

### 15.1 Affected paths

A service is affected when at least one changed repository-relative path matches
one of its configured patterns.

### 15.2 Shared paths

A shared path may affect multiple services.

Example:

```yaml
affected_paths:
  - shared/contracts/**
```

The engine must select every matching service.

### 15.3 Unmatched changed paths

Unmatched changed paths must not be silently ignored.

The engine must follow `changed_fallback`.

The default is:

```text
full
```

### 15.4 Deleted and renamed files

Deleted and renamed paths must participate in matching using both old and new
paths where available.

## 16. Flexible risk rules

Optional risk rules may elevate verification.

Example:

```yaml
verification:
  risk_rules:
    - name: shared-contract-change
      paths:
        - shared/contracts/**
      force_level: full
      rationale: Shared contracts may affect every service.

    - name: database-migration
      paths:
        - "**/db/migrate/**"
      require_checks:
        - backend.integration
```

Rules must be deterministic and ordered.

If multiple rules match, the strictest resulting selection wins.

The engine must record all matched rules.

## 17. Dependency graph

Checks may depend on other checks through `depends_on`.

The engine must:

- validate that every dependency exists;
- reject cycles before execution;
- not start a check before all required dependencies pass;
- mark a dependent check `BLOCKED_BY_DEPENDENCY` when a dependency fails;
- preserve dependency evidence.

Optional dependency behavior must not be inferred. Dependencies are strict by
default.

## 18. Parallel execution

### 18.1 Concurrency

The engine may execute independent checks concurrently up to the configured
concurrency limit.

### 18.2 Deterministic reporting

Runtime execution may be concurrent, but final reporting order must be
deterministic.

Recommended ordering:

1. service declaration order;
2. dependency order;
3. check declaration order.

### 18.3 Output separation

Each check must have separate stdout and stderr files.

Concurrent output must not be merged into one ambiguous stream.

### 18.4 Terminal streaming

Live terminal output may be prefixed by service and check, for example:

```text
[verify:backend.unit]
[verify:frontend.typecheck]
```

Durable files remain the source of truth.

## 19. Timeout behavior

Each check may define `timeout_seconds`.

If absent, the default timeout applies.

On timeout:

- terminate the process safely;
- record timeout status;
- record elapsed duration;
- preserve captured stdout/stderr;
- fail the gate if the check is required;
- warn without failing the gate if optional;
- never report timeout as pass.

## 20. Required and optional semantics

### 20.1 Required

A required selected check must pass.

Possible terminal statuses:

```text
PASSED
FAILED
TIMED_OUT
BLOCKED
BLOCKED_BY_DEPENDENCY
CONFIGURATION_ERROR
```

Only `PASSED` satisfies the requirement.

### 20.2 Optional

An optional selected check may produce:

```text
PASSED
FAILED_OPTIONAL
TIMED_OUT_OPTIONAL
BLOCKED_OPTIONAL
```

Optional failure must remain visible in summary and evidence.

## 21. Verification placement policy

The configuration must support where verification happens.

Example:

```yaml
placement:
  executor: changed
  reviewer: targeted
  final_gate: full
```

### 21.1 Executor

The Executor usually runs fast checks relevant to its changes.

Recommended default:

```text
changed
```

### 21.2 Reviewer

The Reviewer runs independent, risk-based checks.

Recommended default:

```text
targeted
```

The Reviewer must not simply repeat the complete Executor command list without
reason.

### 21.3 Final gate

The final gate runs the configured release-confidence verification.

Recommended default:

```text
full
```

### 21.4 Wasteful configuration warning

Doctor or configuration validation should warn when the same full suite is
configured for Executor, Reviewer, and final gate without an explicit rationale.

This is a warning, not an automatic rewrite.

## 22. Legacy configuration compatibility

Existing configuration such as:

```yaml
validation:
  full_test_command: bundle exec rspec
```

must remain supported.

The engine must translate it internally to an effective legacy service/check:

```text
service: project
check: full-test
kind: custom
required: true
levels: [full]
```

The compatibility path must be visible in doctor/report output as:

```text
Verification configuration: legacy single-command mode
```

If both legacy and new verification configuration are present, the engine must
fail with an ambiguity error rather than guessing.

## 23. Selection request contract

AI roles may request verification using a structured request.

Example:

```json
{
  "requested_level": "full",
  "requested_checks": [],
  "reason_code": "final_gate",
  "reason": "All implementation work is complete and final verification is required."
}
```

The engine must validate the request against configured policy.

A role may request a narrower set only when policy permits it.

A role may not:

- submit arbitrary shell commands;
- refer to an unknown check;
- disable a required check;
- mark a failed check as passed;
- claim unavailable evidence exists.

## 24. Coordinator integration

The Coordinator decision vocabulary remains unchanged in this specification.

`RUN_TARGETED_VERIFICATION` must map to configured check identities selected by
the deterministic engine.

The Coordinator may recommend:

- a configured level;
- a configured named check set;
- escalation from changed to full;
- human intervention when required checks are unavailable.

The engine must independently validate the recommendation.

The Coordinator must not construct commands.

## 25. Executor integration

The Executor prompt must include:

- effective verification placement;
- selected level;
- selected services;
- selected checks;
- required/optional classification;
- check identities;
- evidence locations;
- the rule that it must not silently skip required checks.

Executor completion must fail when required Executor verification evidence is
missing.

## 26. Reviewer integration

The Reviewer must receive:

- the same effective verification configuration snapshot;
- Executor verification selection and results;
- final gate results when available;
- explicit optional failures;
- selection rationale;
- changed-path-to-service mapping.

The Reviewer must independently verify that:

- required checks were selected correctly;
- failures were not hidden;
- optional checks were not misrepresented;
- the full gate, when required, actually ran;
- no check was silently skipped.

## 27. Verification artifacts

Until the complete task-artifact directory migration is implemented, use an
additive compatibility layout under the existing task directory.

Required artifacts:

```text
14-verification-plan.json
15-verification-summary.json
16-verification-summary.md
verification/
  selection.json
  services/
    <service>/
      <check>/
        command.json
        stdout.txt
        stderr.txt
        result.json
```

The exact numeric filenames may be adjusted only if they conflict with an
existing reserved artifact. The selected names must be documented and stable.

## 28. Verification plan artifact

`14-verification-plan.json` must include at least:

```json
{
  "schema_version": 1,
  "requested_level": "changed",
  "effective_level": "full",
  "phase": "final_gate",
  "changed_paths": [],
  "matched_risk_rules": [],
  "selected_services": [],
  "selected_checks": [],
  "skipped_checks": [],
  "fallback_reason": null,
  "concurrency": 4
}
```

Every skipped configured check must have an explicit reason.

## 29. Per-check command artifact

`command.json` must include:

```json
{
  "service": "backend",
  "check": "unit",
  "identity": "backend.unit",
  "kind": "unit",
  "command": "bundle exec rspec",
  "cwd": "services/backend",
  "timeout_seconds": 1200,
  "required": true,
  "dependencies": [],
  "parallel_group": "backend-fast"
}
```

## 30. Per-check result artifact

`result.json` must include:

```json
{
  "schema_version": 1,
  "identity": "backend.unit",
  "status": "PASSED",
  "exit_code": 0,
  "started_at": "...",
  "finished_at": "...",
  "duration_seconds": 42.8,
  "timed_out": false,
  "blocked_by": [],
  "stdout_path": "stdout.txt",
  "stderr_path": "stderr.txt"
}
```

## 31. Verification summary artifact

`15-verification-summary.json` must include:

- requested level;
- effective level;
- phase;
- overall status;
- required pass/fail counts;
- optional pass/fail counts;
- service summaries;
- check summaries;
- matched risk rules;
- fallback reason;
- duplicate execution detection;
- start/end/duration;
- whether final gate requirements are satisfied.

`16-verification-summary.md` must provide a human-readable equivalent.

## 32. Overall verification status

Supported overall statuses:

```text
PASSED
FAILED
BLOCKED
NOT_REQUIRED
NOT_RECORDED
```

Rules:

- `FAILED` when a required selected check fails or times out;
- `BLOCKED` when a required selected check cannot start;
- `PASSED` only when every required selected check passes;
- `NOT_REQUIRED` only when policy explicitly selects no checks;
- `NOT_RECORDED` only for historical tasks without verification evidence.

## 33. Task report integration

The following commands must show concise verification information:

```text
specrelay task show <task-ref>
specrelay task report <task-ref>
specrelay task report <task-ref> --json
```

Human-readable output must include:

- requested/effective level;
- selected services/check count;
- required failures;
- optional failures;
- overall status;
- evidence path.

## 34. CLI behavior

Add or extend a read-only planning command:

```text
specrelay verification plan [--level changed|full|flexible] [--changed-from <ref>] [--json]
```

Purpose:

- validate configuration;
- show selected services/checks;
- show dependency order;
- show fallback/risk-rule decisions;
- perform no verification command execution.

Add an execution command only if it fits existing CLI architecture cleanly:

```text
specrelay verification run [--level changed|full|flexible] [--phase executor|reviewer|final_gate]
```

If execution remains internal to `run`/`resume`, document that decision and do
not add a redundant public command.

## 35. Doctor behavior

`specrelay doctor` must report:

- verification configuration mode: new / legacy / absent;
- configuration schema validity;
- number of configured services;
- number of configured checks;
- default level;
- changed fallback;
- concurrency;
- placement policy;
- missing working directories;
- dependency cycles;
- unknown dependencies;
- duplicate service/check identities;
- unsafe paths;
- warning for repeated full-suite placement;
- ready/not ready.

Doctor must not execute configured test commands.

## 36. Configuration errors

The following must fail before verification execution:

- unknown configuration fields;
- duplicate service names;
- duplicate check names inside a service;
- duplicate check identities;
- missing command;
- invalid `cwd`;
- absolute or traversing `cwd`;
- invalid timeout;
- invalid required flag;
- unsupported level;
- unknown dependency;
- dependency cycle;
- invalid concurrency;
- simultaneous legacy and new configuration.

## 37. Security rules

The engine must:

- reject absolute/traversing service roots and check working directories;
- never evaluate AI-provided shell text;
- use only configured commands;
- preserve command text exactly in evidence;
- avoid logging secret environment values;
- allow configured environment variable names but redact configured secret
  values from durable evidence;
- not execute commands outside the project root unless explicitly supported by
  a future security specification.

## 38. Environment variables

A check may declare non-secret environment variables.

Secret values must not be stored in task artifacts.

The configuration may refer to environment variable names, but evidence should
record only:

```json
{
  "environment_names": ["RAILS_ENV", "DATABASE_URL"],
  "redacted_names": ["DATABASE_URL"]
}
```

## 39. Duplicate execution detection

The engine must detect when an identical check was already executed for the same:

- task;
- iteration;
- phase;
- effective configuration;
- working-tree state or evidence snapshot.

It may reuse prior passing evidence only when a future explicit reuse policy
allows it. This specification must at minimum report duplicates and avoid
silently claiming reused evidence as newly executed evidence.

## 40. Historical tasks

Tasks created before this specification must report:

```text
Verification policy: not recorded
```

They must not fabricate service/check evidence.

## 41. Documentation requirements

Update at least:

```text
README.md
docs/architecture.md
docs/configuration.md
docs/task-lifecycle.md
docs/verification-and-timeline.md
docs/commands.md
docs/operator-recovery.md
docs/roadmap/architecture-roadmap.md
docs/roadmap/current-plan.md
```

Documentation must explain:

- verification levels;
- multi-service configuration;
- check dependencies;
- parallel execution;
- required/optional behavior;
- placement policy;
- evidence paths;
- legacy compatibility;
- safe fallback;
- why UI verification remains a later specification.

## 42. Architecture documentation

`docs/architecture.md` must include a diagram similar to:

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

It must state explicitly:

```text
AI roles request verification intent.
The deterministic engine selects and executes configured checks.
```

## 43. Required tests

At minimum, add deterministic tests for the following.

### 43.1 Legacy configuration

Existing single-command configuration continues to work.

### 43.2 New configuration parsing

A valid multi-service configuration is accepted.

### 43.3 Unknown fields

Unknown fields fail validation.

### 43.4 Duplicate service

Duplicate service names fail validation.

### 43.5 Duplicate check

Duplicate check identities fail validation.

### 43.6 Changed selection

Changed paths select only affected services/checks.

### 43.7 Shared path

One changed shared path selects multiple services.

### 43.8 Unmatched path fallback

An unmatched changed path triggers the configured fallback.

### 43.9 Full level

Full selects every configured full-level required check.

### 43.10 Flexible deterministic resolution

Flexible resolves through configured rules and records why.

### 43.11 Risk escalation

A risk rule elevates changed to full.

### 43.12 Dependency order

A dependent check runs only after its dependency passes.

### 43.13 Dependency failure

A dependent check becomes `BLOCKED_BY_DEPENDENCY`.

### 43.14 Dependency cycle

A cycle fails before execution.

### 43.15 Parallel execution

Independent checks execute concurrently within the configured limit.

### 43.16 Deterministic output order

Final report ordering is stable despite concurrent completion order.

### 43.17 Timeout

A required timed-out check fails the gate.

### 43.18 Optional timeout

An optional timed-out check is visible but does not fail the gate.

### 43.19 Required failure

A required non-zero exit fails the gate.

### 43.20 Optional failure

An optional non-zero exit is reported without failing the gate.

### 43.21 Evidence separation

Each check has separate command/stdout/stderr/result files.

### 43.22 No output mixing

Concurrent output does not mix between evidence files.

### 43.23 Unsafe cwd

Absolute and traversing working directories are rejected.

### 43.24 Unknown dependency

Unknown dependency identity fails validation.

### 43.25 Placement policy

Executor/Reviewer/final-gate placement resolves correctly.

### 43.26 Wasteful configuration warning

Full-suite execution in all phases produces a warning.

### 43.27 Coordinator recommendation

`RUN_TARGETED_VERIFICATION` maps only to configured checks.

### 43.28 Arbitrary command rejection

AI-provided command text is rejected and never executed.

### 43.29 Task report

Task show/report include verification summaries.

### 43.30 Historical task

A historical task reports verification as not recorded.

### 43.31 Doctor states

Doctor reports new, legacy, invalid, absent, and ready states accurately.

### 43.32 No silent skip

A missing required command/cwd/tool does not become pass or skipped success.

### 43.33 Deleted/renamed path handling

Old/new paths participate in changed selection.

### 43.34 Environment redaction

Secret values do not appear in durable evidence.

## 44. Fake verification support

Tests must not depend on real language toolchains.

Provide deterministic fixture commands capable of:

```text
pass
fail
timeout
emit stdout
emit stderr
sleep
record start/end
assert cwd
assert environment
```

## 45. Performance requirements

- Planning must complete quickly for normal repositories.
- Parallel execution must be bounded.
- The engine must not start one process per check without respecting the
  concurrency limit.
- The verification planner must not repeatedly scan the repository for each
  check when one normalized changed-path set is sufficient.

## 46. Completion gates

The task may reach `READY_FOR_REVIEW` only when:

- new and legacy configuration paths work;
- configuration validation is strict;
- changed/full/flexible planning works;
- multi-service selection works;
- dependency execution works;
- bounded parallel execution works;
- timeout behavior works;
- required/optional semantics work;
- per-check evidence is complete;
- task reports and doctor are updated;
- documentation is updated;
- focused tests pass;
- full repository suite passes, except only independently proven pre-existing
  failures that are recorded explicitly;
- required Executor artifacts are complete;
- `08-executor-summary.md` includes the required sections below.

## 47. Required Executor summary sections

`08-executor-summary.md` must include:

```markdown
## Verification Architecture
```

```markdown
## Configuration Contract
```

```markdown
## Selection and Dependency Rules
```

```markdown
## Evidence Model
```

```markdown
## Backward Compatibility
```

```markdown
## Input Coverage
```

## 48. Required Reviewer section

`09-consultant-review.md` must include:

```markdown
## Verification Policy Safety Review
```

It must independently cover:

- no arbitrary AI command execution;
- required-check enforcement;
- no silent skipping;
- changed-path selection;
- fallback behavior;
- dependency validation;
- timeout behavior;
- parallel output isolation;
- evidence completeness;
- backward compatibility;
- task-report accuracy.

An ACCEPT decision is invalid without this section.

## 49. Acceptance criteria

The specification is accepted when all of the following are true:

1. A project can configure multiple services.
2. Each service can configure multiple checks.
3. `changed`, `full`, and deterministic `flexible` levels work.
4. Changed paths map explainably to services.
5. Unmatched paths trigger an explicit safe fallback.
6. Dependencies are validated and enforced.
7. Independent checks run concurrently within a bound.
8. Required and optional semantics are correct.
9. Timeouts are enforced and evidenced.
10. Every selected check has isolated durable evidence.
11. Executor, Reviewer, Coordinator, and task reports consume the same result
    model.
12. AI roles cannot inject commands or suppress required checks.
13. Doctor validates configuration without running commands.
14. Legacy single-command configuration remains supported.
15. Historical tasks remain readable.
16. The full suite introduces no unaccounted regression.

## 50. Risk analysis

### High — Policy complexity

A flexible configuration model can become difficult to understand.

Mitigation:

- strict schema;
- explicit planning output;
- deterministic selection;
- doctor validation;
- safe fallback.

### High — False confidence from skipped checks

Mitigation:

- no silent skipping;
- required checks fail/block explicitly;
- skipped checks always include reasons.

### High — AI command injection

Mitigation:

- AI may request only configured identities/levels;
- command text comes exclusively from configuration.

### Medium — Excessive full-suite execution

Mitigation:

- placement policy;
- changed selection;
- targeted reviewer checks;
- warnings for wasteful configuration.

### Medium — Non-deterministic concurrent logs

Mitigation:

- per-check evidence files;
- deterministic final ordering.

### Medium — Configuration drift

Mitigation:

- capture effective verification configuration for each task;
- resume uses the captured task configuration rather than silently changing.

## 51. Effective configuration capture

At first verification planning for a task, SpecRelay must snapshot the effective
verification configuration or a canonical digest sufficient to reproduce it.

Resume must not silently switch to a changed project verification policy.

If a changed configuration is incompatible with the captured task policy, the
engine must refuse or require explicit human recovery.

## 52. Rollback behavior

The implementation must be additive.

Rollback consists of disabling or removing the new `verification:` block and
continuing through the legacy compatibility path.

The implementation must not require destructive migration of historical task
evidence.

## 53. Expected implementation order

Recommended order:

1. define schema and validation;
2. implement legacy translation;
3. implement normalized service/check model;
4. implement changed-path matching;
5. implement full/flexible selection;
6. implement dependency graph validation;
7. implement bounded parallel runner;
8. implement per-check evidence;
9. implement overall result classification;
10. integrate Executor/Reviewer/Coordinator;
11. integrate task reports and doctor;
12. update documentation and roadmap;
13. add focused tests;
14. run full suite and verify regressions.

## 54. Deliverables

Expected deliverables include, subject to repository architecture:

```text
lib/specrelay/verification_policy.sh
lib/specrelay/verification_runner.sh
lib/specrelay/py/verification_policy_lib.py
```

or equivalent modules following existing conventions.

Also:

```text
test/verification_policy_engine_test.sh
test/verification_multi_service_test.sh
```

or equivalent focused tests.

Update all documentation listed in section 41.

## 55. Release behavior

After implementation and human acceptance:

```text
bin/specrelay release plan
```

must identify this specification as a pending `minor` impact source.

No commit, push, tag, or release may happen automatically.

## 56. Input coverage

The implementation must inspect and account for every input in the immutable
specification bundle.

The Executor and Reviewer must include explicit `## Input Coverage` sections as
required by spec 0023.

## 57. Final definition of done

This specification is complete when SpecRelay no longer treats verification as
one opaque project command, but as a deterministic, explainable, multi-service,
multi-check policy with safe selection, dependencies, parallelism, timeout
handling, required/optional semantics, and durable evidence — while preserving
legacy projects and leaving UI runtime/evidence-pack work to the next
specifications.
