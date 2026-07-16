# Spec 0027 — Local Developer Configuration Overlay

## 1. Status

```yaml
status: proposed
```

## 2. Release metadata

```yaml
release:
  impact: minor
  rationale: Adds a backward-compatible local configuration overlay that lets each developer override shared SpecRelay configuration without committing personal settings or secrets.
```

## 3. Task identity

```yaml
task_id: 0027-local-developer-configuration-overlay
```

## 4. Objective

Add a first-class local developer configuration file that may override any supported shared SpecRelay configuration value without requiring developers to modify the committed project configuration.

The project keeps its shared configuration in:

```text
.specrelay/config.yml
```

A developer may optionally create:

```text
.specrelay/config.local.yml
```

The local file is ignored by Git, contains only overrides, and is merged deterministically on top of the shared configuration.

The feature must preserve reproducibility, safety, task resume behavior, clear configuration provenance, and backward compatibility.

---

## 5. Background

SpecRelay currently supports a committed project configuration and a limited set of environment-variable overrides.

This is insufficient for normal team development because developers may need different local values for:

- provider selection;
- model selection;
- role-specific agents;
- Context adapter settings;
- verification commands;
- service paths;
- timeouts;
- local executable paths;
- optional integrations;
- credentials or local-only endpoints;
- performance-related settings;
- temporary experimental configuration.

Editing the shared configuration creates unnecessary Git noise and merge conflicts. Repeating complete configuration blocks in an ignored file is also undesirable.

The desired model is a sparse overlay:

```yaml
# .specrelay/config.local.yml
roles:
  executor:
    model: claude-sonnet-5
verification:
  services:
    products:
      checks:
        unit:
          timeout_seconds: 900
```

Only the changed values need to be present.

---

## 6. Product decision

SpecRelay will support two project configuration layers:

1. Shared committed configuration:

```text
.specrelay/config.yml
```

2. Optional local developer overlay:

```text
.specrelay/config.local.yml
```

The effective configuration is produced by deterministic deep merge.

The local file:

- is optional;
- is never required for other developers;
- must be ignored by Git;
- may override any supported configuration key;
- must not require a full copy of the shared configuration;
- must not silently introduce unknown keys;
- must not change the effective configuration of an already-started task after that task has captured its effective settings.

---

## 7. Configuration precedence

The required precedence order, from lowest to highest priority, is:

```text
built-in defaults
  < .specrelay/config.yml
  < .specrelay/config.local.yml
  < supported environment-variable overrides
  < explicit CLI flags
```

Higher layers override lower layers only where they provide a value.

The implementation must document and test this exact order.

No code path may use a different precedence order.

---

## 8. Merge semantics

### 8.1 Mapping values

Mappings are merged recursively.

Example:

```yaml
# shared
roles:
  executor:
    provider: claude
    model: provider-default
    agent: none
```

```yaml
# local
roles:
  executor:
    model: claude-sonnet-5
```

Effective result:

```yaml
roles:
  executor:
    provider: claude
    model: claude-sonnet-5
    agent: none
```

### 8.2 Scalar values

A scalar in the higher-priority layer replaces the lower-priority scalar.

### 8.3 Lists

Lists are replaced as complete values by default.

Lists must not be concatenated implicitly because implicit concatenation can create duplicate commands, duplicate services, or ambiguous order.

If future list-specific merge behavior is required, it must be introduced by a later specification with an explicit schema rule.

### 8.4 Null values

The implementation must define one deterministic rule for explicit YAML `null`.

Required rule:

```text
null means remove the inherited value from the merged raw configuration.
```

After removal, normal built-in defaults may still apply where the existing configuration accessor defines a default.

The behavior must be documented and tested.

### 8.5 Type conflicts

A higher layer may not silently replace a mapping with a scalar, or a scalar with a mapping, when the schema expects a fixed type.

Such conflicts must fail validation with a path-specific error.

Example:

```text
.specrelay/config.local.yml: roles.executor must be a mapping, got string
```

---

## 9. Supported scope

The local overlay may override every currently supported project configuration area, including but not limited to:

- `project`;
- `specs`;
- `runtime`;
- `roles.executor`;
- `roles.reviewer`;
- `roles.coordinator`;
- role model/provider/agent values;
- role context configuration;
- Context adapter configuration;
- verification policy;
- multi-service verification configuration;
- execution-efficiency policy;
- phase budgets;
- update notification behavior where project configuration already supports it;
- future configuration keys added through the normal schema.

The implementation must not maintain a separate reduced schema for the local file.

The same schema validation applies after merge.

---

## 10. Secret handling

The local overlay may contain local-only sensitive values, but SpecRelay must not expose them unnecessarily.

Requirements:

- `config.local.yml` must be Git-ignored;
- `specrelay doctor`, `project inspect`, task reports, error messages, logs, and effective-configuration artifacts must redact secret-like values;
- secrets must not be copied into task evidence in plain text;
- environment-variable values must remain redacted under existing policy;
- configuration provenance may name the local file and key path without printing the secret value;
- if a value cannot be represented safely in durable task evidence, store a redacted marker rather than the value.

Examples of secret-like paths include:

```text
*.token
*.api_key
*.apikey
*.secret
*.password
*.cookie
*.authorization
*.credential
```

The implementation should reuse an existing centralized redaction mechanism where possible rather than creating inconsistent per-command redaction.

---

## 11. Git ignore behavior

### 11.1 Project initialization

`specrelay init` must ensure the repository Git ignore rules contain:

```text
.specrelay/config.local.yml
```

It must add the entry idempotently.

It must not duplicate the line.

It must not remove or reorder unrelated user entries.

### 11.2 Existing projects

`doctor` must report when local config exists but is not ignored by Git.

This must be a warning or failure according to whether the file contains secret-like fields:

- no detected secret-like fields: warning;
- detected secret-like fields and file is trackable: failure.

SpecRelay must not automatically modify `.gitignore` during `run` or `resume`.

Only `init` or an explicit future repair command may change Git ignore configuration.

### 11.3 Repository cleanliness

The local file must not be treated as an unrelated dirty-tree change once correctly ignored.

---

## 12. Configuration discovery

Configuration discovery must be deterministic.

For a discovered SpecRelay project root:

```text
<root>/.specrelay/config.yml
<root>/.specrelay/config.local.yml
```

Only the local file from the same project root may be loaded.

SpecRelay must not search parent directories, the user's home directory, arbitrary global paths, or adjacent repositories for a local project overlay under this specification.

A future specification may introduce user-global defaults, but this specification does not.

---

## 13. Validation behavior

The implementation must validate:

- shared YAML syntax;
- local YAML syntax;
- root type of each file;
- merge type compatibility;
- unknown keys;
- supported values;
- provider/model/agent configuration;
- Context adapter configuration;
- verification policy;
- multi-service checks;
- role-specific configuration;
- all existing schema constraints.

Validation errors must identify:

- the configuration source;
- the effective key path;
- the reason;
- whether the error occurred before merge, during merge, or after merged-schema validation.

Example:

```text
Invalid local configuration:
  source: .specrelay/config.local.yml
  path: verification.services.products.checks.unit.timeout_seconds
  error: expected a non-negative integer, got "fast"
```

Invalid local configuration must fail before any task enters `EXECUTOR_RUNNING`, `REVIEWER_RUNNING`, or invokes the Coordinator.

---

## 14. Effective configuration capture

SpecRelay already captures effective role and policy configuration for task reproducibility.

This specification extends that contract.

At task creation or first relevant use, the task must durably record:

- whether shared configuration was present;
- whether local configuration was present;
- cryptographic digest of each loaded configuration file;
- precedence layers used;
- effective configuration relevant to task execution, with secrets redacted;
- provenance for overridden values;
- whether environment variables or CLI flags changed a value;
- capture timestamp.

Suggested structure in `state.json` or a dedicated current-layout artifact:

```json
{
  "configuration_effective": {
    "schema_version": 1,
    "sources": [
      {
        "kind": "shared",
        "path": ".specrelay/config.yml",
        "sha256": "..."
      },
      {
        "kind": "local",
        "path": ".specrelay/config.local.yml",
        "sha256": "..."
      }
    ],
    "precedence": [
      "defaults",
      "shared",
      "local",
      "environment",
      "cli"
    ],
    "captured_at": "..."
  }
}
```

The full future numbered artifact-layout migration is not part of this specification.

---

## 15. Resume behavior

A task must not silently change configuration when resumed.

Required behavior:

1. A newly created task captures the effective configuration and source digests.
2. `resume` compares current source digests against captured digests.
3. If the shared or local file changed in a way relevant to the task:
   - SpecRelay must not silently adopt the new configuration;
   - the task continues using captured effective configuration where supported;
   - if safe continuation from the captured configuration is impossible, block with a clear explanation.
4. The operator may create a new task to use the new configuration.

This applies equally to:

- provider/model/agent selection;
- Context adapter selection;
- verification policy;
- Coordinator configuration;
- phase budgets;
- execution-efficiency settings.

The task must never switch models, verification commands, or service definitions on resume merely because a developer changed `config.local.yml`.

---

## 16. CLI behavior

### 16.1 `specrelay project inspect`

Extend the read-only output to show:

```text
Shared configuration: .specrelay/config.yml
Local overlay: .specrelay/config.local.yml (loaded|not present|invalid)
Effective precedence: defaults < shared < local < environment < CLI
```

It must not print secret values.

### 16.2 New command: `specrelay config show`

Add:

```text
specrelay config show [--effective] [--sources] [--json]
```

Required behavior:

- default output: concise configuration status;
- `--sources`: show loaded sources and digests;
- `--effective`: show merged effective configuration with secrets redacted;
- `--json`: machine-readable equivalent;
- command is read-only;
- no task is created;
- no configuration file is modified.

### 16.3 New command: `specrelay config explain <path>`

Add:

```text
specrelay config explain roles.executor.model
```

Output must identify:

- final redacted value;
- source layer that supplied it;
- overridden lower-priority values, redacted when necessary;
- whether the value came from defaults, shared, local, environment, or CLI.

Example:

```text
roles.executor.model = claude-sonnet-5
source: .specrelay/config.local.yml
replaced: provider-default from .specrelay/config.yml
```

For secret paths:

```text
integrations.example.token = [REDACTED]
source: .specrelay/config.local.yml
```

### 16.4 Unknown command behavior

CLI help and `docs/commands.md` must document the new configuration commands.

---

## 17. Doctor behavior

`doctor` must report configuration readiness as a separate section.

At minimum:

```text
Shared configuration: present / missing / invalid
Local overlay: not present / present / invalid
Local overlay Git ignore: safe / unsafe
Merge: valid / invalid
Schema: valid / invalid
Secret exposure risk: none detected / unsafe
Effective configuration capture: ready
```

Doctor must distinguish:

- no local file;
- valid local file;
- malformed local YAML;
- type conflict during merge;
- invalid merged schema;
- local file not ignored;
- local file contains potential secret and is trackable.

A missing local file is not an error.

---

## 18. Configuration provenance

The merge engine must retain provenance internally for each effective leaf value.

Example internal representation:

```json
{
  "path": "roles.executor.model",
  "value": "claude-sonnet-5",
  "source_kind": "local",
  "source_path": ".specrelay/config.local.yml",
  "overrode": [
    {
      "source_kind": "shared",
      "value": "provider-default"
    }
  ]
}
```

Provenance is required for:

- `config explain`;
- debugging;
- task configuration capture;
- reproducibility;
- Reviewer evidence;
- future user-global configuration layers.

The implementation must not reconstruct provenance heuristically after merge.

---

## 19. Environment-variable compatibility

Existing supported environment-variable overrides must continue to work.

This specification must:

- inventory existing environment overrides;
- preserve their behavior;
- place them above the local file in precedence;
- document them centrally;
- ensure task capture records that an environment override was used without storing secret values;
- add regression tests proving environment variables override local values.

The implementation must not add generic arbitrary environment-variable mapping for every YAML path unless such behavior already exists and is safe.

---

## 20. CLI-flag compatibility

Existing explicit CLI flags remain highest priority.

The implementation must inventory flags that alter task behavior and record their contribution to effective configuration where relevant.

This specification does not require introducing a CLI flag for every configuration key.

---

## 21. Backward compatibility

When `.specrelay/config.local.yml` does not exist:

- configuration behavior must remain unchanged;
- existing projects must not require migration;
- existing tests must continue to pass;
- task state from older versions must remain readable;
- `doctor` may report `Local overlay: not present`, but must not fail;
- `specrelay init` may add the ignore entry idempotently.

Historical tasks without configuration-source metadata must report:

```text
configuration provenance: not recorded
```

They must not fabricate source digests or provenance.

---

## 22. Security boundaries

The implementation must not:

- execute values from configuration merely while showing or validating configuration;
- expand shell substitutions during YAML loading;
- interpolate `${...}`, backticks, or command substitutions in arbitrary YAML strings unless an existing explicit field contract already does so during execution;
- log secrets;
- copy the local file wholesale into task evidence;
- expose secret values through JSON output;
- follow symlinks outside the project root for the local configuration file;
- load a local file owned by another project root;
- automatically commit or push the local file;
- modify local configuration during `run`, `resume`, `doctor`, `config show`, or `config explain`.

If `.specrelay/config.local.yml` is a symlink, required behavior is:

```text
reject when the resolved target is outside the project root
```

The error must be explicit.

---

## 23. Atomic and consistent reads

A command invocation must read each configuration file once, compute its digest from the same bytes, and use that same in-memory content for parsing and merging.

It must not:

1. read the file for the digest;
2. read it again later for parsing;
3. silently accept different content between reads.

This prevents inconsistent task capture when a file changes during command startup.

---

## 24. Error and fallback policy

There is no permissive fallback from an invalid local overlay.

If the local file exists but is invalid:

- do not silently ignore it;
- do not continue using only shared configuration;
- fail before role invocation;
- show an actionable error.

A developer who does not want the overlay must remove or rename the file.

This prevents a typo in local verification or model configuration from silently running with different settings.

---

## 25. Configuration examples

Create a committed example file:

```text
.specrelay/config.local.example.yml
```

It must:

- contain no secrets;
- show sparse override examples;
- explain precedence;
- explain that lists replace rather than append;
- explain `null` removal behavior;
- point to `docs/configuration.md`;
- remain optional.

Example:

```yaml
# Copy to .specrelay/config.local.yml for personal overrides.
# This example file is safe to commit; config.local.yml is Git-ignored.

roles:
  executor:
    model: claude-sonnet-5

verification:
  execution:
    max_parallel_checks: 4
```

---

## 26. Interaction with multi-service verification

Spec 0026 introduced configurable verification policy and multi-service execution.

The local overlay must support safe developer-specific overrides such as:

```yaml
verification:
  services:
    frontend:
      checks:
        unit:
          command: npm test
          timeout_seconds: 900
```

However:

- local overrides must not silently remove required shared checks unless the schema explicitly permits disabling them;
- attempts to disable a required check must be validated according to the shared policy contract;
- the effective verification plan recorded for a task remains authoritative on resume;
- local-only command paths must be shown in effective configuration provenance but must not expose credentials.

The implementation must add focused tests for this integration.

---

## 27. Interaction with Coordinator

The Coordinator may receive redacted effective configuration facts when relevant to a decision.

It must not receive:

- raw local configuration content;
- secret values;
- unrestricted configuration provenance unrelated to the decision;
- permission to edit configuration files.

Coordinator decisions must not be able to change configuration precedence or configuration files.

---

## 28. Interaction with Context adapters

Role-specific Context adapter configuration may be overridden locally.

The task must capture the effective adapter and its relevant redacted options.

Changing local Context configuration after task creation must not silently change a resumed task.

Doctor must report Context readiness based on the merged effective configuration, while still identifying which source supplied the adapter selection.

---

## 29. Interaction with installed and source-local execution

Both execution modes must use the same project configuration discovery and precedence rules.

Installed SpecRelay must not store the local overlay inside the installation directory.

Source-local execution must not treat the SpecRelay repository's own local overlay as configuration for another consumer repository.

The project root remains the configuration boundary.

---

## 30. Out of scope

This specification does not:

- introduce user-global configuration such as `~/.config/specrelay/config.yml`;
- introduce organization-level remote configuration;
- sync local configuration between developers;
- encrypt the local file;
- create a secret manager;
- add arbitrary environment variables for every YAML path;
- change the full task artifact directory layout;
- add epic/ticket hierarchical context;
- add UI runtime or screenshot verification;
- change the human final review gate;
- automatically repair invalid configuration;
- automatically commit, push, tag, or release.

---

## 31. Required implementation areas

At minimum, inspect and update where necessary:

```text
lib/specrelay/config.sh
lib/specrelay/cli.sh
lib/specrelay/doctor.sh
lib/specrelay/project_init.sh
lib/specrelay/workflow.sh
lib/specrelay/task.sh
lib/specrelay/state.sh
lib/specrelay/summary.sh
lib/specrelay/py/*
bin/specrelay
templates/project/config.yml
templates/project-config.yml
README.md
docs/configuration.md
docs/commands.md
docs/architecture.md
docs/task-lifecycle.md
docs/operator-recovery.md
docs/roadmap/architecture-roadmap.md
docs/roadmap/current-plan.md
.gitignore
```

The exact implementation structure should follow repository conventions discovered during implementation.

---

## 32. Required tests

At minimum add deterministic tests for the following.

### 32.1 No local file

Existing configuration behavior remains unchanged.

### 32.2 Sparse deep override

A local nested scalar overrides only the specified value and preserves sibling values.

### 32.3 List replacement

A local list replaces, and does not concatenate with, the shared list.

### 32.4 Null removal

A local `null` removes the inherited raw value and allows existing default behavior to apply.

### 32.5 Type conflict

Mapping/scalar conflicts fail with source and key path.

### 32.6 Invalid local YAML

Malformed local YAML fails before task role invocation.

### 32.7 Unknown key

Unknown local keys fail under the same schema rules as shared configuration.

### 32.8 Precedence

Prove:

```text
defaults < shared < local < environment < CLI
```

### 32.9 Git ignore initialization

`init` adds `.specrelay/config.local.yml` exactly once without disturbing unrelated entries.

### 32.10 Git ignore warning

Doctor reports a present local file that is not ignored.

### 32.11 Secret exposure failure

Doctor fails when a trackable local file contains a secret-like key.

### 32.12 Redaction

`config show`, `config explain`, doctor, task report, and JSON output never print secret values.

### 32.13 Symlink outside project

A local config symlink resolving outside the project root is rejected.

### 32.14 Config show

Shows source status and redacted effective configuration.

### 32.15 Config explain

Reports final source and overridden source for a normal scalar.

### 32.16 Config explain secret

Reports provenance but redacts the value.

### 32.17 Task effective capture

Task state records source digests, precedence, redacted effective settings, and provenance metadata.

### 32.18 Resume unchanged

Resume succeeds when current source digests match captured digests.

### 32.19 Resume changed local config

Resume does not silently adopt a changed local model, Context adapter, or verification command.

### 32.20 Historical task

A task without configuration metadata reports `not recorded` honestly.

### 32.21 Multi-service integration

Local verification overrides are applied and captured correctly.

### 32.22 Required verification protection

Local config cannot silently disable a shared required verification check.

### 32.23 Coordinator isolation

Coordinator input contains only redacted relevant effective configuration facts.

### 32.24 Source-local/installed parity

Both execution modes resolve the same project configuration sources and precedence.

### 32.25 Atomic read

The bytes used for digest and parse are the same snapshot.

### 32.26 No command expansion during inspection

A configuration string containing shell syntax is printed as data and never executed by `config show` or `config explain`.

### 32.27 Full regression suite

Run the complete standalone test suite once under the active verification policy.

Pre-existing unrelated failures must be proved against a clean baseline rather than silently dismissed.

---

## 33. Fake-provider and fixture behavior

Tests must not require a real AI provider.

Use temporary repositories and fake providers to prove:

- task creation captures effective configuration;
- role selection uses the merged value;
- resume preserves captured value;
- invalid local config prevents provider launch.

---

## 34. Documentation requirements

Update documentation to explain:

- why local config exists;
- file name and location;
- Git ignore behavior;
- complete precedence order;
- deep-merge rules;
- list replacement;
- null removal;
- secret-handling limits;
- `config show` and `config explain`;
- task capture and resume behavior;
- multi-service verification examples;
- no user-global config under this specification.

Documentation must not imply that the local file is committed.

Documentation must not tell developers to duplicate the whole shared configuration.

---

## 35. Architecture roadmap update

Update the architecture roadmap and current plan after implementation.

Record this capability as:

```text
Local developer configuration overlay
```

It must be placed before UI runtime and visual verification because developer-local browser paths, credentials, service startup commands, test data, and timeouts may need local overrides.

The roadmap must retain the future item for:

```text
Epic/ticket hierarchical context
```

That capability is not implemented by this specification.

---

## 36. Completion gates

The task may reach `READY_FOR_REVIEW` only when:

- local config discovery works;
- deterministic merge works;
- precedence is enforced;
- schema validation applies to merged configuration;
- local config is ignored safely;
- secret values are redacted;
- `config show` works;
- `config explain` works;
- effective configuration is captured for tasks;
- resume does not silently drift;
- multi-service verification integration passes;
- required checks cannot be silently disabled;
- documentation is updated;
- focused tests pass;
- full suite is run once;
- required Executor artifacts are complete;
- `08-executor-summary.md` contains `## Input Coverage`.

The Reviewer may ACCEPT only when it independently verifies:

- precedence;
- merge correctness;
- secret redaction;
- invalid-config fail-fast behavior;
- resume reproducibility;
- no command execution during config inspection;
- Git ignore safety;
- backward compatibility without a local file.

---

## 37. Required Executor summary sections

`08-executor-summary.md` must include:

```markdown
## Configuration Layering
```

```markdown
## Merge and Precedence
```

```markdown
## Secret Safety
```

```markdown
## Task Reproducibility
```

```markdown
## Backward Compatibility
```

```markdown
## Input Coverage
```

---

## 38. Required Reviewer section

`09-consultant-review.md` must include:

```markdown
## Local Configuration Safety Review
```

It must cover:

- source discovery;
- precedence;
- deep merge;
- type conflicts;
- Git ignore behavior;
- secret redaction;
- symlink boundaries;
- task capture;
- resume drift prevention;
- environment/CLI precedence;
- backward compatibility.

An ACCEPT decision is invalid without this section.

---

## 39. Acceptance criteria

The specification is complete when all of the following are true:

1. `.specrelay/config.local.yml` is optional and Git-ignored.
2. Developers may provide sparse overrides without copying shared config.
3. Effective precedence is exactly documented and enforced.
4. Mappings deep-merge; lists replace; null removes inherited raw values.
5. Invalid local config never falls back silently.
6. All merged configuration uses the existing full schema.
7. Secret values are not exposed in terminal output, JSON, logs, or task evidence.
8. `specrelay config show` reports redacted effective configuration.
9. `specrelay config explain` reports value provenance.
10. Task configuration is captured with digests and provenance.
11. Resume never silently adopts changed local configuration.
12. Existing projects without local config behave unchanged.
13. Multi-service verification overrides work safely.
14. Required shared checks cannot be silently disabled.
15. Installed and source-local modes behave consistently.
16. All required tests and documentation updates are complete.

---

## 40. Risk analysis

### High — secrets accidentally enter durable evidence

Mitigation:

- central redaction;
- never snapshot full local file;
- dedicated secret-output tests;
- Reviewer safety section.

### High — resume silently changes model or verification commands

Mitigation:

- capture-once effective configuration;
- source digests;
- no silent live re-read on resume.

### High — local overlay disables required verification

Mitigation:

- merged-schema validation;
- shared-policy protection;
- explicit test proving refusal.

### Medium — complex merge semantics surprise developers

Mitigation:

- only recursive mappings;
- list replacement;
- explicit null rule;
- `config explain` provenance.

### Medium — unignored local file is committed

Mitigation:

- init adds ignore rule;
- doctor warning/failure;
- example file uses a different committed filename.

### Medium — future schema keys require duplicate overlay work

Mitigation:

- one merged schema, not a separate local schema.

### Low — local file changes during startup

Mitigation:

- single-read snapshot used for digest and parsing.

---

## 41. Rollback behavior

Disabling this capability operationally is achieved by removing or renaming:

```text
.specrelay/config.local.yml
```

With no local file, behavior returns to the pre-0027 shared-config model.

Code rollback must preserve readability of historical task state containing configuration provenance metadata.

Rollback must not require deletion of task evidence.

---

## 42. Expected implementation order

1. Inventory existing configuration accessors, environment overrides, and CLI flags.
2. Define one merged configuration representation with per-leaf provenance.
3. Implement single-read source loading and digests.
4. Implement deep merge, list replacement, null removal, and type-conflict detection.
5. Apply existing schema validation to the merged result.
6. Replace direct shared-file reads with the effective configuration interface.
7. Add task capture and resume drift handling.
8. Add `config show` and `config explain`.
9. Add doctor and Git ignore integration.
10. Integrate verification, Coordinator, Context, and role configuration.
11. Add focused deterministic tests.
12. Update documentation and roadmap.
13. Run the full suite once.
14. Complete Executor artifacts and independent Reviewer safety review.

---

## 43. Deliverables

At minimum:

- local configuration discovery;
- merge engine;
- provenance tracking;
- redaction-safe effective configuration reporting;
- task effective configuration capture;
- resume drift prevention;
- Git ignore integration;
- `specrelay config show`;
- `specrelay config explain`;
- doctor reporting;
- committed local example config;
- deterministic focused tests;
- updated documentation;
- updated architecture roadmap and current plan.

---

## 44. Final definition of done

This task is done only when a developer can create a small ignored local override file, run SpecRelay with those overrides, inspect exactly where every effective value came from, avoid leaking secrets, and resume the task later without SpecRelay silently switching to newly changed local settings.

The final architecture must still satisfy:

```text
Shared configuration defines team policy.
Local configuration defines personal overrides.
Environment variables and CLI flags remain explicit higher-priority inputs.
Task-captured effective configuration preserves reproducibility.
```

