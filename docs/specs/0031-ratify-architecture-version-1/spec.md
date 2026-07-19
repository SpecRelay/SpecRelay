# Spec 0031 — Ratify Architecture Version 1

## 1. Status

```yaml
status: proposed
```

This specification is ready for implementation, but Architecture Version 1 is
not ratified merely because this file exists or because an implementation run
starts. Section 7 defines the mandatory human authorization gate.

## 2. Release metadata

```yaml
release:
  impact: none
  rationale: Ratifies repository-development architecture governance and adds source-local validation; it does not change consumer runtime behavior or the shipped software version.
```

`VERSION` and `CHANGELOG.md` are out of scope. If implementation discovers a
consumer-visible runtime change is required, stop and amend this spec rather
than silently changing the release impact.

## 3. Task identity

```yaml
task_id: 0031-ratify-architecture-version-1
```

This spec intentionally has no `architecture_version` metadata. It is the
bootstrap spec authored while Architecture Version 1 is still Proposed and it
will be at or below the adoption boundary computed during ratification.

## 4. Objective

Ratify the existing proposed Architecture Version 1 as one coherent,
human-authorized repository change and make its future-spec contract
machine-enforced.

The completed change must:

1. prove that the architecture set named by
   `architecture/architecture-version.yml` is internally coherent and still
   honest about Current versus Target behavior;
2. record explicit maintainer authorization before changing any Proposed status;
3. change the version file and every included ADR from Proposed to Accepted
   consistently;
4. compute and record the real spec adoption boundary at execution time;
5. require specs after that boundary to declare the accepted architecture
   version;
6. provide a deterministic source-local validation command and integrate the
   same validation into the repository's release checks; and
7. leave historical specs, consumer runtime behavior, and release versioning
   unchanged.

## 5. Repository baseline

At authoring time, repository evidence shows:

- `architecture/architecture-version.yml` declares `version: 1`,
  `status: proposed`, `ratified_at: null`, documentation-only enforcement, and
  a null adoption boundary;
- the version set contains ADR-0001 through ADR-0007;
- all seven ADRs and their index are Proposed;
- `architecture/north-star.md` and `architecture/principles.md` identify
  Architecture Version 1 as proposed;
- `docs/specs/README.md` says `architecture_version` becomes mandatory only
  after ratification and is not machine-enforced today;
- the existing release metadata scanner lives in
  `lib/specrelay/py/release_lib.py` and exempts historical specs through a
  numeric boundary;
- Ruby/Psych is already a documented runtime requirement and existing code
  uses `YAML.safe_load`; no new YAML dependency is needed;
- numbered spec directories `0001` through `0031` exist after this spec is
  added; and
- the known Reviewer direct-transition gap remains a Target for Spec 0032. It
  must not be rewritten as Current or ENFORCED during ratification.

The implementer must re-check every baseline statement before mutation. If the
repository has advanced, use the actual repository state and the rules below;
do not force it back to this authoring snapshot.

## 6. Architecture decision being ratified

Ratification accepts the intended architecture decisions, including their
explicitly documented Targets and gaps. It does not claim all target behavior
is already implemented.

In particular:

- accepting ADR-0002 accepts the rule that AI output is data and the runner
  enacts transitions; it does not falsely claim the current Reviewer path
  already complies;
- accepting ADR-0004 accepts the immutable-bootstrap target; it does not claim
  runtime self-replacement has already been eliminated;
- accepting ADR-0007 accepts isolation-before-parallelism as ordering; it does
  not claim isolated workspaces or concurrent tasks exist; and
- implementation maturity labels (`ENFORCED`, `ESTABLISHED`, `TARGET`, and
  `PROPOSED`) remain independent from ADR status (`Accepted`).

Ratification must never bulk-replace every occurrence of `Proposed` or
`PROPOSED`. Proposed implementation items and unresolved future directions must
remain proposed where that is still true.

## 7. Mandatory human authorization gate

Before changing `architecture/architecture-version.yml`, any ADR status, or any
other document from Proposed to Accepted, the implementing agent must ask the
maintainer an explicit question equivalent to:

> Do you explicitly ratify Architecture Version 1, including ADR-0001 through
> ADR-0007 and the Current/Target gaps documented in them?

Only an unambiguous affirmative answer authorizes the ratification mutation.

- Starting this task, opening this spec, or asking an agent to implement it is
  not by itself sufficient authorization.
- If the environment cannot ask interactively, or the answer is absent or
  ambiguous, stop before all ratification and validator mutations and report
  `BLOCKED: explicit maintainer ratification required`.
- Do not deliver or commit a partially implemented validator while leaving
  architecture status Proposed. The validator contract is meaningful only for
  an accepted architecture version, so the final change is coherent or is not
  delivered.
- Record the authorization in the execution session/report (and in normal
  durable SpecRelay task evidence when the run has it); do not add a maintainer
  name, email address, or chat transcript to architecture source files.

## 8. Pre-ratification audit

After authorization and before editing, perform a repository-grounded audit.

### 8.1 Version-set integrity

Verify that:

- every path under `documents` and `decisions` in
  `architecture-version.yml` exists inside the repository;
- the decision list has no duplicate paths;
- every listed ADR declares architecture version `1`;
- every listed ADR has all headings required by
  `architecture/decisions/README.md`;
- every listed ADR is Proposed before the transition;
- the decisions index contains exactly the ADRs in the version set; and
- the north star and principles both identify version 1 as Proposed before the
  transition.

An unexpected missing, duplicate, already-Accepted, or extra indexed ADR is not
silently repaired. Stop, report the mismatch, and require the maintainer to
decide whether the proposed version set itself must change.

### 8.2 Truthfulness audit

Re-check material Current/Target claims against code, tests, and operational
documentation, with special attention to:

- the Reviewer directly invoking accept/request-changes transitions;
- engine-only canonical state authorship;
- human-review halt semantics;
- Coordinator permissions and lack of transition ownership;
- runtime update/bootstrap behavior;
- current single-workspace and non-concurrent execution; and
- provider neutrality having only one real provider.

If a material claim is false, do not ratify a knowingly inaccurate baseline.
Make the smallest honest correction, preserving Current versus Target, and show
that correction explicitly in the implementation report. A correction that
changes the meaning of the proposed architecture is not editorial: stop and
request a new architecture decision instead of smuggling it into ratification.

### 8.3 Clean baseline

- Preserve all pre-existing user changes.
- The existing roadmap edits are in scope and must not be discarded.
- Run the relevant pre-change tests before changing the validator so any
  pre-existing failure is recorded rather than attributed to this work.
- A pre-existing failure does not become a pass by documentation. Report it and
  stop if it prevents trustworthy verification of this spec.

## 9. Adoption boundary

The adoption boundary is computed, not hard-coded.

1. Enumerate directories matching `docs/specs/NNNN-*/spec.md`.
2. Accept only a four-digit numeric prefix followed by `-`.
3. Compute the maximum numeric prefix present at ratification time.
4. Store that integer at:

   ```yaml
   spec_contract:
     adoption_boundary:
       exempt_specs_up_to_and_including: <computed maximum>
   ```

Because this bootstrap spec exists before ratification, it is included in the
boundary. If no spec newer than this one exists when implementation runs, the
correct boundary is `31` (rendered in prose as `0031`) and the first spec that
must declare `architecture_version` is `0032`.

If a higher-numbered spec exists, the boundary is that higher number. Never
assume `0030` or `0031` without scanning the repository.

Historical specs at or below the boundary:

- remain valid without `architecture_version`;
- must not be rewritten to add the field; and
- must not be rejected by the validator.

## 10. Coherent ratification mutation

After the audit succeeds, update all ratification surfaces as one coherent
working-tree change.

### 10.1 `architecture/architecture-version.yml`

- change `status: proposed` to `status: accepted`;
- set `ratified_at` to the current UTC ISO-8601 timestamp, including timezone
  (`YYYY-MM-DDTHH:MM:SSZ` is preferred);
- set the computed adoption boundary;
- change `spec_contract.enforcement` from `documentation-only` to a value that
  truthfully names machine enforcement (use `machine-validated` unless the
  implemented schema requires a more precise documented value); and
- update comments that still describe the version as awaiting ratification.

Do not change `version: 1`, its increment policy, document set, or decision set
unless the pre-ratification audit found a problem and the maintainer explicitly
approved a revised set.

### 10.2 Included ADRs

For every ADR listed under the version file's `decisions` key:

- change only its ADR lifecycle status from `Proposed` to `Accepted`;
- preserve accurate implementation-maturity qualifiers;
- update time-sensitive wording such as "once ratified" or "this pass does not
  ratify" where it becomes false; and
- do not rewrite historical context, alternatives, or open Target gaps as if
  they were Current behavior.

ADR-0001's implementation maturity should become truthful after this spec:
the architecture documentation layer is ESTABLISHED and the future-spec
validation contract is ENFORCED. That does not promote unrelated Target items
in other ADRs.

### 10.3 Architecture index and normative documents

Update:

- `architecture/decisions/README.md` header, index statuses, and ratification
  section so it describes a completed ratification and retains a reusable
  checklist for future architecture versions;
- `architecture/north-star.md` status surface;
- `architecture/principles.md` status surface and any sentence that treats the
  whole version as merely proposed; and
- any other repository page that explicitly reports Architecture Version 1 as
  Proposed.

Do not change a principle's implementation maturity merely because the version
is Accepted.

### 10.4 Specification documentation and roadmap

Update `docs/specs/README.md` to state:

- Architecture Version 1 is Accepted;
- the concrete four-digit adoption boundary;
- specs after that boundary require a dedicated architecture metadata section;
- historical specs are exempt and untouched; and
- enforcement is machine-validated, including the exact validation command.

Update `docs/roadmap/architecture-roadmap.md` and
`docs/roadmap/current-plan.md` so they no longer report the architecture as
Proposed or Spec 0031 as unstarted. Preserve all Core/Platform boundaries and
keep Spec 0032's Reviewer gap as the next Core safety objective.

## 11. Future-spec metadata contract

Every spec whose numeric prefix is greater than the recorded adoption boundary
must contain exactly one dedicated second-level section named
`Architecture metadata` (an optional numeric section prefix is allowed). Its
first fenced YAML block must parse to a mapping containing exactly one required
field for this contract:

```yaml
architecture_version: 1
```

Rules:

- the value is an integer, not a quoted string, float, list, or boolean;
- it must equal the currently accepted architecture version;
- a missing section, missing field, duplicate section, duplicate field,
  malformed YAML block, or mismatched version fails validation;
- mentioning `architecture_version` elsewhere in prose or an example does not
  satisfy the contract;
- additional metadata keys may be allowed only if the validator documents and
  preserves them; they must not weaken validation of `architecture_version`;
- specs at or below the boundary are not required to add the section; and
- non-numbered directories and files outside `docs/specs/NNNN-*/spec.md` are
  ignored by this contract.

This dedicated-section rule prevents a prose example from accidentally passing
the validator.

## 12. Validator architecture

Implement a small source-local validator with one reusable validation path.

### 12.1 Required command

Add:

```text
specrelay architecture validate [--json]
```

Behavior:

- operates on this SpecRelay source checkout, not on a consumer project's
  `.specrelay/config.yml`;
- refuses installed mode with an actionable message, matching the source-local
  safety pattern used by release commands;
- reads `architecture/architecture-version.yml` with Ruby Psych
  `YAML.safe_load`, never `YAML.load`, `unsafe_load`, regex-only YAML parsing,
  or a new third-party dependency;
- validates the architecture-version schema, document/ADR set, accepted status
  coherence, adoption boundary, and post-boundary spec metadata;
- is read-only and deterministic;
- prints one actionable diagnostic per failure and exits non-zero if any check
  fails;
- prints a concise success summary and exits zero only when the whole contract
  is valid; and
- emits stable JSON under `--json`, with at least `ok`, `architecture_version`,
  `status`, `adoption_boundary`, `checked_specs`, and `errors`.

The implementation may use a focused Ruby helper plus a shell/CLI wrapper, or
another existing repository pattern, but there must be one canonical validator
used by the CLI, release integration, and tests. Do not create two parsers with
slightly different rules.

### 12.2 Architecture-version schema checks

At minimum reject:

- malformed YAML or a non-mapping root;
- non-positive/non-integer `version`;
- status other than `proposed`, `accepted`, or `superseded`;
- Accepted status with null/invalid `ratified_at`;
- Accepted status with null/non-integer/negative adoption boundary;
- an unsupported `spec_contract.required_field`;
- an enforcement value inconsistent with Accepted status;
- missing or escaping document/decision paths;
- duplicate decision paths;
- missing required architecture documents;
- version mismatch in a listed ADR; and
- index/version-set disagreement.

Resolve paths canonically and reject absolute paths, `..` escapes, and symlink
targets outside the repository root.

### 12.3 Proposed-version behavior

The reusable validator must also handle a Proposed fixture honestly:

- Proposed with `ratified_at: null`, null boundary, and
  `documentation-only` enforcement is valid as a proposed architecture
  configuration;
- post-boundary spec enforcement is inactive while status is Proposed; and
- the command reports that the contract is not ratified rather than claiming
  machine enforcement is active.

This preserves the architecture lifecycle for future versions and makes the
validator testable without special-casing the real repository.

## 13. Release integration

The existing source-local release workflow must call the canonical architecture
validator before it plans, prepares, verifies, or tags a release.

- `release plan` reports architecture validation errors and exits non-zero.
- `release prepare`, `release verify`, and `release tag` refuse to proceed when
  architecture validation fails.
- No release command mutates architecture files or auto-fixes spec metadata.
- Existing release-impact discovery and version-bump behavior remain unchanged
  after validation succeeds.
- Installed-mode release refusal remains unchanged.

This is the enforcement point that prevents a future noncompliant spec from
silently entering the release path. The standalone validation command supports
CI and local pre-review checks.

## 14. Failure semantics

Validation failures must name:

- the affected architecture file or spec directory;
- the violated rule;
- the expected architecture version or boundary when relevant; and
- the minimal recovery action.

Examples of acceptable diagnostics:

```text
docs/specs/0032-example/spec.md: missing Architecture metadata section; expected architecture_version: 1
docs/specs/0033-example/spec.md: architecture_version 2 does not match accepted version 1
architecture/architecture-version.yml: accepted architecture requires a non-null ratified_at timestamp
```

Do not emit stack traces for ordinary invalid input. Do not silently skip a file
because it cannot be read or parsed.

## 15. Required tests

Add a focused suite, expected to be named
`test/architecture_version_test.sh`, using isolated temporary repositories and
the shared test harness.

At minimum cover:

1. the real post-ratification repository validates successfully;
2. JSON success output has the required stable fields;
3. malformed architecture YAML fails cleanly;
4. a non-mapping architecture root fails;
5. missing/invalid version, status, timestamp, enforcement, or boundary fails;
6. missing, duplicate, escaping, or out-of-root architecture paths fail;
7. a missing listed ADR and an ADR version mismatch fail;
8. decision-index/version-set disagreement fails;
9. an exempt historical spec without metadata passes;
10. the bootstrap Spec 0031 passes without `architecture_version` when it is
    at the boundary;
11. the first post-boundary spec with integer version 1 passes;
12. missing metadata section fails;
13. prose-only mention of `architecture_version: 1` fails;
14. duplicate sections or fields fail;
15. malformed metadata YAML fails;
16. quoted, boolean, float, list, and mismatched version values fail;
17. a higher spec number present at ratification produces a higher computed
    boundary in the boundary-computation test;
18. Proposed fixture behavior remains valid but unenforced;
19. `architecture validate` refuses installed mode;
20. all release commands refuse an invalid architecture contract before any
    mutation;
21. release behavior remains unchanged when architecture validation passes;
22. validation is read-only; and
23. existing release-command tests remain green.

Tests must not mutate the real repository, use network access, depend on a real
AI provider, or rely on the developer's global Git configuration.

## 16. Documentation requirements

Update at least:

- `architecture/architecture-version.yml`;
- `architecture/north-star.md`;
- `architecture/principles.md`;
- every ADR listed by the version file;
- `architecture/decisions/README.md`;
- `docs/specs/README.md`;
- `docs/roadmap/architecture-roadmap.md`;
- `docs/roadmap/current-plan.md`;
- `docs/commands.md` with `specrelay architecture validate` and `--json`;
- release documentation describing the new preflight; and
- README architecture status wording if the audit finds any stale Proposed
  claim there.

Documentation must state the concrete boundary derived at implementation time,
not copy the example value blindly.

## 17. Out of scope

This spec does not:

- implement Reviewer Decision as Data (Spec 0032);
- claim Reviewer transition authority is already fixed;
- implement immutable runtime bootstrap;
- create the SpecRelay Platform repository or Platform M000;
- add structured runtime events or external run identities;
- add workspace isolation, multi-repository execution, or parallel tasks;
- rewrite historical specs to add architecture metadata;
- change the architecture version number or add/supersede an ADR;
- change consumer configuration or task lifecycle behavior;
- bump `VERSION`, edit `CHANGELOG.md`, create a Git commit/tag, or push; or
- use a broad search-and-replace to convert Target/Proposed implementation
  claims into Enforced claims.

## 18. Implementation surface

Expected surface, subject to repository-grounded adjustment:

- a focused architecture validator helper using Ruby Psych safe loading;
- a thin shell/CLI integration for `specrelay architecture validate`;
- `bin/specrelay` and/or `lib/specrelay/cli.sh` dispatch and usage;
- `lib/specrelay/release.sh` integration using the same validator;
- `test/architecture_version_test.sh`;
- additive cases in `test/release_command_test.sh`;
- the architecture and documentation files listed in Sections 10 and 16.

Do not put Jira, Platform, or consumer-project policy into the validator.

## 19. Expected implementation order

1. Read this spec and inspect the current repository diff without discarding
   existing roadmap changes.
2. Obtain explicit maintainer ratification authorization (Section 7).
3. Run the pre-ratification integrity/truthfulness audit and relevant baseline
   tests.
4. Compute the actual adoption boundary.
5. Implement the canonical validator and its fixture tests against Proposed and
   Accepted configurations without yet making release commands mutating.
6. Apply the coherent architecture status/boundary/documentation mutation.
7. Expose `specrelay architecture validate [--json]`.
8. Integrate the same validator into all release commands.
9. Update architecture, specs, commands, release, and roadmap documentation.
10. Run focused tests, then the complete test suite.
11. Review the final diff specifically for false Current/Enforced claims,
    unintended historical-spec edits, release/version changes, and any
    user-owned changes lost.

## 20. Acceptance criteria

- Explicit maintainer authorization was obtained before ratification mutation.
- `architecture-version.yml` is Accepted, timestamped, has a computed non-null
  boundary, and truthfully reports machine validation.
- Every ADR in its decision set is Accepted, with honest implementation maturity
  preserved.
- North star, principles, ADR index, specs documentation, and roadmaps agree on
  version, status, and boundary.
- No historical spec at or below the boundary was rewritten to add
  `architecture_version`.
- The first post-boundary spec is required to declare integer architecture
  version 1 in the dedicated metadata section.
- `specrelay architecture validate` and `--json` implement the contract with
  deterministic, actionable output.
- Every source-local release operation refuses an invalid architecture/spec
  contract before mutation.
- Proposed-version fixtures remain supported for future architecture work.
- Validator parsing uses safe YAML loading and rejects path escape.
- Focused tests and the full test suite pass.
- `VERSION` and `CHANGELOG.md` are unchanged.
- No commit, tag, push, Platform repository, or consumer workspace mutation is
  performed automatically.

## 21. Completion gate

Before reporting completion, provide evidence for all of the following:

1. the explicit human authorization and the timestamp used for ratification;
2. the computed adoption boundary and the spec directories considered;
3. `specrelay architecture validate` success output;
4. `specrelay architecture validate --json` parsed successfully;
5. a negative fixture proving a post-boundary spec without metadata fails;
6. a historical fixture proving an exempt spec passes;
7. release commands refusing an invalid architecture fixture without mutation;
8. focused test command and result;
9. full-suite command and result;
10. `git diff --check` success;
11. confirmation that `VERSION` and `CHANGELOG.md` did not change; and
12. a final list of modified files, with any pre-existing user changes clearly
    distinguished from this implementation.

If any item is unavailable, report the spec as blocked or incomplete. Do not
replace missing evidence with an AI claim.

## 22. Definition of done

This spec is done only when Architecture Version 1 is a coherent, explicitly
human-ratified baseline; its Current/Target gaps remain honest; future specs are
machine-checked against the recorded boundary; release tooling cannot bypass
that check; documentation agrees; and all required tests pass without altering
historical specs, consumer runtime behavior, or release version state.
