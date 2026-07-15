# Spec 0023 — Specification Bundle Analysis, Jam Evidence, and Resolved Executor Input

## Status

Proposed

## Release impact

`minor`

Rationale: this specification adds backward-compatible directory-based specification input, immutable multi-file evidence bundles, pre-executor analysis, Jam MCP integration, resolved specification generation, and new executor/reviewer input contracts.

---

# 1. Purpose

SpecRelay currently accepts a specification file as the primary task input.

Real implementation work frequently depends on more than one Markdown file. A complete task may include:

- a functional specification;
- a technical specification;
- logs;
- stack traces;
- JSON, YAML, XML, CSV, or configuration examples;
- source-code fragments;
- screenshots and images;
- PDF documents;
- test fixtures;
- external evidence such as Jam recordings.

SpecRelay must therefore accept either:

- one specification file; or
- one specification directory containing the complete specification and evidence bundle.

A directory must not be handed to the Executor as an unprocessed set of files. SpecRelay must first discover, snapshot, classify, inspect, and analyse the complete bundle, then create a durable resolved specification and an evidence-aware Executor prompt.

The Executor and Reviewer must both consume the same immutable input snapshot and the same resolved specification.

---

# 2. Goals

This specification must deliver:

1. file-or-directory input for `run` and `task create`;
2. a clear directory convention for functional and technical specifications;
3. recursive discovery of supporting evidence;
4. immutable task-local snapshots;
5. deterministic input manifests and integrity digests;
6. a pre-executor specification analysis phase;
7. a durable `02-resolved-specification.md`;
8. provenance for material derived requirements;
9. Jam recordings as first-class external evidence through an optional MCP capability;
10. Jam-specific doctor and task preflight;
11. redacted durable Jam evidence snapshots;
12. one shared numbered input location for Executor and Reviewer;
13. input-coverage reporting and completion-gate enforcement;
14. backward compatibility with existing single-file workflows.

---

# 3. Non-goals

This specification does not:

- migrate every existing task artifact into a new subdirectory hierarchy;
- redesign all historical task runtime layouts;
- require Jam for tasks that contain no Jam reference;
- guarantee support for every arbitrary binary format;
- silently infer requirements from unavailable evidence;
- let the Executor independently fetch mutable external evidence without task-level snapshotting;
- implement a general-purpose web crawler;
- implement a task-input refresh command;
- change the meaning of historical tasks already created from one specification file.

A future specification must perform the complete artifact-layout migration described in Section 19.

---

# 4. CLI contract

The following commands must accept either a regular file or a directory:

```text
specrelay run <input-path>
specrelay task create <input-path>
```

Source-local examples:

```text
bin/specrelay run docs/specs/0023-example/spec.md
bin/specrelay run docs/specs/0023-example/
bin/specrelay task create docs/specs/0023-example/
```

Existing single-file commands must remain backward-compatible.

The CLI may continue displaying a compatibility `Spec:` field for file-backed tasks, but directory-backed tasks must expose explicit bundle metadata and must never represent a directory as one file.

---

# 5. Input kinds

SpecRelay must classify the supplied input as one of:

- `file`;
- `directory`.

Any path that is missing, unreadable, or neither a regular file nor a directory must fail before task creation.

Special filesystem entries such as sockets, devices, and named pipes must be rejected.

## 5.1 Single-file input

When the input resolves to a regular file:

- input kind is `file`;
- the file is the primary specification;
- the file appears in the input manifest;
- an immutable task-local snapshot is created;
- Executor and Reviewer consume the snapshot rather than the live source file.

Existing Markdown-file behavior must remain compatible.

## 5.2 Directory input

When the input resolves to a directory:

- input kind is `directory`;
- eligible files are discovered recursively;
- all accepted local files form one logical specification bundle;
- discovery order is deterministic by normalized relative path;
- the bundle is snapshotted before approval or provider execution;
- Executor and Reviewer use the same immutable bundle.

---

# 6. Specification directory convention

A specification directory has authoritative specification files and supporting evidence.

## 6.1 Functional specification

The primary functional or business specification is:

```text
spec.md
```

It may define:

- objective;
- business behavior;
- user-facing behavior;
- scope;
- functional requirements;
- acceptance criteria;
- constraints;
- exclusions;
- business terminology;
- unresolved product decisions.

For ordinary implementation and defect tasks, project policy should require `spec.md`.

The core implementation may support an explicit policy for technical-only or evidence-only tasks, but it must not silently accept a missing `spec.md` and guess the objective.

## 6.2 Technical specification

The technical specification may use either accepted filename:

```text
tech-spec.md
tech_spec.md
```

The two names are equivalent.

The technical specification may define:

- architecture;
- component boundaries;
- APIs;
- data models;
- implementation constraints;
- compatibility requirements;
- migration behavior;
- operational requirements;
- security requirements;
- verification strategy;
- accepted trade-offs.

If both `tech-spec.md` and `tech_spec.md` exist in the same bundle root, task creation must fail with an explicit ambiguity error.

SpecRelay must never silently choose one.

## 6.3 Authority domains

`spec.md` is the primary functional authority.

`tech-spec.md` or `tech_spec.md` is the primary technical authority.

The technical specification complements the functional specification. It must not silently override explicit functional requirements.

Supporting evidence may clarify or prove behavior but must not silently override an authoritative requirement.

Material conflicts must be detected and handled according to Section 15.

---

# 7. Supporting evidence

All other eligible files beneath the specification directory are supporting evidence.

Supporting evidence may include:

- Markdown notes;
- plain-text files;
- logs;
- stack traces;
- JSON;
- YAML;
- XML;
- CSV;
- configuration examples;
- API requests and responses;
- source-code examples;
- test fixtures;
- screenshots;
- PNG, JPEG, and WebP images;
- PDF documents;
- recorded command output;
- references to external documents;
- Jam recording links.

Supporting evidence must not be ignored solely because it is not Markdown.

A file does not need to affect implementation to be part of the bundle. Every discovered file must nevertheless be accounted for.

---

# 8. Discovery and exclusion rules

Directory traversal must remain bounded to the selected bundle root.

SpecRelay must:

- normalize paths consistently;
- order entries deterministically;
- reject broken symlinks;
- reject symlinks escaping the input root;
- prevent directory cycles;
- reject special filesystem entries;
- record validation failures clearly.

Default exclusions must include at least:

```text
.git/
.specrelay-runs/
node_modules/
.DS_Store
*.tmp
*.swp
```

The implementation may support configurable exclusions.

No file may be silently omitted because of a count or size limit.

If configured limits are exceeded, task creation must fail and report:

- affected path;
- file count;
- bundle size;
- applicable limit.

Partial silent ingestion is forbidden.

---

# 9. Content classification

Every accepted local file must be classified into an internal content class.

At minimum:

- `authoritative-functional-spec`;
- `authoritative-technical-spec`;
- `text-readable`;
- `structured-data`;
- `source-or-config`;
- `log-or-trace`;
- `visual`;
- `document`;
- `unknown-binary`;
- `external-reference-container`.

Every entry must also have an inspection capability classification, such as:

- directly inspectable;
- inspectable through a configured adapter;
- inspectable through provider multimodal capability;
- unsupported;
- failed to inspect.

SpecRelay must not claim a file was inspected when the active provider or adapter could not consume it.

---

# 10. Immutable task input layout

Task creation must produce one durable shared numbered input location before approval or provider execution.

The backward-compatible layout required by this specification is:

```text
<task-runtime>/
├── 01-input-manifest.json
├── 01-input-bundle/
│   ├── local/
│   └── external/
│       └── jam/
└── 02-resolved-specification.md
```

Existing artifacts such as executor log, tests, reviewer report, business summary, timeline, and command timing may retain their existing filenames and locations during this specification.

## 10.1 Local snapshot

All accepted local files must be copied or otherwise immutably snapshotted beneath:

```text
01-input-bundle/local/
```

Relative paths beneath the original bundle root must be preserved.

## 10.2 External snapshot

Externally retrieved evidence must be stored beneath:

```text
01-input-bundle/external/
```

Jam evidence must be stored beneath:

```text
01-input-bundle/external/jam/<canonical-id>/
```

## 10.3 Resume behavior

Executor, Reviewer, and resumed execution must use the task-local snapshot.

Changes to the original live file or directory after task creation must not silently change the existing task.

No resume path may rebuild the task input from the live source unless a future explicit refresh workflow is introduced.

---

# 11. Input manifest

Task creation must produce:

```text
01-input-manifest.json
```

The manifest must record at minimum:

- schema version;
- input kind;
- original input path;
- normalized source root;
- primary functional specification path;
- technical specification path, if any;
- bundle file count;
- bundle total size;
- creation timestamp;
- normalized relative path for each local file;
- original absolute or project-relative source path;
- snapshot path;
- file role;
- media type;
- byte size;
- SHA-256 digest;
- inspection capability;
- analysis status;
- exclusion or rejection reason where applicable;
- external references discovered from that file;
- resolved-specification provenance references.

External evidence entries must additionally record:

- provider;
- canonical reference;
- retrieval status;
- retrieval timestamp;
- adapter;
- available evidence types;
- missing evidence types;
- content digest;
- redaction status.

Manifest and snapshot integrity must be verifiable.

---

# 12. Specification-bundle analysis phase

Before Executor invocation, SpecRelay must run a dedicated specification-bundle analysis phase.

This phase must:

1. read `spec.md`;
2. read `tech-spec.md` or `tech_spec.md`, when present;
3. classify all accepted local evidence;
4. inspect all inspectable local evidence;
5. discover external references;
6. identify Jam references;
7. perform required external capability preflights;
8. retrieve and snapshot supported external evidence;
9. apply redaction before durable storage;
10. correlate specification text and evidence;
11. identify conflicts and ambiguities;
12. derive a consolidated resolved specification;
13. record coverage and provenance for every input.

This phase must not concatenate every file blindly into one prompt.

The analysis must distinguish:

- source-backed fact;
- evidence-backed observation;
- inference;
- unresolved ambiguity;
- unsupported or unavailable input.

---

# 13. Resolved specification

The analysis phase must create:

```text
02-resolved-specification.md
```

This is the analysed implementation brief supplied to Executor and Reviewer.

It does not replace the original snapshot.

It must contain at least:

```text
# Resolved Specification

## Objective

## Functional Requirements

## Technical Requirements

## Acceptance Criteria

## Constraints and Boundaries

## Evidence-Derived Requirements

## Current Behaviour

## Expected Behaviour

## UI and Visual Evidence

## API and Data Contracts

## Defect Reproduction

## External Evidence

## Conflicts and Ambiguities

## Required Verification

## Input Coverage

## Provenance
```

Every material derived statement must identify its source.

Examples:

```text
The failure occurs after the submit action and before the UI confirmation.
Source: local/logs/browser-error.log.
```

```text
POST /offers returns HTTP 500 immediately after the user clicks Submit.
Source: external/jam/<id>/network-errors.json.
```

The resolved specification must not present assumptions as facts.

---

# 14. Executor prompt contract

SpecRelay must generate the Executor prompt from:

- task metadata;
- `01-input-manifest.json`;
- `02-resolved-specification.md`;
- immutable local and external snapshot paths;
- active implementation and verification policies.

The prompt must state that:

- `spec.md` is the primary functional authority;
- `tech-spec.md` or `tech_spec.md` is the primary technical authority;
- the resolved specification is an analysed implementation brief, not a replacement for source evidence;
- the full snapshot remains authoritative and available;
- relevant screenshots, logs, PDFs, examples, structured data, and Jam evidence must be consulted;
- contradictions must not be silently resolved;
- unavailable or unsupported evidence must not be claimed as inspected;
- implementation must remain within documented boundaries;
- verification must cover resolved acceptance criteria;
- input coverage must be recorded in executor artifacts.

The Executor must be able to reopen original snapshot files during implementation.

---

# 15. Reviewer prompt contract

The Reviewer must independently receive:

- `01-input-manifest.json`;
- the immutable input bundle;
- `02-resolved-specification.md`;
- Executor artifacts;
- implementation changes;
- verification evidence.

The Reviewer must verify:

- whether the resolved specification accurately represents the original bundle;
- whether important evidence was omitted or misinterpreted;
- whether implementation satisfies functional requirements;
- whether implementation satisfies technical requirements;
- whether evidence-derived requirements were implemented;
- whether unsupported inputs were disclosed honestly;
- whether conflicts were resolved through evidence rather than assumption;
- whether Executor input coverage is truthful;
- whether the same immutable input snapshot was used.

The Reviewer must not treat the resolved specification as unquestionable.

It must compare the resolved specification against original task evidence.

---

# 16. Conflict and ambiguity handling

SpecRelay must detect material contradictions between:

- functional and technical specifications;
- specification text and screenshots;
- specification text and logs;
- written API contracts and examples;
- multiple evidence files;
- local evidence and external Jam evidence.

Authority rules:

- `spec.md` governs functional requirements;
- the technical specification governs technical decisions;
- supporting evidence clarifies or proves behavior;
- evidence does not silently override explicit authority.

Material unresolved contradictions must block execution before implementation.

Non-material ambiguities may proceed only when:

- the chosen interpretation is recorded;
- the rationale is recorded;
- supporting evidence is cited;
- the decision does not silently change scope.

---

# 17. Input coverage

Every discovered local and external input must receive one final analysis status:

- inspected and used;
- inspected and supplementary;
- inspected and determined irrelevant;
- skipped with justification;
- unsupported;
- unavailable;
- authentication-required;
- failed to inspect.

The system must not require every file to affect implementation.

It must require every discovered input to be accounted for.

No relevant file may be silently ignored.

Executor summary and Reviewer report must each contain a concise input-coverage section.

---

# 18. Jam MCP capability

SpecRelay must support Jam recordings as first-class external specification evidence through an optional Jam MCP capability.

Jam is globally optional.

A SpecRelay installation and general `specrelay doctor` may remain usable when Jam is not configured.

However:

```text
Jam globally optional
+
Jam reference discovered in a task
=
Jam required for that task
```

A task containing a recognised Jam reference must not begin Executor implementation until Jam evidence has been retrieved, inspected, normalized, redacted, and snapshotted, or the task has been blocked with an actionable reason.

---

# 18.1 Jam reference discovery

SpecRelay must detect recognised Jam references in all inspectable local inputs, including:

- `spec.md`;
- `tech-spec.md`;
- `tech_spec.md`;
- supporting Markdown;
- plain text;
- logs;
- structured-data files where URL extraction is supported.

Every discovered Jam reference must be recorded in the input manifest.

Duplicate references to the same recording must resolve to one canonical external-evidence entry.

The manifest must retain provenance showing every local file that referenced it.

---

# 18.2 Jam adapter contract

Jam integration must use a first-class capability adapter.

The adapter must expose a stable internal contract for retrieving available Jam evidence, including where available:

- recording metadata;
- visual or recording context;
- transcript;
- reproduction steps;
- user events;
- console logs;
- console errors;
- network requests;
- network errors;
- browser information;
- device information;
- page URL;
- environment details.

SpecRelay core should depend on the internal adapter contract rather than unstable provider-specific MCP tool names.

---

# 18.3 Jam doctor reporting

`specrelay doctor` must report Jam readiness separately from repository context capabilities.

Doctor must distinguish at least:

- not configured;
- configured;
- registered;
- connected;
- authenticated;
- required tools available;
- ready.

Because Jam is globally optional:

- absence must not fail overall doctor readiness by default;
- project policy may explicitly make Jam globally required;
- a configured but broken Jam integration must be reported honestly;
- doctor output must include actionable failure detail.

Task preflight is stricter than general doctor.

A task containing a Jam reference must block before Executor invocation when Jam capability is not ready.

---

# 18.4 Jam retrieval phase

Jam retrieval must occur during specification-bundle analysis, before Executor invocation.

The Executor must not be solely responsible for opening or interpreting Jam links.

For each canonical Jam reference, SpecRelay must:

1. validate the reference;
2. perform capability readiness checks;
3. retrieve all available relevant evidence;
4. normalize the evidence;
5. apply redaction;
6. snapshot the normalized evidence;
7. record missing or failed evidence classes;
8. calculate integrity digests;
9. include Jam-derived findings in the resolved specification.

---

# 18.5 Jam snapshot layout

Each Jam recording must be stored beneath:

```text
01-input-bundle/external/jam/<canonical-id>/
```

Expected files, when available:

```text
reference.json
metadata.json
transcript.md
user-events.json
console-logs.json
console-errors.json
network-requests.json
network-errors.json
environment.json
retrieval-evidence.json
redaction-report.json
```

Executor, Reviewer, and resume must consume this same snapshot.

They must not independently retrieve a potentially changed Jam recording.

The original Jam URL must remain recorded for provenance.

A URL alone is not evidence of inspection.

---

# 18.6 Jam analysis

Jam analysis must correlate evidence classes rather than relying only on transcript text.

For defect and bug tasks, the resolved specification should derive, when evidence permits:

- reproduction sequence;
- triggering action;
- expected behavior;
- actual behavior;
- visible failure state;
- relevant console errors;
- stack traces;
- relevant network requests;
- endpoint;
- HTTP method;
- response status;
- timing;
- available request or response details;
- browser and environment context;
- correlated timeline;
- uncertainties and missing evidence.

Example correlated evidence:

```text
At 12.4s the user clicked Submit.
At 12.7s POST /offers returned HTTP 500.
At 12.8s the console emitted TypeError X.
At 13.1s the UI displayed an empty state.
```

Every material Jam-derived statement must cite its task-local Jam artifact.

Direct evidence and inference must be labeled separately.

---

# 18.7 Jam task-specific requirement semantics

Jam configuration may declare:

```text
required: false
```

This means Jam is not required for tasks containing no Jam reference.

When a Jam reference is discovered, the effective task requirement becomes required for that task and reference.

A referenced Jam must not be silently skipped.

The task must block before Executor implementation when:

- Jam MCP is unavailable;
- authentication is missing;
- required tools are unavailable;
- the recording is inaccessible;
- retrieval fails;
- required evidence cannot be inspected;
- evidence cannot be stored safely.

A project policy may classify an explicitly marked supplementary Jam reference as optional, but the default behavior for a Jam link inside a specification is required evidence.

---

# 18.8 Sensitive-data handling

Jam evidence may contain:

- credentials;
- authorization headers;
- access tokens;
- refresh tokens;
- cookies;
- session identifiers;
- customer information;
- financial information;
- request payloads;
- response payloads;
- mortgage application data;
- personal identifiers.

Raw unsafe evidence must not be persisted blindly.

Before durable snapshot storage, the Jam adapter must apply configured redaction.

At minimum, it must protect:

- authorization headers;
- access tokens;
- refresh tokens;
- cookies;
- session identifiers;
- recognized API keys;
- recognized secrets;
- configured personal-data patterns;
- configured financial-data patterns.

Redaction must produce:

```text
redaction-report.json
```

The report must record:

- artifact;
- redaction category;
- count;
- policy applied.

It must never preserve the removed secret value.

If evidence cannot be stored safely under active policy, the task must block.

---

# 19. Future complete artifact layout

A future specification must migrate task artifacts into a fully categorized numbered folder structure.

The target structure to preserve for future work is:

```text
<task-runtime>/
├── 00-task/
│   ├── state.json
│   └── task-metadata.json
│
├── 01-input/
│   ├── manifest.json
│   ├── local/
│   └── external/
│       └── jam/
│
├── 02-analysis/
│   ├── resolved-specification.md
│   ├── input-coverage.json
│   ├── conflicts.json
│   └── external-reference-status.json
│
├── 03-executor/
│   ├── prompt.md
│   ├── log.md
│   └── summary.md
│
├── 04-verification/
│   └── tests.txt
│
├── 05-reviewer/
│   ├── prompt.md
│   ├── review.md
│   └── business-summary.md
│
└── 06-telemetry/
    ├── timeline.json
    ├── command-timing.json
    └── efficiency.json
```

This complete migration is explicitly outside Spec 0023.

Spec 0023 must implement only the backward-compatible shared input layout from Section 10.

The future migration must be implemented as a separate specification and must not be forgotten.

---

# 20. Task inspection and reporting

`task show` must display concise bundle provenance:

- input kind;
- original input path;
- primary functional specification;
- technical specification;
- bundle file count;
- total bundle size;
- external reference count;
- Jam reference count;
- manifest path;
- snapshot path;
- resolved specification path;
- integrity status;
- analysis status.

A detailed command or detailed report may list every entry.

Default summary output must remain concise.

---

# 21. Completion gates

## 21.1 Analysis completion gate

Specification analysis must not complete successfully when:

- required `spec.md` is missing under active policy;
- both technical-specification filename variants exist;
- manifest and snapshot integrity do not match;
- a required local input cannot be inspected;
- a required Jam reference cannot be retrieved;
- required Jam capability is unavailable;
- unsafe evidence cannot be redacted;
- a material contradiction remains unresolved;
- input coverage is incomplete;
- `02-resolved-specification.md` is missing or empty;
- material derived statements lack provenance.

## 21.2 Executor completion gate

Executor completion must fail when:

- required evidence was silently ignored;
- unsupported or failed inputs were not disclosed;
- implementation relied on an external reference that was never retrieved;
- input coverage is missing;
- full coverage is claimed falsely;
- required verification was omitted;
- executor artifacts do not reference the immutable input bundle.

## 21.3 Reviewer completion gate

Reviewer completion must fail when:

- Reviewer did not receive the same immutable snapshot;
- Reviewer did not compare resolved specification against original evidence;
- material omitted evidence was not addressed;
- Jam evidence was assumed rather than inspected;
- unsupported or unavailable input was misrepresented;
- reviewer input coverage is missing.

---

# 22. Integrity and reproducibility

The implementation must prove:

- stable deterministic discovery ordering;
- SHA-256 digest generation;
- manifest-to-snapshot integrity checks;
- same snapshot for Executor and Reviewer;
- resume-safe reuse of snapshot;
- no silent reread from live source;
- no silent external evidence refresh;
- honest retrieval timestamps and statuses.

---

# 23. Backward compatibility

Existing single-file workflows must continue to work.

Existing task creation from a Markdown file must not require directory migration.

Existing artifact filenames may remain where they are, except for the newly introduced:

```text
01-input-manifest.json
01-input-bundle/
02-resolved-specification.md
```

Historical task state remains unchanged.

---

# 24. Required tests

The implementation must add focused tests for at least the following.

## 24.1 File and directory inputs

1. a single Markdown file still works;
2. a directory containing `spec.md` works;
3. a directory containing `spec.md` and `tech-spec.md` works;
4. `tech_spec.md` is recognized;
5. both technical filename variants fail with ambiguity;
6. missing required `spec.md` fails under default policy;
7. nested files are discovered;
8. discovery ordering is deterministic.

## 24.2 Local evidence

9. logs appear in the manifest;
10. JSON and structured data appear in the manifest;
11. images appear in the manifest;
12. PDFs appear in the manifest;
13. unsupported binary content is reported honestly;
14. escaping symlinks are rejected;
15. broken symlinks are rejected;
16. excluded directories are not captured;
17. size-limit violations fail clearly;
18. count-limit violations fail clearly;
19. partial silent ingestion never occurs.

## 24.3 Snapshot and resume

20. local files are snapshotted;
21. manifest digests match snapshots;
22. modifying the live source after task creation does not affect resume;
23. Executor and Reviewer receive the same snapshot;
24. resolved specification is created before Executor invocation.

## 24.4 Resolved specification

25. resolved specification includes functional requirements;
26. resolved specification includes technical requirements;
27. evidence-derived statements include provenance;
28. unresolved material contradictions block execution;
29. non-material interpretation records rationale;
30. every discovered file receives an analysis status;
31. irrelevant evidence may be skipped only with justification.

## 24.5 Jam capability

32. SpecRelay works without Jam when no Jam reference exists;
33. general doctor reports Jam optional and not configured without overall failure;
34. doctor reports configured/registered/connected/authenticated/tool-ready states;
35. a Jam reference makes Jam required for the task;
36. unavailable required Jam blocks before Executor invocation;
37. duplicate Jam URLs produce one canonical snapshot;
38. all referencing local files remain recorded as provenance;
39. transcript evidence is snapshotted when available;
40. user events are snapshotted when available;
41. console evidence is snapshotted when available;
42. network evidence is snapshotted when available;
43. environment evidence is snapshotted when available;
44. missing Jam evidence classes are reported honestly;
45. resolved specification includes Jam-derived findings with provenance;
46. Executor and Reviewer consume the same Jam snapshot;
47. resume does not retrieve a different Jam version;
48. Jam is never marked inspected when retrieval did not occur.

## 24.6 Redaction

49. authorization headers are redacted;
50. cookies and session identifiers are redacted;
51. token patterns are redacted;
52. redaction report records category and count;
53. removed values are not preserved;
54. unsafe unredactable evidence blocks the task.

## 24.7 Completion gates and reporting

55. analysis gate detects incomplete coverage;
56. Executor gate detects silent ignored required evidence;
57. Reviewer gate detects missing independent bundle comparison;
58. `task show` reports bundle provenance and integrity;
59. default task output remains concise;
60. existing single-file tests remain green.

---

# 25. Acceptance criteria

The specification is complete only when all of the following are proven:

1. `run` and `task create` accept a file or directory;
2. `spec.md` is treated as functional authority;
3. `tech-spec.md` and `tech_spec.md` are both supported;
4. both technical variants together fail clearly;
5. all accepted local evidence is snapshotted;
6. all evidence is represented in a deterministic manifest;
7. SpecRelay performs analysis before Executor invocation;
8. `02-resolved-specification.md` is generated;
9. material derived requirements have provenance;
10. Executor receives resolved specification plus original snapshot;
11. Reviewer independently receives and checks the same snapshot;
12. no relevant input is silently ignored;
13. every input has a coverage status;
14. material conflicts block implementation;
15. Jam is globally optional;
16. a discovered Jam link makes Jam required for that task;
17. Jam doctor reports meaningful readiness states;
18. Jam evidence is retrieved before Executor invocation;
19. Jam evidence is snapshotted and reused;
20. transcript, user events, console, network, and environment evidence are used when available;
21. Jam-derived defect timelines can be represented;
22. unavailable Jam evidence is reported honestly;
23. sensitive Jam data is redacted before storage;
24. redaction evidence is durable and does not preserve secrets;
25. live source changes do not affect resume;
26. external evidence is not silently refreshed on resume;
27. completion gates reject incomplete or dishonest coverage;
28. existing single-file workflows remain compatible;
29. default terminal output remains concise;
30. the future full artifact-layout migration remains explicitly documented as follow-up work.

---

# 26. Documentation requirements

Update at least:

- README;
- command documentation;
- task lifecycle documentation;
- provider/capability documentation;
- doctor documentation;
- artifact documentation;
- security/redaction documentation;
- release notes or changelog;
- migration or backward-compatibility notes.

Documentation must include:

- file input example;
- directory input example;
- accepted technical-spec filenames;
- Jam configuration example;
- Jam optional-global/required-per-task semantics;
- shared input bundle layout;
- resolved specification lifecycle;
- security warnings for external evidence;
- future artifact-layout migration note.

---

# 27. Operational constraints

The Executor implementing this specification must:

- split work into bounded internal phases;
- write required executor artifacts before optional expensive verification;
- avoid repeated full-suite execution;
- use isolated temporary directories for bundle and Jam adapter tests;
- never mutate real installed SpecRelay during automated tests;
- never retrieve real private Jam recordings during automated tests;
- use fakes or fixtures for Jam MCP tests;
- redact secrets in all recorded test fixtures;
- report unsupported provider capabilities honestly.

The Reviewer must prioritize:

- immutable input integrity;
- Jam task-specific preflight;
- redaction safety;
- evidence provenance;
- resume reproducibility;
- completion-gate correctness;
- backward compatibility.

---

# 28. Recommended implementation phases

The task may remain one specification, but implementation should be internally split into:

1. input path abstraction;
2. directory convention and validation;
3. manifest and local snapshot;
4. content classification;
5. resolved-specification analysis;
6. Executor and Reviewer prompt integration;
7. input-coverage artifacts;
8. completion gates;
9. Jam capability adapter;
10. Jam doctor and task preflight;
11. Jam retrieval and normalization;
12. redaction;
13. reporting;
14. focused tests;
15. documentation;
16. bounded release verification.

---

# 29. Release behavior

This specification has release impact:

```text
minor
```

If the current released version is `0.5.0`, successful release preparation should propose:

```text
0.6.0
```

Release commands must remain operator-controlled.

The implementation must not commit, push, or tag automatically.
