# Change-Aware Test Selection
- Spec: 0017
- Status: Draft
---
# Summary
Add a safe, explainable mechanism for selecting relevant tests based on changed
files.
SpecRelay now supports parallel test execution, but the complete standalone
suite is still commonly executed for every implementation and review, even when
only a small part of the codebase changed.
This specification introduces:
- change-aware test selection
- explicit test-to-source mappings
- explainable selection output
- safe full-suite fallback
- changed-file inputs from Git or task evidence
- strict final-gate behavior
- operator override
- no silent skipping
The purpose is to reduce feedback time during implementation without weakening
final verification.
---
# Problem
After Spec 0016, the standalone suite runs significantly faster in parallel.
However, a full suite can still take several minutes.
Many changes affect only a narrow part of the system.
Examples:
```text
lib/specrelay/context/*
→ context adapter tests
→ config tests
→ workflow integration tests
lib/specrelay/providers/*
→ provider tests
→ model selection tests
→ workflow tests
scripts/test
→ test runner tests
→ release readiness tests

Running every test file for every small change:

* delays executor feedback
* delays reviewer feedback
* wastes CPU
* increases provider waiting time
* makes small Specs disproportionately expensive

A naive file-name matcher is unsafe because important indirect dependencies may
be missed.

⸻

Goals

* Select relevant test files from changed source files.
* Make every selection explainable.
* Allow explicit, reviewable mapping rules.
* Support changed files from the current Git working tree.
* Support changed files from SpecRelay task evidence.
* Preserve targeted test execution from Spec 0016.
* Fall back to the complete suite when confidence is insufficient.
* Keep final verification policy explicit.
* Prevent silent omission of required tests.
* Integrate with executor and reviewer workflows without coupling selection to
    an AI provider.
* Reuse existing runtime directories.
* Keep all output append-only and copyable.

⸻

Non-Goals

This specification does not:

* use AI to guess relevant tests
* perform semantic code analysis
* replace the full suite permanently
* weaken CI verification
* silently trust historical pass results
* implement flaky-test retries
* automatically modify test mappings
* infer safety from file names without declared rules
* create a new top-level runtime directory
* change test implementation semantics

⸻

Core Safety Principle

Change-aware selection is an optimization, not a replacement for trust.

When selection is uncertain, SpecRelay must run more tests, not fewer.

The safe fallback is:

full standalone suite

No path may silently result in zero tests for meaningful code changes.

⸻

New Test Runner Commands

Add:

scripts/test --changed

This selects tests based on the current Git working-tree changes.

Add:

scripts/test --changed-from <git-ref>

Example:

scripts/test --changed-from main

This selects tests based on files changed between the supplied Git reference and
the current working tree or HEAD, according to documented semantics.

Add:

scripts/test --changed-files <file>

The input file contains one project-relative changed path per line.

Example:

scripts/test --changed-files \
  .specrelay-runs/tasks/<task-id>/05-changed-files.txt

The runner must understand the existing name-status evidence format or require a
normalized path-only file with a clear error.

⸻

Explain Command

Support:

scripts/test --changed --explain

Example output:

Changed files:
  lib/specrelay/context/fake.sh
  lib/specrelay/context/capability.sh
  docs/context-adapters.md
Selected tests:
  test/context_adapters_test.sh
    reason: rule context-adapters
    matched: lib/specrelay/context/**
  test/config_test.sh
    reason: context configuration may affect config parsing
    matched: lib/specrelay/context/**
  test/workflow_fake_provider_test.sh
    reason: context handoff affects workflow execution
    matched: lib/specrelay/context/**
Ignored non-code changes:
  docs/context-adapters.md
    reason: documentation-only rule
Selection mode:
  mapped
Fallback:
  not required

The explanation must include:

* changed paths
* matched rules
* selected tests
* ignored paths
* fallback reason when applicable
* whether final full verification is still required

⸻

Mapping File

Introduce one explicit mapping file inside the existing test tree:

test/test-selection.yml

Do not create a new top-level directory.

Conceptual structure:

version: 1
rules:
  - id: context-adapters
    paths:
      - lib/specrelay/context/**
      - lib/specrelay/contexts.sh
    tests:
      - test/context_adapters_test.sh
      - test/config_test.sh
      - test/workflow_fake_provider_test.sh
  - id: providers
    paths:
      - lib/specrelay/providers/**
    tests:
      - test/provider_model_agent_test.sh
      - test/guided_model_selection_test.sh
      - test/provider_streaming_test.sh
      - test/workflow_fake_provider_test.sh
  - id: state-machine
    paths:
      - lib/specrelay/state.sh
      - lib/specrelay/transitions.sh
      - lib/specrelay/workflow.sh
    tests:
      - test/state_test.sh
      - test/transitions_test.sh
      - test/reviewer_continuation_test.sh
      - test/workflow_fake_provider_test.sh
  - id: test-runner
    paths:
      - scripts/test
      - test/test_runner_test.sh
      - test/serial-tests.txt
      - test/test-selection.yml
    tests:
      - test/test_runner_test.sh
      - test/release_readiness_test.sh
always:
  - test/release_readiness_test.sh
full_suite_if_changed:
  - bin/specrelay
  - lib/specrelay/cli.sh
  - lib/specrelay/task.sh
  - test/test_helper.sh
  - scripts/smoke
  - .github/workflows/**

The exact schema may be refined, but it must remain:

* explicit
* versioned
* easy to review
* deterministic
* validated before use

⸻

Mapping Validation

Reject mapping files with:

* unknown schema version
* duplicate rule IDs
* missing paths
* missing tests
* nonexistent test files
* paths outside the repository
* tests outside the allowed test directory
* invalid glob syntax
* empty mappings
* unknown keys where strict validation is feasible

Validation errors must be actionable.

Example:

scripts/test: invalid test selection rule 'providers'
Referenced test does not exist:
  test/provider_models_test.sh
Fix:
  test/test-selection.yml

⸻

Rule Matching

Rules may use project-relative glob patterns.

Matching behavior must be documented and consistent across supported platforms.

Do not depend on shell glob expansion that varies by shell configuration.

Use a deterministic implementation, preferably Python if that reduces
cross-platform ambiguity.

A changed file may match multiple rules.

Selected tests are the union of all matched rule tests.

Duplicates must be removed.

Final order must be deterministic.

⸻

Always-Run Tests

The mapping may declare a small set of always-run tests.

These tests run whenever change-aware selection is used.

The list must remain intentionally small.

Do not put the entire suite into always.

Every always-run test must have a documented reason.

⸻

Full-Suite Triggers

Some files have broad impact and must trigger the complete standalone suite.

Examples may include:

bin/specrelay
lib/specrelay/cli.sh
lib/specrelay/task.sh
test/test_helper.sh
scripts/test
scripts/smoke
test/test-selection.yml

The mapping must support explicit full-suite trigger patterns.

When triggered, output must say:

Full-suite fallback selected.
Reason:
  changed file 'test/test_helper.sh' matches full-suite trigger

⸻

Unmapped File Behavior

For a changed code or executable file not covered by any rule:

fallback to full suite

Do not silently ignore it.

Examples of meaningful file types:

.sh
.py
.rb
.yml
.yaml
.json

The exact classification must follow repository conventions.

Documentation-only changes may be ignored only through an explicit safe rule or
documented extension/path policy.

Unknown file types must default conservatively.

⸻

Documentation-Only Changes

Support a clear documentation-only path policy.

Examples:

docs/**
README.md
CONTRIBUTING.md

Possible behavior:

* run a small documentation/release-readiness set
* or run no implementation tests but run validation tests

The behavior must be explicit in the mapping.

It must never report:

all tests passed

when no tests ran.

Instead:

No implementation tests selected.
Documentation validation tests: 1 passed.
Final full suite: still required by release policy.

⸻

Selection Modes

The runner must report one of:

explicit
mapped
full-suite-fallback
documentation-only

Explicit

The operator supplied test files directly.

Mapped

Tests were selected through change mappings.

Full-Suite Fallback

Selection could not safely narrow the suite.

Documentation-Only

Only explicitly safe documentation paths changed.

⸻

Integration with Parallel Runner

Selected tests must run through the parallel runner from Spec 0016.

Examples:

scripts/test --changed --jobs auto --timings
scripts/test --changed-files <file> --jobs 4 --explain

All existing features remain available:

* timings
* slowest
* slow threshold
* serial-only tests
* deterministic output
* timing JSON
* targeted tests

⸻

Git Change Sources

Working Tree

scripts/test --changed

Must include relevant:

* tracked modifications
* staged changes
* untracked files

Excluded runtime paths must follow project conventions:

.specrelay-runs/
.specrelay-cache/
.specrelay-locks/

Git Reference

scripts/test --changed-from <ref>

The command must validate the ref.

Document whether comparison uses:

<ref>...HEAD

or another explicit Git range.

Working-tree changes must not be silently ignored where the command promises to
include them.

Evidence File

scripts/test --changed-files <file>

Must normalize existing changed-file evidence safely.

Rename records must include both relevant old and new paths where required.

⸻

SpecRelay Workflow Integration

Add a workflow helper or documented convention for executors.

During implementation:

scripts/test --changed --jobs auto --timings

Before executor submission:

scripts/test --changed-files \
  .specrelay-runs/tasks/<task-id>/05-changed-files.txt \
  --jobs auto \
  --timings \
  --explain

However, note that 05-changed-files.txt is normally captured after executor
work. The implementation must not create a circular dependency.

Acceptable alternatives include:

* current Git working-tree selection before evidence capture
* a normalized changed-path snapshot generated for test selection
* selection from Git diff directly

The architecture must remain clear.

⸻

Final Verification Policy

Change-aware testing must not silently redefine what “fully verified” means.

Introduce explicit policy terminology:

targeted verification
full verification

Targeted Verification

Relevant tests selected from changed files.

Useful for:

* development feedback
* executor iteration
* reviewer focused checks

Full Verification

Complete standalone suite.

Required for:

* release readiness
* CI on protected branches
* explicit final gate, unless policy is changed separately

The current repository policy should continue requiring full verification before
final merge unless explicitly changed by another specification.

⸻

Executor Behavior

Executor guidance should encourage:

1. run targeted tests during implementation
2. run change-aware tests before submission
3. run full suite once at the final gate when required
4. run smoke with --skip-tests after full suite

The executor must not run the full suite after every edit.

This is guidance and workflow integration, not a hidden restriction.

⸻

Reviewer Behavior

Reviewer guidance should encourage:

* independent targeted tests for changed areas
* examination of selection explanation
* verification that mappings cover the changes
* full suite only when required by review policy or risk

The reviewer must remain free to run additional tests.

The reviewer must reject suspiciously narrow selection.

⸻

Selection Evidence

When requested, write machine-readable selection metadata under existing
runtime locations.

General cache:

.specrelay-cache/tests/latest-selection.json

Task-specific evidence:

.specrelay-runs/tasks/<task-id>/07-test-selection.json

No new top-level directory.

Conceptual JSON:

{
  "schema_version": 1,
  "mode": "mapped",
  "changed_files": [
    "lib/specrelay/context/fake.sh"
  ],
  "selected_tests": [
    {
      "path": "test/context_adapters_test.sh",
      "rules": ["context-adapters"]
    }
  ],
  "ignored_files": [],
  "full_suite_fallback": false
}

Output must be atomically written.

⸻

Timing Integration

Selection JSON and timing JSON should be linkable through:

* common invocation timestamp
* run identifier
* or explicit paths

Do not duplicate complete timing data inside selection output.

The final human-readable summary should show:

Changed files:    4
Selected tests:   5 / 30
Workers:          5
Wall time:        1m 12s
Full suite:       not run
Final policy:     full verification still required

⸻

Safety Against Mapping Drift

Mappings can become stale when:

* source files are added
* tests are renamed
* architectural dependencies change

Add a mapping coverage validation command or test.

Possible command:

scripts/test --validate-selection-map

It must check at least:

* all mapped tests exist
* all declared full-suite patterns are valid
* all relevant current source files are matched by a rule or explicit fallback
* no stale test references exist

It must not pretend to prove semantic completeness.

⸻

Change-Aware Test for the Mapping Itself

Any change to:

test/test-selection.yml

must trigger the full suite.

This prevents a broken or narrowed mapping from validating itself with only a
small subset.

⸻

CI Integration

CI should continue running the full parallel suite by default:

scripts/test --jobs auto --timings

Change-aware selection may be added as an earlier fast feedback job, but it must
not replace the protected full-suite job in this specification.

No weakening of CI is allowed.

⸻

Smoke Integration

Recommended final workflow:

scripts/test --jobs auto --timings
scripts/smoke --skip-tests

Recommended development workflow:

scripts/test --changed --jobs auto --timings --explain

Smoke behavior from Spec 0016 remains unchanged.

⸻

Output Contract

All selection and test output must remain:

* append-only
* deterministic
* copyable
* redirectable
* non-interactive
* understandable without color

No dashboard, spinner, cursor movement, or hidden test list.

⸻

Required Tests

Argument Parsing

* --changed works
* --changed-from requires a valid ref
* --changed-files requires a readable file
* incompatible change-source options are rejected
* --explain works
* --validate-selection-map works
* unknown option remains rejected

Mapping Validation

* valid mapping parses
* unknown schema version is rejected
* duplicate rule ID is rejected
* nonexistent test is rejected
* invalid glob is rejected
* path outside repository is rejected
* unknown key is rejected
* empty mapping is rejected

Selection

* one changed file selects expected tests
* multiple rules produce a union
* duplicates are removed
* output order is deterministic
* always-run tests are included
* full-suite trigger selects all tests
* unmapped code file falls back to full suite
* documentation-only change follows documented policy
* mapping-file change triggers full suite

Git Inputs

* unstaged tracked change is detected
* staged change is detected
* untracked file is detected
* runtime directories are excluded
* valid Git ref comparison works
* invalid Git ref fails clearly
* rename evidence is handled conservatively

Explicit Changed-File Input

* path-only input works
* existing name-status evidence is normalized
* malformed evidence fails clearly
* missing evidence file fails
* duplicate changed paths are removed

Execution

* selected tests run exactly once
* non-selected tests do not run
* selected tests use parallel runner
* serial-only behavior is preserved
* failing selected test fails the command
* complete logs remain available
* timing output still works

Explainability

* every selected test has at least one reason
* ignored file has a reason
* fallback has an explicit reason
* full verification policy is displayed
* no test is silently omitted

Evidence

* selection JSON is valid
* task-specific output can be written explicitly
* output is atomic
* no new top-level directory is created
* timing and selection results can be associated

Compatibility

* direct explicit test-file execution remains unchanged
* default scripts/test still runs the full suite
* CI still runs the full suite
* smoke behavior remains unchanged
* all existing tests pass

⸻

Performance Evidence

The executor must report at least one real comparison:

full parallel suite wall time
change-aware selected suite wall time
number of total tests
number of selected tests

Use a representative real change set.

Do not fabricate expected savings.

If a common change still triggers the full suite, document why and refine the
mapping only when safe.

⸻

Acceptance Criteria

This specification is accepted only when:

* scripts/test --changed exists
* test selection is deterministic
* selection rules are explicit and versioned
* selected tests are explainable
* unmapped meaningful changes fall back to full suite
* broad-impact changes trigger full suite
* direct targeted test execution still works
* selected tests use the parallel runner
* final verification policy remains explicit
* CI still performs the complete suite
* selection evidence uses existing runtime directories
* no new top-level directory is created
* real performance evidence shows reduced feedback time for a narrow change
* all existing tests pass

⸻

Reviewer Rejection Conditions

Reject if:

* selection is based on opaque AI guesses
* tests are silently skipped
* unmapped source changes result in no tests
* mapping changes do not trigger full verification
* CI full-suite verification is removed
* explanations do not show why tests were selected
* documentation paths are broadly ignored without explicit policy
* mappings contain stale or missing test files
* runtime directories pollute selection
* a new top-level results directory is introduced
* narrow selection is presented as complete verification

⸻

Verification

Validate the mapping:

scripts/test --validate-selection-map

Run change-aware tests:

scripts/test --changed --jobs auto --timings --explain

Run from a Git reference:

scripts/test --changed-from HEAD~1 --jobs auto --timings --explain

Run the full suite:

scripts/test --jobs auto --timings

Run smoke without test duplication:

scripts/smoke --skip-tests

Run:

SPECRELAY_PROVIDER_OPTIONAL=1 bin/specrelay doctor
bin/specrelay version

Inspect selection evidence under:

.specrelay-cache/tests/

or an explicit task evidence destination.

Verify no new top-level directory exists.

⸻

Executor Deliverables

Write:

03-executor-log.md
07-tests.txt
08-executor-summary.md

When available, also write:

07-test-selection.json
07-test-timings.json

The summary must include:

* mapping architecture
* fallback rules
* full-suite triggers
* documentation-only behavior
* Git change detection
* task evidence integration
* executor/reviewer guidance
* CI policy
* performance comparison
* remaining risks
* verification results

⸻

Reviewer Focus

The reviewer must independently verify:

1. a narrow change selects the correct tests
2. every selection is explainable
3. an unmapped code change triggers the full suite
4. a mapping-file change triggers the full suite
5. selected tests run exactly once
6. CI still runs the full suite
7. targeted verification is not mislabeled as full verification
8. no new top-level runtime directory is created
