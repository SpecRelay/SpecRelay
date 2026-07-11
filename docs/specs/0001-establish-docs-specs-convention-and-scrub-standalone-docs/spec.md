# 0001 — Establish `docs/specs/` convention and scrub standalone docs

- **Status:** Draft (spec only — not yet implemented)
- **Spec number:** 0001 (the first standalone SpecRelay spec)
- **Spec path:** `docs/specs/0001-establish-docs-specs-convention-and-scrub-standalone-docs/spec.md`

## Goal

Establish `docs/specs/` as SpecRelay's standard directory for executable
implementation/design specs, define the work needed to scrub stale
"origin-repository" framing from the **active** standalone documentation now
that SpecRelay lives in its own GitHub repository, and establish the
**dogfood bootstrap / project-init model** this repository needs so it can run
its own specs without hand-written configuration.

Concretely, after this spec is implemented:

1. `docs/specs/` is the documented home for SpecRelay's own design specs, with
   a stated rationale for choosing it over `spec/` and `docs/sdd/`.
2. Active usage/installation docs no longer present the old host path
   (`tools/specrelay/bin/specrelay`) as the way to run SpecRelay, no longer
   claim that no public repository exists, and no longer advertise a stale
   version.
3. Historical/reference documents keep their truthful references to the old
   host path and origin repository.
4. Preparing a repository (including this one) to run SpecRelay is done through
   a supported command (`specrelay init` / `bin/specrelay init`), not by hand-
   editing `.specrelay/config.yml`, and the responsibilities of `install`,
   `init`, `doctor`, and `run` — including how optional context adapters such as
   ContextPlus are configured — are documented.

## Context

SpecRelay has been extracted into a standalone repository:

- **Remote:** `git@github.com:SpecRelay/SpecRelay.git`
- **Default branch:** `main`
- **VERSION:** `0.4.0`
- **License:** undecided — `LICENSE.TODO` is still present (no `LICENSE`).

Sprint-reports is now only a **consumer** repository. The old in-host path
`tools/specrelay/` must no longer appear as an *active* installation or usage
path in standalone SpecRelay docs.

During Sprint-reports SDD 0088A, the host repository could not fully remove its
archived `tools/specrelay/` snapshot because the standalone repository still had
**active** docs carrying stale origin-repo framing. Cleaning those active docs
(this spec) unblocks the host's later archive removal.

### Dogfood bootstrap failure that motivated the init work

When we first tried to run this standalone dogfood task, execution failed
**before claim** because `.specrelay/config.yml` was hand-written with
`context.adapter: contextplus` and `context.required: true`, but this
standalone repo's Claude MCP setup does not currently have a `contextplus`
server registered (`claude mcp list` has no such entry, so the adapter's health
check fails). Current actual config (verified `2026-07-11`):

```yaml
context:
  adapter: contextplus
  required: true
```

This exposed a product/design issue: **SpecRelay and consumer repositories must
not rely on humans hand-writing `.specrelay/config.yml`.** We need a clear
`install` → `init` → `doctor` → `run` model, with optional context adapters
(like ContextPlus) configured explicitly and auditably — never silently
installed or silently registered into a user's MCP configuration.

### Discovered current state (verified while authoring this spec)

Findings below were confirmed by inspecting the working tree on
`2026-07-11`. Line numbers are indicative and must be re-verified at
implementation time.

**Active-doc bugs (must fix):**

- `README.md` — the "Project status" callout and "Current project status"
  section say SpecRelay is *incubated at `tools/specrelay/`*, that *no public
  repository has been created*, and that *nothing is pushed to any remote*.
  These are now false: a remote exists and `main` tracks `origin/main`.
- `docs/commands.md` — presents `tools/specrelay/bin/specrelay …` as the direct
  CLI usage path (heading, intro, and examples).
- `docs/installation.md` — instructs use of `tools/specrelay/bin/specrelay …`
  as the in-repo path, and states the source tree version is `0.3.0` (actual
  `VERSION` is `0.4.0`).
- `docs/publication.md` — says SpecRelay *"has never been pushed to a remote,
  has no configured remote."* A remote is now configured; this must be
  reconciled with reality (without inventing push/release status beyond what is
  true).
- `docs/standalone-verification.md` — shows `version` output as
  `specrelay 0.3.0` and an updater example `0.0.1 → 0.3.0`. If treated as a
  live status doc these are stale; if treated as a historical verification
  record they are reference-allowed. Classify during implementation (see
  §4).

**Historical / reference-allowed (do not rewrite to erase the path):**

- `docs/architecture.md` — describes compatibility shims that delegated to
  `tools/specrelay/bin/specrelay`; this is a truthful architecture/history
  statement.
- `docs/migration.md`, `docs/extraction.md`, `CHANGELOG.md` — migration and
  extraction history may reference the old host path.
- `docs/engine-parity.md` — references `tools/specrelay/bin/specrelay` inside
  shim-loop / parity descriptions that are historical/test-shape statements.
- `docs/dogfood-report.md`, `docs/dogfood-orchestration.md` — dogfood evidence
  and orchestration transcripts that reference the old path and `docs/sdd/`
  spec paths; these are historical evidence.
- `docs/knowledge-boundaries.md`, `docs/architecture.md` — references to
  "Sprint Reports" / "Sprint-Reports" describing origin-domain policy are
  historically accurate and remain allowed.

**Not-yet-classified (decide during implementation):** any remaining hit from
the §6 search that is not clearly one of the above.

## Scope

### 1. Repository facts verification

Verify and record (in the implementation's evidence) that:

- The git remote `origin` is `git@github.com:SpecRelay/SpecRelay.git`.
- Branch `main` exists and is pushed / tracks `origin/main`.
- `VERSION` is `0.4.0`.
- `LICENSE.TODO` still exists and no real `LICENSE` has been added, unless a
  human has explicitly chosen a license.
- This is the standalone **SpecRelay** repository, not Sprint-reports
  (confirm by remote URL and repository contents).
- Active docs should no longer use host-repository paths
  (`tools/specrelay/...`) as usage examples.

If any fact differs from the above (e.g. `main` is not actually pushed, or a
license was chosen), stop and reconcile the spec/docs with reality rather than
asserting the assumption.

### 2. Establish the `docs/specs/` convention

- Document `docs/specs/` as the home for executable implementation/design
  specs (see `docs/specs/README.md`, created alongside this spec).
- Require each spec to live at `docs/specs/<number>-<slug>/spec.md`.
- State that `spec/` is **not** used for design specs because it commonly means
  test specs (Ruby/RSpec and others).
- State that `docs/sdd/` is a historical origin-host convention, not the
  standalone SpecRelay convention.
- State that `docs/adr/` is reserved for Architecture Decision Records.
- State that `docs/updates/` is reserved for update/release notes.
- State that this spec is `0001`, the first standalone SpecRelay spec.

### 3. Clean active standalone documentation

In the **active** docs identified in §Context (README.md, docs/commands.md,
docs/installation.md, docs/publication.md, and any others confirmed active):

- Replace active `tools/specrelay/bin/specrelay …` usage examples with:
  - `bin/specrelay …` when running from the standalone **source checkout**, and
  - `specrelay …` (or an installed absolute path) when referring to **installed**
    usage.
- Do not present Sprint-reports as the source owner of SpecRelay.
- Do not say the public repository does not exist, and do not say the project
  has no configured remote when it does.
- Ensure version examples either match `VERSION = 0.4.0` or are clearly marked
  as illustrative placeholders.
- Ensure active installation/usage instructions do not depend on the old host
  path `tools/specrelay/`.

### 4. Preserve historical truth

- Historical changelog, migration/extraction notes, dogfood evidence, and
  architecture history **may** mention `tools/specrelay/` and `docs/sdd/` where
  those are historically accurate.
- Do not rewrite historical facts merely to erase the old path.
- Classify every remaining reference discovered by the §9 stale-reference
  search as exactly one of:
  - **active-doc bug** — fix it;
  - **historical/reference-allowed** — leave it, note why;
  - **test fixture / intentional** — leave it, note why.
- Record the classification table in the implementation evidence.

### 5. License handling

- Do **not** choose a license.
- If `LICENSE.TODO` remains, document (where the docs speak to status) that the
  GitHub repository exists and is visible, but that **open-source licensing is
  still pending a human decision**.
- Do **not** create a real `LICENSE` file unless a human has explicitly chosen
  one.

### 6. Dogfood bootstrap / project init model

- State explicitly that **hand-writing `.specrelay/config.yml` is allowed only
  as a temporary bootstrap escape hatch**, not the normal product path.
- The normal product path to prepare a repository is `specrelay init` (or
  `bin/specrelay init` from a source checkout).
- For **this** repository, `init` should be able to configure:
  - spec root: `docs/specs`
  - runs root: `.specrelay-runs/tasks`
  - validation command: `scripts/test`
  - executor provider: `claude`
  - reviewer provider: `claude-subagent`
  - context adapter: **configurable, not hardcoded**
- `init` must **not overwrite an existing `.specrelay/config.yml` without
  explicit approval** (e.g. a `--force` flag or an interactive confirmation).
  The current implementation already refuses to overwrite unless `--force` is
  given; preserve that guarantee.
- Note the current gap to close: `init` today writes a fixed bundled template
  (fixed spec root and `context.adapter: none`); it does not yet accept
  per-project values for spec root / providers / context adapter. Making those
  configurable (via flags, prompts, or a documented template-selection
  mechanism) is part of this section's intent. If full configurability is not
  implemented here, the docs must state which values `init` sets automatically
  and which must still be adjusted, and record it as a follow-up.

### 7. install vs init vs doctor responsibilities

Document the responsibility boundaries so no step silently reaches outside its
scope:

- **`install`** installs the SpecRelay CLI/resources globally or user-locally.
  It must **not** modify arbitrary project configs or a user's MCP
  configuration.
- **`init`** creates/updates the **project-local** `.specrelay/config.yml` and
  the project directories (spec root, runs root, gitignore entry). It is a
  project-side operation only.
- **`doctor`** checks whether a repository is ready to run SpecRelay:
  installation, project config, providers, and any configured (optional)
  context adapter. It reports readiness; it does not silently fix things.
- **`run`** must **fail clearly** if a required provider or context adapter is
  missing — with an actionable message — rather than proceeding, hanging, or
  failing obscurely before claim (the failure mode that motivated this spec).

### 8. ContextPlus / MCP setup policy

- ContextPlus is an **optional** adapter from the core product's perspective
  (`context.adapter` defaults to `none`, `context.required` defaults to
  `false`).
- A project **may** mark it required (`context.adapter: contextplus`,
  `context.required: true`).
- If ContextPlus is required and missing/unregistered, `run` must fail clearly
  with actionable instructions (the `contextplus` adapter already health-checks
  `claude mcp list` and errors when the server is not registered / not
  connected — surface that as an actionable message).
- **Generic `install` must not silently mutate Claude MCP configuration.**
- Any MCP/provider-specific setup must be **explicit, user-approved, and
  provider-specific**. A future explicit command may be introduced, e.g.:
  - `specrelay setup contextplus`, or
  - `specrelay doctor --fix-contextplus`.

  No such command exists today; introducing one is optional for this task (see
  Non-goals).
- If automatic installation/registration of ContextPlus is not possible or is
  out of scope, the docs must explain the **manual** setup steps (how to
  register the `contextplus` MCP server so the adapter's health check passes).

## Non-goals / Policy

This task must **not**:

- Push, tag, or publish a release.
- Change anything in the Sprint-reports repository.
- Implement live provider terminal output streaming.
- Implement the duplicate-transition fix (transition attempt after
  `READY_FOR_HUMAN_REVIEW`).
- Implement the AI review state/schema rename.
- Resolve or choose the license.
- **Fully implement ContextPlus installation/registration** unless the current
  code already supports a safe, explicit setup flow. Absent that, document the
  manual setup instead.
- **Silently edit a user's MCP configuration** (or any Claude MCP config) as a
  side effect of `install` or `init`.
- **Require ContextPlus for all SpecRelay users by default** — it stays an
  optional, per-project adapter.

Additionally, this spec itself performs **no implementation** — it only
authors `docs/specs/README.md` and this `spec.md`.

## Acceptance criteria / verification

Implementation of this spec is complete when:

1. `docs/specs/README.md` documents the convention (§2) and is accurate.
2. Every active-doc bug in §Context is fixed per §3, and no active
   installation/usage instruction depends on `tools/specrelay/`.
3. Every remaining `tools/specrelay/` / `docs/sdd/` / "Sprint(-)Reports"
   reference is classified per §4 with a recorded rationale.
4. License status is handled per §5 (no `LICENSE` created; status framed
   honestly).
5. The bootstrap/init model (§6), the install/init/doctor/run responsibilities
   (§7), and the ContextPlus/MCP setup policy (§8) are documented in the active
   docs (e.g. `docs/installation.md`, `docs/configuration.md`,
   `docs/context-adapters.md`) consistently with those sections.
6. Dogfood readiness (below) is met.
7. The verification commands below pass / are recorded.

### Dogfood-readiness acceptance criteria

- This standalone repo can be initialized/re-initialized using a **supported
  command** (`bin/specrelay init`, with `--force` or explicit approval to
  overwrite), **not** by manual file editing.
- `.specrelay/config.yml` is generated or updated according to the documented
  rules in §6 (spec root `docs/specs`, runs root `.specrelay-runs/tasks`,
  validation `scripts/test`, executor `claude`, reviewer `claude-subagent`,
  configurable context adapter).
- `bin/specrelay doctor` **clearly reports** missing ContextPlus / provider
  setup (registered vs. required), pointing to the documented setup steps.
- The first dogfood spec can `run` after the documented setup is followed
  (either ContextPlus is registered, or the project config is set so it is not
  required).
- No hidden dependency on Sprint-reports remains in the setup path.

### 9. Tests / verification commands

Run and record output for:

- `scripts/test`
- `bin/specrelay version` (expect it to report `0.4.0`)
- `bin/specrelay help`
- `bin/specrelay doctor` (expect it to clearly report project config,
  providers, and the configured context adapter — including a clear message
  when a required `contextplus` server is not registered)

Search **active** docs for stale references and classify every hit:

```sh
grep -rn "tools/specrelay/bin/specrelay" docs README.md
grep -rni "no public repository has been created" docs README.md
grep -rn "0.3.0" docs README.md
grep -rni "Sprint-reports" docs README.md
grep -rni "Sprint Reports" docs README.md
grep -rn "/Users/" docs README.md
```

For each remaining hit, classify as active-doc bug / historical-reference-allowed
/ test-fixture-intentional (§4).

Also:

- Verify markdown/code fences are balanced in every edited doc.

## Expected next standalone SpecRelay tasks

Recorded here so follow-up work is discoverable (not part of this task):

1. Restore live provider terminal streaming.
2. Fix the duplicate transition attempt after `READY_FOR_HUMAN_REVIEW`.
3. Clarify AI review state names and schema compatibility.
4. Decide license / publication readiness.
5. Add a release/tag/GitHub Actions workflow.
6. Make `specrelay init` fully configurable (spec root, providers, context
   adapter) so no consumer needs to hand-edit `.specrelay/config.yml`.
7. Add an explicit, user-approved ContextPlus setup command (e.g.
   `specrelay setup contextplus`) if manual MCP registration proves too
   error-prone.
8. Later, Sprint-reports can remove its archived `tools/specrelay/` snapshot
   once standalone docs are clean and pushed.

## Assumptions

- The git remote is already `git@github.com:SpecRelay/SpecRelay.git` and `main`
  tracks `origin/main` (verified `2026-07-11`).
- `VERSION` is `0.4.0` (verified).
- `LICENSE.TODO` is still present and no license has been chosen (verified).
- `docs/standalone-verification.md` and other status docs that reference `0.3.0`
  will be treated as either historical records (reference-allowed) or active
  status docs (fix) — the classification is decided during implementation, not
  assumed here.
- The current `.specrelay/config.yml` is a hand-written bootstrap file with
  `context.adapter: contextplus` / `context.required: true`, and the Claude MCP
  setup in this repo does **not** currently register a `contextplus` server
  (verified `2026-07-11`).
- `specrelay init` currently writes a fixed bundled template and refuses to
  overwrite an existing config without `--force`; per-project configurability of
  spec root / providers / context adapter is a gap this spec intends to close or
  document.

## Human decisions required

- **License choice.** No license may be selected by automation. A human must
  choose one (candidates in `LICENSE.TODO`: Apache-2.0, MIT) before any `LICENSE`
  file is added or the project is published.
- **Publication readiness.** Whether/when to tag, release, or announce is a
  human decision and is out of scope here.
- **Status-doc classification.** Whether `docs/standalone-verification.md`
  (and similar) should be updated as live status or preserved as historical
  verification records is a judgment call to confirm during implementation.
- **ContextPlus for this repo.** Whether this repository should *require*
  ContextPlus (and therefore need the `contextplus` MCP server registered) or
  run with `context.adapter: none` for dogfooding is a human decision. The
  bootstrap failure was caused by requiring it without registering it.
- **Explicit setup command.** Whether to add `specrelay setup contextplus` /
  `specrelay doctor --fix-contextplus` in this task or defer it (documenting
  manual setup instead) is a scoping decision — it must never silently mutate
  MCP configuration.
