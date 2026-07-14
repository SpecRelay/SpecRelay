# Bounded Verification, Review Policy, and Execution Timeline
- Spec: 0019
- Status: Draft
---
# Summary
Improve SpecRelay execution efficiency, reviewer discipline, decision
reliability, and performance observability.
Recent real SpecRelay tasks have taken approximately:
```text
0016: about 54 minutes
0017: about 52 minutes including a repeated review
0018: about 95 minutes including a repeated review

The parallel test runner and change-aware test selection reduced standalone test
wall time significantly, but overall tasks remain too slow.

The remaining delays come from:

* repeated full-suite executions
* repeated focused tests
* duplicate smoke and doctor checks
* broad repository exploration
* polling and waiting
* reviewers acting like a second executor
* reviewers repeating verification already supported by valid evidence
* reviewers terminating without a required decision marker
* complete review repetition after only the decision marker was missing
* no durable execution timeline
* no clear report showing where time was spent

This specification introduces:

* bounded verification policy
* risk-based reviewer verification
* structured AI reviewer contract
* mandatory decision marker guarantees
* narrow decision-marker recovery
* execution timeline instrumentation
* verification ledger
* duplicate-work reporting
* phase budgets and warnings
* final human-readable performance tables
* machine-readable execution metrics
* no new top-level runtime directory

The objective is to reduce execution time without weakening correctness,
independent review, evidence quality, or final human approval.

⸻

Problem

SpecRelay currently allows Executor and Reviewer agents broad freedom to:

* inspect the entire repository repeatedly
* run the same tests multiple times
* run the full standalone suite more than once
* run smoke after smoke has already been proven
* repeat doctor and version checks
* wait on long-running commands through repeated polling
* finish without an explicit review decision marker

This freedom has resulted in unnecessarily long executions.

A representative Executor may perform:

focused test
focused test again
full suite
change-aware suite
smoke
full suite again
doctor
version

The Reviewer may then perform:

full repository inspection
focused test
full suite
smoke
doctor
version

If the Reviewer forgets:

DECISION: ACCEPT

the entire review may be repeated from the beginning on resume.

This is wasteful and does not improve trust proportionally.

SpecRelay also lacks a reliable final report that answers:

* How long did the entire task take?
* How long did Executor and Reviewer each take?
* How much time was spent in tests?
* How many test suites were executed?
* Were any commands duplicated?
* How much time was spent waiting?
* Which phase was the bottleneck?
* Did a phase exceed its expected budget?
* Was full verification completed?
* Was Reviewer verification targeted or full?
* Was review repeated because of a missing marker?

Without this information, performance problems are diagnosed by intuition rather
than evidence.

⸻

Goals

* Reduce unnecessary repeated verification.
* Preserve independent Reviewer judgment.
* Introduce explicit verification budgets.
* Make full-suite execution an intentional operation.
* Require a reason for additional full-suite execution.
* Prefer change-aware and targeted testing during implementation.
* Preserve one final full-suite gate when repository policy requires it.
* Prevent Reviewer from blindly repeating the Executor’s complete verification.
* Improve the AI Reviewer template.
* Introduce risk-based review.
* Introduce structured findings and severity levels.
* Guarantee a final machine-readable decision marker.
* Recover a missing marker without repeating the entire review.
* Record execution timing for major orchestration phases.
* Record verification commands and durations.
* Record duplicate operations.
* Print a final execution timeline table.
* Write machine-readable timeline evidence.
* Warn when phases exceed configured soft budgets.
* Keep output append-only, scrollable, copyable, and redirectable.
* Reuse existing .specrelay-runs and .specrelay-cache namespaces.
* Avoid adding any new top-level runtime directory.

⸻

Non-Goals

This specification does not:

* reduce correctness standards
* remove independent Reviewer verification
* trust Executor evidence blindly
* remove the final human-review gate
* skip tests silently
* replace CI full verification
* introduce flaky-test retries
* terminate a valid long-running Executor automatically
* impose hard timeouts on implementation by default
* estimate unavailable provider metrics dishonestly
* fabricate command classification
* parse arbitrary natural-language logs as precise timing evidence
* create a dashboard or TUI
* introduce cursor movement or screen redraw
* add a new top-level runtime folder
* redesign the complete provider architecture
* solve distributed background execution

⸻

Core Principles

1. Independence Is Not Blind Repetition

The Reviewer must make an independent judgment.

This does not require repeating every command executed by the Executor.

Executor evidence is:

reviewable evidence

It is neither:

automatically trusted truth

nor:

information that must be discarded and reproduced from zero

The Reviewer must inspect evidence, assess risk, and independently verify the
highest-risk claims.

⸻

2. Targeted During Development, Full at the Final Gate

Preferred Executor workflow:

implementation
→ targeted/change-aware verification
→ final full suite once
→ smoke --skip-tests

The Executor must not run the full suite after every edit.

⸻

3. Additional Verification Requires a Reason

Repeated expensive verification is allowed only when justified.

Example:

ADDITIONAL_VERIFICATION_REASON:
The test runner itself changed after the previous full-suite result.

No additional full-suite run may occur silently.

⸻

4. Metrics Must Be Honest

SpecRelay may report only timings it can measure reliably.

If a time period cannot be classified precisely, report:

agent_tool_execution_unclassified

Do not invent a split between:

coding
analysis
testing
waiting

unless instrumentation proves it.

⸻

5. Stream-Friendly Output Remains Mandatory

All output remains:

* append-only
* visible
* copyable
* redirectable
* non-interactive
* understandable without color

No output may be erased or replaced.

⸻

Scope Overview

This specification contains five connected capabilities:

A. Bounded verification policy
B. Reviewer Policy v2
C. Decision-marker guarantee and smart recovery
D. Execution timeline and verification ledger
E. Phase budgets and performance reporting

⸻

A. Bounded Verification Policy

Verification Levels

Define explicit verification levels:

focused
targeted
full
smoke

Focused

One or more directly relevant test files.

Example:

scripts/test test/contextplus_adapter_test.sh

Targeted

Change-aware test selection.

Example:

scripts/test --changed --jobs auto --timings --explain

Full

Complete standalone suite.

Example:

scripts/test --jobs auto --timings

Smoke

Packaging and installation validation.

Example:

scripts/smoke --skip-tests

⸻

Executor Verification Policy

Default Executor policy:

focused runs: allowed as needed
targeted runs: allowed as needed, but duplicates must be reported
full-suite runs: maximum 1 without explicit override reason
smoke runs: maximum 1 without explicit override reason
doctor runs: maximum 1 final run without explicit override reason
version runs: maximum 1 final run without explicit override reason

This is a default policy, not an absolute ban.

Additional expensive runs require a recorded reason.

⸻

Reviewer Verification Policy

Default Reviewer policy:

focused runs: maximum 3
targeted runs: maximum 1
full-suite runs: default 0
smoke runs: default 0
doctor runs: maximum 1
version runs: maximum 1

A Reviewer may run the full suite when justified by risk.

Examples:

* test runner changed
* test helper changed
* workflow core changed
* state-machine transitions changed
* selection map changed
* Executor evidence is missing
* Executor test result failed
* evidence fingerprint does not match current tree
* changed files trigger full-suite fallback
* security-sensitive behavior changed
* broad-impact code changed

The Reviewer must record a reason before the full suite starts.

⸻

Verification Policy Configuration

Add configuration following existing .specrelay/config.yml conventions.

Conceptual configuration:

verification:
  executor:
    full_suite_max_runs: 1
    smoke_max_runs: 1
    doctor_max_runs: 1
    version_max_runs: 1
  reviewer:
    default_mode: targeted
    focused_max_runs: 3
    targeted_max_runs: 1
    full_suite_max_runs: 0
    smoke_max_runs: 0
    doctor_max_runs: 1
    version_max_runs: 1

Exact parser structure may be refined.

Requirements:

* sensible defaults exist
* missing configuration remains backward compatible
* invalid negative values are rejected
* non-integer limits are rejected
* unknown values are rejected where strict validation is appropriate
* policy is visible through doctor or another inspection command
* policy is captured durably for each task

⸻

Soft Limit versus Hard Refusal

Default verification limits should be enforced at two levels.

Prompt-Level Policy

The Executor and Reviewer prompts explicitly instruct agents not to exceed the
budget without justification.

Engine-Level Observation

SpecRelay records detected verification operations and reports violations.

The initial implementation may use:

warning + explicit reason requirement

rather than killing arbitrary agent commands.

Hard blocking is required only where SpecRelay directly owns the command and can
enforce it safely.

Do not claim enforcement over commands hidden inside provider execution unless
the engine can actually observe them.

⸻

Verification Operation Classification

SpecRelay must classify known verification commands where reliably possible.

At minimum recognize:

scripts/test
scripts/test --changed
scripts/test --changed-files
scripts/test <explicit test files>
scripts/smoke
scripts/smoke --skip-tests
bin/specrelay doctor
bin/specrelay version

Classification must distinguish:

test_focused
test_targeted
test_full
smoke
doctor
version

Unknown commands remain:

agent_tool_execution_unclassified

Do not guess from vague command text.

⸻

Repeated Verification Reporting

If an operation occurs more than once, report:

Duplicate verification detected:
  full suite: 2 runs
  doctor:     2 runs

A duplicate is not automatically a failure.

The report must distinguish:

justified duplicate
unjustified duplicate

where justification is available.

⸻

Verification Reasons

Support durable reason recording.

Conceptual event:

{
  "operation": "test_full",
  "reason": "The test runner changed after the first full-suite run."
}

Prompt conventions may include:

FULL_SUITE_REASON:
...
ADDITIONAL_VERIFICATION_REASON:
...

The engine must not infer reasons from unrelated prose where a structured reason
is required.

⸻

Final Verification Gate

Current project policy continues to require full verification before final merge
unless separately changed.

This specification must not silently redefine:

targeted verification

as:

full verification

Task output and artifacts must state which verification level completed.

Example:

Verification result:
  Targeted: passed
  Full:     passed
  Smoke:    passed with standalone suite explicitly skipped

⸻

B. Reviewer Policy v2

Reviewer Role

The Reviewer is not a second Executor.

The Reviewer must:

* identify defects
* validate acceptance criteria
* inspect real code and evidence
* test high-risk behavior independently
* assess residual risk
* reject unsupported claims
* avoid unrelated implementation work
* avoid broad repository exploration without justification
* stop when sufficient evidence exists

The Reviewer must not:

* rewrite the implementation
* refactor code for personal preference
* repeat every Executor command automatically
* run the complete suite merely because it is available
* reject on style preference alone
* continue exploring after a clear decision is justified

⸻

Risk Classification

The Reviewer must classify the change:

low
medium
high
critical

Low Risk

Examples:

* documentation-only change
* comments
* output formatting with strong focused coverage
* narrow non-behavioral change

Expected verification:

evidence inspection
focused tests
no full suite by default

Medium Risk

Examples:

* one adapter
* one provider capability
* one configuration parser branch
* contained CLI behavior

Expected verification:

evidence inspection
one or more focused tests
possibly targeted selection
no full suite unless justified

High Risk

Examples:

* state machine
* workflow orchestration
* provider execution
* Git guard
* test runner
* task recovery
* evidence authorization
* security or secret handling

Expected verification may include:

focused tests
targeted tests
full suite when justified

Critical Risk

Examples:

* destructive file operations
* credential handling
* cross-repository mutation
* release installation behavior
* task ownership boundaries

Expected verification must be explicitly documented.

⸻

Reviewer Template Structure

Replace or upgrade the AI Reviewer template.

The template must require the following sequence:

1. Read the Spec and extract acceptance criteria.
2. Inspect the real working tree and current diff.
3. Inspect Executor evidence.
4. Classify change risk.
5. Select the minimum sufficient independent verification.
6. Record reasons for expensive verification.
7. Evaluate each acceptance criterion.
8. Record blocking findings and residual risks.
9. Write review artifacts.
10. Emit exactly one final decision marker.

⸻

Reviewer Evidence Intake

The Reviewer should inspect available files such as:

03-executor-log.md
04-git-status.txt
05-changed-files.txt
05-git-diff-stat.txt
06-git-diff.patch
07-tests.txt
07-test-timings.json
07-test-selection.json
08-executor-summary.md
state.json

Missing optional files are not automatically failures.

Missing required evidence must be reported.

⸻

Evidence Validation

Where practical, Reviewer must compare evidence with current reality.

Examples:

* current git status matches evidence scope
* current diff matches captured diff
* timing JSON is valid
* test-selection JSON matches selected tests
* test result corresponds to the current working tree
* required output files exist and are non-empty

Evidence must not be trusted merely because the file exists.

⸻

Structured Reviewer Findings

09-consultant-review.md must follow a stable structure.

Recommended structure:

# Independent Review
## Decision
Risk level:
Decision:
## Acceptance Criteria
| Criterion | Result | Evidence |
|---|---|---|
## Independent Verification
| Check | Command or Method | Result | Duration |
|---|---|---|---|
## Findings
### BLOCKER
...
### HIGH
...
### MEDIUM
...
### LOW
...
### NOTE
...
## Residual Risks
...
## Verification Budget
Focused runs:
Targeted runs:
Full-suite runs:
Smoke runs:
Additional-run reasons:

Empty severity sections may be omitted.

⸻

Severity Contract

Use:

BLOCKER
HIGH
MEDIUM
LOW
NOTE

Decision policy:

BLOCKER → REQUEST_CHANGES
HIGH    → REQUEST_CHANGES
MEDIUM  → judgment required; must explain
LOW     → normally ACCEPT with note
NOTE    → ACCEPT

A Reviewer must not reject solely for optional refactoring or personal style.

⸻

Business Summary

10-business-summary.md must be understandable without implementation detail.

It should include:

* what was changed
* whether acceptance criteria passed
* major risks
* verification performed
* final recommendation

⸻

Reviewer Stop Condition

The Reviewer must stop when:

* all acceptance criteria have been assessed
* sufficient independent evidence exists
* blocking findings are recorded
* required artifacts are written
* a decision can be justified

The template must explicitly discourage endless exploration.

⸻

Reviewer Verification Budget

The Reviewer prompt must display the effective verification budget.

Example:

Review verification budget:
  Focused test runs: 3
  Targeted runs:     1
  Full-suite runs:   0 by default
  Smoke runs:        0 by default

If the Reviewer exceeds the default budget, it must record:

ADDITIONAL_VERIFICATION_REASON:
...

⸻

C. Mandatory Decision Marker

Current Failure

Recent tasks have ended with prose such as:

I accept this implementation.

but without the required marker:

DECISION: ACCEPT

SpecRelay correctly refuses to infer a machine decision from prose.

However, repeating the entire review from zero is wasteful.

⸻

Required Final Marker

The Reviewer final output must end with exactly one of:

DECISION: ACCEPT

or:

DECISION: REQUEST_CHANGES

The marker must:

* appear exactly once
* use uppercase spelling
* be on its own line
* be the final non-empty line
* agree with review artifacts
* agree with required next-prompt artifacts

⸻

Reviewer Completion Checklist

The Reviewer template must end with:

Before finishing, verify:
[ ] 09-consultant-review.md exists and is non-empty
[ ] 10-business-summary.md exists and is non-empty
[ ] If requesting changes, 11-next-executor-prompt.md exists and is non-empty
[ ] The final decision marker is present exactly once
[ ] The final marker is the final non-empty output line

⸻

Decision Consistency

Before applying a transition, SpecRelay must validate consistency.

ACCEPT requires

09-consultant-review.md non-empty
10-business-summary.md non-empty
no required changes prompt
DECISION: ACCEPT

REQUEST_CHANGES requires

09-consultant-review.md non-empty
11-next-executor-prompt.md non-empty
DECISION: REQUEST_CHANGES

A conflicting artifact/marker combination must fail clearly.

⸻

Smart Marker Recovery

When the Reviewer provider exits successfully but no valid marker exists,
SpecRelay must inspect whether review artifacts are complete.

If artifacts strongly indicate that only the marker is missing, invoke one
narrow corrective attempt.

Example corrective prompt:

Your review artifacts already exist, but the required final decision marker is
missing.
Do not repeat the review.
Do not run tests.
Do not inspect the repository again.
Read only:
  09-consultant-review.md
  10-business-summary.md
  11-next-executor-prompt.md if present
Then output exactly one line:
  DECISION: ACCEPT
or:
  DECISION: REQUEST_CHANGES

⸻

Corrective Attempt Limits

* Maximum marker-recovery attempts per Reviewer iteration: 1
* The corrective attempt must not receive the full original review prompt.
* The corrective attempt must not run repository tools.
* The corrective attempt must not rewrite implementation files.
* The corrective attempt must be recorded in the timeline.
* Failure after the corrective attempt leaves the task in REVIEWER_RUNNING.

⸻

When Smart Recovery Is Forbidden

Do not use marker-only recovery when:

* review artifacts are missing
* review artifacts are empty
* artifacts contradict each other
* no clear decision exists in artifacts
* REQUEST_CHANGES lacks 11-next-executor-prompt.md
* provider exited because of a real execution failure before review completion
* review output indicates unfinished verification
* review process was interrupted before artifacts were written

In these cases, normal resume behavior remains.

⸻

Recovery Decision Extraction

The corrective step may inspect structured decision content in the review
artifact.

Preferred future artifact field:

Decision: ACCEPT

or:

Decision: REQUEST_CHANGES

Do not infer a decision from vague sentiment.

Examples that are insufficient:

looks good overall
probably acceptable
I have no major concerns

⸻

D. Execution Timeline

Timeline Purpose

At the end of each completed run or resume, SpecRelay must print a durable
summary showing where wall time was spent.

Example:

╭─ Execution Timeline ─────────────────────────────────────────────────────╮
│ Phase                              Status     Duration      Share         │
├───────────────────────────────────────────────────────────────────────────┤
│ Task initialization                PASS          2s         0.1%         │
│ Executor context preflight         PASS          8s         0.4%         │
│ Executor provider execution        PASS      18m 42s       42.4%         │
│ Executor evidence capture          PASS          8s         0.3%         │
│ Reviewer context preflight         PASS          7s         0.3%         │
│ Reviewer provider execution        PASS       6m 21s       14.4%         │
│ Marker recovery                    SKIPPED        0s         0.0%         │
│ Finalization                       PASS          3s         0.1%         │
├───────────────────────────────────────────────────────────────────────────┤
│ Total wall time                              44m 05s      100.0%         │
╰───────────────────────────────────────────────────────────────────────────╯

⸻

Required Timeline Phases

Record at least:

task_initialization
task_approval
executor_context_preflight
executor_claim
executor_provider_execution
executor_evidence_capture
executor_submission
reviewer_context_preflight
reviewer_start
reviewer_provider_execution
reviewer_marker_recovery
reviewer_transition
finalization
total_wall_time

Record additional phases only when reliably measurable.

⸻

Multi-Resume Tasks

Timeline data must survive multiple invocations.

Example:

run invocation 1
resume invocation 2
resume invocation 3

The final report must show:

Invocations: 3
Resume count: 2

Each invocation must retain:

* invocation ID
* start timestamp
* finish timestamp
* initial task state
* final task state
* exit code
* phases executed

Do not overwrite previous invocation timing.

⸻

Timeline Storage

Store task timeline data under the existing task runtime directory.

Required machine-readable file:

.specrelay-runs/tasks/<task-id>/20-execution-timeline.json

Optional append-only event source:

.specrelay-runs/tasks/<task-id>/20-execution-events.jsonl

Do not create a new top-level directory.

⸻

Timeline JSON

Conceptual structure:

{
  "schema_version": 1,
  "task_id": "0019-bounded-verification-review-policy-and-execution-timeline",
  "started_at": "2026-07-14T08:00:00Z",
  "finished_at": "2026-07-14T08:44:05Z",
  "wall_seconds": 2645.0,
  "invocation_count": 2,
  "resume_count": 1,
  "phases": [
    {
      "name": "executor_provider_execution",
      "role": "executor",
      "status": "passed",
      "started_at": "2026-07-14T08:00:12Z",
      "finished_at": "2026-07-14T08:18:54Z",
      "duration_seconds": 1122.0,
      "source": "orchestrator"
    }
  ]
}

⸻

Timeline Accuracy

Use a monotonic clock for durations where available.

Use UTC wall-clock timestamps for evidence.

Duration calculation must not depend only on parsing display logs.

⸻

Overlapping Phases

If operations overlap, do not sum them as if sequential.

The final report must distinguish:

wall time
sum of measured operation durations

A percentage column must use wall time and clearly account for overlap.

Do not report phase shares exceeding logical meaning without explanation.

⸻

Unclassified Agent Time

Provider execution may contain implementation, tests, reads, edits, and waiting.

At minimum, record:

executor_provider_execution
reviewer_provider_execution

If semantic tool events allow reliable classification, record sub-events.

Otherwise use:

agent_tool_execution_unclassified

Do not call the entire provider duration “coding time.”

⸻

Provider Metrics

If the provider returns reliable fields, capture:

input_tokens
output_tokens
cache_read_tokens
cache_write_tokens
cost
model
provider

If unavailable, record:

not_available

Do not estimate token use or cost.

⸻

Verification Ledger

Purpose

The final report must show exactly which verification operations occurred.

Example:

╭─ Verification Ledger ────────────────────────────────────────────────────╮
│ Operation                     Role       Count      Total Duration       │
├───────────────────────────────────────────────────────────────────────────┤
│ Focused tests                 Executor       3             2m 40s       │
│ Targeted tests                Executor       1             1m 12s       │
│ Full suite                    Executor       1             4m 13s       │
│ Smoke --skip-tests            Executor       1             1m 54s       │
│ Doctor                        Executor       1                3s       │
│ Full suite                    Reviewer       0                0s       │
│ Focused tests                 Reviewer       2               51s       │
╰───────────────────────────────────────────────────────────────────────────╯

⸻

Verification Event Fields

Record where available:

operation
role
command
classification
started_at
finished_at
duration_seconds
exit_code
status
reason
source

⸻

Verification Evidence Integration

Existing timing evidence from:

07-test-timings.json
07-test-selection.json

may be incorporated.

Do not duplicate full detailed test data unnecessarily.

The timeline may reference evidence paths.

⸻

Duplicate Work Detection

Report repeated operations.

Example:

Duplicate work detected:
  Full suite executed 2 times by Executor.
  Doctor executed once by Executor and once by Reviewer.

Potential saving may be reported only from measured duplicate durations.

Do not claim that all duplicate work was avoidable.

Example:

Measured duplicate duration:
  4m 13s
Avoidability:
  unknown

or:

Avoidability:
  second full-suite run had no recorded justification

⸻

Slowest Phases

Print the slowest measured phases.

Example:

Slowest phases:
1. Executor provider execution   18m 42s
2. Reviewer provider execution    6m 21s
3. Full standalone suite          4m 13s
4. Smoke verification             1m 54s

Default count:

5

⸻

Performance Summary

At the end of a terminal task state, print:

Total wall time:        44m 05s
Invocations:             2
Resume count:            1
Executor provider time: 18m 42s
Reviewer provider time:  6m 21s
Verification time:       8m 59s
Marker recovery:         not used
Duplicate full suites:   0
Budget warnings:         1

⸻

Terminal and Non-Terminal Reports

Print timeline summary when the invocation ends in:

READY_FOR_HUMAN_REVIEW
CHANGES_REQUESTED
BLOCKED
REVIEWER_RUNNING after failure
EXECUTOR_RUNNING after provider failure
maximum-iterations stop

The report must indicate whether it is:

final
partial

Example:

Execution Timeline — PARTIAL
Task remains REVIEWER_RUNNING.

⸻

E. Phase Budgets

Purpose

Budgets identify abnormal phases.

They are soft warnings by default.

Conceptual configuration:

performance:
  phase_budgets:
    executor_context_preflight_seconds: 30
    executor_evidence_capture_seconds: 120
    reviewer_context_preflight_seconds: 30
    reviewer_provider_seconds: 900
    reviewer_marker_recovery_seconds: 60
    finalization_seconds: 30

⸻

Default Budgets

Recommended defaults:

context preflight:       30 seconds
evidence capture:       120 seconds
reviewer provider:      900 seconds
marker recovery:         60 seconds
finalization:            30 seconds

Executor provider execution should not have a strict default budget because
implementation complexity varies.

It may have an advisory display threshold.

⸻

Budget Warning

Example:

⚠ Reviewer provider execution exceeded soft budget.
Expected:
  ≤ 15m 00s
Actual:
  23m 41s
Over:
  8m 41s

Warnings must not alter task state by default.

⸻

Budget Status Values

within_budget
exceeded
not_configured
not_measurable

⸻

Budget Report

Add to final report:

Budget warnings:
  Reviewer provider execution:
    expected ≤ 15m
    actual    23m 41s

If there are no warnings:

Budget warnings: none

⸻

AI Reviewer Template Installation

The project currently may report:

no .claude/agents/ai-reviewer.md

This specification must improve the project template and installation behavior.

Requirements:

* update templates/claude/agents/ai-reviewer.md
* ensure specrelay init installs it
* ensure upgrade behavior is documented
* do not overwrite an existing customized agent silently
* doctor must distinguish:
    * template available
    * project reviewer installed
    * project reviewer missing
    * project reviewer customized where detectable

⸻

Reviewer Prompt Contract

Even when the provider runs without a Claude sub-agent file, the generated
Reviewer prompt must include the same critical policy:

* risk classification
* evidence inspection
* bounded verification
* structured artifacts
* mandatory marker
* stop condition

The feature must not depend exclusively on Claude sub-agent installation.

⸻

Decision Marker Enforcement in Provider Adapter

The provider adapter must preserve the final marker in captured output.

Semantic event rendering must not remove:

DECISION: ACCEPT
DECISION: REQUEST_CHANGES

Existing marker parsing behavior must remain compatible.

⸻

Execution Event Instrumentation

Introduce a small internal instrumentation API.

Conceptual shell interface:

specrelay::timeline::start <task-dir> <phase> [role]
specrelay::timeline::finish <task-dir> <phase> <status>
specrelay::timeline::event <task-dir> <event-type> <json>
specrelay::timeline::render <task-dir>

Exact naming may follow repository conventions.

Requirements:

* writes atomically where appropriate
* supports multiple invocations
* survives interruption
* avoids corrupting previous timeline data
* tolerates missing optional metrics
* does not expose secrets
* remains task-scoped

⸻

Concurrency and Locking

Timeline writes must not corrupt data under concurrent attempts.

Use existing task locks or atomic append/write behavior.

Do not create a separate top-level lock namespace.

⸻

Security and Privacy

Do not record:

* full prompts unless already part of existing evidence
* secrets
* MCP configuration values
* API keys
* environment credentials
* authorization headers
* full command lines containing known secrets

Verification commands may be redacted.

Example:

command: <redacted: contains sensitive environment assignment>

⸻

CLI Inspection

Add an inspection command if consistent with existing CLI design.

Suggested:

bin/specrelay task timeline <task-ref>

It should print the current timeline report without mutating task state.

Optional machine-readable mode:

bin/specrelay task timeline <task-ref> --json

If added:

* unknown task fails clearly
* legacy tasks without timeline data remain displayable
* read-only command never mutates task files
* future schema handling follows existing read-only compatibility rules

⸻

Task Show Integration

task show should display a small summary when timeline data exists:

Total wall time: 44m 05s
Invocation count: 2
Resume count: 1
Full-suite runs: 1
Reviewer marker recovery: not used
Budget warnings: 1
Timeline: <task runtime path>/20-execution-timeline.json

Legacy tasks:

Execution timeline: not recorded

⸻

Documentation

Update relevant documentation:

* reviewer contract
* task lifecycle
* commands
* configuration
* recovery behavior
* evidence files
* execution timeline
* verification policy
* phase budgets
* reviewer agent installation
* full versus targeted verification
* marker recovery

Document clearly:

Independent review does not mean automatic full-suite repetition.

⸻

Required Tests

Verification Policy Configuration

* defaults load successfully
* valid executor limits parse
* valid reviewer limits parse
* negative limits are rejected
* non-integer limits are rejected
* unknown verification modes are rejected
* missing policy remains backward compatible
* effective policy can be inspected
* effective policy is captured durably

Reviewer Template

* risk classification is required
* evidence inspection is required
* verification budget is present
* severity contract is present
* stop condition is present
* final marker requirement is present
* artifact checklist is present
* full-suite reason requirement is present
* plain Reviewer prompt includes critical policy
* Claude agent template includes critical policy

Reviewer Agent Installation

* init installs missing AI Reviewer template
* init does not overwrite an existing customized template
* doctor detects missing template
* doctor detects installed template
* upgrade documentation explains template updates

Decision Marker

* valid ACCEPT marker parses
* valid REQUEST_CHANGES marker parses
* lowercase marker is rejected
* marker not on final line is rejected if strict contract requires final line
* duplicate markers are rejected
* conflicting markers are rejected
* prose without marker is rejected
* marker is preserved through semantic event rendering
* marker agrees with artifacts
* conflicting artifact/marker state is rejected

Smart Marker Recovery

* missing marker with complete ACCEPT artifacts triggers one corrective attempt
* missing marker with complete REQUEST_CHANGES artifacts triggers one corrective
    attempt
* corrective attempt receives a narrow prompt
* corrective attempt does not receive original full prompt
* corrective attempt does not rerun repository tools
* corrective attempt succeeds with valid marker
* second recovery attempt is forbidden
* missing review artifacts prevents marker recovery
* empty artifacts prevent marker recovery
* unclear artifact decision prevents marker recovery
* missing 11-next-executor-prompt.md prevents REQUEST_CHANGES recovery
* provider execution failure before artifacts prevents recovery
* failed correction leaves task in REVIEWER_RUNNING
* successful correction continues transition normally
* recovery is recorded in timeline

Timeline Phases

* invocation start is recorded
* invocation finish is recorded
* executor preflight is timed
* executor provider is timed
* evidence capture is timed
* reviewer provider is timed
* marker recovery is timed
* finalization is timed
* durations are non-negative
* UTC timestamps are valid
* monotonic duration is used where available
* partial invocation is retained after failure
* resume adds a new invocation
* previous invocation remains intact
* resume count is correct
* total wall time spans all task invocations honestly

Timeline JSON

* JSON is valid
* schema version is recorded
* task ID is correct
* phase records are structured
* file is written atomically
* interrupted write does not destroy previous valid timeline
* no secret values are recorded
* no new top-level directory is created

Verification Ledger

* focused test is classified
* targeted test is classified
* full suite is classified
* smoke is classified
* doctor is classified
* version is classified
* unknown command remains unclassified
* operation count is correct
* duration aggregation is correct
* role separation is correct
* duplicate operation is reported
* justified duplicates are distinguishable
* no false duplicate is reported for different targeted commands

Final Timeline Rendering

* table is append-only
* redirected output contains complete report
* no cursor movement
* no redraw
* no ANSI in non-TTY default
* partial report is labeled partial
* final report is labeled final
* total wall time is printed
* slowest phases are sorted correctly
* verification counts are printed
* duplicate work is printed
* budget warnings are printed
* missing optional metrics are shown honestly

Phase Budgets

* default budgets load
* configured budgets override defaults
* within-budget status is correct
* exceeded status is correct
* warning includes expected and actual duration
* warning does not change state by default
* unmeasurable phase is reported honestly
* invalid budget values are rejected

Task Inspection

* task timeline displays timeline
* task timeline --json displays valid JSON if implemented
* unknown task fails
* legacy task without timeline remains inspectable
* task show reports timeline summary
* read-only commands do not mutate task files

Compatibility

* existing run behavior remains valid
* existing resume behavior remains valid
* manual Reviewer behavior remains unchanged
* Reviewer Running State remains valid
* all existing standalone tests pass
* smoke behavior remains valid
* CI full-suite behavior remains valid
* existing evidence contracts remain valid
* no new top-level directory is created

⸻

Performance Acceptance Criteria

The Executor must compare the new policy against recent historical behavior.

Use at least one real SpecRelay task or controlled fixture demonstrating:

review missing marker
→ marker-only corrective attempt
→ no repeated full review

Report:

* original full review duration or representative measured fixture
* marker-recovery duration
* commands avoided
* review artifacts preserved
* final transition result

Also demonstrate:

one full-suite run
versus
two duplicate full-suite runs

and show that duplicate work is reported.

Do not claim unrealistically large savings without measured evidence.

⸻

Acceptance Criteria

This specification is accepted only when:

* effective verification policy exists
* Executor and Reviewer budgets are visible
* Reviewer template is risk-based and structured
* full-suite repetition requires a recorded reason
* Reviewer evidence use is explicit
* Reviewer no longer behaves as a blind second Executor by default
* final decision marker is mandatory
* marker-only recovery avoids a complete repeated review
* corrective recovery is limited to one attempt
* timeline data survives resume
* final timeline table is printed
* verification ledger is printed
* duplicate work is reported
* phase budgets produce warnings
* task-specific timeline JSON exists
* task show or equivalent exposes timeline summary
* legacy tasks remain readable
* no secrets are recorded
* no new top-level runtime directory is created
* all existing tests pass
* CI still performs full verification
* human final review remains required

⸻

Reviewer Rejection Conditions

The Reviewer must reject the implementation if:

* verification limits silently skip required tests
* targeted verification is mislabeled as full verification
* Reviewer independence is weakened into blind trust
* Reviewer still runs full suite by default without risk justification
* missing marker causes complete review repetition despite complete artifacts
* marker recovery can run repository tools
* marker recovery can execute more than once automatically
* contradictory artifacts can produce acceptance
* timing is fabricated from prose
* overlapping durations are summed dishonestly
* duplicate work report is based on guesses
* timeline overwrites previous resume history
* partial failures destroy timeline evidence
* timeline output is not stream-friendly
* secrets appear in timeline or verification ledger
* phase-budget warnings change state unexpectedly
* a new top-level runtime directory is added
* CI full verification is removed
* human final review is removed

⸻

Verification

Run focused tests for the new policy:

scripts/test --changed --jobs auto --timings --explain

Run specific new tests:

scripts/test test/reviewer_policy_test.sh test/execution_timeline_test.sh

Exact test filenames may follow implementation conventions.

Run the full suite once:

scripts/test --jobs auto --timings

Run smoke without duplicate tests:

scripts/smoke --skip-tests

Run:

SPECRELAY_PROVIDER_OPTIONAL=1 bin/specrelay doctor
bin/specrelay version

Exercise marker recovery with a deterministic fake Reviewer.

Exercise:

ACCEPT artifact + missing marker
REQUEST_CHANGES artifacts + missing marker
missing artifact
conflicting artifacts
correction failure
correction success

Inspect:

bin/specrelay task timeline <task-ref>

if implemented.

Inspect:

.specrelay-runs/tasks/<task-id>/20-execution-timeline.json

Verify:

* timeline contains all invocations
* resume count is accurate
* verification counts are accurate
* no secret values appear
* no new root-level runtime directory exists

⸻

Executor Deliverables

Write:

03-executor-log.md
07-tests.txt
08-executor-summary.md

Also write task-specific performance evidence where implemented:

20-execution-timeline.json

The Executor summary must explicitly report:

* verification policy defaults
* Executor limits
* Reviewer limits
* risk classification behavior
* Reviewer template changes
* severity contract
* marker parsing rules
* marker-only recovery flow
* recovery safety limits
* timeline architecture
* multi-resume behavior
* verification ledger design
* duplicate-work detection
* phase budgets
* task inspection commands
* security/redaction behavior
* measured performance evidence
* remaining limitations
* verification results

⸻

Reviewer Focus

The Reviewer must independently verify:

1. targeted verification is not presented as full verification
2. Reviewer full-suite execution requires a reason
3. Reviewer template contains a clear stop condition
4. missing marker with complete artifacts does not repeat the full review
5. marker recovery cannot inspect or modify the repository
6. marker recovery runs at most once
7. conflicting artifacts cannot produce an accepted transition
8. timeline survives multiple resume invocations
9. verification ledger counts real operations accurately
10. duplicate-work reporting is evidence-based
11. budget warnings are accurate and non-blocking
12. output remains stream-friendly
13. secrets are excluded
14. CI and human final review remain intact
