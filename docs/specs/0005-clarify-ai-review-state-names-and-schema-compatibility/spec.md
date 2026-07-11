# 0005 — Clarify AI review state names and schema compatibility

- **Status:** Draft
- **Spec number:** 0005
- **Spec path:** `docs/specs/0005-clarify-ai-review-state-names-and-schema-compatibility/spec.md`

## Goal

Clarify SpecRelay's task state names, reviewer-result schema, and compatibility rules without breaking existing task evidence or current users.

SpecRelay has evolved from an in-host workflow into a standalone tool. During that evolution, state names, reviewer decision concepts, task metadata, and compatibility behavior have accumulated some ambiguity. The goal of this task is to make the current lifecycle model explicit, stable, and migration-safe.

This task must not rename states recklessly. It must first document the current truth, identify ambiguity, define compatibility policy, and only implement schema/state changes when they are safe, tested, and backwards compatible.

## Context

SpecRelay is now a standalone repository.

Current repository facts to verify during implementation:

- Remote should be `git@github.com:SpecRelay/SpecRelay.git`.
- `VERSION` should be read from `VERSION`.
- Specs live under `docs/specs/<number>-<slug>/spec.md`.
- Spec 0002 fixed non-ASCII shell/global hook noise and added doctor diagnostics.
- Spec 0003 restored live provider terminal output.
- Spec 0004 fixed duplicate transition attempts after accepted reviewer runs.

This task is about lifecycle/schema clarity. It is separate from:

- live provider terminal streaming;
- duplicate human-ready transition warnings;
- ContextPlus setup;
- release/tag/license work;
- Sprint-reports cleanup.

## Problem

SpecRelay's lifecycle contains several related concepts that must be clearly separated:

- task lifecycle state;
- executor status;
- reviewer status;
- reviewer decision/result;
- human-final-review status;
- compatibility metadata such as engine version and schema version.

Some current or historical names may be ambiguous. For example, a task can be ready for automated reviewer work, accepted by automated review, and still pending human review. Names and schema must make these distinctions obvious.

The current implementation may already be functionally correct after spec 0004, but the public contract and stored state shape need to be stable and documented before more users or host repos depend on it.

## Scope

### 1. Repository facts verification

Before implementation, verify and record:

- this is the standalone SpecRelay repository;
- current branch name;
- current `origin` remote;
- current `VERSION`;
- working tree status;
- current state machine implementation files;
- current transition implementation files;
- current workflow implementation files;
- current task metadata/state JSON fields;
- current tests that cover lifecycle and transitions.

Likely files to inspect include, but are not limited to:

- `lib/specrelay/state.sh`
- `lib/specrelay/transitions.sh`
- `lib/specrelay/workflow.sh`
- `lib/specrelay/cli.sh`
- `lib/specrelay/py/state_lib.py`
- `test/state_test.sh`
- `test/transitions_test.sh`
- `test/workflow_fake_provider_test.sh`
- `docs/task-lifecycle.md`
- `docs/current-workflow-contract.md`
- `docs/providers.md`

### 2. Document the current lifecycle truth

Produce a clear lifecycle map based on actual code and tests.

The map must include:

- every valid task state;
- every allowed transition;
- which actor owns each transition;
- where transition authorization is enforced;
- which state is terminal from the automated run perspective;
- what requires human action;
- how reviewer acceptance differs from human approval;
- how request-changes/rework loops are represented;
- how failure/blocking states are represented.

Do not invent the model. Read the code and tests first, then document the current truth.

### 3. Identify naming ambiguity

Identify state or field names that may be misleading.

Examples to evaluate:

- whether `READY_FOR_REVIEW` clearly means ready for automated/AI review;
- whether `READY_FOR_HUMAN_REVIEW` clearly means automated review accepted but human final gate is still pending;
- whether `review_result` is the correct field name for automated reviewer decision;
- whether human review result/status is represented separately enough;
- whether provider failure and reviewer request-changes are clearly different;
- whether state names are too provider-specific or AI-specific;
- whether old host-workflow language still leaks into standalone docs or schema.

This task may conclude that current names are acceptable if documentation and schema compatibility make them clear. Renaming is not required unless it is clearly worth the migration cost.

### 4. Define schema/version compatibility policy

Define how SpecRelay should handle stored task state created by older engine versions.

At minimum, policy must answer:

- Does `state.json` have a schema version today?
- If not, should a schema version be added?
- How should unknown future schema versions behave?
- How should missing older fields be handled?
- Which fields are required for current operation?
- Which fields are optional metadata?
- How should `engine_version` relate to schema compatibility?
- Should SpecRelay refuse to resume incompatible tasks or provide a clear recovery path?

The policy must be implemented only as far as needed and safe in this task. If full migration tooling is too large, define a minimal safe compatibility guard and record follow-ups.

### 5. Preserve existing task evidence

Existing task directories and evidence must remain readable.

The implementation must not:

- rewrite historical task evidence unnecessarily;
- make old accepted tasks unreadable;
- break `show`, `resume`, `doctor`, or task lookup for existing task dirs;
- require manual edits to old state files unless a clear incompatibility is detected and documented.

If a schema field is added, old task files without that field must either still work or fail with a clear, actionable compatibility message.

### 6. State/schema implementation rules

If implementation changes are needed, they must follow these rules:

- transition guards stay strict;
- invalid transitions are still refused;
- accepted reviewer flow still ends cleanly at the human gate;
- request-changes/rework flow still works;
- manual reviewer flow still works;
- blocked/failure states still work;
- task recovery behavior is preserved;
- CLI output remains understandable;
- no hidden state mutation occurs just because a task is inspected.

If renaming a state is proposed, prefer compatibility aliases or an explicit migration plan over immediate destructive rename.

### 7. Documentation

Update active docs where relevant.

Likely docs:

- `docs/task-lifecycle.md`
- `docs/current-workflow-contract.md`
- `docs/commands.md`
- `docs/providers.md`
- `docs/versioning.md`
- `docs/operator-recovery.md`

Docs should clearly explain:

- task state names;
- reviewer decision/result fields;
- human final review gate;
- schema/version compatibility behavior;
- what happens when a task was created by an older SpecRelay version;
- what operators should do when compatibility checks fail.

Do not rewrite unrelated documentation.

### 8. Tests

Add or update tests for lifecycle/schema compatibility.

Required coverage:

- current valid transitions still pass;
- invalid transitions are still refused;
- automated reviewer accepted flow reaches `READY_FOR_HUMAN_REVIEW` cleanly;
- request-changes/rework flow still works;
- manual reviewer path still works or is explicitly verified as unaffected;
- old/minimal `state.json` fixtures remain readable or produce a clear compatibility error;
- unknown future schema versions are handled safely;
- missing optional metadata does not crash normal commands;
- any new schema field is created for new tasks.

Prefer deterministic fake-provider tests over real Claude runs.

## Acceptance criteria

Implementation is complete when:

1. The current lifecycle state model is documented based on real code.
2. Ambiguous state/field names are either clarified in docs or safely improved with compatibility handling.
3. Stored task schema/version compatibility policy is documented.
4. New tasks include any required schema/compatibility metadata if introduced.
5. Existing task directories without new metadata remain readable or fail with clear actionable messages.
6. Valid lifecycle transitions still work.
7. Invalid lifecycle transitions are still refused.
8. Automated reviewer accepted flow reaches `READY_FOR_HUMAN_REVIEW` cleanly.
9. Request-changes/rework flow still works.
10. Manual reviewer path is not broken.
11. `scripts/test` exits 0.
12. `bin/specrelay doctor` passes or reports only intentional documented warnings.
13. `bin/specrelay version` reports the expected version.
14. No unrelated behavior is changed.

## Suggested verification commands

Run and record output for:

~~~sh
git status --short
scripts/test
bin/specrelay doctor
bin/specrelay version
~~~

Also run or inspect deterministic lifecycle tests that prove:

- accepted review reaches `READY_FOR_HUMAN_REVIEW`;
- request-changes returns to the correct executor/rework state;
- invalid transitions still fail;
- old/minimal state fixtures are handled according to the documented compatibility policy.

If a real dogfood run is used as additional evidence, record the relevant final state and evidence files, but do not rely only on a real provider run for automated coverage.

## Non-goals

This task must not:

- implement live provider terminal streaming;
- fix duplicate transition warnings already handled by spec 0004;
- fix non-ASCII hook noise already handled by spec 0002;
- implement ContextPlus setup;
- change Sprint-reports;
- remove the archived Sprint-reports `tools/specrelay/` snapshot;
- choose or change the license;
- tag or publish a release;
- perform a destructive state rename without compatibility;
- rewrite historical task evidence;
- hide real compatibility errors by silently ignoring them.

## Risks

Potential risks:

- breaking old task directories;
- confusing automated reviewer acceptance with human approval;
- weakening transition guards;
- over-engineering schema migration before it is needed;
- introducing a state rename that conflicts with existing evidence;
- breaking host repositories that already have `.specrelay/version` pins;
- changing docs more broadly than necessary.

The implementation must explicitly address these risks.

## Expected follow-up tasks

Likely follow-ups after this task:

1. Improve ContextPlus setup/init/doctor flow.
2. Add release/tag/CI readiness.
3. Add formal migration tooling if schema evolution becomes more complex.
4. Update Sprint-reports host integration after a stable SpecRelay release.

## Human decisions required

- Decide whether current state names should remain stable for now or be renamed with compatibility aliases.
- Decide whether `state.json` should get an explicit schema version in this task or only document current implicit schema behavior.
- Decide how strict resume/show should be with older task state files.
