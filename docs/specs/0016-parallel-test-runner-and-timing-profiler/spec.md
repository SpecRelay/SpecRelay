# Parallel Test Runner and Timing Profiler
- Spec: 0016
- Status: Draft
---
# Summary
Redesign SpecRelay's standalone test runner to execute independent test files in
parallel while producing deterministic, complete, stream-friendly output and
per-test timing data.
The current sequential test and smoke workflow is prohibitively slow.
A representative `scripts/smoke` run took approximately:
```text
14 minutes 46 seconds

The same test suites may also be executed multiple times during one SpecRelay
task by:

* the executor during implementation
* the executor before submission
* scripts/smoke
* the independent reviewer
* manual operator verification

This specification introduces:

* bounded parallel test-file execution
* deterministic output collection
* per-file timing
* slow-test reporting
* machine-readable timing evidence
* targeted test selection
* clear separation between test and smoke responsibilities
* safe compatibility for serial-only tests
* no new top-level runtime directories

⸻

Problem

The current standalone suite runs test files sequentially.

With approximately 29 standalone test files, total wall time becomes excessive,
especially when expensive integration-style test files include:

* temporary Git repositories
* provider simulations
* installation and upgrade flows
* multi-round workflow execution
* repeated CLI processes
* context preparation scenarios
* artificial failure and recovery cases

The slow test runner causes several practical problems:

* Specs take much longer than implementation work requires
* executor and reviewer spend most of their time waiting
* users avoid rerunning verification
* missing artifacts become expensive to reconstruct
* reviewers may duplicate the executor’s entire verification cost
* slow regressions are invisible because no timing profile exists

Blindly running every test in parallel is also unsafe because some test files may
share resources or rely on serial execution.

⸻

Goals

* Reduce standalone test-suite wall time substantially.
* Run independent test files concurrently.
* Preserve complete output for every test.
* Prevent interleaved unreadable parallel logs.
* Print results in deterministic order.
* Record per-test duration and exit status.
* Identify the slowest test files.
* Support explicit serial-only tests.
* Support targeted test execution.
* Keep existing scripts/test behavior compatible.
* Avoid adding any new top-level runtime directory.
* Keep scripts/smoke from unnecessarily duplicating full-suite work.
* Preserve CI and non-interactive execution.
* Keep output append-only and copyable.

⸻

Non-Goals

This specification does not:

* parallelize assertions within a single test file
* rewrite every existing test
* introduce a third-party test framework
* add distributed testing
* use remote workers
* change test semantics
* hide failing test output
* skip required tests silently
* weaken verification policy
* make flaky tests pass through retries
* create a new root-level cache or results directory
* alter executor or reviewer state transitions

⸻

Core Principle

Parallel execution must reduce wall-clock time without reducing trust.

The runner must never trade correctness for speed.

The following are acceptance-critical:

complete logs
real exit codes
deterministic summary
bounded concurrency
safe cleanup
no hidden failures

⸻

Directory Policy

No new top-level runtime directory may be created.

Do not introduce directories such as:

.specrelay-test-results/
.specrelay-timings/
.test-cache/
.test-results/

Existing runtime namespaces must be reused.

General reusable timing data may be stored under:

.specrelay-cache/tests/

Task-specific timing evidence may be stored under the existing task directory:

.specrelay-runs/tasks/<task-id>/

Possible files:

07-tests.txt
07-test-timings.json

Temporary per-worker logs must use the operating system temporary directory and
must be removed after completion unless explicitly retained for debugging.

⸻

Test Runner Command Contract

Preserve:

scripts/test

This remains the canonical standalone-suite command.

Add support for:

scripts/test --jobs <n>
scripts/test --jobs auto
scripts/test --serial
scripts/test --timings
scripts/test --slowest <n>
scripts/test --slow-threshold <seconds>
scripts/test <test-file> [<test-file> ...]

Combinations must be supported where meaningful:

scripts/test --jobs 8 --timings
scripts/test --jobs auto --slowest 10
scripts/test test/context_adapters_test.sh test/config_test.sh

⸻

Default Concurrency

The default may remain serial initially only if backward compatibility requires
it.

The preferred behavior is:

jobs = min(logical CPU count, 8)

when parallel execution is considered safe.

Support environment override:

SPECRELAY_TEST_JOBS=4 scripts/test

Precedence:

--jobs
→ SPECRELAY_TEST_JOBS
→ configured/default auto value

Invalid values must fail clearly.

Examples of invalid values:

0
-1
abc
999999

A reasonable upper bound must prevent accidental process explosions.

⸻

Auto Job Detection

--jobs auto must use a portable best-effort logical CPU count.

Supported approaches may include:

sysctl -n hw.logicalcpu
getconf _NPROCESSORS_ONLN
nproc

The runner must fall back safely when detection fails.

Fallback:

1 worker

The selected worker count must be printed in the summary.

⸻

Test File Discovery

The runner must continue discovering standalone tests according to current
repository conventions.

Discovery must:

* include executable standalone test/*_test.sh files
* preserve the current exclusion of host-integration tests
* avoid running helper files
* avoid duplicate test files
* sort discovered files deterministically

The existing skipped host-integration list must remain visible in the final
summary.

⸻

Parallel Execution Model

Each test file must run in its own process.

Each test process must receive:

* the repository root as expected by current tests
* the current environment, subject to existing test conventions
* isolated stdout capture
* isolated stderr capture
* a recorded start time
* a recorded end time
* a recorded exit code

Parallel processes must not write directly into a shared terminal stream.

Instead, output from each test must be captured separately and printed later in
a deterministic order.

⸻

Deterministic Output

Parallel completion order must not control final presentation order.

The final output must follow deterministic test-name order or the explicit input
order for targeted tests.

Example:

=== config_test.sh ===
<complete captured output>
=== context_adapters_test.sh ===
<complete captured output>

Even if context_adapters_test.sh finishes before config_test.sh, the printed
order remains stable.

This preserves:

* readable logs
* reproducible CI output
* easy diffing
* reliable evidence
* compatibility with user copy/paste expectations

⸻

Live Progress

The runner may emit append-only progress lines while tests execute.

Example:

[test] started config_test.sh
[test] started context_adapters_test.sh
[test] passed config_test.sh (1.8s)
[test] started install_upgrade_test.sh
[test] passed context_adapters_test.sh (42.6s)

Requirements:

* append-only
* no spinner
* no cursor movement
* no redraw
* no progress-bar replacement
* no loss of final full logs

Live progress is optional if it complicates deterministic logging.

⸻

Complete Test Logs

No test output may be discarded.

For passing tests, the runner may support a compact mode in the future, but the
default behavior for this specification must preserve the complete existing
output unless current compatibility tests require otherwise.

For failing tests, complete stdout and stderr must always be printed.

Parallel execution must not produce mixed lines from different test files.

⸻

Timing Measurement

Record for each test file:

name
path
started_at
finished_at
duration_seconds
exit_code
status
execution_mode
worker

Possible status values:

passed
failed
cancelled
not-run

Possible execution modes:

parallel
serial

Use a monotonic clock for duration measurement where available.

Wall-clock timestamps may be recorded separately for evidence.

⸻

Timing Summary

At the end of every test run, print:

Test files:        29
Workers:            8
Passed:            29
Failed:             0
Wall time:       3m 12s
Serial sum:     14m 46s
Speedup:          4.6x

Only print speedup when it can be calculated honestly.

The serial sum means the sum of individual test-file durations, not a separate
serial execution.

⸻

Slowest Tests

When --timings or --slowest is used, print a sorted slowest-test section.

Example:

Slowest test files:
142.3s  install_upgrade_test.sh
 81.6s  context_adapters_test.sh
 37.9s  workflow_fake_provider_test.sh
 22.4s  guided_model_selection_test.sh

Default slowest count:

10

when timing output is enabled.

⸻

Slow Threshold

Support:

scripts/test --slow-threshold 30

Tests meeting or exceeding the threshold must be marked:

SLOW  context_adapters_test.sh  81.6s

This is informational only.

A slow test must not fail merely for exceeding the threshold unless a future
separate policy explicitly introduces performance budgets.

⸻

Machine-Readable Timing Output

Write the latest general timing result to:

.specrelay-cache/tests/latest.json

only when caching or timing persistence is enabled.

The runner must create:

.specrelay-cache/tests/

under the existing cache namespace if needed.

No new root-level directory is allowed.

Conceptual JSON:

{
  "schema_version": 1,
  "started_at": "2026-07-13T20:00:00Z",
  "finished_at": "2026-07-13T20:03:12Z",
  "jobs": 8,
  "wall_seconds": 192.4,
  "serial_sum_seconds": 886.7,
  "passed": 29,
  "failed": 0,
  "tests": [
    {
      "name": "config_test.sh",
      "path": "test/config_test.sh",
      "duration_seconds": 1.8,
      "exit_code": 0,
      "status": "passed",
      "execution_mode": "parallel"
    }
  ]
}

The file must be written atomically.

A partially written JSON file must never replace a previous valid result.

⸻

Task-Specific Timing Evidence

When the test runner is invoked with an explicit task timing destination, it may
write:

.specrelay-runs/tasks/<task-id>/07-test-timings.json

The mechanism must follow existing task/evidence conventions.

Do not infer the active task merely from the newest task directory.

Require an explicit environment variable or CLI argument if needed.

Example:

SPECRELAY_TEST_TIMINGS_OUT=.specrelay-runs/tasks/<task-id>/07-test-timings.json scripts/test

The standard human-readable output remains suitable for 07-tests.txt.

⸻

Serial-Only Tests

Some tests may be unsafe to execute concurrently.

Introduce an explicit serial-test mechanism.

Acceptable designs include:

test/serial-tests.txt

or a lightweight metadata convention near the runner.

The mechanism must be:

* explicit
* reviewable
* deterministic
* easy to maintain
* covered by tests

Serial-only tests run after or before the parallel group in deterministic order.

They must still receive timing measurement.

Do not classify every slow test as serial merely because it is slow.

Serial classification must be based on resource conflicts or correctness.

⸻

Resource Isolation

Parallel tests commonly create temporary repositories and files.

The implementation must verify that tests use unique temporary paths.

Tests that rely on fixed shared paths, ports, files, or global mutable state must
either:

* be fixed to use isolated resources
* be declared serial-only

Do not hide resource conflicts by adding automatic retries.

A parallelization-induced flaky failure is a rejection-level defect.

⸻

Failure Behavior

By default, the runner should allow already-running tests to finish after one
test fails, then report all failures.

It must not start unlimited new work after a fatal runner-level error.

Optional future fail-fast behavior is outside this specification unless trivial.

Final exit code:

0 when all selected tests pass
non-zero when any selected test fails or runner setup fails

The exit code must remain compatible with CI and SpecRelay evidence gates.

⸻

Interrupt Handling

On SIGINT or SIGTERM:

* stop launching new tests
* terminate active child test processes
* wait for cleanup
* remove temporary capture files
* exit non-zero
* report which tests were cancelled or not run
* do not leave orphan test processes

No valid previous latest.json timing result may be destroyed by an interrupted
run.

⸻

Targeted Test Execution

Support explicit test files:

scripts/test test/context_adapters_test.sh
scripts/test test/context_adapters_test.sh test/config_test.sh

Requirements:

* preserve given order in final output
* reject unknown files clearly
* reject files outside the allowed test root
* do not silently expand a typo to a different file
* still provide timing and summary
* still support --jobs

This allows executors and reviewers to run affected tests during development
without executing the full suite repeatedly.

⸻

Test Groups

Optionally support lightweight groups if the repository already has a suitable
convention.

Possible conceptual groups:

fast
workflow
provider
context
packaging
all

Do not introduce a complex manifest system merely for this specification.

Targeted file execution is mandatory.

Named groups are optional.

⸻

Smoke Test Responsibility

The current smoke command executes the full standalone suite and then performs:

* doctor
* version
* install
* installed doctor
* upgrade
* fake-provider run
* uninstall

This creates expensive duplication when scripts/test was already executed.

Refactor smoke responsibilities clearly.

Support one or both of:

scripts/smoke --skip-tests
scripts/smoke --tests-already-passed <evidence-or-fingerprint>

The minimum required behavior is:

scripts/smoke --skip-tests

which skips only the standalone suite and still runs all non-test smoke checks.

Default scripts/smoke must remain backward compatible and continue running the
suite unless explicitly skipped.

The skip must be visible:

Standalone suite: SKIPPED by explicit --skip-tests

It must never happen silently.

⸻

Verification Workflow

Recommended full verification after this specification:

scripts/test --jobs auto --timings
scripts/smoke --skip-tests

This runs the standalone suite once, then executes smoke-only checks.

It avoids the current duplicate suite run.

⸻

Fingerprint-Based Reuse

A test-result fingerprint is valuable but optional for this specification.

If implemented, it must include enough state to avoid stale reuse:

HEAD commit
working-tree diff hash
test-file content hash
runner version
relevant runtime versions

A weak cache keyed only by HEAD is forbidden because SpecRelay commonly tests
uncommitted working-tree changes.

No previous result may be treated as valid after relevant source or test changes.

If reliable fingerprinting cannot be completed safely, implement only explicit
--skip-tests and leave automatic reuse for a later specification.

⸻

CI Behavior

CI must work with the parallel runner.

The implementation must ensure:

* deterministic final logs
* stable exit status
* no dependency on an interactive TTY
* no ANSI requirement
* bounded worker count
* portable CPU detection
* complete failure output

Update CI to use an appropriate command only when safe.

Potential command:

scripts/test --jobs auto --timings

Do not overload small CI environments with excessive workers.

⸻

Stream-Friendly Output

All output must remain append-only.

The runner must not:

* clear the screen
* redraw progress
* move the cursor upward
* use an alternate screen
* overwrite status lines
* hide previous output

The complete run must remain copyable and redirectable.

Example:

scripts/test --jobs 8 --timings | tee /tmp/test.log

must preserve the complete result.

⸻

Documentation

Update relevant documentation with:

* parallel execution
* default worker behavior
* environment override
* serial mode
* targeted test execution
* timing output
* slowest reporting
* slow threshold
* cache location
* task-specific timing evidence
* serial-only test declaration
* smoke --skip-tests
* recommended executor verification flow
* recommended reviewer verification flow
* no-new-top-level-directory policy

Document that:

.specrelay-cache/tests/

is reusable local cache/profiling data and should remain ignored by Git.

⸻

Required Tests

Argument Parsing

* default invocation works
* --jobs 1 works
* --jobs auto works
* environment job override works
* CLI jobs override environment
* invalid job count is rejected
* --serial forces one worker
* --timings works
* --slowest validates its argument
* --slow-threshold validates its argument
* unknown option is rejected

Discovery

* standalone tests are discovered
* helper files are excluded
* host-integration tests remain skipped
* discovery order is deterministic
* explicit test-file selection works
* explicit order is preserved
* missing explicit test is rejected
* path outside test root is rejected

Parallel Execution

* multiple test files overlap in wall-clock execution
* worker count is bounded
* each file runs exactly once
* exit codes are preserved
* one failure makes the suite fail
* all failures are reported
* output from different tests is not interleaved

Deterministic Output

* final logs follow deterministic order
* parallel completion order does not change final ordering
* complete stdout is preserved
* complete stderr is preserved
* output remains append-only
* redirected output remains complete

Timing

* each test receives a duration
* wall time is recorded
* serial sum is recorded
* slowest list is correctly sorted
* slow threshold marking works
* failed tests still receive timing
* timing JSON is valid
* timing JSON is atomically written
* no new top-level directory is created

Serial-Only Tests

* serial-only tests do not overlap other serial-only tests
* parallel-safe tests still run concurrently
* serial tests remain timed
* serial-test metadata is deterministic
* invalid serial metadata fails clearly

Interrupts

* SIGINT terminates active children
* no orphan processes remain
* interrupted run exits non-zero
* cancelled tests are reported
* temporary files are cleaned
* prior valid timing JSON remains intact

Smoke

* default smoke still runs standalone tests
* smoke --skip-tests skips the standalone suite visibly
* smoke --skip-tests still runs doctor/version/install/upgrade/fake-run/uninstall
* invalid smoke option fails
* smoke exit codes remain correct

Compatibility

* all existing standalone tests remain green
* existing CI behavior remains valid
* existing test output assertions are updated only where necessary
* test semantics are unchanged
* no flaky retries are introduced

⸻

Performance Acceptance Criteria

The implementation must include a real before/after timing comparison.

Using the current standalone suite on the same machine:

serial baseline wall time
parallel wall time
worker count
speedup
slowest files

The reviewer must not accept a claim of improvement without measured evidence.

A specific speedup ratio is not guaranteed because machine load varies, but the
parallel runner must demonstrate genuine overlap and meaningful wall-time
reduction when more than one parallel-safe test exists.

If performance does not improve materially, the executor must explain why and
identify the actual bottleneck.

⸻

Acceptance Criteria

This specification is accepted only when:

* scripts/test supports bounded parallel test-file execution
* complete logs remain available
* output is deterministic
* per-file timing is recorded
* slowest tests are reported
* targeted test execution works
* serial-only tests are supported
* interrupted runs clean up children
* scripts/smoke --skip-tests avoids duplicate standalone-suite execution
* general timing data stays under .specrelay-cache/tests/
* task timing evidence can remain under the existing task directory
* no new top-level runtime folder is created
* no flaky retry mechanism is added
* CI remains functional
* all existing tests pass
* before/after timing evidence is documented

⸻

Reviewer Rejection Conditions

The reviewer must reject the implementation if:

* parallel logs are interleaved and unreadable
* tests are silently skipped
* a failing test returns success
* job count is unbounded
* process cleanup leaves orphan children
* timing output is fabricated or based only on estimates
* serial-only resource conflicts are ignored
* retries hide flaky tests
* smoke silently skips tests
* automatic result reuse uses a weak or unsafe fingerprint
* a new top-level runtime directory is added
* output stops being append-only or copyable
* test semantics are weakened to obtain speedup

⸻

Verification

Capture a serial baseline:

scripts/test --serial --timings

Run the parallel suite:

scripts/test --jobs auto --timings

Run targeted tests:

scripts/test test/context_adapters_test.sh test/config_test.sh

Run smoke without duplicating the suite:

scripts/smoke --skip-tests

Run full compatibility checks:

SPECRELAY_PROVIDER_OPTIONAL=1 bin/specrelay doctor
bin/specrelay version

Verify timing output:

cat .specrelay-cache/tests/latest.json

Verify no unwanted top-level directory was created:

git status --short

and inspect root-level hidden directories before and after.

Verify interrupted execution leaves no orphan child processes.

⸻

Executor Deliverables

Write:

03-executor-log.md
07-tests.txt
08-executor-summary.md

Also include timing evidence in:

07-test-timings.json

when task-specific timing output is implemented.

The executor summary must explicitly report:

* runner architecture
* worker selection
* deterministic output design
* serial-only mechanism
* timing format
* slowest tests
* interrupt cleanup
* targeted-test behavior
* smoke deduplication
* directory policy
* serial baseline
* parallel wall time
* measured speedup
* remaining bottlenecks
* verification results

⸻

Reviewer Focus

The reviewer must independently verify:

1. tests genuinely overlap in time
2. each selected test runs exactly once
3. failure exit codes are preserved
4. logs are complete and not interleaved
5. output order is deterministic
6. timing data matches observed execution
7. serial-only tests remain safe
8. smoke skipping is explicit
9. no new top-level runtime directory appears
10. measured wall time improves meaningfully
 