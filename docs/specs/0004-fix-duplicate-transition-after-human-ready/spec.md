# 0004 — Fix duplicate transition after human-ready review
- **Status:** Draft
- **Spec number:** 0004
- **Spec path:** `docs/specs/0004-fix-duplicate-transition-after-human-ready/spec.md`
## Goal
Fix the non-blocking but confusing duplicate transition attempt that appears after a task has already reached `READY_FOR_HUMAN_REVIEW`.
Observed warning:
```text
Refusing to transition task in state 'READY_FOR_HUMAN_REVIEW'. Allowed source states: READY_FOR_REVIEW.

This warning appears after the reviewer has accepted the task and the task has already transitioned successfully to READY_FOR_HUMAN_REVIEW.

The task outcome is usually correct, but the extra warning makes the run look partially broken. The runner should stop cleanly after the accepted reviewer transition and should not attempt a second invalid transition.

Context

SpecRelay is a standalone repository.

Current repository facts to verify during implementation:

* Remote should be git@github.com:SpecRelay/SpecRelay.git.
* VERSION should be recorded.
* Specs live under docs/specs/<number>-<slug>/spec.md.
* Spec 0002 has been completed and pushed.
* Spec 0003 may be running in a separate worktree/branch and may touch related workflow/provider files.

This task is about lifecycle correctness and terminal trust. It is separate from:

* non-ASCII hook/test noise;
* live provider terminal streaming;
* ContextPlus setup;
* state/schema naming cleanup;
* release/tag/license work.

Problem

When the reviewer accepts a task, SpecRelay transitions:

READY_FOR_REVIEW -> READY_FOR_HUMAN_REVIEW

After that, the runner appears to attempt another transition that expects the task to still be in READY_FOR_REVIEW. Since the state is already READY_FOR_HUMAN_REVIEW, the transition layer correctly refuses it.

The refusal is technically correct, but the runner should not make that second transition attempt.

The correct behavior is:

1. reviewer accepts;
2. state transitions once to READY_FOR_HUMAN_REVIEW;
3. runner prints a clean success message;
4. run exits successfully without transition warnings.

Scope

1. Repository and baseline verification

Before implementation, verify and record:

* this is the standalone SpecRelay repository;
* current branch name;
* current origin remote;
* current VERSION;
* working tree status;
* current task/state transition implementation files;
* current workflow implementation files;
* current tests that cover reviewer acceptance and final human-ready state.

2. Reproduce the issue

Create or use a deterministic test path that reproduces the duplicate transition attempt.

The reproduction should show:

* reviewer returns accepted;
* first transition succeeds to READY_FOR_HUMAN_REVIEW;
* a second invalid transition is attempted from READY_FOR_HUMAN_REVIEW;
* warning/error text is emitted.

Prefer a deterministic fake provider test over a real Claude provider run.

If the issue cannot be reproduced after current branch changes, inspect recent code and add a regression test that would have failed under the old behavior.

3. Identify the real source

Inspect the code paths involved in:

* executor completion;
* transition to READY_FOR_REVIEW;
* reviewer execution;
* reviewer accepted result handling;
* transition to READY_FOR_HUMAN_REVIEW;
* final runner return/exit behavior;
* any cleanup/finalization path that may re-submit or re-transition.

Likely files to inspect include, but are not limited to:

* lib/specrelay/workflow.sh
* lib/specrelay/transitions.sh
* lib/specrelay/state.sh
* lib/specrelay/cli.sh
* provider adapter files under lib/specrelay/providers/
* workflow and transition tests under test/

Do not assume the source. Confirm it from code and tests.

4. Correct transition ownership

The fix must make transition ownership clear.

Expected ownership:

* executor path owns transition from EXECUTOR_RUNNING to READY_FOR_REVIEW;
* reviewer accepted path owns transition from READY_FOR_REVIEW to READY_FOR_HUMAN_REVIEW;
* after READY_FOR_HUMAN_REVIEW, the run loop must stop cleanly;
* no path should attempt to transition a task out of READY_FOR_HUMAN_REVIEW during the same accepted run.

If a helper currently performs an unconditional submit/accept/final transition, make it state-aware or remove the duplicate call.

Do not weaken transition guards. The transition layer should continue refusing invalid transitions. The runner should stop making the invalid call.

5. Preserve lifecycle semantics

The implementation must preserve:

* DRAFT -> READY_FOR_EXECUTOR;
* READY_FOR_EXECUTOR -> EXECUTOR_RUNNING;
* EXECUTOR_RUNNING -> READY_FOR_REVIEW;
* READY_FOR_REVIEW -> REVIEWER_RUNNING, if that state exists in current implementation;
* reviewer accepted flow to READY_FOR_HUMAN_REVIEW;
* reviewer request-changes flow back to executor/rework state;
* failure behavior;
* manual reviewer behavior;
* fake provider tests;
* max iteration handling;
* evidence capture.

If actual current state names differ from the list above, document the current names and preserve the current intended behavior. Do not do a state/schema rename in this task.

6. Tests

Add or update tests so this bug cannot return.

Required test coverage:

* accepted automated reviewer reaches READY_FOR_HUMAN_REVIEW;
* accepted automated reviewer does not emit the duplicate transition warning;
* accepted automated reviewer exits successfully;
* state file ends in READY_FOR_HUMAN_REVIEW;
* request-changes path still works;
* failure path still works;
* manual reviewer path still works or is explicitly verified as unaffected.

The tests should assert absence of the warning text:

Refusing to transition task in state 'READY_FOR_HUMAN_REVIEW'

If exact text is too brittle, assert the absence of the invalid transition attempt in a stable way.

7. Documentation

Update docs only where relevant.

Candidate docs:

* docs/task-lifecycle.md
* docs/current-workflow-contract.md
* docs/commands.md
* docs/providers.md

Docs should explain the clean accepted-review outcome if the current docs are unclear.

Do not make broad doc rewrites.

Acceptance criteria

Implementation is complete when:

1. The duplicate transition warning no longer appears after an accepted reviewer run.
2. A deterministic automated test proves the accepted reviewer path stops cleanly at READY_FOR_HUMAN_REVIEW.
3. Existing lifecycle guards remain strict; invalid transitions are still refused when genuinely attempted.
4. Request-changes/rework flow still works.
5. Failure flow still works.
6. Manual review flow is not broken.
7. Evidence files are still produced correctly.
8. scripts/test exits 0.
9. bin/specrelay doctor passes or reports only intentional documented warnings.
10. bin/specrelay version reports the expected version.
11. No unrelated behavior is changed.
12. If spec 0003 changes related workflow/provider files, merge/rebase conflicts are resolved intentionally and tests are rerun.

Suggested verification commands

Run and record output for:

git status --short
scripts/test
bin/specrelay doctor
bin/specrelay version

Also run or inspect a deterministic fake-provider workflow test that exercises accepted reviewer behavior and confirms:

* final state is READY_FOR_HUMAN_REVIEW;
* no duplicate transition warning is printed;
* process exits successfully.

If a real dogfood run is used as additional evidence, record the relevant terminal output and final state.json, but do not rely only on a real provider run for automated coverage.

Non-goals

This task must not:

* implement live provider terminal streaming;
* change provider output streaming behavior from spec 0003;
* fix non-ASCII global hook noise;
* implement ContextPlus setup;
* rename states or schema fields;
* change Sprint-reports;
* choose or change the license;
* tag or publish a release;
* weaken transition validation;
* hide transition errors globally;
* silence all transition errors by redirecting output;
* remove evidence files.

Risks

Potential risks:

* hiding a real transition bug instead of fixing duplicate ownership;
* weakening transition guards;
* breaking request-changes/rework loop;
* breaking manual reviewer flow;
* introducing conflict with spec 0003 if both touch workflow/provider execution paths;
* making tests pass by matching brittle terminal text only.

The implementation must address these risks with code-level reasoning and tests.

Expected follow-up tasks

Likely follow-ups after this task:

1. Merge/rebase with spec 0003 if both touched workflow/provider files.
2. Clarify AI review state names and schema compatibility.
3. Improve ContextPlus setup/init/doctor flow.
4. Improve release/tag/CI readiness.

Human decisions required

* Decide merge order if spec 0003 and spec 0004 both change workflow files. Preferred order: merge 0003 first if it changes provider execution heavily, then rebase 0004; otherwise merge the smaller accepted branch first.
* Decide whether any current lifecycle docs should be treated as normative or historical if they disagree with actual code.

