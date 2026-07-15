
Spec 0024 — Remove Obsolete In-Host Legacy Surfaces

1. Status

proposed

2. Release metadata

release:
  impact: minor
  rationale: Removes obsolete in-host SpecRelay compatibility surfaces, tests, code paths, templates, fixtures, and current-documentation references so the standalone repository has one coherent supported architecture.

3. Task identity

0024-remove-obsolete-in-host-legacy-surfaces

4. Objective

Remove obsolete architecture, code, tests, templates, fixtures, commands, and current-documentation references that belong to the former in-host SpecRelay model.

The standalone SpecRelay repository must expose one coherent supported architecture:

* source-local execution through bin/specrelay;
* installed execution through specrelay;
* consumer configuration through .specrelay/config.yml;
* consumer task runtime through .specrelay-runs/;
* SpecRelay source owned only by the standalone SpecRelay repository;
* no required copy of SpecRelay source inside consumer repositories;
* no supported runtime dependency on .ai/scripts/;
* no supported runtime dependency on tools/specrelay/.

This is a deliberate cleanup and simplification task.

The implementation must not preserve obsolete compatibility behavior merely because historical tests, documentation, fixtures, or code still reference it.

⸻

5. Background

SpecRelay originally existed inside host repositories under paths such as:

tools/specrelay/
.ai/scripts/

Legacy scripts included names such as:

start-spec-task.sh
show-task.sh
approve-task.sh
run-ai-loop.sh
authorize-submit.sh
new-task.sh

The product has since migrated to a standalone, versioned repository with its own source-local and installed execution modes.

The current architecture is:

Standalone source checkout:
  bin/specrelay
Installed CLI:
  specrelay
Consumer project configuration:
  .specrelay/config.yml
Consumer runtime:
  .specrelay-runs/

The repository still contains assumptions, tests, wording, fixtures, migration leftovers, or code paths referring to the previous in-host model.

These leftovers create real costs:

* failing or misleading tests;
* contradictory documentation;
* unnecessary compatibility code;
* confusing ownership boundaries;
* false expectations that a consumer project should contain SpecRelay source;
* maintenance of unsupported scripts and layouts;
* incorrect migration and release guidance;
* difficulty understanding the current product contract.

This specification removes those obsolete surfaces.

⸻

6. Product decision

The former in-host architecture is no longer a supported product surface.

The repository must not preserve compatibility with:

.ai/scripts/
tools/specrelay/

except where a reference is retained solely as clearly labelled historical documentation.

No runtime, test, template, fixture, installation flow, migration flow, or current documentation may require those paths.

The following are not accepted reasons for retaining legacy behavior:

* an old test expects it;
* an old document mentions it;
* a prior migration once used it;
* a compatibility shim previously existed;
* deleting it reduces historical test count;
* maintaining it appears inexpensive;
* the code still works;
* the path may be useful someday.

Legacy compatibility may remain only if the implementation finds a current, explicit, user-facing support commitment in authoritative product documentation.

Any such exception must be:

* identified explicitly;
* justified in task evidence;
* supported by current tests;
* approved during review.

The default decision is removal.

⸻

7. Authoritative current architecture

After this task, executable behavior and current documentation must agree on the following architecture.

7.1 Source-local execution

Inside the standalone SpecRelay checkout:

bin/specrelay <command>

or:

./bin/specrelay <command>

Source-local execution uses the current checkout.

It must not perform installed-CLI update checks.

7.2 Installed execution

Inside a consumer repository or any compatible working directory:

specrelay <command>

The installed CLI resolves its installed resources according to the current installation contract.

Installed mode may perform update behavior according to existing policy.

7.3 Consumer project ownership

A consumer project may own:

.specrelay/config.yml
.specrelay/version
.specrelay-runs/
its own specs
its own source code

A consumer project must not own or vendor the SpecRelay source tree.

7.4 Standalone repository ownership

The standalone SpecRelay repository owns:

bin/
lib/
install/
templates/
test/
docs/
VERSION
release metadata

7.5 Unsupported paths

The following are not part of the current supported architecture:

.ai/scripts/
tools/specrelay/

⸻

8. Scope

This task must audit and clean all relevant repository areas, including:

README.md
CHANGELOG.md
bin/
lib/
templates/
test/
scripts/
install/
docs/
docs/specs/

The audit must cover tracked files and generated templates distributed with SpecRelay.

The task must search for at least these terms and paths:

.ai/scripts
.ai-runs
tools/specrelay
start-spec-task.sh
show-task.sh
approve-task.sh
run-ai-loop.sh
authorize-submit.sh
new-task.sh
legacy workflow
compatibility shim
legacy shim
in-host
in-repo vendor
vendored SpecRelay
host-owned SpecRelay

Searches must be case-insensitive where appropriate and cover:

* shell scripts;
* Markdown;
* YAML;
* JSON;
* templates;
* test fixtures;
* help output;
* comments;
* examples.

⸻

9. Out of scope

This task does not:

* redesign the standalone installer;
* redesign the update mechanism;
* redesign task recovery;
* redesign test-level policies;
* introduce Playwright or UI verification;
* migrate the complete numbered artifact layout;
* rewrite Git history;
* remove valid historical release notes solely because they mention previous behavior;
* add a new compatibility layer;
* preserve permanent dual-mode support.

A minimal adjustment to installer, recovery, or tests is allowed only where required to remove obsolete legacy dependencies safely.

⸻

10. Legacy-reference classification

Every discovered legacy reference must be classified into exactly one of the following categories.

10.1 Current executable dependency

A runtime, installer, CLI, library, or generated code path actively depends on legacy behavior.

Required action:

remove or replace

10.2 Current test dependency

A current test expects, creates, copies, or invokes a legacy layout.

Required action:

remove the obsolete test or replace it with a test of the current standalone contract

A legacy fixture must not be preserved solely to keep an obsolete test alive.

10.3 Current documentation

A document presents legacy behavior as current, recommended, required, or supported.

Required action:

rewrite or remove

10.4 Template or generated output

A template generates or references legacy paths.

Required action:

remove or update

10.5 Historical documentation

A historical report, migration record, old accepted spec, release note, or dogfood report describes behavior that existed at that time.

Required action:

retain only when historically useful and clearly label as historical and unsupported

Historical content must not be rewritten in a way that falsifies the record.

10.6 Ambiguous reference

It is unclear whether the reference is current or historical.

Required action:

investigate and resolve before completion

Ambiguous references may not be ignored.

⸻

11. Required inventory artifact

Before deleting or rewriting legacy surfaces, the Executor must create this task-runtime artifact:

legacy-surface-inventory.md

The inventory must include:

* path;
* line, symbol, or section;
* detected legacy reference;
* classification;
* current behavior impact;
* decision;
* action taken;
* justification;
* replacement behavior, where relevant;
* verification method.

Example:

| Path | Reference | Classification | Decision | Action |
|---|---|---|---|---|
| test/compat_shim_test.sh | tools/specrelay | Current test dependency | Remove | Deleted obsolete compatibility test |
| docs/dogfood-report-0085b-realprovider.md | .ai/scripts | Historical documentation | Retain | Added historical/no-longer-supported notice |

Every remaining legacy search result must appear in this inventory.

The inventory is evidence and does not replace implementation.

⸻

12. Code cleanup requirements

12.1 Remove runtime dependencies

Remove any active code path that:

* resolves SpecRelay from tools/specrelay;
* expects .ai/scripts inside a consumer repository;
* delegates current commands through legacy host scripts;
* copies SpecRelay source into a consumer repository;
* installs from an in-host vendored source tree;
* treats a consumer repository as owner of SpecRelay source;
* emits instructions telling users to invoke legacy scripts;
* falls back to legacy paths when current resolution fails.

12.2 Remove obsolete compatibility helpers

Remove helpers whose only purpose is compatibility with the unsupported in-host architecture.

Examples may include:

* legacy shim discovery;
* legacy path fallback;
* compatibility banners;
* legacy command translation;
* old argument translation;
* host-vendored source resolution;
* legacy submit wrappers;
* old host-script orchestration;
* compatibility environment-variable translation.

Removal must cover:

* function definitions;
* source statements;
* call sites;
* help output;
* docs;
* tests;
* fixtures;
* templates;
* comments.

12.3 No renamed compatibility layer

Do not replace old paths with renamed equivalents that preserve the same unsupported architecture.

This is not acceptable:

tools/specrelay -> vendor/specrelay

The source must remain standalone.

12.4 Preserve current standalone behavior

Cleanup must not break:

bin/specrelay version
bin/specrelay doctor
bin/specrelay help
bin/specrelay run <input-path>
specrelay version

It must also preserve:

* installation from the standalone checkout;
* current update behavior;
* current release behavior;
* task lifecycle;
* config discovery;
* .specrelay-runs/ task storage;
* file and directory input support;
* Context Plus integration;
* Jam integration;
* current evidence capture.

⸻

13. Test cleanup requirements

13.1 Delete obsolete tests

Delete tests whose primary purpose is validating unsupported in-host behavior.

This includes tests requiring:

.ai/scripts/
tools/specrelay/

or invoking scripts such as:

start-spec-task.sh
show-task.sh
run-ai-loop.sh
approve-task.sh
authorize-submit.sh
new-task.sh

13.2 Remove suite references

When deleting a test, remove it from:

* serial-test lists;
* explicit test manifests;
* CI configuration;
* helper registries;
* documentation;
* test-count expectations;
* release verification lists;
* shell comments listing expected test files.

13.3 Replace still-valid coverage

If an obsolete test indirectly covered behavior that is still valid, add or retain a current-contract test.

Examples:

* task creation through bin/specrelay run;
* installed CLI invocation;
* task lookup;
* exit-code propagation;
* paths containing spaces;
* dirty-tree behavior;
* version pin behavior;
* installed resource resolution;
* task-runtime creation;
* project initialization.

The replacement test must exercise the current standalone interface directly.

13.4 No fake legacy fixture

Do not add a fixture containing:

.ai/scripts/
tools/specrelay/

to preserve obsolete compatibility coverage.

13.5 Test names must describe current behavior

Test names and comments must not describe unsupported concepts as current.

References such as these must be removed unless explicitly historical:

shim
legacy engine
host vendor
direct tools/specrelay command
in-host workflow

⸻

14. Documentation cleanup requirements

14.1 Current documentation

Current documentation must use only the supported standalone architecture.

At minimum audit:

README.md
docs/architecture.md
docs/commands.md
docs/configuration.md
docs/task-lifecycle.md
docs/current-workflow-contract.md
docs/engine-parity.md
docs/providers.md
docs/operator-recovery.md
docs/verification-and-timeline.md
docs/migration.md
docs/release-process.md
docs/versioning.md

Current documentation must not instruct users to:

* create .ai/scripts;
* invoke .ai/scripts scripts;
* keep SpecRelay under tools/specrelay;
* copy SpecRelay source into consumer repositories;
* use legacy shims as the normal interface;
* treat a consumer repository as owner of SpecRelay;
* use .ai-runs/ as the canonical current runtime.

14.2 Historical documentation

Historical documents may retain old names only when:

* they are genuinely historical;
* preserving the reference is useful;
* a clear notice appears near the beginning;
* the notice says the architecture is no longer supported;
* the document points readers to current architecture documentation.

Recommended notice:

> Historical document: this report describes the former in-host SpecRelay architecture.
> `.ai/scripts/` and `tools/specrelay/` are no longer supported current product surfaces.
> See README.md and docs/architecture.md for the standalone architecture.

Equivalent wording is acceptable.

14.3 Migration documentation

docs/migration.md may describe migration away from legacy paths.

It must clearly distinguish:

from: unsupported old in-host layout
to: current standalone layout

It must not imply that both layouts remain supported.

14.4 Historical specs

Accepted historical specs must not be rewritten as though they originally specified the current architecture.

They may receive a short historical notice when needed to prevent confusion.

14.5 Terminology normalization

Use these terms consistently:

standalone SpecRelay repository
source-local CLI
installed CLI
consumer project
project configuration
task runtime
input path

Avoid presenting these as current concepts:

host vendor
vendored tool
legacy shim
in-host engine
tools/specrelay command
.ai script workflow

⸻

15. Template cleanup requirements

Audit all templates for generated legacy behavior.

Templates must not generate:

.ai/scripts/
tools/specrelay/

Templates must not instruct users to copy SpecRelay source into a consumer repository.

Project initialization may generate:

.specrelay/config.yml
.specrelay/version

where consistent with current supported initialization.

Executor and Reviewer templates must mention only current commands, paths, and task artifacts.

⸻

16. Installation cleanup requirements

Installation must use the standalone checkout as its source.

The installer must not:

* search for tools/specrelay;
* assume invocation from a host repository;
* copy from a consumer repository’s vendored source;
* emit legacy paths as current usage;
* create .ai/scripts;
* create a permanent source copy in consumer repositories.

Installed files must resolve their resources relative to the installed prefix according to the current installation design.

⸻

17. CLI and help cleanup requirements

CLI help must not advertise legacy scripts or paths.

Current help must describe:

bin/specrelay
specrelay
run <input-path>
task create <input-path>
.specrelay/config.yml
.specrelay-runs/

All remaining <spec-path> wording must be reviewed.

Use:

<input-path>

where the command accepts either:

* a single spec file;
* a specification directory.

Use <spec-path> only where the implementation truly requires one concrete spec file.

⸻

18. Runtime directory terminology

The canonical current task runtime is:

.specrelay-runs/

Current code, tests, help, templates, and documentation must not present:

.ai-runs/

as the canonical runtime.

Historical .ai-runs/ references may remain only under the historical-document rules.

Tests must default to .specrelay-runs/ unless explicitly verifying a supported migration behavior.

⸻

19. Engine ownership terminology

Current tasks are owned by:

engine: specrelay

Documentation must not describe the former script collection as a second current engine.

If engine-parity documentation remains, it must clearly state:

* the legacy side is historical;
* standalone SpecRelay is the only current supported engine;
* parity rows are migration evidence;
* parity does not represent a continuing compatibility promise.

If an engine-parity document no longer provides current value, it may be moved to a historical area or removed.

⸻

20. Required repository searches

The Executor must run and record broad searches before and after cleanup.

At minimum:

grep -RInE '\.ai/scripts|tools/specrelay|start-spec-task\.sh|show-task\.sh|approve-task\.sh|run-ai-loop\.sh|authorize-submit\.sh|new-task\.sh' README.md CHANGELOG.md bin lib templates test scripts install docs

And:

grep -RInE '\.ai-runs|in-host|vendored SpecRelay|host-owned SpecRelay|compatibility shim|legacy shim' README.md CHANGELOG.md bin lib templates test scripts install docs

Equivalent rg commands are acceptable.

Missing optional directories must not cause the audit to fail.

Searches must cover tracked content, not .git or task-runtime evidence unless intentionally inspected.

⸻

21. Allowed remaining references

After cleanup, legacy references may remain only in:

1. clearly labelled historical reports;
2. historical accepted specs;
3. changelog entries describing past versions;
4. migration documentation explicitly describing removal;
5. this specification;
6. task evidence generated by this task.

Every remaining result must be individually accounted for in:

legacy-surface-inventory.md

An unreviewed broad-search result is not acceptable.

⸻

22. Forbidden remaining references

After cleanup, none of the following may remain in current executable or generated product surfaces:

* runtime resolution of tools/specrelay;
* required .ai/scripts lookup;
* test fixtures copying tools/specrelay;
* tests invoking .ai/scripts/start-spec-task.sh;
* templates generating legacy paths;
* README instructions using legacy paths;
* CLI help recommending legacy paths;
* installer logic sourcing from a consumer repository’s vendored copy;
* current workflow docs treating shims as supported;
* fallback behavior silently enabling the old architecture.

⸻

23. Backward compatibility policy

This cleanup intentionally removes unsupported legacy compatibility.

The implementation must not silently support both architectures.

Users of old in-host layouts must migrate to the standalone CLI.

Migration guidance must state:

1. Install SpecRelay from the standalone repository.
2. Keep project configuration under .specrelay/.
3. Invoke source-local SpecRelay with bin/specrelay only from the standalone checkout.
4. Invoke the installed CLI with specrelay from consumer repositories.
5. Remove obsolete tools/specrelay copies.
6. Remove obsolete .ai/scripts wrappers used only for SpecRelay.

No automatic copying of old source trees is required.

⸻

24. Deletion safety

Before deleting a file, determine whether it contains still-valid behavior.

If a legacy test covers a current requirement:

* delete the legacy test;
* add direct current-contract coverage.

If a legacy helper contains reusable generic behavior:

* preserve only the generic behavior;
* move it to an appropriately named current module;
* remove legacy assumptions and naming;
* add direct tests.

Deletion must not reduce current product behavior or test coverage without a justified replacement.

⸻

25. Automated legacy-reference gate

Add an automated verification mechanism that detects reintroduction of forbidden legacy references in current product surfaces.

The gate must inspect at least:

README.md
bin/
lib/
templates/
test/
scripts/
install/
current operational docs

It may exclude explicitly historical files through an exact allowlist.

The allowlist must:

* name exact files;
* avoid broad directory wildcards where possible;
* document why each file is historical;
* fail when a new unclassified result appears.

The gate must not exclude all of docs/ or all historical specs without individual accountability.

⸻

26. Verification requirements

26.1 Static search verification

Run all required legacy-reference searches after cleanup.

Every result must be:

* historical and labelled;
* migration-specific and accurate;
* part of this spec or task evidence;
* otherwise removed.

26.2 Syntax checks

Run syntax checks for every modified shell file.

At minimum:

bash -n bin/specrelay

and all modified .sh files.

26.3 Focused tests

Run tests covering at least:

* CLI help and parsing;
* source-local execution;
* installation and installed resource resolution;
* task creation;
* task execution;
* task lookup and show;
* dirty-tree guard;
* project initialization;
* templates;
* update behavior affected by cleanup;
* release behavior affected by cleanup;
* current task-runtime directory behavior.

26.4 Full suite

Run the full test suite once after focused tests pass.

The full suite must run in the foreground under Executor ownership.

Do not:

* start an unowned background full-suite process;
* poll indefinitely;
* rely on a completion notification that may not arrive;
* claim success before the command exits;
* run repeated full suites without recorded justification.

26.5 Smoke verification

Verify:

bin/specrelay version
bin/specrelay doctor
bin/specrelay help

Verify a temporary consumer project can use the supported CLI without:

.ai/
tools/

26.6 Installation verification

Install SpecRelay from the standalone checkout into a temporary prefix.

Verify:

<prefix>/bin/specrelay version
<prefix>/bin/specrelay help

The installed CLI must work without:

.ai/scripts/
tools/specrelay/

⸻

27. Required test cases

At minimum, add or update tests for the following.

27.1 Source-local version

bin/specrelay version succeeds from the standalone checkout.

27.2 Source-local help

bin/specrelay help contains current commands and no legacy-path instructions.

27.3 Temporary installation

install/install.sh installs from the standalone checkout into a temporary prefix.

27.4 Installed version

The temporary installed CLI reports its version without repository-relative legacy paths.

27.5 Installed help

The temporary installed CLI help contains no legacy-path instructions.

27.6 Consumer project operation

A temporary consumer project can initialize and use SpecRelay without tools/specrelay.

27.7 No .ai/scripts requirement

A temporary consumer project with no .ai directory can run supported commands.

27.8 No vendored source requirement

A temporary consumer project with no tools directory can run supported commands.

27.9 Input path support

run and task create support the current file-or-directory input contract.

27.10 Paths containing spaces

A supported direct CLI command handles an input path containing spaces without legacy shims.

27.11 Exit-code propagation

Direct current CLI invocation returns the correct non-zero exit code for invalid input.

27.12 Runtime location

New task runtime is created under .specrelay-runs/.

27.13 Project initialization

Project initialization does not generate .ai/scripts or tools/specrelay.

27.14 Legacy-reference regression gate

The verification gate fails when a forbidden legacy reference is added to a current executable, template, test, or current documentation file.

27.15 Historical allowlist behavior

Explicitly allowed historical references pass only when the exact file is allowlisted.

27.16 New unclassified historical reference

A new legacy reference in a non-allowlisted file causes verification failure.

⸻

28. Executor artifact priority

This task must not repeat the Spec 0023 failure pattern.

The Executor must create and maintain:

03-executor-log.md
07-tests.txt
08-executor-summary.md

before any optional long-running verification.

These files may initially contain accurate work-in-progress information and must be updated after final verification.

The Executor must not:

* postpone all artifact writing until after the full suite;
* start an unowned background test;
* wait indefinitely;
* exit with missing artifacts;
* claim full-suite success without an observed exit code;
* claim test success based only on partial logs.

⸻

29. Test evidence format

07-tests.txt must record for every relevant command:

* exact command;
* working directory;
* test type;
* exit code;
* result;
* test count where available;
* failure count;
* relevant output summary;
* duration where available.

Example:

COMMAND: bash test/cli_test.sh
WORKING_DIRECTORY: <repository-root>
TYPE: focused
EXIT_CODE: 0
RESULT: PASS
SUMMARY: 20 tests, 0 failures

Test types may include:

syntax
focused
smoke
installation
full-suite
static-search

The Executor summary must not state that tests passed without matching evidence.

⸻

30. Required Executor summary sections

08-executor-summary.md must contain:

## Deleted Legacy Surfaces

This section must enumerate:

* deleted code;
* deleted tests;
* deleted fixtures;
* removed template behavior;
* removed current documentation sections;
* removed help output;
* removed installer behavior;
* replacement tests.

It must also contain:

## Retained Historical References

This section must list exact paths and reasons.

It must also contain:

## Current Standalone Contract

describing the final supported architecture.

⸻

31. Reviewer requirements

The Reviewer must independently verify the cleanup.

The Reviewer must:

1. inspect legacy-surface-inventory.md;
2. independently run legacy-reference searches;
3. challenge every remaining reference;
4. verify no executable dependency remains;
5. verify deleted tests were genuinely obsolete;
6. verify still-valid behavior has replacement coverage;
7. run targeted tests independently;
8. inspect temporary installation behavior;
9. inspect current documentation;
10. inspect templates and project initialization;
11. verify the cleanup did not merely rename legacy paths;
12. verify historical records are labelled clearly;
13. verify current architecture is coherent.

The Reviewer must classify risk as at least:

medium

Risk may be classified as high if core workflow, CLI, installer, update, or release code changes.

⸻

32. Required Reviewer section

09-consultant-review.md must contain:

## Legacy Surface Coverage

This section must list:

* search commands or terms used;
* remaining results;
* why each remaining result is allowed;
* removed executable surfaces;
* removed tests;
* replacement tests;
* current documentation changes;
* template changes;
* installer verification;
* unresolved references, if any.

An ACCEPT decision is invalid without this section.

⸻

33. Completion gates

The task may reach READY_FOR_REVIEW only when:

* required Executor artifacts are non-empty;
* legacy-surface-inventory.md exists;
* every discovered reference is classified;
* focused tests pass;
* the full suite passes;
* source-local smoke passes;
* temporary installation smoke passes;
* current documentation contains no unsupported instructions;
* no executable dependency on .ai/scripts remains;
* no executable dependency on tools/specrelay remains;
* no template generates legacy paths;
* every remaining historical reference is accounted for;
* the automated legacy-reference gate passes.

The Reviewer may ACCEPT only when:

* independent targeted verification passes;
* the required Reviewer section exists;
* historical references are clearly labelled;
* no unsupported compatibility promise remains;
* the standalone architecture is coherent across code, tests, templates, installer, and documentation.

⸻

34. Acceptance criteria

AC-01 — One supported architecture

The repository implements and documents the standalone architecture as the only current supported architecture.

AC-02 — No current .ai/scripts dependency

No runtime, installer, template, test, or current documentation requires .ai/scripts/.

AC-03 — No current tools/specrelay dependency

No runtime, installer, template, test, or current documentation requires tools/specrelay/.

AC-04 — Obsolete compatibility tests removed

Tests whose primary purpose is validating the former in-host layout are removed.

AC-05 — Current behavior remains covered

Still-valid behavior formerly covered by legacy tests has direct current-contract coverage.

AC-06 — Current documentation rewritten

README and current operational documentation use only current paths and commands.

AC-07 — Historical records remain truthful

Historical records are retained only where useful and clearly labelled as unsupported historical architecture.

AC-08 — Templates are clean

Generated project templates do not create or reference unsupported legacy paths.

AC-09 — Installer is standalone

Installation has no dependency on a host-vendored SpecRelay tree.

AC-10 — CLI help is current

Help output advertises current commands and paths only.

AC-11 — Runtime terminology is current

.specrelay-runs/ is the canonical task-runtime path.

AC-12 — Inventory is complete

Every discovered legacy reference has a classification, action, and justification.

AC-13 — Search gate exists

A regression gate detects reintroduction of forbidden legacy references.

AC-14 — Focused tests pass

All relevant focused tests pass.

AC-15 — Full suite passes

The full repository test suite passes.

AC-16 — Installed smoke passes

A temporary standalone installation runs successfully.

AC-17 — No hidden compatibility layer

Unsupported legacy behavior is not retained under renamed paths, wrappers, aliases, or fallback logic.

AC-18 — Migration guidance is unambiguous

Migration documentation tells users to remove the old layout rather than maintain dual-mode operation.

⸻

35. Historical-reference allowlist

If automated search verification requires an allowlist, it must:

* contain exact file paths;
* state why each path is historical;
* avoid broad directory wildcards;
* be reviewed during this task;
* fail when a new unclassified reference appears.

Possible categories include:

CHANGELOG.md
specific historical dogfood reports
specific accepted migration specs
specific migration documentation

An allowlist entry does not automatically make the content acceptable.

Where appropriate, the document must still contain a historical notice.

⸻

36. Migration note

Add or update concise guidance for users of the old in-host layout.

It must state:

* the old layout is unsupported;
* remove .ai/scripts wrappers used only for SpecRelay;
* remove tools/specrelay;
* install SpecRelay from the standalone repository;
* configure consumer repositories through .specrelay/;
* use specrelay in consumer repositories;
* use bin/specrelay only inside the standalone source checkout;
* do not maintain both architectures.

⸻

37. Risk analysis

Primary risks:

* deleting still-valid generic behavior;
* reducing test coverage;
* rewriting historical records inaccurately;
* leaving hidden fallback paths;
* installation regressions;
* incomplete current documentation;
* broad allowlists hiding future regressions;
* accidental removal of update or release behavior;
* cleanup based only on filenames rather than runtime call paths.

Mitigations:

* inventory before deletion;
* call-site analysis;
* replacement current-contract tests;
* temporary installation smoke;
* independent Reviewer searches;
* exact historical allowlist;
* full suite;
* migration guidance;
* no dual-mode fallback.

⸻

38. Rollback behavior

This cleanup must be implemented as ordinary repository changes.

The Executor must not automatically:

* commit;
* push;
* tag;
* release.

If verification fails:

* preserve evidence;
* keep the task recoverable;
* report exact current behavior that failed;
* do not restore the entire legacy architecture as a shortcut;
* restore only still-valid behavior using the current standalone design.

⸻

39. Documentation source of truth

After completion:

* README.md is the primary user entry point;
* docs/architecture.md defines standalone ownership;
* docs/commands.md defines supported commands;
* docs/configuration.md defines .specrelay/config.yml;
* docs/task-lifecycle.md defines .specrelay-runs/;
* docs/migration.md explains migration away from in-host layouts.

Historical documents must defer to those current sources.

⸻

40. Recommended implementation order

1. run broad repository searches;
2. create legacy-surface-inventory.md;
3. classify every result;
4. identify executable legacy dependencies;
5. remove obsolete runtime code;
6. remove obsolete tests and suite references;
7. add replacement current-contract tests;
8. clean templates;
9. clean installer behavior;
10. rewrite current documentation;
11. label retained historical documentation;
12. add migration guidance;
13. add an exact regression search gate;
14. run syntax verification;
15. run focused tests;
16. write or update required Executor artifacts;
17. run one foreground full suite;
18. run temporary installation smoke;
19. update inventory and summary;
20. submit for independent review.

This order is guidance, but no discovered legacy surface may be skipped.

⸻

41. Deliverables

Required repository deliverables:

* cleaned runtime code;
* cleaned CLI and help;
* cleaned installation behavior;
* cleaned templates;
* removed obsolete tests;
* replacement standalone-contract tests;
* updated current documentation;
* labelled historical documents;
* migration guidance;
* automated legacy-reference regression gate.

Required task-runtime deliverables:

legacy-surface-inventory.md
03-executor-log.md
07-tests.txt
08-executor-summary.md
09-consultant-review.md
10-business-summary.md

⸻

42. Release behavior

This specification has release impact:

minor

If the current version is:

0.6.0

successful release preparation should propose:

0.7.0

Release commands remain operator-controlled.

The implementation must not commit, push, tag, or release automatically.

⸻

43. Runner-owned workflow transitions

The Executor owns:

* repository analysis;
* implementation;
* tests;
* documentation;
* required Executor artifacts.

The Executor does not own:

* task state transitions;
* review decisions;
* human acceptance;
* Git commit, push, or tag;
* release commands.

The Executor must not:

* run specrelay task submit;
* run specrelay task accept;
* run specrelay task request-changes;
* run specrelay run or specrelay resume for this task;
* edit state.json;
* fabricate workflow metadata;
* bypass the working-tree guard manually.

The SpecRelay orchestrator owns lifecycle transitions.

⸻

44. Context capability

When Context Plus is configured as required, preflight must complete before Executor and Reviewer execution.

The Executor must use repository context to identify:

* current standalone architecture decisions;
* historical migration decisions;
* current installer behavior;
* update and release contracts;
* current test organization;
* legacy compatibility surfaces.

The Reviewer must independently inspect the repository and may not rely solely on the Executor inventory.

⸻

45. Final definition of done

This task is complete only when a new contributor can inspect the standalone SpecRelay repository and see one clear supported architecture without needing to understand, maintain, or recreate the former in-host model.

A consumer repository must not require:

.ai/scripts/
tools/specrelay/

to install, configure, run, inspect, recover, review, or release SpecRelay tasks.

Historical documentation may explain where the project came from, but it must not define how the product works today.
