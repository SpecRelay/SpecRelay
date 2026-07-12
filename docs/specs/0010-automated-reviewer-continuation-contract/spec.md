# Spec 0010 — Automated reviewer continuation contract

## Status

Draft

## Context

SpecRelay's intended workflow is automated until `READY_FOR_HUMAN_REVIEW`.
The executor should not leave the operator responsible for manually resuming the reviewer phase when an automated reviewer is configured.

`READY_FOR_REVIEW` is still a useful state in the lifecycle, but it should be treated as an internal handoff state for automated review, not as the normal endpoint of a successful automated run.

## Problem

`READY_FOR_REVIEW` currently exists between executor completion and reviewer execution. In practice, a `specrelay run` or `specrelay resume` invocation can appear to stop there, requiring the operator to run another `resume` even when the reviewer provider is automated.

That is not the desired SpecRelay contract.

SpecRelay should automate the executor-reviewer loop until one of these explicit endpoints is reached:

- `READY_FOR_HUMAN_REVIEW` after automated reviewer acceptance;
- `CHANGES_REQUESTED` only as an internal loop state before requeueing the executor, unless max iterations or another explicit guard stops the workflow;
- `READY_FOR_REVIEW` only when the reviewer provider is explicitly `manual`, or when reviewer execution fails or is unavailable;
- another explicit failure/recovery state with clear logging.

## Desired contract

`READY_FOR_REVIEW` is an internal handoff state for automated reviewer execution.

If the effective reviewer provider is not `manual`, then both `specrelay run <spec>` and `specrelay resume <task>` must continue from `READY_FOR_REVIEW` into reviewer execution in the same invocation.

The normal successful automated path is:

~~~text
READY_FOR_EXECUTOR
-> EXECUTOR_RUNNING
-> READY_FOR_REVIEW
-> reviewer execution
-> READY_FOR_HUMAN_REVIEW
~~~

The command should only stop at `READY_FOR_REVIEW` when one of these is true:

1. the effective reviewer provider is explicitly `manual`;
2. the reviewer provider fails or is unavailable;
3. the workflow is intentionally interrupted or recoverable;
4. the maximum iteration limit or another explicit guard stops it.

Stopping at `READY_FOR_REVIEW` must never be silent. The operator must see a clear reason.

## Required implementation

### 1. Audit workflow continuation

Audit:

- `lib/specrelay/workflow.sh`
- CLI `run` and `resume` paths
- any state dispatch logic that decides what to do after executor submission
- manual reviewer handling
- reviewer failure handling

Ensure that automated reviewer continuation works for both:

- `specrelay run <spec>`
- `specrelay resume <task>`

### 2. Continue automatically for automated reviewers

When the effective reviewer provider is not `manual`, a successful executor round must not leave the operator to manually start the reviewer.

After executor outputs are captured and the task transitions to `READY_FOR_REVIEW`, the same invocation should run the reviewer unless an explicit guard stops it.

This must work when starting from:

- `READY_FOR_EXECUTOR`
- `READY_FOR_REVIEW`
- `CHANGES_REQUESTED` followed by requeue into a new executor round

### 3. Preserve manual reviewer behavior

Manual reviewer mode remains supported, but it must be explicit.

When the effective reviewer provider is `manual`:

- the workflow may stop at `READY_FOR_REVIEW`;
- the command should return the existing intentional handoff status;
- the log must clearly say that manual reviewer mode is configured;
- the log must tell the operator what to do next, such as `specrelay task accept` or `specrelay task request-changes`.

Manual reviewer mode should be documented as an explicit opt-out / safe bootstrap mode, not the intended automated AI workflow.

### 4. Add explicit stop reasons

Whenever a command exits while the task is still `READY_FOR_REVIEW`, it must log a clear reason.

Examples:

~~~text
[reviewer] reviewer provider is 'manual'; stopping at READY_FOR_REVIEW for human review
~~~

~~~text
[reviewer] automated reviewer failed; task remains READY_FOR_REVIEW for recovery/resume
~~~

~~~text
[workflow] maximum iteration limit reached; task remains READY_FOR_REVIEW
~~~

The workflow must not silently stop at `READY_FOR_REVIEW` when an automated reviewer is configured.

### 5. Keep human final review unchanged

This spec does not remove human final review.

`READY_FOR_HUMAN_REVIEW` remains the normal endpoint after automated reviewer acceptance.

Humans still make final merge/release decisions outside the automated executor-reviewer loop.

## Documentation updates

Update relevant docs, likely including:

- `README.md`
- `docs/configuration.md`
- `docs/providers.md`
- `docs/commands.md` if applicable
- workflow/lifecycle docs if present

Clarify:

- `READY_FOR_REVIEW` is not the normal final state for automated workflows;
- `READY_FOR_REVIEW` is an internal handoff state when the reviewer is automated;
- `READY_FOR_HUMAN_REVIEW` is the normal successful endpoint of the automated workflow;
- `manual` reviewer mode is an explicit opt-out / safe bootstrap mode;
- automated reviewer failures leave the task at `READY_FOR_REVIEW` with a clear recovery reason.

## Required tests

Add or update deterministic tests using fake providers. Do not require real Claude in CI.

Required coverage:

1. `specrelay run <spec>` with fake executor and fake reviewer reaches `READY_FOR_HUMAN_REVIEW` in one invocation.
2. `specrelay resume <task>` starting from `READY_FOR_EXECUTOR` with automated reviewer reaches `READY_FOR_HUMAN_REVIEW` in one invocation.
3. `specrelay resume <task>` starting from `READY_FOR_REVIEW` with automated reviewer runs reviewer and reaches `READY_FOR_HUMAN_REVIEW`.
4. No second manual `resume` is required for an automated reviewer success path.
5. Manual reviewer mode stops at `READY_FOR_REVIEW` and prints a clear human handoff message.
6. Reviewer failure leaves the task at `READY_FOR_REVIEW` and reports the failure clearly.
7. Request-changes flow still requeues executor and continues the automated loop until acceptance or max iterations.
8. Existing lifecycle tests still pass.

## Non-goals

This spec does not:

- remove `READY_FOR_REVIEW` from the state machine;
- remove manual reviewer support;
- remove human final review;
- add a new provider;
- change model or agent selection semantics from spec 0009;
- change terminal rendering/formatting behavior;
- change release packaging or Homebrew behavior.

## Verification

Run from the repository root:

~~~bash
HOME="$(mktemp -d)" GIT_CONFIG_NOSYSTEM=1 ./scripts/test
./scripts/smoke
SPECRELAY_PROVIDER_OPTIONAL=1 bin/specrelay doctor
bin/specrelay version
~~~

All must pass.

## Expected report

The executor should report:

- changed files;
- before/after workflow behavior;
- exact tests added or updated;
- exact verification results;
- any intentional remaining cases where `READY_FOR_REVIEW` is a valid stopping point.

Do not commit automatically.
