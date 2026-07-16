# Spec 0028 — UI Runtime Verification and Compact Review Evidence

## 1. Status

Proposed.

## 2. Release metadata

```yaml
release:
  impact: minor
  rationale: Adds first-class UI runtime verification, Playwright scenario execution, compact screenshot evidence, and independent reviewer evidence validation.
```

## 3. Task identity

```text
0028-ui-runtime-verification-and-compact-review-evidence
```

## 4. Objective

Add a first-class UI verification capability to SpecRelay.

For tasks that change user-visible behaviour, SpecRelay must be able to:

- start or connect to the real application runtime;
- execute explicit browser scenarios;
- verify acceptance criteria through real user flows;
- capture compact screenshots only where they prove behaviour;
- record browser-console and network failures;
- compare actual UI with supplied visual references when such references exist;
- allow the independent Reviewer to validate the evidence;
- produce a compact, readable, repository-safe verification package.

The final verification package must resemble a human-readable scenario report:

```text
Scenario 01
Acceptance criterion
Environment
Steps
Evidence screenshots
Result: PASS / FAIL / BLOCKED
Reviewer verification
```

This specification must not treat a passing unit test as proof that the user interface works.

## 5. Background

Spec 0023 added immutable multi-file task input and supporting evidence.

Spec 0026 added configurable verification levels and multi-service verification.

Spec 0027 adds local developer configuration overrides.

The missing capability is verification of real user-visible behaviour.

Today a task may pass unit, integration, or service tests while still having:

- a missing or invisible button;
- an incorrect form;
- stale options in a selector;
- incorrect navigation;
- a broken submit flow;
- unexpected browser-console errors;
- failed network requests;
- a visual result that does not match the supplied design or screenshot.

Manual UI testing has already demonstrated a useful evidence format:

- one Markdown file per scenario;
- direct mapping to an acceptance criterion;
- numbered user steps;
- a compact screenshot for each material checkpoint;
- a clear PASS, FAIL, or BLOCKED result;
- an index linking all scenarios.

SpecRelay must formalize that pattern.

## 6. Architectural decision

UI verification is a deterministic verification capability orchestrated by SpecRelay.

The browser automation may use Playwright, but:

- the verification plan comes from configuration and the resolved specification;
- the deterministic engine owns scenario selection, execution boundaries, artifact paths, retention limits, and completion gates;
- AI may interpret results and explain evidence;
- AI must not fabricate screenshots, browser results, or successful steps;
- the Reviewer independently validates the produced evidence;
- no role may silently skip required UI verification.

## 7. Scope

This specification introduces:

1. UI-impact detection and explicit UI-verification configuration.
2. Application-runtime readiness checks.
3. Playwright-based scenario execution.
4. Per-scenario evidence capture.
5. Screenshot cropping and size controls.
6. Browser-console and network-error capture.
7. Optional actual-versus-expected visual comparison.
8. Reviewer evidence validation.
9. Compact checked-in evidence publication.
10. Explicit PASS, FAIL, and BLOCKED outcomes.
11. CLI, doctor, reporting, and documentation support.
12. Deterministic fake fixtures and tests.

## 8. Out of scope

This specification does not:

- introduce arbitrary free-form browser exploration;
- permit AI to claim a UI step succeeded without browser evidence;
- require video recording by default;
- keep full-page source screenshots by default;
- keep duplicate screenshots;
- add a general visual-design approval system;
- replace product or UX review;
- remove the final human review gate;
- implement cross-browser testing beyond explicitly configured browsers;
- implement the complete task-artifact folder migration;
- implement per-task isolated workspaces;
- implement autonomous source-code repair;
- require every non-UI task to start a browser;
- commit, push, tag, or release automatically.

## 9. Terminology

### 9.1 UI-impacting task

A task that changes or may change user-visible behaviour, browser navigation, rendered content, forms, controls, client-side behaviour, styling, or visual presentation.

### 9.2 UI verification scenario

A deterministic browser flow tied to one or more acceptance criteria.

### 9.3 Checkpoint

A material point in a scenario where behaviour must be asserted and, when useful, captured as visual evidence.

### 9.4 Actual evidence

Evidence produced by the current application under test.

### 9.5 Expected reference

A screenshot, design export, prototype image, or other approved visual reference supplied through the immutable specification bundle.

### 9.6 Compact evidence

The minimal evidence required to prove a scenario result without retaining unnecessary full-page images, duplicate files, or large videos.

## 10. Configuration

Add first-class UI verification configuration under:

```yaml
verification:
  ui:
    enabled: auto
    required_when_detected: true
    provider: playwright
    browsers:
      - chromium
    runtime:
      start_command: bin/dev
      working_directory: .
      ready_url: http://127.0.0.1:3000/health
      ready_timeout_seconds: 120
      stop_command: null
    scenarios:
      manifest: .specrelay/ui-scenarios.yml
    screenshots:
      mode: checkpoints
      retain_source: false
      crop: important-region
      max_width: 1600
      max_height: 1200
      max_file_bytes: 750000
      format: png
    video:
      mode: off
    trace:
      mode: on-failure
    console:
      fail_on:
        - error
    network:
      fail_on_status:
        - 500-599
    expected_references:
      policy: compare-when-present
    publication:
      enabled: true
      destination: spec-directory
      path: verification/ui
```

## 11. Local override compatibility

All new configuration must participate in the configuration layering introduced by Spec 0027.

A developer must be able to override locally, without committing changes:

```yaml
verification:
  ui:
    runtime:
      start_command: bin/dev-local
      ready_url: http://127.0.0.1:3100/health
    browsers:
      - chromium
```

Local configuration must not require repetition of the complete committed configuration.

## 12. UI-impact detection

`verification.ui.enabled` supports:

```text
true
false
auto
```

### 12.1 true

UI verification is explicitly enabled.

### 12.2 false

UI verification is disabled only when policy permits it.

If the task is explicitly marked UI-impacting and `required_when_detected: true`, disabling it must produce a configuration conflict and must not silently skip verification.

### 12.3 auto

SpecRelay determines UI impact using deterministic signals, including:

- changed files matching configured UI paths;
- frontend service selection from Spec 0026;
- specification language identifying pages, forms, buttons, links, views, layouts, browser behaviour, screenshots, Playwright, CSS, JavaScript, templates, or visual acceptance criteria;
- supplied expected screenshots or design references;
- explicit metadata in the specification.

The detection result must be recorded with reasons.

AI may assist classification, but the engine must store the final effective decision and its evidence.

## 13. Scenario source

Scenarios may come from:

1. a committed scenario manifest;
2. scenario definitions inside the specification bundle;
3. acceptance criteria resolved into configured reusable flows;
4. explicitly named Playwright test files.

The engine must never invent unbounded browser exploration.

A scenario must have:

```yaml
id: 01-only-berechnung-offered
title: Only Berechnung is offered for new Haushaltsrechnung rules
acceptance_criteria:
  - Berechnung is the only rule type offered
service: frontend
browser: chromium
steps:
  - action: goto
    url: /companies/19892/financing/condition/versions/56742/sets/household_calculation
  - action: click
    target: Neues Element
  - action: click
    target: Kondition
assertions:
  - type: visible
    target: Berechnung
  - type: absent
    target: Tabelle
  - type: absent
    target: Pauschalbetrag
checkpoints:
  - id: type-picker
    after_step: 3
    region:
      locator: "[data-testid='condition-type-picker']"
```

## 14. Scenario selection

Scenario selection must be deterministic and explainable.

The execution plan must state:

- which scenarios were selected;
- which acceptance criteria each scenario covers;
- which changed paths or specification requirements selected them;
- which scenarios were not selected and why;
- whether selection fell back to a broader set;
- whether required coverage is incomplete.

A UI-impacting task must not pass when no scenario covers its material UI acceptance criteria.

## 15. Runtime readiness

Before browser execution, SpecRelay must verify:

- required services are configured;
- the start command exists or the runtime is declared external;
- required working directories exist;
- the application reaches the configured readiness URL or readiness command;
- credentials and test data required by the scenario are available;
- the configured browser and Playwright runtime are available.

Failure must produce `BLOCKED`, not PASS and not a silent skip.

Runtime logs must be captured with secrets redacted.

## 16. Playwright execution

Playwright is the initial supported UI provider.

The provider adapter must support:

- browser launch;
- configured base URL;
- scenario-specific authentication/setup;
- deterministic step execution;
- assertions;
- checkpoint screenshots;
- console-event capture;
- failed-network-request capture;
- HTTP status capture;
- trace-on-failure;
- bounded timeout;
- clean browser and runtime shutdown.

The adapter must return structured results to the deterministic engine.

## 17. Scenario result model

Each scenario has exactly one final result:

```text
PASS
FAIL
BLOCKED
```

### 17.1 PASS

All required steps and assertions completed successfully, and no configured fatal browser-console or network condition occurred.

### 17.2 FAIL

The runtime was available, but one or more assertions, steps, console rules, network rules, or visual comparisons failed.

### 17.3 BLOCKED

Verification could not be performed reliably because a prerequisite was unavailable.

Examples:

- application failed to start;
- required service unavailable;
- credentials missing;
- test data unavailable;
- browser unavailable;
- required expected reference missing;
- scenario definition invalid;
- screenshot could not be stored safely.

A blocked scenario cannot be reported as passed.

## 18. Screenshot evidence policy

Screenshots are evidence, not decoration.

### 18.1 Capture only material checkpoints

A screenshot must be captured only when it proves a material acceptance criterion or explains a failure.

Do not capture every click automatically.

### 18.2 Important-region capture

The preferred capture is:

1. locator/element screenshot;
2. configured bounding region;
3. automatically cropped viewport screenshot;
4. full viewport only when the relevant region cannot be isolated.

Full-page screenshots are disabled by default.

### 18.3 No retained source image by default

When an intermediate full viewport or full-page image is required to create a cropped image:

- produce the final cropped evidence;
- verify that the cropped file is readable and non-empty;
- delete the intermediate source image;
- do not publish the source image.

`retain_source: false` is the default.

### 18.4 No duplicate images

The engine must detect exact duplicate screenshot content by digest.

Duplicate screenshots must not be published twice.

The scenario report may reference the already-existing image.

### 18.5 Size limits

Each published screenshot must satisfy configured:

- maximum width;
- maximum height;
- maximum byte size;
- permitted format.

When optimization cannot meet the limit without making the evidence unreadable, the scenario must be BLOCKED with an explicit reason.

### 18.6 No fabricated or AI-generated evidence

Screenshots must come from the browser session under test.

Image generation, reconstruction, mockup creation, or AI alteration is forbidden.

Cropping, scaling, and lossless or controlled compression are allowed and must be recorded.

## 19. Video policy

Video is disabled by default:

```yaml
video:
  mode: off
```

Supported modes may include:

```text
off
on-failure
explicit
```

Video must never be produced merely because Playwright supports it.

When enabled:

- it must have a configured maximum duration and size;
- it must remain runtime-only by default;
- it must not be committed automatically;
- the final compact evidence package should prefer screenshots and Markdown;
- a retained video requires an explicit policy and justification.

## 20. Trace policy

Playwright trace is not the same as published review evidence.

Default:

```yaml
trace:
  mode: on-failure
```

Traces:

- remain in task runtime evidence;
- are not published to the specification directory by default;
- may be used by Reviewer to diagnose a failure;
- must have size limits and retention policy;
- must be redacted where possible.

## 21. Console and network evidence

For every scenario, capture:

```text
console-errors.json
network-errors.json
```

The files must include only relevant events for that scenario and must redact:

- authorization headers;
- cookies;
- tokens;
- session identifiers;
- API keys;
- configured personal and financial patterns.

Configured fatal events influence PASS/FAIL.

Non-fatal warnings may be recorded without failing the scenario.

## 22. Visual-reference comparison

When an expected reference exists in the immutable input bundle:

- record its snapshot path and digest;
- identify which scenario/checkpoint it applies to;
- capture the actual screenshot using the same intended region where possible;
- normalize dimensions only according to documented policy;
- produce a comparison result;
- optionally produce a compact diff image;
- record tolerance and comparison method;
- never claim visual equivalence when no comparison was performed.

Suggested runtime paths:

```text
29-ui-verification/
└── scenarios/
    └── <scenario-id>/
        ├── actual/
        ├── expected/
        └── diff/
```

Expected references must be copied or linked from the immutable input snapshot, not re-fetched from a mutable source during review.

## 23. Expected-reference policy

Supported policies:

```text
ignore
compare-when-present
required
```

### 23.1 ignore

Behavioural verification runs without visual comparison.

### 23.2 compare-when-present

Visual comparison runs whenever a mapped expected reference exists.

Absence of a reference does not block behavioural verification, but the report must state:

```text
Visual equivalence not assessed: no expected reference supplied.
```

### 23.3 required

A missing mapped expected reference produces BLOCKED.

## 24. Runtime artifact layout

Until the complete task-folder migration is implemented, use one contained runtime directory:

```text
<task-runtime>/
└── 29-ui-verification/
    ├── plan.json
    ├── environment.json
    ├── runtime.log
    ├── summary.json
    ├── summary.md
    ├── console-errors.json
    ├── network-errors.json
    ├── traces/
    └── scenarios/
        ├── 01-<slug>/
        │   ├── result.json
        │   ├── report.md
        │   ├── screenshots/
        │   │   ├── step-01-<slug>.png
        │   │   └── step-02-<slug>.png
        │   └── comparison/
        │       └── <checkpoint>-diff.png
        └── 02-<slug>/
```

This directory is task-runtime evidence and may include diagnostic files that are not appropriate for Git.

## 25. Compact published evidence

When publication is enabled, produce a compact package under the specification directory:

```text
<spec-directory>/
└── verification/
    └── ui/
        ├── README.md
        ├── environment.md
        ├── summary.md
        ├── console-errors.json
        ├── network-errors.json
        └── scenarios/
            ├── 01-<slug>.md
            ├── 01-<slug>/
            │   ├── step-01-<slug>.png
            │   └── step-02-<slug>.png
            └── 02-<slug>.md
```

Only compact, reviewed evidence is published.

Do not publish by default:

- full-page source screenshots;
- source images used only for cropping;
- duplicate screenshots;
- Playwright trace archives;
- videos;
- raw runtime logs;
- browser caches;
- authentication state;
- large temporary files.

## 26. Publication ownership

The deterministic engine owns publication.

The Executor may produce initial runtime evidence.

The Reviewer must independently validate the scenario evidence before the package is marked verified.

The Reviewer may write review artifacts and evidence-validation findings, but must not silently replace browser evidence or alter screenshots.

After Reviewer acceptance, the engine may publish the compact package according to configuration.

No AI role may independently copy arbitrary task files into the repository.

## 27. Scenario Markdown contract

Each published scenario file must contain:

```markdown
# Scenario 01 — <title>

**Acceptance criterion:** <criterion text>

## Environment

- Service:
- Browser:
- Base URL:
- Test data:
- Commit/branch:
- Scenario definition:

## Steps

1. <action and expected checkpoint>
   ![Evidence](01-<slug>/step-01-<slug>.png)

2. <action and expected checkpoint>
   ![Evidence](01-<slug>/step-02-<slug>.png)

## Browser diagnostics

- Console errors:
- Network errors:
- Trace:
- Visual reference:

## Result: PASS | FAIL | BLOCKED

<evidence-backed explanation>

## Reviewer verification

- Evidence integrity:
- Acceptance-criterion coverage:
- Independent checks:
- Reviewer result:
```

## 28. Index contract

The published `README.md` must provide:

- task/spec identity;
- verification date;
- environment summary;
- scenario table;
- acceptance-criterion coverage;
- PASS/FAIL/BLOCKED totals;
- links to each scenario;
- statement of whether visual comparison was performed;
- compact evidence size;
- Reviewer verification status.

Example:

```markdown
| Scenario | Acceptance criterion | Result | Evidence |
|---|---|---|---|
| 01 | Only Berechnung is offered | PASS | [Open](scenarios/01-only-berechnung-offered.md) |
| 02 | Berechnung form fields | PASS | [Open](scenarios/02-berechnung-form-fields.md) |
```

## 29. Reviewer responsibilities

The Reviewer must independently:

- inspect the same immutable specification input;
- map scenarios to acceptance criteria;
- inspect scenario reports and screenshots;
- verify that screenshots show the claimed state;
- verify that images are compact and relevant;
- inspect configured console/network failures;
- inspect visual comparisons when required;
- independently rerun a bounded subset or all required UI scenarios according to verification policy;
- detect missing coverage;
- detect unsupported PASS claims;
- verify that no source screenshot or video was unnecessarily published;
- record a final UI evidence decision.

The Reviewer must not accept when:

- a required UI scenario is absent;
- evidence does not prove the claim;
- screenshots are fabricated, stale, unrelated, or unreadable;
- required console/network evidence is missing;
- a required reference comparison was skipped;
- a BLOCKED prerequisite was represented as PASS;
- published evidence violates retention or secret-redaction policy.

## 30. Reviewer evidence section

`09-consultant-review.md` must include:

```markdown
## UI Verification Evidence Review
```

It must state:

- whether UI verification was required;
- scenarios inspected;
- acceptance criteria covered;
- scenarios independently rerun;
- screenshot relevance and integrity;
- console/network findings;
- expected-reference comparison findings;
- publication/retention compliance;
- final UI evidence verdict.

An ACCEPT decision is invalid for a required UI task without this section.

## 31. Completion gates

A UI-impacting task cannot reach `READY_FOR_HUMAN_REVIEW` when:

- UI verification was required but not run;
- selected scenarios do not cover material UI acceptance criteria;
- a required scenario is FAIL;
- a required scenario is BLOCKED;
- required browser-console or network checks are missing;
- required expected-reference comparison was not performed;
- evidence files are missing, unreadable, oversized, or unsafe;
- the Reviewer did not complete independent UI evidence review;
- the compact package claims more than the evidence proves.

Optional scenarios may fail without blocking only when configuration explicitly marks them optional and the report states that clearly.

## 32. Integration with Spec 0026

UI scenarios are a verification check kind managed by the Spec 0026 verification policy.

Example:

```yaml
verification:
  services:
    frontend:
      affected_paths:
        - app/javascript/**
        - app/views/**
        - app/assets/**
      checks:
        ui:
          kind: ui
          command: specrelay ui run --plan effective
          required: true
          levels:
            - changed
            - full
          dependencies:
            - frontend-unit
          parallel_group: browser
```

The effective verification plan must show UI checks beside unit, integration, lint, and other checks.

Full-suite placement and Reviewer rerun policy remain configurable.

## 33. Coordinator integration

The Coordinator may receive deterministic UI verification facts, including:

- UI verification required;
- runtime ready/not ready;
- selected scenarios;
- PASS/FAIL/BLOCKED totals;
- missing acceptance-criterion coverage;
- required evidence missing;
- fatal console/network events;
- required visual comparison missing;
- Reviewer UI verdict.

The Coordinator may recommend only from the engine-computed allowlist.

It must not:

- create screenshots;
- change scenario results;
- downgrade FAIL or BLOCKED to PASS;
- bypass required UI verification;
- edit published evidence;
- decide that missing evidence is acceptable.

## 34. CLI

Add commands such as:

```text
specrelay ui plan <task-ref>
specrelay ui run <task-ref>
specrelay ui report <task-ref>
specrelay ui publish <task-ref> --dry-run
```

Required behaviours:

### 34.1 plan

Read-only. Shows:

- whether UI verification is required;
- detection reasons;
- runtime requirements;
- selected scenarios;
- acceptance-criterion coverage;
- expected references;
- projected artifact paths;
- publication size policy.

### 34.2 run

Executes the deterministic UI verification plan.

It must respect locks, timeouts, redaction, and configured policies.

### 34.3 report

Read-only. Displays scenario results and evidence paths.

Supports:

```text
--json
```

### 34.4 publish

Publishes only reviewed compact evidence.

`--dry-run` must show files, destination, and estimated size without mutation.

Publication must refuse when Reviewer UI evidence validation is incomplete.

## 35. Doctor behaviour

`specrelay doctor` must report UI verification readiness separately:

```text
UI verification: disabled
UI verification: auto, no UI impact detected
UI verification: required
Playwright runtime: available / unavailable
Browser chromium: available / unavailable
Runtime start command: configured / missing
Scenario manifest: valid / invalid / not configured
Screenshot policy: valid / invalid
Expected-reference policy: ignore / compare-when-present / required
Publication destination: valid / invalid
```

Doctor must distinguish configuration readiness from task-specific runtime readiness.

## 36. Security and privacy

UI verification may interact with authenticated systems and sensitive data.

Required controls:

- credentials must come from approved secret sources, not committed scenario files;
- browser storage state must not be published;
- cookies and authorization headers must be redacted;
- screenshots must not include irrelevant personal or financial information;
- configured sensitive regions may be masked only by deterministic redaction before publication;
- redaction must be reported;
- a screenshot that cannot be safely published must remain runtime-only or produce BLOCKED;
- arbitrary URL navigation outside configured origins must be rejected;
- file uploads/downloads must be explicitly configured;
- browser automation must have bounded timeouts.

## 37. Determinism

For the same:

- immutable input snapshot;
- repository commit;
- effective configuration;
- scenario manifest;
- browser/provider version;
- test data identity;

SpecRelay must be able to explain why the same scenarios and checkpoints were selected.

Pixel-perfect output is not guaranteed across all platforms, so visual comparison must record:

- browser name/version;
- viewport;
- device scale factor;
- operating system/runtime details;
- threshold;
- normalization rules.

## 38. Failure recovery

A failed or interrupted UI verification run must preserve completed scenario evidence.

Resume must:

- verify artifact integrity;
- reuse completed PASS scenarios only when configuration and input digests match;
- rerun incomplete, failed, or stale scenarios;
- never silently reuse evidence from a different commit, config, browser, viewport, or test-data identity;
- record why evidence was reused or invalidated.

## 39. Retention and cleanup

Runtime diagnostics must have explicit retention.

At minimum:

- published compact evidence is retained in the repository;
- temporary source screenshots are deleted after verified cropping;
- videos are deleted unless explicitly retained;
- traces are retained only according to failure/debug policy;
- stale runtime directories can be cleaned through a documented command;
- cleanup must never delete published evidence or current-task required evidence;
- cleanup actions must be recorded.

## 40. Fake provider and fixtures

Tests must not require a real browser installation.

Add deterministic fixtures capable of simulating:

- runtime ready;
- runtime timeout;
- PASS scenario;
- failed assertion;
- blocked credentials;
- console error;
- network 500;
- screenshot checkpoint;
- screenshot crop;
- oversized screenshot;
- duplicate screenshot;
- expected-reference match;
- expected-reference mismatch;
- required reference missing;
- trace-on-failure;
- video disabled;
- publication dry-run;
- publication refusal before review;
- successful compact publication;
- resume with valid evidence;
- resume with stale evidence.

## 41. Required tests

At minimum, add tests for:

1. UI verification disabled leaves non-UI workflow unchanged.
2. Auto detection selects UI verification for configured frontend paths.
3. Explicit UI requirement cannot be silently disabled.
4. Non-UI change does not start a browser.
5. Required runtime unavailable produces BLOCKED.
6. Missing credentials produce BLOCKED.
7. Missing test data produce BLOCKED.
8. Invalid scenario manifest is rejected.
9. Selected scenarios map to acceptance criteria.
10. Missing material UI coverage blocks completion.
11. PASS scenario produces structured evidence.
12. Failed assertion produces FAIL.
13. Console error obeys configured severity policy.
14. Network 500 obeys configured failure policy.
15. Element screenshot is preferred over full-page screenshot.
16. Cropped screenshot is retained while source screenshot is deleted.
17. Duplicate screenshot is not published twice.
18. Oversized screenshot is optimized or blocks safely.
19. AI cannot inject or fabricate screenshot evidence.
20. Video is off by default.
21. Video is not published by default.
22. Trace is captured only according to policy.
23. Expected reference is taken from immutable input.
24. `compare-when-present` behaves honestly without a reference.
25. `required` reference policy blocks when missing.
26. Visual mismatch produces FAIL.
27. Visual comparison records threshold and environment.
28. Console/network evidence is redacted.
29. Unapproved external-origin navigation is rejected.
30. Runtime evidence and published evidence remain separate.
31. Publication dry-run is read-only.
32. Publication refuses before Reviewer validation.
33. Compact package contains required index and scenario files.
34. Scenario report follows the Markdown contract.
35. Reviewer UI section is mandatory for acceptance.
36. Reviewer detects unsupported PASS claim.
37. Reviewer detects irrelevant or unreadable screenshot.
38. Coordinator cannot bypass UI completion gates.
39. Spec 0026 effective plan includes UI check kind.
40. Spec 0027 local override can change runtime URL without duplicating config.
41. Resume reuses only digest-compatible evidence.
42. Resume rejects stale evidence.
43. Cleanup does not remove published evidence.
44. Full current test suite has no new regressions.

## 42. Documentation

Update at least:

```text
README.md
docs/architecture.md
docs/configuration.md
docs/task-lifecycle.md
docs/verification-and-timeline.md
docs/commands.md
docs/operator-recovery.md
docs/roadmap/architecture-roadmap.md
docs/roadmap/current-plan.md
```

Documentation must explain:

- when UI verification is required;
- scenario configuration;
- Playwright runtime requirements;
- PASS/FAIL/BLOCKED;
- compact screenshot policy;
- why source screenshots and videos are not retained by default;
- expected-reference policies;
- Reviewer responsibilities;
- runtime versus published evidence;
- redaction and retention;
- integration with Specs 0023, 0026, and 0027.

## 43. Required Executor summary sections

`08-executor-summary.md` must contain:

```markdown
## UI Verification Architecture
```

```markdown
## Scenario and Coverage Model
```

```markdown
## Screenshot and Retention Policy
```

```markdown
## Reviewer Evidence Contract
```

```markdown
## Security and Redaction
```

```markdown
## Backward Compatibility
```

```markdown
## Input Coverage
```

## 44. Required Reviewer section

`09-consultant-review.md` must contain:

```markdown
## UI Verification Evidence Review
```

It must independently cover:

- UI-impact detection;
- scenario selection;
- acceptance-criterion coverage;
- runtime readiness;
- PASS/FAIL/BLOCKED correctness;
- screenshot provenance;
- screenshot cropping and retention;
- console/network evidence;
- visual-reference comparison;
- publication boundaries;
- secret redaction;
- Coordinator authority boundaries;
- backward compatibility.

## 45. Acceptance criteria

The implementation is complete only when:

1. UI-impacting tasks can be identified deterministically or explicitly.
2. Non-UI tasks remain backward-compatible and do not start a browser.
3. UI scenarios execute against a real or deterministic fake runtime.
4. Every required scenario maps to acceptance criteria.
5. Scenario outcomes are PASS, FAIL, or BLOCKED.
6. Required prerequisites cannot be silently skipped.
7. Browser-console and network evidence are captured and redacted.
8. Checkpoint screenshots are compact and relevant.
9. Full-page/source screenshots are not retained by default.
10. Duplicate screenshots are not published.
11. Video is disabled and unpublished by default.
12. Expected references are sourced from the immutable input bundle.
13. Visual-comparison claims are made only when comparison occurred.
14. Runtime diagnostics remain separate from compact repository evidence.
15. Reviewer independently validates required UI evidence.
16. Compact publication is refused before Reviewer validation.
17. Completion gates prevent unsupported UI PASS claims.
18. Coordinator cannot bypass UI gates or alter evidence.
19. Spec 0026 verification planning includes UI checks.
20. Spec 0027 local overrides work for developer runtime details.
21. CLI and doctor expose clear readiness and result information.
22. Documentation is complete.
23. Required tests pass.
24. No new regression is introduced.

## 46. Implementation order

Recommended order:

1. Define UI configuration schema and effective policy.
2. Define scenario schema and validation.
3. Implement UI-impact detection and coverage plan.
4. Implement fake provider and fixtures.
5. Implement Playwright provider adapter.
6. Implement runtime readiness and lifecycle.
7. Implement scenario execution and structured results.
8. Implement screenshot checkpoint/crop/size/dedup policy.
9. Implement console/network capture and redaction.
10. Implement expected-reference mapping and comparison.
11. Implement runtime artifact writer.
12. Implement Reviewer validation contract and completion gates.
13. Implement compact publication and dry-run.
14. Integrate with Spec 0026 plans and Spec 0027 overrides.
15. Integrate Coordinator facts and restrictions.
16. Add CLI and doctor support.
17. Add focused tests.
18. Update documentation and roadmap.
19. Run the full suite.
20. Produce required Executor artifacts.

## 47. Risks

### 47.1 Evidence bloat

Mitigation:

- checkpoint-only capture;
- important-region crop;
- source deletion;
- byte/dimension limits;
- deduplication;
- no video by default;
- compact publication separate from runtime diagnostics.

### 47.2 False confidence from screenshots

Mitigation:

- screenshots supplement assertions;
- scenario reports map to acceptance criteria;
- console/network checks remain mandatory;
- Reviewer independently checks evidence.

### 47.3 Flaky visual comparisons

Mitigation:

- fixed browser/version/viewport;
- recorded environment;
- configurable tolerance;
- required deterministic setup;
- separate behavioural and visual verdicts.

### 47.4 Secret leakage

Mitigation:

- deterministic redaction;
- restricted origins;
- no browser storage-state publication;
- safe BLOCKED fallback when evidence cannot be published.

### 47.5 Reviewer becomes a second full Executor

Mitigation:

- bounded independent reruns;
- configured Reviewer verification mode from Spec 0026;
- evidence inspection first;
- rerun only the required subset unless policy requires full UI execution.

### 47.6 UI verification silently skipped

Mitigation:

- explicit required/detected status;
- BLOCKED outcomes;
- completion gates;
- doctor and report visibility;
- tests for every missing prerequisite.

## 48. Rollback

The capability must be additive.

When UI verification is disabled or not applicable:

- existing non-UI workflows behave unchanged;
- no browser starts;
- no UI artifacts are required;
- existing verification continues through Spec 0026.

Rollback consists of disabling the UI capability and removing its new adapter/commands without changing historical task evidence.

## 49. Release behaviour

This spec declares `minor` impact.

`release plan` must include it after implementation.

The implementation must not:

- prepare a release automatically;
- change VERSION automatically outside the release workflow;
- create a tag;
- push a tag;
- publish a release.

## 50. Input coverage

The Executor and Reviewer must account for every immutable specification input relevant to UI verification, including:

- `spec.md`;
- technical specification;
- scenario manifests;
- screenshots;
- design exports;
- prototype images;
- browser logs;
- expected-reference mappings;
- supporting Markdown;
- external/Jam snapshots.

Unsupported or unavailable evidence must be disclosed.

## 51. Final definition of done

This task is done only when SpecRelay can prove a UI feature through real browser scenarios, store only compact and meaningful repository evidence, preserve richer diagnostics in task runtime when needed, and prevent both AI roles and deterministic workflow paths from claiming success when required UI evidence is missing.
