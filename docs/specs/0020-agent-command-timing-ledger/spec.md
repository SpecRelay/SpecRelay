# Agent Command Timing Ledger
- Spec: 0020
- Status: Draft
---
# Summary
Add an honest, task-scoped command timing ledger to SpecRelay.
SpecRelay already records provider semantic events and, since Spec 0019,
maintains an execution timeline and verification ledger.
This specification extends that observability by recording the duration of
individual observable agent tool executions, especially shell commands.
At the end of a task, the user should be able to identify:
- which commands were executed
- which role executed them
- how long each command took
- whether each command succeeded or failed
- which commands were repeated
- which commands consumed the most time
- which tool executions could not be timed reliably
The implementation must remain append-only, stream-friendly, task-scoped, and
honest about unavailable timing information.
---
# Motivation
Recent SpecRelay tasks have taken between approximately 40 and 95 minutes.
The execution timeline identifies large phases such as:
```text
executor_provider_execution
reviewer_provider_execution
full_suite
smoke

However, provider execution may still account for most of the total task time.

A phase-level report such as:

Executor provider execution: 88m 02s

does not explain whether the time was spent on:

* repository exploration
* reading files
* editing files
* running focused tests
* running the full suite
* polling background commands
* sleeping
* waiting for tools
* repeated commands

A command timing ledger provides the next level of evidence.

⸻

Core Principle

Only report durations that SpecRelay can measure from reliable event data.

Do not fabricate command timing from prose.

Do not infer a duration merely because two log lines appeared near each other
unless the event protocol proves they represent the start and finish of the same
tool invocation.

When timing is unavailable, report:

not_measurable

rather than estimating.

⸻

Goals

* Record observable agent tool invocations per task.
* Record Bash command durations where start and finish events are available.
* Preserve role separation between Executor and Reviewer.
* Record command success, failure, or unknown result.
* Detect repeated normalized commands.
* Print the slowest observed commands at the end of a task.
* Add command timing data to the existing execution timeline.
* Preserve all existing raw provider event evidence.
* Avoid adding a new top-level runtime directory.
* Avoid increasing provider execution time materially.
* Keep all terminal output append-only and copyable.
* Support tasks spanning multiple run and resume invocations.

⸻

Non-Goals

This specification does not:

* time commands executed outside SpecRelay
* profile CPU, disk, memory, or network usage
* parse every shell pipeline into separate subcommands
* time commands hidden inside scripts
* instrument arbitrary child processes recursively
* replace scripts/test timing reports
* build a dashboard or TUI
* alter task state based on command duration
* terminate slow commands automatically
* claim precise timing when provider events do not contain sufficient data
* record command arguments containing secrets without redaction

⸻

Observable Operation Model

An observable operation is a provider event representing one agent tool call.

Examples:

Bash
Read
Edit
Write
Task
MCP tool call

For each operation, capture where available:

operation_id
invocation_id
role
provider
tool
display_command
normalized_command
started_at
finished_at
duration_seconds
status
exit_code
timing_source
redacted

⸻

Timing Sources

Supported timing sources may include:

provider_event_timestamps
local_renderer_monotonic_clock
existing_test_timing_artifact
not_measurable

The recorded source must make clear how the duration was obtained.

Preferred source:

provider_event_timestamps

A local monotonic clock may be used only when SpecRelay itself observes both
the beginning and completion of the operation.

⸻

Bash Command Timing

For observable Bash tool calls, record:

tool: Bash
command: scripts/test --jobs auto --timings
duration_seconds: 253.4
status: passed
exit_code: 0

A pipeline remains one observable command:

scripts/test --jobs auto --timings 2>&1 | tail -30

Do not split it into fictional individual timings for:

scripts/test
tail

unless the event protocol provides separate tool invocations.

⸻

Non-Bash Tool Timing

Where reliable events exist, record timings for:

Read
Edit
Write
MCP retrieval
other named provider tools

Example:

Tool       Count    Total time
Bash          18       14m 20s
Read          27          41s
Edit          11          18s
Write          4           3s
MCP            2          22s

If only Bash operations can currently be timed reliably, implement Bash first
and report other tools as unsupported or not measurable.

Do not pretend broader support exists.

⸻

Command Normalization

Repeated-command detection requires a conservative normalized command.

Normalization may:

* trim leading and trailing whitespace
* collapse repeated whitespace outside quoted content where safe
* remove volatile temporary paths only when deterministic and safe
* preserve meaningful flags and arguments

Normalization must not:

* merge semantically different commands
* remove test filenames
* remove Git refs
* remove provider model names
* hide meaningful environment differences
* expose secrets

When safe normalization is uncertain, use the redacted original command as the
comparison key.

⸻

Secret Redaction

Before persisting command text, redact likely sensitive values.

At minimum protect:

* API keys
* tokens
* passwords
* authorization headers
* secret environment assignments
* MCP configuration secrets
* known credential variable values

Examples:

OPENAI_API_KEY=<redacted> command
Authorization: <redacted>
password=<redacted>

When safe redaction is not possible, store:

<redacted: command may contain sensitive data>

The raw existing provider event file remains governed by its existing evidence
contract; this specification must not copy secrets from it into new summary
artifacts.

⸻

Runtime Storage

Store command timing data under the existing task directory.

Required file:

.specrelay-runs/tasks/<task-id>/21-command-timings.json

Optional append-only source:

.specrelay-runs/tasks/<task-id>/21-command-timing-events.jsonl

Do not create another top-level runtime folder.

⸻

JSON Structure

Conceptual structure:

{
  "schema_version": 1,
  "task_id": "0020-agent-command-timing-ledger",
  "generated_at": "2026-07-14T10:00:00Z",
  "operation_count": 3,
  "measurable_operation_count": 2,
  "operations": [
    {
      "operation_id": "executor-12",
      "invocation_id": "invocation-1",
      "role": "executor",
      "provider": "claude",
      "tool": "Bash",
      "command": "scripts/test --jobs auto --timings",
      "normalized_command": "scripts/test --jobs auto --timings",
      "started_at": "2026-07-14T09:10:00Z",
      "finished_at": "2026-07-14T09:14:13Z",
      "duration_seconds": 253.0,
      "status": "passed",
      "exit_code": 0,
      "timing_source": "provider_event_timestamps",
      "redacted": false
    }
  ]
}

⸻

Existing Timeline Integration

Extend:

20-execution-timeline.json

with a summary reference rather than duplicating every operation.

Example:

{
  "command_timing_summary": {
    "artifact": "21-command-timings.json",
    "operation_count": 32,
    "measurable_operation_count": 27,
    "bash_wall_seconds": 948.2,
    "duplicate_command_count": 3
  }
}

Existing timeline files without this block remain valid.

⸻

Terminal Report

At the end of a final or partial invocation, print a compact section after the
execution timeline.

Example:

╭─ Slowest Agent Commands ─────────────────────────────────────────────────╮
│ Role       Tool    Status    Duration    Command                         │
├───────────────────────────────────────────────────────────────────────────┤
│ executor   Bash    PASS       4m 13s    scripts/test --jobs auto ...     │
│ executor   Bash    PASS       1m 54s    scripts/smoke --skip-tests       │
│ reviewer   Bash    PASS         51s     test/contextplus_adapter_test.sh │
│ executor   MCP     PASS         22s     semantic_code_search             │
│ reviewer   Bash    PASS         18s     bin/specrelay doctor             │
╰───────────────────────────────────────────────────────────────────────────╯

Then print:

Command timing summary:
  Observable operations:       32
  Measurable operations:       27
  Unmeasurable operations:      5
  Bash command time:       15m 48s
  Repeated commands:             3

⸻

Duplicate Commands

Report commands observed more than once.

Example:

Repeated agent commands:
  2× scripts/test --jobs auto --timings
     executor: 2 runs, total 8m 31s
  2× bin/specrelay doctor
     executor: 1 run
     reviewer: 1 run
     total: 7s

A repeated command is informational.

Do not automatically claim it was unnecessary.

⸻

Polling and Sleep Detection

Classify clearly observable polling or sleeping commands.

Examples:

sleep 30
sleep 120
until ...; do sleep 5; done

Report them separately when confidently detected:

Waiting/polling commands:
  Count:      4
  Total time: 5m 30s

Do not classify arbitrary long-running commands as waiting.

⸻

Task Inspection

Extend:

bin/specrelay task timeline <task-ref>

to include the command timing summary.

Add, if consistent with current CLI design:

bin/specrelay task commands <task-ref>

Optional:

bin/specrelay task commands <task-ref> --json

Expected behavior:

* read-only
* does not mutate task state
* unknown task fails clearly
* legacy tasks without command timings remain readable
* --json prints valid JSON
* default output shows slowest operations and duplicates

If adding another CLI subcommand would make this small task unnecessarily large,
integrating only with task timeline is acceptable.

⸻

Stream-Friendly Requirements

The report must:

* append new lines only
* use no cursor movement
* use no screen redraw
* remain copyable
* remain redirectable
* contain no ANSI escapes by default in non-TTY output
* remain understandable without color
* preserve complete raw provider logs

⸻

Performance Requirements

The feature must add negligible overhead.

Acceptance target:

command timing extraction overhead:
  less than 2 seconds for a normal task event file

A controlled fixture with at least 1,000 events must complete within a reasonable
bound and must not make provider execution wait on per-event disk-heavy work.

Batch extraction after provider completion is acceptable.

⸻

Backward Compatibility

* Existing tasks without 21-command-timings.json remain inspectable.
* Existing raw event files remain unchanged.
* Existing timeline JSON remains readable.
* Existing timeline CLI behavior remains valid.
* Existing run and resume behavior remains valid.
* Manual Reviewer behavior remains unchanged.
* Human final review remains required.

⸻

Required Tests

Event Pairing

* matching start and finish events produce one operation
* duration is non-negative
* unmatched start is marked incomplete
* unmatched finish is ignored or reported honestly
* duplicate event IDs do not create duplicate completed operations
* Executor and Reviewer events remain separate
* multiple resume invocations remain separate

Bash Timing

* Bash command text is captured
* exit code is captured when available
* passed status is recorded
* failed status is recorded
* pipeline remains one command
* command duration uses reliable timestamps
* missing timestamps produce not_measurable

Other Tools

* Read timing is captured when supported
* Edit timing is captured when supported
* Write timing is captured when supported
* unsupported tool is retained without fabricated timing

Redaction

* API key assignment is redacted
* token assignment is redacted
* authorization header is redacted
* normal command remains readable
* persisted artifact contains no fixture secret
* normalized command does not reintroduce a secret

Duplicate Detection

* identical normalized commands are grouped
* different test filenames are not grouped
* different Git refs are not grouped
* role counts are correct
* total measured duration is correct
* duplicate report does not claim avoidability

Waiting Detection

* direct sleep is classified as waiting
* polling loop containing sleep is classified as waiting
* ordinary long test command is not classified as waiting
* waiting duration is aggregated correctly

JSON Artifact

* JSON is valid
* schema version is present
* task ID is correct
* operation count is correct
* measurable count is correct
* artifact path remains task-scoped
* no new top-level directory is created
* atomic write preserves previous valid data on failure

Timeline Integration

* timeline references command timing artifact
* timeline summary counts are correct
* legacy timeline without command summary still renders
* partial invocation still writes available command timings
* resume preserves prior operation history

Rendering

* slowest commands are sorted by duration
* default maximum row count is bounded
* duplicate commands are printed
* waiting summary is printed
* unmeasurable count is printed
* partial report remains labeled partial
* no ANSI escapes appear in redirected output
* no cursor movement appears

CLI Inspection

* task timeline includes command timing summary
* legacy task reports command timing not recorded
* read-only inspection does not mutate task files
* JSON inspection output is valid if implemented

Compatibility

* existing standalone tests pass
* smoke passes with tests skipped
* doctor passes
* version works
* CI full verification remains unchanged
* human final review remains required

⸻

Acceptance Criteria

This specification is accepted only when:

* observable Bash commands have reliable durations
* unavailable timings are reported honestly
* role and invocation separation is preserved
* slowest commands are shown at task completion
* repeated commands are reported
* polling and sleep commands are identifiable
* secrets are redacted from the new artifact
* command timing data survives resume
* timeline references the command timing artifact
* legacy tasks remain readable
* no new top-level directory is added
* output remains stream-friendly
* extraction overhead is measured
* all existing tests pass
* human final review remains required

⸻

Reviewer Rejection Conditions

Reject if:

* command durations are guessed from prose
* incomplete operations are presented as precisely timed
* separate commands are merged incorrectly
* semantically different commands are grouped as duplicates
* secrets appear in the new JSON or terminal report
* raw provider evidence is removed or rewritten
* command timing history is lost on resume
* timeline JSON compatibility is broken
* a new top-level runtime directory is created
* terminal output uses redraw or cursor movement
* CI full verification is weakened
* human final review is removed

⸻

Verification

Run focused tests:

scripts/test test/command_timing_test.sh test/execution_timeline_test.sh

Exact filenames may follow repository conventions.

Run change-aware verification:

scripts/test --changed --jobs auto --timings --explain

Run the full suite once:

scripts/test --jobs auto --timings

Run smoke without rerunning the standalone suite:

scripts/smoke --skip-tests

Run:

SPECRELAY_PROVIDER_OPTIONAL=1 bin/specrelay doctor
bin/specrelay version

Use a deterministic fixture containing:

* successful Bash command
* failed Bash command
* repeated command
* sleep command
* polling command
* operation without timestamps
* secret-bearing command
* Executor and Reviewer operations
* operations from two invocations

Inspect:

.specrelay-runs/tasks/<task-id>/21-command-timings.json

and:

bin/specrelay task timeline <task-ref>

⸻

Executor Deliverables

Write:

03-executor-log.md
07-tests.txt
08-executor-summary.md

The summary must explicitly report:

* supported timing sources
* supported tool types
* unsupported/unmeasurable cases
* command normalization rules
* secret-redaction rules
* duplicate detection behavior
* waiting/polling detection behavior
* timeline integration
* multi-resume behavior
* measured extraction overhead
* remaining limitations
* verification results

⸻

Reviewer Focus

The Reviewer must independently verify:

1. command durations come from reliable event pairing
2. incomplete operations are not assigned fabricated durations
3. pipelines remain single observable commands
4. Executor and Reviewer operations remain separated
5. resume preserves prior command timing history
6. duplicate grouping is conservative
7. sleep and polling classification does not misclassify ordinary tests
8. secrets are absent from the new artifact and terminal report
9. timeline compatibility is preserved
10. no new top-level runtime directory is created
11. output remains stream-friendly
12. instrumentation overhead is bounded
    