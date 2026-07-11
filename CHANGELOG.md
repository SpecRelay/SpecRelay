# Changelog

All notable changes to SpecRelay are recorded here.

SpecRelay is still incubating inside its origin repository and has not had a
public release. The entries below are **incubation milestones**, tracked by the
SDD (spec-driven-development) task that delivered them, not dated public
releases. Versions follow the `VERSION` file (the single source of truth).
Dates are intentionally omitted where the repository history does not record a
release date.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased] — 0.3.0 — Standalone readiness (SDD 0086)

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
