# Agent Execution Efficiency and Completion Gate
- Spec: 0021
- Status: Draft
---
# Summary
Reduce unnecessary Executor and Reviewer runtime by introducing an explicit,
durable execution-efficiency policy and a strict provider-completion gate.
SpecRelay must make the expected stopping behavior unambiguous:
1. inspect only enough context to act safely;
2. implement the requested change;
3. run the required bounded verification;
4. write the required role artifacts;
5. stop.
A provider exit code of zero is not sufficient evidence of successful role
completion when required artifacts are missing, background work is unresolved,
or the role explicitly reports that it is still waiting.
This specification also adds an efficiency summary showing where the agent spent
its observable work and how long it continued after its final required
verification passed.
---
# Motivation
Task 0020 produced the following evidence:
```text
Executor provider execution: 39m 19s
Measured agent command time:  6m 24s

Therefore command and test execution alone do not explain most of the provider
runtime.

Observed causes include:

* broad repository exploration after sufficient context was already available;
* repeated focused verification;
* waiting for background jobs;
* continuing analysis after required checks had passed;
* returning successfully before writing required artifacts;
* relying on later recovery to complete an otherwise-finished task.

The objective is not to make the model think faster.

The objective is to give the model a stricter completion contract and prevent
SpecRelay from accepting an incomplete provider exit as successful role
completion.

⸻

Core Principle

A role is complete only when its required work and required durable outputs are
complete.

provider exit 0
+
required artifacts complete
+
no explicit unresolved wait
+
verification contract satisfied
=
successful role completion

If any required part is missing, the role must remain incomplete.

⸻

Scope

This specification applies independently to:

* Executor
* Automated Reviewer

Manual reviewers remain unchanged.

⸻

Goals

* Add an explicit efficiency and completion policy to configuration.
* Capture the effective policy durably in task state.
* Inject the effective policy into Executor and Reviewer prompts.
* Require role artifacts before provider completion is accepted.
* Detect explicit unresolved waiting language in final provider output.
* Detect active provider-owned background processes where technically reliable.
* Prevent a role from being marked successful when completion requirements fail.
* Report exploration, implementation, verification, waiting, and artifact work.
* Report time between final required verification and provider completion.
* Report verification commands repeated without a recorded reason.
* Preserve stream-friendly output.
* Preserve existing task recovery semantics.
* Add no new top-level runtime directory.
* Avoid rerunning expensive verification merely to enforce completion.

⸻

Non-Goals

This specification does not:

* make Claude or another model execute tokens faster;
* interrupt a provider based only on elapsed time;
* impose a universal hard tool-call limit;
* kill valid long-running implementation work;
* inject a new prompt into an already-running provider process;
* replace command timing from Spec 0020;
* remove full-suite verification where policy requires it;
* infer intent from arbitrary prose;
* automatically accept incomplete work;
* change human final-review requirements.

⸻

Configuration

Add an optional configuration section:

execution_efficiency:
  enabled: true
  executor:
    exploration_warning_calls: 25
    repeated_verification_limit: 1
    unresolved_wait_is_failure: true
    require_artifacts_before_success: true
  reviewer:
    exploration_warning_calls: 15
    repeated_verification_limit: 1
    unresolved_wait_is_failure: true
    require_artifacts_before_success: true

Defaults:

execution_efficiency:
  enabled: true
  executor:
    exploration_warning_calls: 30
    repeated_verification_limit: 1
    unresolved_wait_is_failure: true
    require_artifacts_before_success: true
  reviewer:
    exploration_warning_calls: 20
    repeated_verification_limit: 1
    unresolved_wait_is_failure: true
    require_artifacts_before_success: true

These values guide and validate execution.

They are not automatic hard termination thresholds unless this specification
explicitly defines a reliable enforcement point.

⸻

Durable Effective Policy

Capture the resolved policy once per task:

{
  "execution_efficiency_effective": {
    "executor": {
      "exploration_warning_calls": 30,
      "repeated_verification_limit": 1,
      "unresolved_wait_is_failure": true,
      "require_artifacts_before_success": true
    },
    "reviewer": {
      "exploration_warning_calls": 20,
      "repeated_verification_limit": 1,
      "unresolved_wait_is_failure": true,
      "require_artifacts_before_success": true
    }
  }
}

Resume must use the captured policy rather than silently adopting later config
changes.

Legacy tasks without this block remain valid and readable.

⸻

Executor Completion Contract

The Executor prompt must clearly state:

Completion contract:
- Do not continue broad repository exploration after sufficient implementation
  context has been obtained.
- Prefer focused verification before broader verification.
- Do not rerun an already-passing verification command unless source changed or
  a concrete reason is recorded.
- Do not end by saying that you are waiting for a background task.
- Before finishing, ensure all required Executor artifacts are non-empty:
  03-executor-log.md
  07-tests.txt
  08-executor-summary.md
- After required verification passes, write the deliverables and finish.
- Do not run additional exploratory commands after completion criteria are met
  unless a concrete blocker or inconsistency is discovered.

The prompt must include the effective verification policy from Spec 0019 and
the efficiency policy from this specification.

⸻

Reviewer Completion Contract

The Reviewer prompt and ai-reviewer.md template must clearly state:

Reviewer completion contract:
- Review independently, but do not repeat the Executor's entire verification
  without a concrete risk-based reason.
- Prefer inspection of changed files and focused tests.
- Run the full suite only when required by policy or justified by identified
  risk.
- Do not end while waiting for background verification.
- Before finishing, write:
  09-consultant-review.md
  10-business-summary.md
- End with exactly one explicit marker:
  DECISION: ACCEPT
  or
  DECISION: REQUEST_CHANGES
- Once sufficient evidence exists, decide and stop.

⸻

Required Executor Artifacts

Successful Executor completion requires non-empty:

03-executor-log.md
07-tests.txt
08-executor-summary.md

This check must occur immediately after provider execution and before the
Executor is considered successful.

Missing artifacts must produce a distinct result:

provider exited successfully, but Executor completion contract failed

The task must remain EXECUTOR_RUNNING.

It must not display an Executor Result: SUCCESS card.

⸻

Required Reviewer Artifacts

Successful automated Reviewer completion requires:

For ACCEPT:

09-consultant-review.md
10-business-summary.md
DECISION: ACCEPT

For REQUEST_CHANGES:

09-consultant-review.md
10-business-summary.md
11-next-executor-prompt.md
DECISION: REQUEST_CHANGES

Existing marker and artifact-consistency rules from Spec 0019 remain
authoritative.

The completion gate must not weaken them.

⸻

Unresolved Waiting Detection

Inspect only the provider’s final extracted output, not arbitrary intermediate
streaming prose.

Recognize explicit unresolved completion statements such as:

I will wait for the background task.
I'll continue when the monitor finishes.
The test is still running; I am stopping here.
Waiting for completion notification.
I'll pick this back up once it completes.

Detection must be conservative.

It must not reject historical narration such as:

I waited for the test, and it completed successfully.

When policy enables unresolved_wait_is_failure, final unresolved waiting must
produce:

provider exited without completing its declared background work

The task remains in its running state.

⸻

Background Process Check

Where SpecRelay can reliably identify provider-owned child processes, check for
live background jobs before accepting completion.

Requirements:

* inspect only processes started under the current provider invocation;
* do not scan and kill unrelated system processes;
* do not guess ownership based only on command name;
* never kill a process automatically under this specification;
* report live owned jobs clearly;
* if ownership cannot be established reliably, report not_verifiable.

A live owned background verification job prevents successful completion when the
policy requires resolved waiting.

⸻

Verification Repetition

Use command timing and verification ledger evidence from Specs 0019 and 0020.

A verification operation is repeated when the same normalized verification
command is executed more than the allowed count during the same role iteration.

Examples:

scripts/test test/command_timing_test.sh
scripts/test --changed --jobs auto --timings --explain
scripts/test --jobs auto --timings
scripts/smoke --skip-tests
bin/specrelay doctor

A repeated command is allowed when a reason is durably recorded, for example:

source changed after previous verification
previous run was interrupted
previous result was incomplete
reviewer independently reproduced a suspected failure

Without a reason, report it as unjustified repeated verification.

This is advisory unless another existing verification policy makes it a hard
failure.

⸻

Observable Work Classification

Using Spec 0020 operation evidence, classify observable operations as:

exploration
implementation
verification
waiting
artifact_writing
inspection
other

Examples:

Exploration:

find
grep
ls
git log
broad Read operations
context-tree queries

Implementation:

Edit
Write to source files
patch application
file creation under implementation paths

Verification:

scripts/test
scripts/smoke
doctor
version
syntax checks
compile checks

Waiting:

sleep
wait
jobs; wait
poll loops

Artifact writing:

Write 03-executor-log.md
Write 07-tests.txt
Write 08-executor-summary.md
Write 09-consultant-review.md
Write 10-business-summary.md

Classification must remain honest. Unknown cases use other.

⸻

Post-Verification Work

Define:

final_required_verification_at

as the completion time of the last verification operation necessary to satisfy
the effective verification policy.

Define:

provider_completed_at

as the provider completion time.

Report:

post_verification_seconds

Also report observable operations executed during that interval.

Do not claim every post-verification operation was waste.

Distinguish:

artifact writing
necessary final inspection
unjustified exploration
repeated verification
waiting

⸻

Efficiency Artifact

Write under the existing task directory:

22-agent-efficiency.json

Conceptual structure:

{
  "schema_version": 1,
  "task_id": "0021-agent-execution-efficiency-and-completion-gate",
  "roles": {
    "executor": {
      "observable_operations": 82,
      "exploration_operations": 31,
      "implementation_operations": 14,
      "verification_operations": 9,
      "waiting_operations": 3,
      "artifact_writing_operations": 3,
      "unjustified_repeated_verification": 2,
      "final_required_verification_at": "2026-07-14T10:30:00Z",
      "provider_completed_at": "2026-07-14T10:38:12Z",
      "post_verification_seconds": 492,
      "completion_gate": "passed"
    },
    "reviewer": {
      "observable_operations": 14,
      "completion_gate": "passed"
    }
  }
}

Do not create another top-level runtime directory.

⸻

Timeline Integration

Extend 20-execution-timeline.json with a summary reference:

{
  "agent_efficiency_summary": {
    "artifact": "22-agent-efficiency.json",
    "executor_post_verification_seconds": 492,
    "reviewer_post_verification_seconds": 31,
    "executor_completion_gate": "passed",
    "reviewer_completion_gate": "passed"
  }
}

Existing timeline files without this block remain valid.

⸻

Terminal Output

At finalization, print a compact stream-friendly section:

Agent Efficiency -- FINAL
+-- Agent Efficiency ---------------------------------------------------
| Role       Explore  Implement  Verify  Wait  Artifacts  After verify
|------------------------------------------------------------------------
| executor        31         14       9     3          3       8m 12s
| reviewer         6          0       2     0          2          31s
+------------------------------------------------------------------------
Completion gates:
  Executor: passed
  Reviewer: passed
Unjustified repeated verification:
  Executor: 2
  Reviewer: 0
Unresolved waiting:
  Executor: none
  Reviewer: none

When incomplete:

Agent Efficiency -- PARTIAL
Completion gate:
  Executor: failed
  Reason: required artifact 08-executor-summary.md is missing

The output must remain:

* append-only;
* copyable;
* redirectable;
* free of cursor movement;
* understandable without color;
* free of ANSI escapes in non-TTY output.

⸻

Completion Result Semantics

Current incorrect behavior to prevent:

provider exit 0
required artifacts missing
Executor Result: SUCCESS

Required behavior:

provider exit 0
required artifacts missing
Executor Result: INCOMPLETE
task remains EXECUTOR_RUNNING

Similarly:

provider exit 0
final output declares unresolved waiting
Executor Result: INCOMPLETE
task remains EXECUTOR_RUNNING

A successful completion card is printed only after the completion gate passes.

⸻

Recovery Semantics

This specification does not add a direct:

EXECUTOR_RUNNING -> READY_FOR_REVIEW

recovery transition.

Existing recovery remains:

EXECUTOR_RUNNING -> READY_FOR_EXECUTOR

However, documentation must clearly distinguish:

* provider interruption;
* completion-gate failure;
* missing artifacts;
* unresolved background work.

Do not tell operators that ordinary recovery submits completed work.

⸻

Task Inspection

Extend:

bin/specrelay task timeline <task-ref>

to include the efficiency summary.

Optionally add:

bin/specrelay task efficiency <task-ref>

only if implementation remains small and consistent with existing CLI design.

Read-only inspection must not mutate task files.

Legacy tasks should display:

Agent efficiency: not recorded

⸻

Doctor

bin/specrelay doctor must report:

* whether execution-efficiency policy is enabled;
* resolved Executor policy;
* resolved Reviewer policy;
* completion-gate artifact requirements;
* unresolved-wait policy;
* whether command timing support from Spec 0020 is available.

Malformed configuration fails clearly.

Doctor must not run providers or mutate tasks.

⸻

Required Tests

Configuration

* defaults resolve correctly;
* Executor and Reviewer values remain isolated;
* invalid booleans fail;
* invalid negative limits fail;
* unknown keys fail;
* effective policy is captured durably;
* resume uses captured policy;
* legacy tasks remain readable.

Executor Completion Gate

* exit 0 plus all artifacts passes;
* exit 0 with missing 03-executor-log.md is incomplete;
* exit 0 with missing 07-tests.txt is incomplete;
* exit 0 with missing 08-executor-summary.md is incomplete;
* incomplete result remains EXECUTOR_RUNNING;
* incomplete result does not print SUCCESS;
* provider failure remains a provider failure;
* existing evidence files are preserved.

Reviewer Completion Gate

* ACCEPT with required artifacts passes;
* REQUEST_CHANGES with required artifacts passes;
* ACCEPT without business summary fails;
* REQUEST_CHANGES without next prompt fails;
* missing decision marker fails;
* conflicting marker fails;
* completion gate does not bypass Spec 0019 consistency checks.

Unresolved Waiting

* final “I will wait” fails when enabled;
* final “waiting for monitor” fails when enabled;
* “I waited and it completed” passes;
* intermediate waiting prose does not fail if final output confirms completion;
* disabled policy does not block;
* detector does not match unrelated words containing “wait”.

Work Classification

* exploration operations classify correctly;
* implementation operations classify correctly;
* verification operations classify correctly;
* waiting operations classify correctly;
* artifact writes classify correctly;
* unknown operations classify as other;
* Executor and Reviewer remain separate.

Repeated Verification

* identical verification command is counted;
* different test targets are not merged;
* repeated command with recorded reason is justified;
* interrupted previous run is justified;
* repeated verification without reason is reported;
* advisory reporting does not falsely fail a valid task.

Post-Verification Timing

* final required verification timestamp is selected correctly;
* provider completion timestamp is selected correctly;
* post-verification duration is non-negative;
* artifact writes after verification are distinguished;
* waiting after verification is reported;
* legacy tasks without timing evidence remain readable.

Efficiency Artifact

* JSON is valid;
* schema version exists;
* task ID is correct;
* role totals are correct;
* completion-gate result is recorded;
* artifact is task-scoped;
* no new top-level directory is created;
* atomic write preserves previous valid data on failure;
* secrets are not copied into the artifact.

Timeline and Rendering

* timeline references the efficiency artifact;
* final output prints efficiency table;
* partial output names completion failure;
* non-TTY output has no ANSI escapes;
* output contains no cursor movement;
* legacy timeline renders correctly.

Compatibility

* command timing from Spec 0020 still works;
* decision-marker recovery from Spec 0019 still works;
* manual Reviewer behavior remains unchanged;
* human final review remains required;
* CI full verification remains unchanged;
* existing standalone tests pass.

⸻

Acceptance Criteria

This specification is accepted only when:

* provider exit zero alone cannot produce a false successful role result;
* missing artifacts produce INCOMPLETE, not SUCCESS;
* explicit unresolved waiting prevents successful completion when enabled;
* Executor and Reviewer receive clear stop contracts;
* effective policy is durable across resume;
* repeated verification is reported conservatively;
* post-verification delay is measured;
* efficiency data is stored under the existing task directory;
* timeline displays the efficiency summary;
* legacy tasks remain inspectable;
* stream-friendly output is preserved;
* no new top-level runtime directory is added;
* human final review remains required;
* all existing tests pass.

⸻

Reviewer Rejection Conditions

Reject if:

* missing artifacts can still produce Executor Result: SUCCESS;
* unresolved waiting is accepted as completed work;
* arbitrary intermediate prose triggers false waiting failures;
* background-process ownership is guessed unsafely;
* valid long-running work is killed automatically;
* tool-call limits are enforced as blind universal cutoffs;
* repeated verification detection merges different commands;
* post-verification time is fabricated;
* recovery semantics are silently changed;
* timeline compatibility is broken;
* a new top-level runtime directory is introduced;
* human final review is weakened.

⸻

Verification

Run focused tests:

scripts/test \
  test/agent_efficiency_test.sh \
  test/completion_gate_test.sh \
  test/command_timing_test.sh \
  test/execution_timeline_test.sh

Exact new filenames may follow repository conventions.

Run change-aware verification:

scripts/test --changed --jobs auto --timings --explain

Run the full suite once:

scripts/test --jobs auto --timings

Run smoke without repeating the standalone suite:

scripts/smoke --skip-tests

Run:

SPECRELAY_PROVIDER_OPTIONAL=1 bin/specrelay doctor
bin/specrelay version

Use deterministic provider fixtures covering:

* successful complete Executor;
* exit-zero Executor missing each required artifact;
* unresolved waiting final output;
* completed waiting narration;
* repeated verification with and without reason;
* post-verification artifact writing;
* Reviewer ACCEPT;
* Reviewer REQUEST_CHANGES;
* legacy task without efficiency evidence.

⸻

Executor Deliverables

Write:

03-executor-log.md
07-tests.txt
08-executor-summary.md

The summary must explicitly report:

* enforced completion-gate conditions;
* unresolved-wait detection rules;
* background-process ownership limitations;
* operation classification rules;
* repeated-verification rules;
* post-verification timing;
* prompt/template changes;
* durable policy behavior;
* timeline integration;
* remaining limitations;
* verification results.

The Executor must write these artifacts immediately after the required
verification succeeds.

It must not end with unresolved background work.

⸻

Reviewer Focus

The Reviewer must independently verify:

1. provider exit zero cannot bypass missing Executor artifacts;
2. incomplete Executor completion remains EXECUTOR_RUNNING;
3. no false SUCCESS card is printed;
4. Reviewer artifact and marker rules remain strict;
5. unresolved-wait detection is conservative;
6. historical completed waiting does not falsely fail;
7. no unrelated process is killed or treated as provider-owned;
8. repeated verification grouping is conservative;
9. post-verification duration comes from real timestamps;
10. prompt contracts explicitly require stopping after completion;
11. effective policy survives resume;
12. no new top-level runtime directory is created;
13. output remains append-only and copyable;
14. human final review remains required.

End the review with exactly one marker:

DECISION: ACCEPT

or:

DECISION: REQUEST_CHANGES

