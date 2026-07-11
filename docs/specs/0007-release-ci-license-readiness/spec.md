# 0007 — Release, CI, and license readiness

- **Status:** Draft
- **Spec number:** 0007
- **Spec path:** `docs/specs/0007-release-ci-license-readiness/spec.md`

## Goal

Make the standalone SpecRelay repository ready for its first clean public release baseline.

SpecRelay has already been extracted from the host repository and has completed the important standalone hardening tasks:

- `0001` — standalone docs/specs convention and public-doc scrub;
- `0002` — non-ASCII shell/global hook/test noise diagnostics;
- `0003` — generic live provider output streaming;
- `0004` — duplicate transition warning fix after reviewer accept;
- `0005` — task state/schema compatibility policy and tests;
- `0006` — Claude semantic live agent events restored.

The next step is to make the repository release-ready: continuous verification, license clarity, release notes, version/tag policy, and installation smoke checks.

## Context

Repository:

- Standalone SpecRelay repo: `/Users/hrmohseni/dev/Teal-lead-managments/specrelay`
- GitHub remote should be: `git@github.com:SpecRelay/SpecRelay.git`
- Current version is read from `VERSION`.
- Specs live under `docs/specs/<number>-<slug>/spec.md`.
- Runtime is shell-first with Python helpers under `lib/specrelay/py/`.
- `scripts/test`, `bin/specrelay doctor`, and `bin/specrelay version` are the baseline local verification commands.

This task is about release readiness only. It must not change workflow semantics unless a small change is strictly necessary for CI/release verification.

## Problem

SpecRelay now works as a standalone tool, but the repository is not yet fully release-ready.

Likely gaps:

- no GitHub Actions CI or insufficient CI coverage;
- no explicit license file or unclear license decision;
- no clear release/tag policy;
- no release notes/changelog baseline;
- no documented minimum runtime requirements;
- no fresh-clone or install smoke verification;
- no clear policy for how `VERSION` maps to Git tags;
- no clear distinction between required tools and optional provider tools like Claude.

Before Sprint-reports removes its archived `tools/specrelay/` snapshot, SpecRelay should have a stable public baseline that can be installed, verified, and tagged independently.

## Scope

### 1. Repository facts verification

Before implementation, verify and record:

- current branch name;
- current `origin` remote;
- current `VERSION`;
- current Git status;
- whether `.github/workflows/` exists;
- whether a `LICENSE` file exists;
- whether release notes/changelog docs exist;
- current install/bootstrap docs;
- current minimum requirements documented in docs;
- whether `scripts/test`, `bin/specrelay doctor`, and `bin/specrelay version` pass locally.

Record this in the executor log.

### 2. CI readiness

Add or update GitHub Actions CI so the standalone repo has a minimal reliable verification gate.

At minimum CI should run:

~~~yaml
scripts/test
bin/specrelay doctor
bin/specrelay version
~~~

CI requirements:

- should run on pull requests and pushes to `main`;
- should use a currently available GitHub-hosted runner image;
- should not require a real Claude installation;
- should not require private host-repo paths;
- should not require Sprint-reports;
- should make optional-provider checks non-blocking or documented when a provider is absent;
- should keep the workflow simple and maintainable.

If `bin/specrelay doctor` currently fails in CI because Claude is absent, change doctor behavior only if appropriate and tested. Preferred behavior: doctor should distinguish required core dependencies from optional provider availability based on config/environment, and CI should use a config/profile that does not require real Claude.

Do not hide real failures by ignoring exit codes.

### 3. License readiness

Add a `LICENSE` file if missing.

Human decision required: choose the license.

Default proposal: MIT License, unless the maintainer decides otherwise.

Implementation rules:

- do not invent legal claims;
- use a standard license text if a license is chosen;
- make the license discoverable from `README.md` or release docs;
- do not add multiple conflicting licenses.

If the license cannot be decided during implementation, stop and report a blocking issue rather than adding an arbitrary license.

### 4. Release notes / changelog baseline

Add or update a release notes/changelog document.

Acceptable paths include one of:

- `CHANGELOG.md`
- `docs/release-notes.md`
- `docs/releases/README.md`

The release notes should summarize the current baseline, including:

- standalone repository publication;
- docs/specs convention;
- doctor diagnostics;
- generic live streaming;
- Claude semantic live events;
- duplicate transition fix;
- state/schema compatibility;
- install/bootstrap verification;
- known limitations.

Do not overstate stability. Be clear about what is ready and what remains future work.

### 5. Version and tag policy

Document how `VERSION` relates to Git tags.

At minimum answer:

- Is the current version releasable as-is?
- Should the first public tag be `v0.4.0`, `v0.5.0`, or another value?
- When should `VERSION` be bumped?
- Who creates tags?
- What local verification must pass before tagging?
- What should happen if CI fails after tagging?

Implementation may update `VERSION` only if the spec/implementation clearly justifies it.

Do not create a Git tag automatically in this task unless explicitly instructed by the human after review.

### 6. Installation and fresh-clone smoke verification

Add or document a fresh-clone/install smoke verification.

The smoke path should verify, without relying on Sprint-reports:

- fresh clone or temporary checkout can run `bin/specrelay version`;
- `scripts/test` passes;
- `bin/specrelay doctor` has a clear result;
- install/bootstrap instructions are accurate;
- no `.ai/` host workflow is required;
- no archived `tools/specrelay/` path is required.

If a script is added, keep it simple. If documentation is enough, document the exact commands.

### 7. Requirements documentation

Document minimum requirements clearly:

- Bash version assumptions;
- Git;
- Python 3;
- macOS/Linux support assumptions;
- Claude CLI optionality and when it is required;
- environment variables such as `SPECRELAY_HOME`, `SPECRELAY_PYTHON`, `SPECRELAY_CLAUDE_BIN`, `SPECRELAY_SEMANTIC_EVENTS` when relevant.

Do not make Claude mandatory for CI unless real-provider tests are explicitly requested.

### 8. README / docs discoverability

Ensure top-level docs help a new user find:

- what SpecRelay is;
- how to install or run from source;
- how to verify the repo;
- how to configure a consumer project;
- how to read release/version policy;
- license.

Keep README/docs changes focused. Do not rewrite unrelated docs.

### 9. Tests

Add/update tests where needed.

Potential test coverage:

- CI workflow file exists and contains baseline commands;
- release/version docs mention `VERSION` and tag policy;
- license file exists when chosen;
- install smoke command/script works;
- doctor behavior in no-Claude environment is deterministic if changed;
- all existing tests still pass.

Avoid tests that depend on network access or real GitHub Actions execution.

## Acceptance criteria

Implementation is complete when:

1. CI workflow exists and runs the baseline local verification commands.
2. CI does not require real Claude or Sprint-reports.
3. License decision is implemented or the task clearly stops as blocked for human decision.
4. Release notes/changelog baseline exists and accurately summarizes the current standalone state.
5. Version/tag policy is documented.
6. Fresh-clone/install smoke verification is documented or scripted.
7. Minimum requirements are documented.
8. README/docs make release/verification/license information discoverable.
9. `scripts/test` exits 0 locally.
10. `bin/specrelay doctor` passes locally or reports only intentional documented warnings.
11. `bin/specrelay version` reports the expected version.
12. No Git tag is created automatically.
13. No Sprint-reports files are changed.
14. No unrelated workflow/provider/state behavior is changed.

## Suggested verification commands

Run and record output for:

~~~sh
git status --short
git remote -v
git log --oneline -5 --decorate
scripts/test
bin/specrelay doctor
bin/specrelay version
~~~

If a fresh-clone/install smoke command or script is added, run and record it too.

Also inspect the final diff and record:

~~~sh
git diff --stat
git diff -- .github docs README.md LICENSE VERSION scripts test
~~~

## Non-goals

This task must not:

- change Sprint-reports;
- delete archived Sprint-reports `tools/specrelay/`;
- create a Git tag automatically;
- publish a GitHub release automatically;
- change provider execution semantics;
- change task lifecycle semantics;
- change schema compatibility behavior from spec 0005;
- change Claude semantic live events behavior from spec 0006;
- require real Claude in CI;
- require network access in tests;
- over-engineer a release system.

## Risks

Potential risks:

- CI accidentally depends on local machine paths;
- CI fails because Claude is absent;
- license text is added without human approval;
- docs overclaim production readiness;
- tag/version policy conflicts with current `VERSION`;
- fresh-clone verification accidentally depends on untracked local files;
- release docs imply Sprint-reports can already remove archived code before the standalone baseline is reviewed.

The implementation must explicitly address these risks.

## Expected follow-up tasks

Likely follow-ups after this task:

1. Create the first reviewed Git tag after human approval.
2. Update Sprint-reports integration to consume the tagged standalone SpecRelay version.
3. Remove Sprint-reports archived `tools/specrelay/` snapshot after the tagged baseline is confirmed.
4. Improve ContextPlus setup/init/doctor flow.
5. Add more provider compatibility tests if additional providers are introduced.

## Human decisions required

- Choose license. Default proposal: MIT.
- Decide first public tag/version policy: keep `0.4.0`, bump to `0.5.0`, or another version.
- Decide whether this task only prepares tag readiness or also creates the tag in a separate manual step after review.

## Runner-owned workflow transitions (mandatory)

You are the executor agent for this task. You own implementation, tests, and the required executor artifacts (`03-executor-log.md`, `07-tests.txt`, `08-executor-summary.md`) only. You do not own workflow state transitions or review decisions. Specifically, you must NOT:

- run `specrelay task submit` or otherwise transition this task to `READY_FOR_REVIEW`;
- run `specrelay task accept` or `specrelay task request-changes`;
- requeue this task yourself (`specrelay task requeue`);
- run `specrelay run` or `specrelay resume` for this task yourself;
- edit `state.json` directly, or otherwise write canonical transition metadata by hand.

The SpecRelay orchestrator owns evidence capture and the `EXECUTOR_RUNNING -> READY_FOR_REVIEW` submission after your process exits.

## Context Plus is mandatory (when configured)

Before you were launched, the orchestrator ran a context-capability preflight for the configured executor provider and context adapter. If that preflight had failed, you would not have been launched at all — this is enforced by the orchestrator, not only by this prompt text.

- Use the configured context capability for task-relevant repository context before implementation.
- Ordinary Read/Grep/Find/Bash tools remain allowed and may be used after or alongside it.
- Do not claim context-capability usage in `03-executor-log.md` unless it actually occurred.
