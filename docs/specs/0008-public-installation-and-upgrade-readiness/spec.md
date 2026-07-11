# 0008 — Public installation and upgrade readiness

- **Status:** Draft
- **Spec number:** 0008
- **Spec path:** `docs/specs/0008-public-installation-and-upgrade-readiness/spec.md`

## Goal

Make SpecRelay genuinely ready for an external user who wants to install, use,
upgrade, verify, and later package SpecRelay without knowing the internal
Mortgage Hub / Sprint-reports history.

This task is user-facing readiness. It must validate the complete first-user
journey from a fresh checkout or release artifact, not only improve internal
developer docs.

## Context

SpecRelay is now a standalone repository. Recent completed work includes:

- specs convention and standalone docs cleanup;
- non-ASCII hook/noise diagnostics;
- generic live provider output streaming;
- state-aware reviewer transitions;
- state/schema compatibility guards;
- Claude semantic live terminal events;
- optional ANSI color for semantic live output;
- release/CI/license readiness baseline from spec 0007.

Spec 0007 added important release-readiness foundations such as CI/smoke checks
and related documentation. This spec goes one level higher: it verifies the
public installation, upgrade, and packaging story from an external user's point
of view.

## Problem

A tool can have working tests and still not be ready for users if the install
and upgrade path is unclear.

External users need clear answers to these questions:

- How do I install SpecRelay from a fresh clone?
- How do I install it from a release tag or source archive?
- Where does the `specrelay` executable get installed?
- How do I confirm the executable is the one I just installed?
- How do I configure a consumer project?
- Is there a `specrelay init` command or must configuration be written manually?
- How do I upgrade?
- How do I uninstall?
- How do I pin a version in a host project?
- What are the requirements?
- What is optional, such as Claude Code?
- What is the Homebrew path?
- What is not supported yet?

The answer must be tested where practical, documented honestly, and must not
claim commands or packaging channels that do not exist.

## Scope

### 1. Repository and release facts

Verify and record:

- current `origin` remote;
- current branch;
- current `VERSION`;
- current release/tag policy;
- current license status;
- current CI workflow status;
- current smoke script behavior;
- current installer scripts under `install/` and/or `scripts/`;
- current docs covering installation, upgrade, versioning, publication, and
  verification.

If docs mention files or commands that do not exist, fix the docs or add the
missing command only when it is small and safe.

### 2. Fresh-user install path from clone

Define and test the canonical clone installation path.

At minimum, a user should be able to do something like:

~~~sh
git clone git@github.com:SpecRelay/SpecRelay.git
cd SpecRelay
./install/install.sh
specrelay version
specrelay doctor
~~~

If the actual installer path or invocation differs, document the real command.
Do not invent a nicer command unless it is implemented and tested.

The install docs must explain:

- what directory the user should clone;
- whether install creates a symlink or copies files;
- where the `specrelay` binary is installed by default;
- how to customize the install prefix/bin directory;
- how to ensure the install directory is on `PATH`;
- how to verify which executable is being used;
- how to reinstall after pulling updates.

### 3. Fresh-user install path from release archive/tag

Define a release-based installation path for users who do not want to track
`main`.

At minimum, document a safe manual flow such as:

~~~sh
git clone --branch vX.Y.Z --depth 1 git@github.com:SpecRelay/SpecRelay.git SpecRelay
cd SpecRelay
./install/install.sh
specrelay version
~~~

If release tarball/archive installation is supported, document it and test it
with a local archive where possible. If it is not yet supported, say so clearly
and record the follow-up.

Do not create or push an actual release tag in this task unless the spec is
explicitly updated by the human to include release cutting.

### 4. Upgrade path

Document the canonical upgrade path.

If SpecRelay does not have `specrelay self-update`, the docs must say that
clearly. Do not pretend it exists.

Expected minimal upgrade path:

~~~sh
cd <local SpecRelay clone>
git fetch origin
git checkout main
git pull --ff-only origin main
./install/install.sh
specrelay version
specrelay doctor
~~~

If version-tag users are expected to upgrade by checking out a new tag, document
that path too.

The task should also decide whether `self-update` is a near-term follow-up or
explicit non-goal.

### 5. Uninstall/reinstall path

Document how to remove or replace an installed SpecRelay executable.

At minimum:

- how to locate the installed executable;
- how to remove the symlink/copy created by the installer;
- how to reinstall cleanly;
- what is not removed from consumer projects (`.specrelay/`, task runs, docs).

If uninstall is not automated, document the manual command. If adding
`install/uninstall.sh` is small and safe, it may be added with tests.

### 6. Consumer project first-run path

Verify and document how a user enables SpecRelay in a project.

The docs must clearly answer:

- Is there a `specrelay init` command?
- If yes, what does it create?
- If not, what files must the user create manually?
- What is the minimal `.specrelay/config.yml`?
- Where should specs live by default?
- How does a user run a first deterministic fake-provider task?
- How does a user switch to Claude provider?
- What does `specrelay doctor` verify in a consumer project?

A new user should be able to bootstrap a small temporary consumer project,
configure the fake provider, and run a simple fake-provider verification without
Claude installed.

### 7. Homebrew readiness plan

Create a clear Homebrew plan without prematurely publishing anything.

The docs must explain the recommended phased approach:

1. First support an organization/user tap, for example `SpecRelay/tap`.
2. Later consider Homebrew core only after stable public adoption and after
   satisfying Homebrew's expectations.

This task may add a sample formula under a non-published packaging path, for
example:

~~~text
packaging/homebrew/specrelay.rb
~~~

The formula must be clearly marked as a template/sample unless it is actually
tested against a real release tarball with a real sha256.

The Homebrew docs must explain:

- why a tag/release archive and sha256 are needed;
- how to calculate sha256;
- how to test a formula locally;
- what the user-facing install command would look like once the tap exists;
- that the tap repository is not created in this task unless explicitly
  requested.

### 8. Installation/upgrade smoke tests

Add deterministic smoke tests where practical.

Required coverage:

- installer can install into a temporary prefix/bin directory;
- installed `specrelay version` works;
- installed `specrelay doctor` works in a controlled mode that does not require
  Claude unless Claude is intentionally configured;
- reinstall/upgrade path works by running the installer again over an existing
  install;
- uninstall instructions or uninstall script are verified if implemented;
- temporary consumer project can run a fake-provider task or at least pass
  `doctor` with a minimal config;
- docs reference commands/files that actually exist.

Avoid tests that require network access or real GitHub availability. Simulate
fresh clone/release archive locally where possible.

### 9. Documentation

Update or create user-facing docs as needed.

Likely files:

- `README.md`
- `docs/installation.md`
- `docs/upgrading.md`
- `docs/homebrew.md`
- `docs/standalone-verification.md`
- `docs/versioning.md`
- `docs/publication.md`
- `CHANGELOG.md`
- `CONTRIBUTING.md`

Documentation must clearly separate:

- source clone install;
- release/tag install;
- upgrade;
- uninstall;
- consumer project bootstrap;
- Homebrew plan;
- unsupported/not-yet-implemented features.

### 10. No false claims

This task must not claim any of the following unless implemented and tested:

- `specrelay self-update`;
- official Homebrew tap availability;
- Homebrew core availability;
- published release artifacts;
- stable API compatibility beyond the documented version policy;
- full cross-platform support beyond what was actually verified.

### 11. Documentation/code consistency audit (ai-reviewer sub-agent)

Before release readiness is accepted, audit docs/code/tests for references that
imply standalone SpecRelay ships files it does not ship, or that describe
behavior inherited from the incubation host that is not true standalone. Human
review surfaced one concrete instance: docs referenced the Claude reviewer
sub-agent (`.claude/agents/ai-reviewer.md`, provider `claude-subagent`) as
though standalone ships it — it does not (the incubation host, Sprint-reports,
did).

Required checks (search all docs/code/tests): `.claude/agents/ai-reviewer.md`,
`ai-reviewer`, `claude-subagent`, `.ai/`, `tools/specrelay`, Sprint-reports, and
other legacy host-only assumptions. Each reference is classified as one of:
**active standalone behavior**, **optional consumer-project integration**,
**historical note**, or **stale/incorrect (must fix)**.

Findings and resolution:

- **`lib/specrelay/providers/claude.sh`** — *active behavior, already truthful.*
  The reviewer only adds `--agent ai-reviewer` when
  `.claude/agents/ai-reviewer.md` exists **and** `claude --help` advertises
  `--agent`; otherwise it falls back to a plain `claude --print` reviewer. No
  code change needed.
- **Provider docs (`docs/providers.md`, `README.md`, `docs/configuration.md`,
  `docs/installation.md`)** — *stale/misleading → fixed.* They now state plainly
  that standalone SpecRelay does **not** ship `.claude/agents/ai-reviewer.md`,
  describe `claude-subagent` truthfully as **legacy shorthand** for the Claude
  reviewer with the `ai-reviewer` sub-agent *when available*, and document how a
  consumer project obtains the file.
- **Incubation/legacy history (`docs/architecture.md`, `docs/extraction.md`,
  `docs/migration.md`, `docs/current-workflow-contract.md`,
  `docs/engine-parity.md`, `docs/knowledge-boundaries.md`, `docs/dogfood-*.md`,
  the `# tools/specrelay/...` test-header comments, and `docs/specs/*`)** —
  *historical notes; left as-is.* They describe the frozen legacy `.ai/` engine
  and the incubation path and are explicitly labeled as such; they do not claim
  `.ai/` or `tools/specrelay` are runtime requirements for standalone SpecRelay.
- **Sprint-reports references** — *historical; not changed* (this task does not
  modify the Sprint-reports repository).

Fixes delivered by this audit:

- Add a standalone template at `templates/claude/agents/ai-reviewer.md`.
- Wire `specrelay init` to copy that template into a consumer project's
  `.claude/agents/ai-reviewer.md` when the reviewer provider is `claude` /
  `claude-subagent` (never overwriting an existing file), and document the
  manual copy step for already-initialized projects.
- Make `specrelay doctor` report the sub-agent state when the reviewer provider
  is `claude` / `claude-subagent`: an info line when the agent file is present,
  a non-failing **warning** when it is absent (so `claude-subagent` never
  silently pretends a sub-agent that is not there).
- Keep `provider: claude-subagent` fully backward compatible.

## Acceptance criteria

Implementation is complete when:

1. A fresh-user installation path from source clone is documented and tested.
2. A release/tag installation path is documented honestly.
3. Upgrade instructions exist and do not mention non-existent commands as if
   they exist.
4. Uninstall/reinstall instructions exist, or an uninstall script exists and is
   tested.
5. A temporary install into a non-default prefix/bin directory is tested.
6. An installed `specrelay version` works from that temporary install.
7. `specrelay doctor` is verified in a controlled environment without requiring
   Claude unless Claude is explicitly configured.
8. Consumer project bootstrap documentation exists and is verified with fake
   provider where practical.
9. Homebrew tap strategy is documented.
10. Any Homebrew formula is clearly marked as sample/template unless it targets
    a real published release tarball with a real sha256.
11. `scripts/test` exits 0.
12. `scripts/smoke` exits 0, or the smoke script is updated so it covers this
    task's installation/upgrade readiness checks.
13. `bin/specrelay doctor` passes locally.
14. `bin/specrelay version` reports the expected version.
15. No unrelated behavior is changed.
16. No network-dependent test is added to the standalone suite.
17. The doc/code consistency audit (section 11) is complete: a standalone
    `templates/claude/agents/ai-reviewer.md` template exists; `specrelay doctor`
    clearly reports whether the `ai-reviewer` sub-agent is configured when the
    reviewer provider is `claude` / `claude-subagent`; provider docs no longer
    imply standalone ships `.claude/agents/ai-reviewer.md`; and no active
    standalone doc claims `.ai/` or `tools/specrelay` as a runtime requirement.
    `provider: claude-subagent` remains backward compatible.

## Suggested verification commands

Run and record:

~~~sh
git status --short
scripts/test
scripts/smoke
bin/specrelay doctor
bin/specrelay version
~~~

Also run and record a temp-prefix install check, for example:

~~~sh
tmp="$(mktemp -d)"
./install/install.sh --prefix "$tmp/prefix"
"$tmp/prefix/bin/specrelay" version
"$tmp/prefix/bin/specrelay" doctor
~~~

Use the real installer syntax if different.

## Non-goals

This task must not:

- cut or push a release tag;
- publish a Homebrew tap;
- submit to Homebrew core;
- implement `specrelay self-update` unless explicitly approved;
- change provider execution behavior;
- change task state schema;
- change Sprint-reports;
- remove Sprint-reports archived `tools/specrelay/`;
- require network access in automated tests;
- hide missing packaging functionality behind vague docs.

## Risks

Potential risks:

- documenting commands that do not exist;
- making install tests depend on the developer's local machine;
- making `doctor` require Claude in CI or fake-provider-only install checks;
- confusing source installs with release/tag installs;
- creating an untested Homebrew formula that looks official;
- breaking existing installed/symlinked local workflows;
- mixing release cutting with installation readiness.

The implementation must explicitly address these risks.

## Expected follow-up tasks

Likely follow-ups after this task:

1. Cut the first standalone release, likely `v0.5.0` or another human-approved
   version.
2. Create and test a real Homebrew tap repository.
3. Add `specrelay self-update` if the team decides it is worth supporting.
4. Update Sprint-reports to pin the released SpecRelay version and remove the
   archived snapshot.

## Human decisions required

- Confirm whether the public install recommendation is source clone first,
  release tag first, or both.
- Confirm whether `self-update` should remain a documented non-goal for now.
- Confirm whether Homebrew should start with a separate tap repository.
- Confirm whether the first public release version should be `v0.5.0` or another
  version.
- Confirm whether an uninstall script should be added now or only documented.

## Runner-owned workflow transitions

You are the executor agent for this task. You own implementation, tests, and
the required executor artifacts (`03-executor-log.md`, `07-tests.txt`,
`08-executor-summary.md`) only. You do not own workflow state transitions or
review decisions. Specifically, you must NOT:

- run `specrelay task submit` or otherwise transition this task to
  `READY_FOR_REVIEW`;
- run `specrelay task accept` or `specrelay task request-changes`;
- requeue this task yourself (`specrelay task requeue`);
- run `specrelay run` or `specrelay resume` for this task yourself;
- edit `state.json` directly, or otherwise write canonical transition metadata
  by hand.

The SpecRelay orchestrator owns evidence capture and the
`EXECUTOR_RUNNING -> READY_FOR_REVIEW` submission after your process exits.
