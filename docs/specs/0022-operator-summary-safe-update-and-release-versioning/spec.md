# Spec 0022 — Operator Summary, Safe Installed Updates, and Release Versioning

## Status

Proposed

## Release impact

Minor

## Target release

`0.5.0`

If `VERSION` is already greater than `0.4.0` when this spec is implemented,
the executor must stop and document the discovered version before selecting a
different target. It must not silently downgrade or invent a conflicting
version.

---

## Summary

SpecRelay must become easier to operate, safer to update, and disciplined about
release versions.

This specification introduces four related capabilities:

1. a compact, summary-first terminal result;
2. a safe update path for the installed `specrelay` command;
3. a strict distinction between source-local and installed execution;
4. enforceable release-impact and semantic-versioning rules.

The repository-owned command:

```text
bin/specrelay
./bin/specrelay
```

must always execute the current checkout and must never perform automatic update
discovery.

The installed command:

```text
specrelay
```

may perform a cached daily update check before operational commands, offer an
interactive update when appropriate, and continue the original command after a
successful update.

---

## Problem

SpecRelay has gained substantial functionality while the published version has
remained `0.4.0`.

It also lacks a complete operator-facing update contract:

- users cannot reliably inspect how SpecRelay was installed;
- the installed command has no safe, explicit update workflow;
- source-development execution and installed execution are not formally distinguished;
- update discovery could accidentally interfere with development runs;
- update notifications need throttling and version-specific dismissal;
- CI and non-interactive environments must never wait for input;
- failed update discovery or installation must never corrupt the working installation;
- the final terminal output is overloaded and does not lead with the result an operator needs;
- future specs do not yet have an enforceable release-impact discipline.

A versioned update feature without reliable versioning is incomplete. A detailed
telemetry system without a usable terminal summary is also incomplete.

---

## Goals

Implement all of the following:

1. Detect source-local versus installed execution reliably.
2. Disable automatic update checks for source-local execution.
3. Add installation metadata for installed execution.
4. Add `specrelay install-info`.
5. Add explicit update commands.
6. Check for updates at most once per 24 hours during installed operational commands.
7. Prompt only in an interactive terminal.
8. Remember a rejected version and do not offer that exact version again.
9. Offer a later version even if an earlier version was rejected.
10. Continue the original command after a successful accepted update.
11. Preserve the previous working installation if update fails.
12. Replace the default final data dump with a concise operator summary.
13. Keep detailed timeline, command timing, verification, and efficiency reports available through explicit inspection commands.
14. Establish mandatory release-impact metadata for future specs.
15. Consolidate the current unreleased feature set into version `0.5.0`.

---

## Non-goals

This specification does not:

- create a Homebrew tap;
- create a hosted package registry;
- automatically push Git tags or GitHub releases;
- mutate a source-development checkout through the installed update workflow;
- automatically commit or push repository changes;
- silently update without user approval;
- make update availability a dependency of `run` or `resume`;
- remove existing task evidence or detailed telemetry;
- copy SpecRelay source code into consumer repositories;
- modify consumer `.specrelay/config.yml` during installation or update;
- use a consumer repository as update-state storage.

---

## Terminology

### Source-local execution

The executable belongs to the current standalone SpecRelay repository checkout.

Typical invocations:

```text
bin/specrelay
./bin/specrelay
```

This mode is for SpecRelay development, dogfooding, and repository-local verification.

### Installed execution

The executable is an installed launcher whose runtime resources and installation
metadata belong to an installation prefix outside the source repository.

Typical invocation:

```text
specrelay
```

### Update discovery

A read-only operation that determines whether a newer released version exists.

### Update installation

A mutating operation performed only after explicit approval, or after an
explicit `--yes`, that atomically installs and verifies a newer version.

---

## 1. Execution-mode contract

### 1.1 Source-local mode

When repository-owned `bin/specrelay` is executed:

- it must use the current repository checkout;
- automatic update discovery must be disabled;
- no update prompt may be displayed;
- no update-state cache may be read or written as part of ordinary commands;
- no network request may be made for update discovery;
- the installed SpecRelay version must not influence execution;
- the repository must not be modified by `specrelay update`.

This remains true even if an installed version is newer.

### 1.2 Installed mode

When the installed `specrelay` launcher is executed:

- it must use installed resources;
- it must be able to locate installation metadata;
- update discovery may run under the rules in this specification;
- explicit update and installation-information commands must be available.

### 1.3 Detection

Mode detection must not rely only on the literal command text supplied by the user.

The installer must create durable installation metadata and the installed
launcher must identify itself as installed.

The implementation may also use resolved executable and resource paths as
defensive evidence, but it must not classify a repository-owned executable as
installed merely because it was reached through a symlink.

### 1.4 Environment inspection

Add:

```text
specrelay environment
```

Example source-local output:

```text
SpecRelay environment
  Execution mode: source-local
  Executable:     /path/to/specrelay/bin/specrelay
  Resources:      /path/to/specrelay
  Update checks:  disabled
```

Example installed output:

```text
SpecRelay environment
  Execution mode: installed
  Executable:     /Users/user/.local/bin/specrelay
  Resources:      /Users/user/.local/share/specrelay
  Update checks:  enabled
  Check interval: 24h
```

The command must support a machine-readable JSON form if the existing CLI conventions support JSON output.

---

## 2. Installation metadata

An installed SpecRelay distribution must contain metadata under the installation
prefix, not in a consumer repository.

Example conceptual structure:

```json
{
  "schema_version": 1,
  "installation_type": "source-install",
  "installed_version": "0.5.0",
  "installed_commit": "abcdef123456",
  "installed_at": "2026-07-14T18:00:00Z",
  "executable_path": "/Users/user/.local/bin/specrelay",
  "resource_path": "/Users/user/.local/share/specrelay",
  "update_source": {
    "type": "official-git",
    "repository": "git@github.com:SpecRelay/SpecRelay.git",
    "ref": "main"
  }
}
```

Requirements:

- metadata writes must be atomic;
- metadata must not contain credentials or access tokens;
- installed version and commit must describe the installed payload;
- update source must be explicit;
- missing or malformed metadata must produce a clear diagnostic;
- source-local execution must not require installation metadata.

---

## 3. `install-info`

Add:

```text
specrelay install-info
```

Example:

```text
╭─ SpecRelay Installation ─────────────────────────────╮
│ Mode              installed                         │
│ Executable        ~/.local/bin/specrelay            │
│ Version           0.5.0                             │
│ Commit            abcdef12                          │
│ Resources         ~/.local/share/specrelay          │
│ Update source     github:SpecRelay/SpecRelay        │
│ Last update       2026-07-14 18:00 UTC              │
╰──────────────────────────────────────────────────────╯
```

Source-local invocation must report source-local mode and explain that installed
update metadata is not applicable.

The command must not mutate files or perform network requests.

---

## 4. Explicit update commands

### 4.1 Check

```text
specrelay update --check
```

Requirements:

- installed mode only;
- bypass the 24-hour cache;
- perform read-only discovery;
- print installed and available versions;
- return success when no update exists;
- never modify the installed payload.

### 4.2 Update

```text
specrelay update
```

Requirements:

- installed mode only;
- discover the newest released version;
- require confirmation in an interactive terminal unless `--yes` is supplied;
- stage the new installation separately;
- verify staged executable, version, resources, and metadata;
- atomically activate the new installation;
- preserve the prior installation until verification succeeds;
- roll back automatically if activation verification fails;
- never modify consumer project configuration;
- print proof of the installed version and commit.

### 4.3 Explicit source

Support:

```text
specrelay update --from /path/to/specrelay
```

Requirements:

- the path must be a valid SpecRelay source checkout;
- the checkout must pass structural validation;
- a dirty source checkout must not be reset or overwritten;
- the command must report the source commit;
- the installed payload must still be staged and activated atomically.

### 4.4 Dry run

```text
specrelay update --dry-run
```

Must show current installation, selected source, proposed version, proposed
installation areas, verification steps, and whether activation would occur.
It must not mutate installation state.

### 4.5 Non-interactive update

```text
specrelay update --yes
```

This is explicit consent for scripts. Automatic daily discovery must never infer `--yes`.

### 4.6 Source-local behavior

For:

```text
bin/specrelay update
```

the command must not mutate the repository and must clearly explain that installed-update operations are not applicable.

---

## 5. Daily update discovery

### 5.1 Scope

Automatic discovery applies only to installed mode and only before operational commands such as:

```text
specrelay run ...
specrelay resume ...
```

It must occur before task creation, task approval, task claim, or any lifecycle transition.

### 5.2 Check interval

The default interval is 24 hours. A new automatic check must not run if a
successful check occurred less than 24 hours ago.

### 5.3 State location

Update notification state must live in user-level SpecRelay installation state,
not in a project repository.

Example schema:

```json
{
  "schema_version": 1,
  "last_checked_at": "2026-07-14T18:30:00Z",
  "last_available_version": "0.6.0",
  "ignored_version": "0.6.0",
  "last_check_status": "success"
}
```

Writes must be atomic.

### 5.4 Interactive prompt

Prompt only when all conditions are true:

- execution mode is installed;
- stdin and the operator terminal are interactive;
- a newer valid semantic version exists;
- that exact version is not the ignored version;
- automatic checks are enabled.

Example:

```text
╭─ SpecRelay Update Available ───────────────╮
│ Installed   0.5.0                         │
│ Available   0.6.0                         │
╰────────────────────────────────────────────╯

Update before running this task? [y/N]
```

### 5.5 Accepted update

If the user accepts:

1. perform the safe update;
2. verify the new installation;
3. re-execute the original command with exactly the original arguments;
4. prevent an update-check loop;
5. only then create or resume the task.

### 5.6 Rejected update

If the user rejects version `0.6.0`:

- continue using the installed version;
- store `ignored_version = 0.6.0`;
- do not offer `0.6.0` again;
- continue the original command immediately.

If `0.7.0` later becomes available, it must be offered.

### 5.7 Non-interactive and CI behavior

In CI or non-interactive execution:

- never prompt;
- never wait for input;
- never auto-install;
- never block the requested command because update discovery failed;
- an available update may produce one concise advisory on stderr;
- repeated advisories must respect the check cache.

### 5.8 Discovery failure

Network, source, metadata, or remote failures must not block `run` or `resume`.

### 5.9 Configuration

Support disabling automatic discovery through:

```text
SPECRELAY_UPDATE_CHECK=0
```

### 5.10 Notification controls

Support:

```text
specrelay update --ignore 0.6.0
specrelay update --reset-notifications
```

---

## 6. Update source and version discovery

The official installed update mechanism must compare semantic versions from an
authoritative release source.

Preferred authority:

1. official versioned Git tags or official release metadata;
2. explicit operator-provided source via `--from`;
3. a documented fallback only if no official release mechanism exists yet.

Automatic discovery must not run `git pull`, reset a checkout, modify the user's
source repository, or install an unverified moving branch as a released version.

---

## 7. Summary-first terminal output

### 7.1 Default final output

A normal successful run must end with a concise summary of approximately 15–20
lines, excluding provider streaming output that occurred during execution.

Example:

```text
╭─ SpecRelay Result ─────────────────────────────────────────╮
│ READY FOR HUMAN REVIEW                                    │
├────────────────────────────────────────────────────────────┤
│ Task          0022-operator-summary-safe-update           │
│ Executor      passed · 18m 12s                            │
│ Reviewer      accepted · 3m 41s                           │
│ Tests         focused passed · full suite not required    │
│ Context       ready                                       │
│ Active time   22m 31s                                     │
│ Warnings      1                                           │
╰────────────────────────────────────────────────────────────╯

Warnings
  ⚠ One verification budget warning.

Details
  specrelay task report 0022
```

### 7.2 Default suppression of large detail blocks

The following detailed blocks must no longer be printed automatically in full at
the end of every normal run:

- Execution Timeline;
- Verification Ledger;
- Duplicate Work;
- Command Timing;
- Repeated Agent Commands;
- Tool Counts;
- Agent Efficiency.

They must remain persisted and available through explicit commands.

### 7.3 Detailed commands

Provide or preserve:

```text
specrelay task report <task-ref>
specrelay task timeline <task-ref>
specrelay task commands <task-ref>
specrelay task efficiency <task-ref>
```

Support:

```text
specrelay task report <task-ref> --json
```

### 7.4 Verbose mode

Support:

```text
specrelay run <spec> --verbose
specrelay resume <task> --verbose
```

### 7.5 Warning collapse

Repeated warnings with the same root cause must be collapsed.

### 7.6 Rendering constraints

The terminal UI must remain append-only, copyable, redirectable, readable
without color, and free of cursor movement or screen redraw.

---

## 8. Release-impact metadata

Every new specification after 0022 must contain:

```yaml
release:
  impact: none|patch|minor|major
  rationale: <non-empty explanation>
```

### 8.1 Meanings

- `none`: no released artifact change;
- `patch`: backward-compatible defect correction;
- `minor`: backward-compatible public capability or command addition;
- `major`: incompatible public CLI, configuration, schema, installation, or behavior change.

### 8.2 Pre-1.0 policy

While below `1.0.0`:

- `patch` increments patch;
- `minor` increments minor and resets patch;
- `major` requires at least a minor increment unless an explicit human-approved `1.0.0` release is part of the spec.

### 8.3 Validation

Missing, malformed, or empty release metadata must fail release preparation with an actionable message.
Historical specs before 0022 remain readable and are not rewritten automatically.

---

## 9. Release commands

### 9.1 Plan

```text
bin/specrelay release plan
```

Read-only. Shows current version, pending impact, proposed version, and source task.

### 9.2 Prepare

```text
bin/specrelay release prepare
```

Must update `VERSION` and `CHANGELOG.md`, show the diff, and never commit, tag, or push.

### 9.3 Verify

```text
bin/specrelay release verify
```

Must verify semantic syntax, monotonic increase, impact/bump consistency,
changelog presence, accepted source task, and source-local reported version.

### 9.4 Tag

```text
bin/specrelay release tag
```

Must require a clean committed release state, create the documented tag, refuse
conflicts, and never push automatically.

---

## 10. Baseline release `0.5.0`

This specification formalizes the current set of previously implemented but
unreleased capabilities as version `0.5.0`.

The executor must:

- change `VERSION` from `0.4.0` to `0.5.0`;
- add an honest `0.5.0` changelog entry;
- summarize relevant capabilities delivered since `0.4.0`;
- not fabricate intermediate versions;
- ensure source-local and installed version outputs agree after installation.

The changelog must cover model selection, context adapters and Context Plus,
parallel and change-aware tests, execution timeline, command timing, efficiency
and completion gates, operator summary, updates, installation metadata, and
release workflow.

---

## 11. Safety requirements

### 11.1 Atomic installation

The current installation remains usable until the replacement is fully staged and verified.

### 11.2 Rollback

If post-activation verification fails, restore the prior installation and metadata,
report failure, return non-zero, and do not continue the original command.

### 11.3 Locking

Concurrent update attempts must be serialized with stale-lock handling.

### 11.4 No consumer mutation

Update and release commands must not modify consumer source code,
`.specrelay/config.yml`, task runtime data, or consumer Git state.

### 11.5 Secret handling

Installation metadata, update state, reports, and logs must not persist secrets.

---

## 12. Backward compatibility

Existing commands and telemetry artifacts must continue to work.

Existing installations without metadata must receive an actionable migration path,
for example a one-time reinstall from an official source.

---

## 13. Required tests

Add focused tests covering:

### Execution mode

- source-local detection;
- no automatic update discovery in source-local mode;
- no update-state mutation in source-local mode;
- installed launcher detection;
- symlink safety;
- correct `environment` output.

### Installation metadata

- fresh install metadata;
- atomic metadata update;
- malformed metadata errors;
- version and commit proof;
- secret absence;
- unchanged consumer config.

### Explicit update

- newer/equal/older version handling;
- dry-run no mutation;
- `--from` validation;
- dirty source refusal;
- successful update;
- failed staging preservation;
- activation rollback;
- concurrent update locking;
- source-local update refusal;
- `--yes` non-interactive success.

### Daily discovery and dismissal

- 24-hour cache;
- interactive prompt;
- exact-version dismissal;
- later-version notification;
- accepted update and original-command re-exec;
- argument preservation;
- loop prevention;
- discovery failure non-blocking;
- CI and closed-stdin safety;
- environment disable;
- reset notifications;
- `--check` cache bypass.

### Operator summary

- concise summary-first output;
- no automatic telemetry dump;
- prominent final state;
- executor/reviewer/test/context/time/warning fields;
- collapsed warnings;
- verbose details;
- redirected plain text;
- color-independent information;
- complete `task report`;
- valid report JSON.

### Release versioning

- `VERSION` becomes `0.5.0`;
- version command reports `0.5.0`;
- honest changelog entry;
- valid/invalid impact handling;
- patch/minor/pre-1.0-major planning;
- prepare/verify/tag behavior;
- no automatic push;
- legacy spec compatibility.

---

## 14. Documentation requirements

Document execution modes, installation metadata, `install-info`, `environment`,
update commands, daily checks, dismissal behavior, CI behavior, rollback,
release impact, release commands, pre-1.0 policy, summary-first output, detailed
report commands, and migration for legacy installations.

---

## 15. Executor evidence requirements

The executor must write:

- `03-executor-log.md`;
- `07-tests.txt`;
- `08-executor-summary.md`.

The summary must include files changed, execution-mode detection, installation
metadata schema, update authority, atomic update and rollback design, daily cache,
ignored-version behavior, CI behavior, terminal before/after, release behavior,
proof of `0.5.0`, proof of no source-local update request, proof of no consumer
config mutation, and known limitations.

Verification must obey the bounded-verification policy and avoid duplicate full suites.

---

## 16. Reviewer focus

The reviewer must independently verify:

1. source-local execution cannot trigger automatic updates;
2. installed execution is not inferred only from command spelling;
3. checks occur before lifecycle mutation;
4. dismissal is version-specific;
5. later versions are offered;
6. CI and closed stdin cannot hang;
7. failures preserve the prior installation;
8. activation and rollback are real;
9. the original command is re-executed exactly once;
10. consumer config and source are untouched;
11. default output is genuinely concise;
12. detailed evidence remains accessible;
13. release impact drives the correct bump;
14. `0.5.0` history is honest;
15. tag creation never pushes;
16. no credentials are persisted.

---

## 17. Acceptance criteria

Accepted only when:

- source-local execution never performs automatic update discovery;
- installed execution is detected from installation evidence;
- installed operational commands check at most once per 24 hours;
- interactive users can accept or reject updates;
- rejection suppresses only that exact version;
- later versions are offered;
- accepted update safely installs and continues the original command;
- non-interactive execution never waits;
- failed discovery never blocks normal execution;
- failed update preserves the prior installation;
- `install-info` and `environment` are trustworthy;
- all update flags behave as documented;
- normal final output is concise and summary-first;
- detailed telemetry remains available explicitly;
- warnings are collapsed and actionable;
- `VERSION` is `0.5.0`;
- `CHANGELOG.md` contains a truthful `0.5.0` entry;
- future specs require release-impact metadata;
- release plan/prepare/verify/tag are implemented and tested;
- tagging never pushes automatically;
- no source is copied into consumer repositories;
- consumer `.specrelay/config.yml` is untouched;
- tests, docs, and required evidence are complete.

---

## 18. Expected operator workflow

### Development checkout

```text
cd /path/to/specrelay
bin/specrelay environment
bin/specrelay run docs/specs/...
```

Expected:

```text
Execution mode: source-local
Update checks: disabled
```

### Installed consumer workflow

```text
specrelay environment
specrelay update --check
specrelay run path/to/spec.md
```

### Release workflow

```text
bin/specrelay release plan
bin/specrelay release prepare
bin/specrelay release verify
git add VERSION CHANGELOG.md
git commit -m "Release 0.5.0"
bin/specrelay release tag
git push
git push --tags
```

The final pushes remain explicit human operations.
