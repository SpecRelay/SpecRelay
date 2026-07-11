# 0003 — Restore live provider terminal output
- **Status:** Draft
- **Spec number:** 0003
- **Spec path:** `docs/specs/0003-restore-live-provider-terminal-output/spec.md`
## Goal
Restore live terminal visibility while SpecRelay runs executor and reviewer providers.
Today, during `specrelay run`, the operator sees phase banners such as:
```text
[executor] task '<id>': running provider 'claude' (round 1)

Then the terminal can stay silent for a long time while the executor or reviewer is actually working. This creates a bad operator experience: the user cannot tell whether the provider is making progress, blocked, waiting, or hung.

After this task, executor and reviewer provider output must be streamed live to the terminal while still being captured completely in durable evidence files.

Context

SpecRelay is a standalone repository:

* Remote: git@github.com:SpecRelay/SpecRelay.git
* Current version: 0.4.0 unless changed before implementation.
* Spec convention: docs/specs/<number>-<slug>/spec.md.

Recent dogfood runs showed that SpecRelay captures evidence, but the live terminal experience is too quiet. This is especially painful for real providers such as claude and claude-subagent, where provider runs can take several minutes.

This problem is separate from:

* non-ASCII shell/global hook noise;
* duplicate transition after READY_FOR_HUMAN_REVIEW;
* ContextPlus setup;
* AI review state/schema naming.

Those are separate tasks.

Problem

When a provider runs, SpecRelay currently prioritizes evidence capture but does not provide enough live output to the operator.

The operator needs useful live visibility for:

* executor progress;
* reviewer progress;
* provider errors;
* long-running operations;
* final provider status.

The evidence files must remain the durable source of truth. Live terminal output is an operator UX layer, not a replacement for evidence.

Scope

1. Repository facts verification

Before implementation, verify and record:

* this is the standalone SpecRelay repository;
* origin is git@github.com:SpecRelay/SpecRelay.git;
* VERSION value;
* working tree state;
* current configured providers in .specrelay/config.yml;
* current provider implementation files under lib/specrelay/providers/;
* current evidence capture behavior.

2. Investigate current provider output flow

Inspect the current implementation and identify:

* where executor provider stdout/stderr is produced;
* where reviewer provider stdout/stderr is produced;
* where provider output is redirected into evidence files;
* whether stdout and stderr are merged or separated;
* whether output is buffered;
* whether provider output is hidden by command substitution, redirection, subshells, or temporary files;
* which evidence files currently receive provider output.

The implementation must be based on the real current code, not assumptions.

3. Live streaming requirement

For real provider runs, SpecRelay must stream provider output live to the terminal.

Minimum expected behavior:

* executor output appears while executor is running;
* reviewer output appears while reviewer is running;
* output is prefixed or otherwise clearly scoped so the operator can tell whether it belongs to executor or reviewer;
* output is still captured in the existing evidence files;
* output order is not misleading;
* provider exit code is preserved;
* task state transitions remain unchanged except where needed to support correct output handling.

Example acceptable terminal shape:

[executor] task '0003-...': running provider 'claude' (round 1)
[executor:claude] ...
[executor:claude] ...
[executor] task '0003-...': capturing evidence
Transitioned: EXECUTOR_RUNNING -> READY_FOR_REVIEW
[reviewer] task '0003-...': running provider 'claude-subagent' (round 1, isolated context)
[reviewer:claude-subagent] ...
[reviewer:claude-subagent] ...
Transitioned: READY_FOR_REVIEW -> READY_FOR_HUMAN_REVIEW

The exact prefix format may differ, but executor and reviewer output must not be ambiguous.

4. Evidence preservation requirement

Live terminal output must not replace durable evidence.

The implementation must preserve:

* executor log evidence;
* reviewer log evidence;
* test output evidence;
* executor summary;
* reviewer decision/review;
* provider exit status handling;
* failure diagnostics.

If the same stream is shown live and written to a file, use a safe pattern such as tee or an equivalent that preserves exit codes correctly.

Do not introduce a pipe-status bug where a failing provider looks successful because tee succeeded.

5. Provider abstraction requirement

The solution must work through the provider abstraction.

It must not hardcode behavior only for one provider unless the provider-specific part is isolated and documented.

Check at least:

* fake;
* claude;
* claude-subagent;
* manual reviewer path, if applicable.

Fake provider tests must remain deterministic. If fake provider intentionally emits small output, tests should assert the live streaming path without making output noisy or flaky.

6. Non-interactive and CI behavior

SpecRelay must remain usable in non-interactive environments.

The implementation should define behavior for:

* normal terminal run;
* redirected stdout/stderr;
* CI;
* tests.

Do not require a TTY to preserve evidence.

If color or formatting is added, it must be disabled by default or controlled safely. Prefer no color in this task unless already supported.

7. Failure behavior

If the provider fails:

* live terminal output should show useful failure context;
* evidence files should contain the complete captured output;
* exit code and state transition behavior must remain correct;
* SpecRelay must not pretend success because streaming succeeded.

The implementation should include a test or fixture that proves provider failure is still detected when output is streamed.

8. Documentation

Update active docs where appropriate.

At minimum, document that:

* SpecRelay streams provider output live for operator visibility;
* evidence files remain the durable source of truth;
* live output is not a substitute for reviewing evidence;
* provider logs are scoped by role/provider where possible.

Candidate docs to inspect:

* README.md
* docs/commands.md
* docs/providers.md
* docs/current-workflow-contract.md
* docs/task-lifecycle.md

Only update docs that are actually relevant.

Acceptance criteria

Implementation is complete when:

1. During a real bin/specrelay run ..., executor provider output is visible live in the terminal.
2. During a real bin/specrelay run ..., reviewer provider output is visible live in the terminal.
3. Live output clearly identifies role/provider context or is otherwise not ambiguous.
4. Existing durable evidence files still contain the complete provider output.
5. Provider exit codes are preserved correctly, including failure cases.
6. scripts/test exits 0.
7. bin/specrelay doctor passes or reports only intentional documented warnings.
8. bin/specrelay version reports the expected version.
9. Tests cover the streaming behavior without making the suite flaky.
10. Docs are updated where needed.
11. No unrelated behavior is changed.

Suggested verification commands

Run and record output for:

git status --short
scripts/test
bin/specrelay doctor
bin/specrelay version

Also run a small dogfood or fixture task that uses a provider capable of emitting visible output, and verify:

* terminal shows executor output live;
* terminal shows reviewer output live;
* evidence files still contain the same meaningful output;
* failure behavior is correct.

If a real Claude provider run is too expensive for automated tests, use a deterministic fake or fixture provider for tests, and record at least one manual observation from a real provider run if available.

Non-goals

This task must not:

* fix non-ASCII global hook noise;
* fix duplicate transition after READY_FOR_HUMAN_REVIEW;
* implement ContextPlus setup;
* rename AI review states or schema fields;
* change Sprint-reports;
* choose or change the license;
* tag or publish a release;
* redesign the whole provider abstraction;
* remove evidence files;
* expose hidden prompts, secrets, tokens, or private environment data.

Risks

Possible risks:

* losing provider exit codes when piping through tee;
* duplicating output too much;
* mixing executor and reviewer streams ambiguously;
* making tests flaky due to timing or buffering;
* leaking information that should remain only in evidence;
* changing CI behavior accidentally.

The implementation must explicitly address these risks.

Expected follow-up tasks

Likely follow-ups after this task:

1. Fix duplicate transition attempt after READY_FOR_HUMAN_REVIEW.
2. Clarify AI review state names and schema compatibility.
3. Improve ContextPlus setup/init/doctor flow.
4. Improve release/tag/CI readiness.
5. Add richer provider progress events if needed.

Human decisions required

* Decide whether live provider output should be shown by default or controlled by a config flag. The expected default for this task is: show live output by default.
* Decide whether output prefixes should be plain text only or later support color. This task should prefer plain text.
* Decide whether real provider live output should be tested manually only, while automated tests use fake providers.
