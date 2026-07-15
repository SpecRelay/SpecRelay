# Changelog

All notable changes to SpecRelay are recorded here.

SpecRelay is still incubating inside its origin repository and has not had a
public release. The entries below are **incubation milestones**, tracked by the
SDD (spec-driven-development) task that delivered them, not dated public
releases. Versions follow the `VERSION` file (the single source of truth).
Dates are intentionally omitted where the repository history does not record a
release date.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).

## 0.6.0

- 0023-specification-bundle-analysis-jam-evidence-and-resolved-executor-input (minor): adds backward-compatible directory-based specification input, immutable multi-file evidence bundles, pre-executor analysis, Jam MCP integration, resolved specification generation, and new executor/reviewer input contracts.

## 0.5.0 — Operator summary, safe updates, and release versioning (spec 0022)

The published `VERSION` had stayed at `0.4.0` while a substantial amount of
engine functionality shipped underneath it (specs 0009-0021), and SpecRelay
still lacked an operator-facing update story. This release closes both gaps:
it consolidates everything delivered since `0.4.0` (including the `task 0007`/
`task 0008` work below, which had been sitting under an untagged
"[Unreleased]" heading) into one honest version, and adds the execution-mode,
update, and summary-first-output contract described below. No intermediate
version between `0.4.0` and `0.5.0` was ever published or tagged.

### Added — safe updates, installation metadata, and execution-mode contract (spec 0022)
- **Execution-mode contract**: `bin/specrelay` (source-local) and an installed
  `specrelay` launcher are now formally distinguished by structural,
  symlink-safe evidence (never by command spelling alone). Source-local
  execution never performs automatic update discovery, never reads/writes
  update-check state, and is never influenced by an installed version.
- `specrelay environment` / `specrelay install-info` (plus `--json`):
  read-only, no-mutation, no-network inspection of execution mode,
  executable/resource paths, installation metadata (version, commit, update
  source, last-update time), and whether automatic update checks are enabled.
- Installation metadata (`install-metadata.json`, schema v1) written atomically
  under the install prefix by `install/install.sh` — never in a consumer
  repository, never containing credentials.
- Explicit update commands: `specrelay update --check` (cache-bypassing,
  read-only discovery), `specrelay update [--yes]` (discover, confirm, stage,
  verify, atomically activate; prints the installed version/commit as proof),
  `specrelay update --from <path>` (explicit source, with dirty-checkout and
  structural-validity refusal), `specrelay update --dry-run`, `specrelay
  update --ignore <version>`, `specrelay update --reset-notifications`. All of
  these refuse cleanly (no mutation) under source-local execution.
- Daily (<=1/24h) automatic update discovery before `run`/`resume` in
  installed mode only: an interactive TTY may accept/reject an offered
  version (a rejected version is never re-offered, a later version still is);
  a non-interactive/CI session never prompts or blocks and gets at most one
  concise stderr advisory; discovery failure never blocks the requested
  command. An accepted update re-executes the original command exactly once
  (loop-safe) after activating.
- Atomic install/update safety: a new payload is staged beside the current
  install, verified in place (staged-payload check + a real launcher probe +
  post-activation re-verification), and activated with a rename-based swap;
  any failure before activation leaves the current installation completely
  untouched, and a post-activation verification failure rolls back
  automatically. Concurrent update attempts are serialized with stale-lock
  reclaim.

### Added — summary-first terminal output (spec 0022)
- A normal `specrelay run`/`resume` now ends with a concise "SpecRelay
  Result" operator-summary card (task, executor/reviewer status+duration,
  tests, context readiness, active time, collapsed warning count) instead of
  an automatic full telemetry dump. The full execution timeline, command
  timing, and agent-efficiency detail are still fully captured — just no
  longer printed by default.
- `specrelay task report <task-ref> [--json]`: the explicit, read-only
  command for the full combined detail the summary no longer dumps
  automatically (execution timeline + command timing + agent efficiency in
  one report/JSON object).
- `specrelay run <spec> --verbose` / `specrelay resume <task> --verbose`:
  prints the full detail inline in addition to the concise summary.

### Added — release-impact metadata and release commands (spec 0022)
- Every spec after 0022 must declare `release: { impact, rationale }`
  (`none|patch|minor|major`); missing/malformed metadata fails release
  preparation with an actionable message. Pre-1.0, `minor`/`major` both bump
  the minor version and reset patch; `patch` bumps patch only.
- `bin/specrelay release plan|prepare|verify|tag`: read-only planning,
  VERSION/CHANGELOG.md preparation (diff shown, nothing committed), release
  verification (semver syntax, monotonic increase, changelog presence,
  source-local version proof), and annotated-tag creation from a clean tree.
  None of these commit, push, or push tags automatically.

### Added — consolidated capabilities delivered since 0.4.0 (specs 0009-0021)
These were implemented across specs 0009-0021 but never previously reflected
in a version bump or this changelog:
- **Model/agent selection** (0009, 0012, 0014): explicit per-role provider
  configuration, guided model selection with alias/validation support, and
  `specrelay models [<provider>]` discovery.
- **Context capability adapters and Context Plus** (0015, 0018): first-class,
  pluggable context adapters (`none`, `fake`, `contextplus`), a documented
  capability/readiness contract, and `specrelay contexts [<adapter>]`
  diagnostics — never a silent no-op when context is required.
- **Parallel test runner, timing profiler, and change-aware test selection**
  (0016, 0017): `scripts/test --jobs`/`--timings`/`--slowest`, and
  `--changed`/`--changed-from`/`--changed-files` selection with a documented,
  always-safe fallback to the full suite.
- **Bounded verification policy and execution timeline** (0019): a
  command-string verification classifier, a per-task verification ledger,
  and `specrelay task timeline <task-ref>` (phase durations, invocation/resume
  history, duplicate-work detection, phase-budget warnings).
- **Agent command-timing ledger** (0020): `specrelay task commands
  <task-ref>` — slowest observed agent tool commands, repeated commands, and
  waiting/polling detection.
- **Agent execution-efficiency and completion gate** (0021): `specrelay task
  efficiency <task-ref>` and a completion contract that rejects an executor/
  reviewer invocation that exits zero without actually finishing its declared
  work.

### Notes
- `VERSION` moves from `0.4.0` directly to `0.5.0`; no `0.4.1`-`0.4.x` or other
  intermediate version was ever published.
- This changelog entry is the human-reviewed record of what shipped; nothing
  here was auto-generated by `release prepare` (that automation applies to
  specs numbered after 0022, which carry the new `release:` metadata this
  spec introduces).

## 0.5.0 — Public installation & upgrade readiness (task 0008)

Validates and documents the complete first-user journey — install, verify,
upgrade, uninstall, bootstrap a consumer project, and plan Homebrew packaging —
from an external user's point of view. Documentation and readiness only; no
workflow, provider, or task-state semantics change.

### Added

- `install/uninstall.sh`: a copy-safe, no-sudo uninstaller that removes only the
  tool-owned `<prefix>/bin/specrelay` and `<prefix>/share/specrelay/`, refuses to
  delete an unrelated directory, is idempotent, and never touches a consumer
  project's `.specrelay/` config, task runs, or specs.
- `docs/upgrading.md`: the canonical upgrade path (fast-forward the clone and
  reinstall, or `install/update.sh --from`), the version-tag upgrade path, and
  uninstall/reinstall instructions. States plainly that there is **no**
  `specrelay self-update` and records it as a documented non-goal for now.
- `docs/homebrew.md`: a phased Homebrew plan (organization tap first, Homebrew
  core only much later), how a tag/release archive/sha256 are used, how to
  compute a sha256, and how to test a formula locally — with explicit notes that
  no tap exists and `brew install specrelay` does not work yet.
- `packaging/homebrew/specrelay.rb`: a clearly-marked **sample/template** formula
  with placeholder `url`/`sha256`; not validated against any real release
  tarball and not installable.
- `test/install_upgrade_test.sh`: deterministic install/upgrade/uninstall smoke
  tests — install into a temporary prefix, run the installed `version` and
  (provider-optional) `doctor`, reinstall over an existing install, uninstall
  and verify tool-owned files are gone while a consumer `.specrelay/` survives,
  bootstrap a temporary fake-provider consumer project and run a task, and check
  that the docs reference commands/files that actually exist. No network access.

### Changed

- `docs/installation.md`: adds the two supported source install paths (`main`
  clone and version tag), a "release tarball not supported yet" note, a
  "verify which executable you are running" section, a fake-provider consumer
  bootstrap walkthrough (init → switch to `fake` → `doctor` → `run`), an
  uninstall section, and cross-links to `upgrading.md` and `homebrew.md`.
- `scripts/smoke`: extends the fresh-clone smoke check to also run the installed
  executable's `doctor` (provider-optional), reinstall over the existing install
  (upgrade path), bootstrap a temporary fake-provider consumer project and pass
  `doctor` there, and uninstall and verify removal.
- `README.md`: documents the version-tag install option, the upgrade/uninstall
  commands (and that `self-update` does not exist), and links the Homebrew plan.

### Notes

- No release tag is created and no Homebrew tap is published (both remain
  explicit human follow-ups). No `specrelay self-update` is implemented. No
  network-dependent test was added.

## 0.5.0 — Standalone release-readiness baseline (task 0007)

This entry summarizes the first clean public-release baseline for the standalone
SpecRelay repository. It captures readiness work only; it does not change
workflow, provider, or state semantics.

### Baseline summary

The standalone repository now consolidates the following completed work:

- **Standalone repository publication.** SpecRelay lives in its own repository
  (`git@github.com:SpecRelay/SpecRelay.git`, default branch `main`), extracted
  from the origin host where it was incubated.
- **docs/specs convention.** Specs live under `docs/specs/<number>-<slug>/`
  (task 0001), and public docs were scrubbed of host-only references.
- **Doctor diagnostics.** `bin/specrelay doctor` reports read-only readiness,
  including the non-ASCII commit-hook noise diagnostic (task 0002).
- **Generic live streaming.** Provider stdout/stderr is streamed live to the
  terminal for any provider (task 0003).
- **Claude semantic live events.** Structured Claude stream-json rendering is
  available on top of the generic streaming, with an honest fallback when it is
  not (task 0006).
- **Duplicate transition fix.** The duplicate transition warning after a
  reviewer accept is fixed (task 0004).
- **State/schema compatibility.** Tasks record `engine_version` and
  `schema_version`; resume/run refuse unsafe cross-version actions, with a
  logged per-invocation override (task 0005; see `docs/versioning.md`).
- **Install/bootstrap verification.** Source install (`install/install.sh`),
  update (`install/update.sh`), and a fresh-clone smoke check (`scripts/smoke`)
  verify the repo end to end without any host workflow.

### Added

- `.github/workflows/ci.yml`: a minimal CI gate that runs `scripts/test`,
  `bin/specrelay doctor`, and `bin/specrelay version` on pull requests and
  pushes to `main`, on a current GitHub-hosted Ubuntu runner. It does not
  require a real Claude installation or any Sprint-reports/host path.
- `SPECRELAY_PROVIDER_OPTIONAL` doctor mode: when set to `1`, an absent
  **configured** provider CLI (e.g. Claude) is an advisory warning rather than a
  hard failure, while core dependency checks stay mandatory. CI uses it so
  verification does not require real Claude; default off, so local diagnostics
  still fail loudly when a configured provider is missing.
- `scripts/smoke`: fresh-clone/install smoke verification (version, test suite,
  doctor result, source install into a temp prefix), independent of any host
  workflow or archived path.
- Release/version/tag policy in `docs/versioning.md` (how `VERSION` maps to Git
  tags; who tags; what must pass before tagging; what to do if CI fails after
  tagging).
- Minimum-requirements and environment-variable reference in
  `docs/installation.md` (Bash 3.2+, git, ruby, python3, macOS/Linux support,
  Claude CLI optionality, and the `SPECRELAY_*` variables).

### Known limitations

- **Open-source licensing is undecided.** No `LICENSE` is granted; a human must
  choose one (default proposal MIT). Publication remains blocked until then
  (see `LICENSE.TODO`).
- **No release is tagged or published.** This baseline only makes the repo
  tag-ready; creating the first tag and consuming it from Sprint-reports are
  explicit human follow-ups.
- **CI is not proven by remote execution here.** The workflow is verified by
  local commands and file-level tests; its first real run happens on the
  hosting provider.
- **Sprint-reports still holds the archived `tools/specrelay/` snapshot.** It
  must not be removed until this standalone baseline is reviewed and tagged.

## [Unreleased] — 0.4.0 — Versioned engine identity (SDD 0087)

### Added
- Task metadata now records `engine_version` (the running engine's `VERSION`)
  alongside the existing `engine` field, so upgrade diagnostics and resume
  safety can compare the engine that created a task with the engine resuming
  it.
- Resume/version safety: `specrelay run` (on an existing task) and
  `specrelay resume` refuse to act across incompatible engine versions
  (different major version, or a task created by a newer engine than the one
  running). An explicit, per-invocation `SPECRELAY_ALLOW_ENGINE_MISMATCH=1`
  override exists for deliberate human recovery and always logs that it was
  used. See `docs/versioning.md`.
- `docs/versioning.md`: the version-compatibility policy (semantic-version
  rules, schema compatibility, active-task safety).
- `docs/publication.md`: the future, human-only steps to publish this repository
  to a Git hosting provider. No remote action is performed by this project.
- `.github/workflows/ci.yml`: standalone CI configuration. See the
  release-readiness baseline entry above for its current, accurate scope.

### Notes
- Still no public repository, remote, tag, or published package (see
  `docs/publication.md`). This milestone only adds versioned engine identity so
  a consuming project can pin and verify an exact engine version.

## 0.3.0 — Standalone readiness (SDD 0086)

### Added
- Standalone-ready source layout under `tools/specrelay/` (bin, lib, docs,
  install, scripts, templates, test) that works both incubated in the host
  repo and as a future repository root.
- User-level installer (`install/install.sh`): copy-based, no sudo, `--prefix`,
  `--dev-link`, `--force`; idempotent; prints PATH guidance.
- Local-source updater (`install/update.sh`): version detection, downgrade
  refusal, delegates to the installer, never touches consumer project config.
- `specrelay init`: initializes a consumer project (`.specrelay/config.yml`
  from a provider-neutral template, spec root, safe idempotent `.gitignore`);
  refuses to overwrite an existing config unless `--force`.
- Standalone test entry point (`scripts/test`) that runs the host-independent
  suite with no Rails app and no legacy `.ai/` workflow present.
- Provider-neutral project template (`templates/project/config.yml`).
- Public-facing documentation set: README, `docs/configuration.md`,
  `docs/providers.md`, `docs/context-adapters.md`, `docs/task-lifecycle.md`,
  `docs/installation.md`, `docs/extraction.md`, `docs/migration.md`,
  `docs/standalone-verification.md`, plus `CONTRIBUTING.md`, `SECURITY.md`,
  and this changelog.

### Fixed
- Standalone tests no longer assume the host's `.ai-runs/tasks` path; they use
  the generic `.specrelay-runs/tasks` default so the suite passes in an
  extracted repository.
- `install/install.sh`, `install/update.sh`, and `scripts/test` are now
  executable, so they run as documented (`./install/install.sh`,
  `scripts/test`) and the updater can delegate to the installer.
- `scripts/test` now excludes the host-only `host_repo_safety_test.sh` from the
  standalone suite (it remains in the host suite via `test/run_all.sh`).

### Notes
- No public repository has been created, nothing is pushed to any remote, and
  no package is published. Those are later, explicitly-authorized steps.

## 0.2.x — Active engine cutover and dogfooding (SDD 0085 / 0085B)
- SpecRelay became the origin repository's only active workflow engine; the
  legacy `.ai/` engine was frozen (rollback/reference only).
- Added the SpecRelay-native `task recover` command for interrupted tasks.
- Produced real-provider dogfood evidence for accepted and
  request-changes/rework workflows.

## 0.1.x — Executable engine (SDD 0084)
- Migrated the executor/reviewer workflow into SpecRelay as a runnable CLI
  (`bin/specrelay run` / `resume`, task/state/evidence/lifecycle libraries).

## 0.0.x — Initial incubation (SDD 0083)
- Incubated SpecRelay from the existing `.ai/` AI workflow: initial source
  tree, CLI skeleton, and workflow-contract documentation.
