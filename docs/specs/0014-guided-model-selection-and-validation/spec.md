# Guided Model Selection and Validation
- Spec: 0014
- Status: Draft
---
# Summary
Make role model configuration discoverable, understandable, and safer.
SpecRelay currently supports explicit executor and reviewer model configuration,
but users must already know the exact provider-specific model syntax.
An invalid value can therefore survive configuration parsing, be captured into
task state, enter `EXECUTOR_RUNNING`, and fail only after the provider starts.
This specification introduces:
- a model-discovery command
- an explicit model-selection syntax
- provider-aware validation
- actionable configuration errors
- clear configured-versus-resolved model reporting
- safe compatibility with existing string-based model configuration
The implementation must not pretend to know models that cannot be reliably
discovered or validated.
---
# Problem
Current configuration may look like:
```yaml
roles:
  executor:
    provider: claude
    model: fable-5

This is syntactically valid as a non-empty string, but the user does not know
whether the provider expects:

fable-5
claude-fable-5
claude-fable-5-<version>

or whether the model exists at all.

The task can then be created and enter:

EXECUTOR_RUNNING

before the provider rejects the value.

This produces several usability and workflow problems:

* model syntax must be guessed
* mistakes are discovered too late
* invalid model values are durably captured into task state
* failed tasks must be deleted or recovered
* error messages come from the provider rather than SpecRelay guidance
* executor and reviewer configuration is harder to audit
* different providers may use different model naming conventions

⸻

Goals

* Let users inspect model-selection options before editing configuration.
* Clearly distinguish provider default, semantic alias, and raw provider ID.
* Validate model configuration as early as reliably possible.
* Produce actionable errors containing valid configuration examples.
* Prevent known-invalid model configuration from entering role execution.
* Show both configured and resolved model values.
* Preserve current configurations and task-state compatibility.
* Keep provider-specific knowledge inside provider capability adapters.
* Avoid stale or fabricated global model lists.

⸻

Non-Goals

This specification does not:

* guarantee remote account access to every listed model
* make billable provider requests merely to validate configuration
* automatically choose the cheapest or most capable model
* add fallback model chains
* benchmark models
* estimate cost
* manage provider subscriptions
* install or upgrade provider CLIs
* change executor or reviewer lifecycle semantics
* change model selection for already-created tasks without explicit action

⸻

Design Principles

1. No guessing

SpecRelay must not invent provider model identifiers.

2. No false certainty

If a provider CLI cannot reliably list or validate models, SpecRelay must say so.

3. Provider-owned capabilities

Provider-specific model knowledge belongs in provider adapters or capability
modules, not in generic workflow code.

4. Early feedback

Known configuration errors must be reported before claiming a task for role
execution.

5. Deterministic existing tasks

A task’s durable roles_effective model configuration remains authoritative
after task creation.

⸻

Model Selection Forms

SpecRelay must support three explicit model-selection concepts.

Provider Default

model: provider-default

Meaning:

* do not pass an explicit model argument
* allow the provider to choose its configured default

The literal string provider-default must never be passed as a remote model ID.

⸻

Semantic Alias

Preferred structured form:

model:
  alias: opus

or:

model:
  alias: sonnet

Aliases are provider-specific.

An alias is valid only when the selected provider declares support for it.

SpecRelay must resolve the alias through that provider’s capability adapter.

The generic engine must not assume that every provider supports aliases such as:

opus
sonnet
haiku
default

Aliases must not silently cross provider boundaries.

For example, an alias supported by Claude must not automatically be accepted for
Codex.

⸻

Raw Provider Model ID

Advanced structured form:

model:
  id: <exact-provider-model-id>

The value must be passed to the provider exactly as configured, subject only to
structural validation.

SpecRelay must not rewrite, normalize, prefix, suffix, or guess a raw model ID.

⸻

Backward Compatibility

Existing string configuration remains valid:

model: provider-default
model: some-provider-model-id

For backward compatibility, a non-default string must continue to mean:

model:
  id: some-provider-model-id

The recommended documented syntax for new explicit raw identifiers is:

model:
  id: some-provider-model-id

Existing task state and existing configuration files must not require migration.

⸻

Invalid Structured Forms

The following must be rejected:

model: {}
model:
  alias:
model:
  id:
model:
  alias: opus
  id: some-id
model:
  unknown_key: value
model:
  alias:
    nested: value

A model selection must resolve to exactly one of:

provider-default
alias
raw id

⸻

New CLI Command

Introduce:

bin/specrelay models

This command displays model-selection guidance for configured automated
providers.

Also support:

bin/specrelay models <provider>

Examples:

bin/specrelay models claude
bin/specrelay models claude-subagent

If aliases or providers share the same underlying adapter, the implementation
may reuse capability data while clearly reporting the configured provider name.

⸻

Models Command Output

The output must be stream-friendly, append-only, copyable, and usable without
color.

Example shape:

Provider: claude
Configuration forms:
  Provider default:
    model: provider-default
  Semantic alias:
    model:
      alias: <alias>
  Exact provider model ID:
    model:
      id: <provider-model-id>
Supported aliases:
  opus
  sonnet
Provider model discovery:
  unavailable
SpecRelay cannot reliably enumerate every model available to this account.
Use an exact model ID from the provider's own documentation or CLI.

The command must clearly distinguish:

* SpecRelay-declared aliases
* dynamically discovered provider models
* configured model values
* values that cannot be verified locally

⸻

Capability Result Model

Provider capability discovery must conceptually return structured information
such as:

provider
supports_explicit_model
supports_aliases
declared_aliases
supports_model_discovery
discovered_models
discovery_source
validation_level
notes

The exact internal representation may follow repository conventions.

Generic CLI and workflow code must consume this provider capability result
rather than embedding provider-specific conditionals throughout the engine.

⸻

Discovery Levels

Each provider must declare one of the following practical capability levels.

Exact Discovery

The provider exposes a reliable, non-billable machine-readable list of model
identifiers available to the current environment or account.

SpecRelay may display and validate against that list.

Declared Aliases Only

The provider does not expose a reliable complete model list, but SpecRelay can
safely support a small adapter-owned set of provider-recognized aliases.

SpecRelay may validate aliases but must not claim to list all remote models.

Structural Validation Only

The provider exposes neither reliable discovery nor safe aliases.

SpecRelay may validate configuration shape and forwarding behavior only.

It must state that model availability will ultimately be validated by the
provider.

No Explicit Model Support

The provider does not support model selection.

Explicit alias or raw-ID configuration must fail before role execution.

⸻

Provider Alias Contract

Aliases must be:

* provider-scoped
* explicitly declared by the adapter
* stable enough to document
* resolved deterministically
* covered by tests

An adapter may resolve an alias either to:

* a provider-recognized alias argument
* an exact provider model identifier

The resolution must be visible in diagnostics.

SpecRelay must not create aliases merely because a model family name sounds
plausible.

⸻

Configured and Resolved Values

For each role, SpecRelay must retain two concepts:

configured model
resolved model

Examples:

configured: provider-default
resolved: provider-managed default
configured: alias:opus
resolved: opus

or, when the adapter resolves to an exact identifier:

configured: alias:opus
resolved: <exact-provider-model-id>
configured: id:<raw-provider-model-id>
resolved: <raw-provider-model-id>

The implementation must not fabricate an exact resolved model when the provider
default remains unknown.

⸻

Task State

Task state must continue to retain the effective executable role configuration.

The implementation may extend roles_effective to preserve model-selection
metadata.

Conceptual example:

{
  "roles_effective": {
    "executor": {
      "provider": "claude",
      "model": "<resolved-model-value>",
      "model_configured": {
        "kind": "alias",
        "value": "opus"
      },
      "agent": "none"
    }
  }
}

Exact schema changes must follow current state compatibility conventions.

Requirements:

* old state files remain readable
* new state data remains JSON-compatible
* resume uses durable task configuration
* aliases are not silently re-resolved differently after task creation
* raw IDs remain unchanged
* provider-default remains distinguishable from a known exact model

⸻

Validation Timing

Model configuration must be validated during task preflight before the role is
claimed.

Known-invalid configuration must fail before:

READY_FOR_EXECUTOR -> EXECUTOR_RUNNING

and before:

READY_FOR_REVIEW -> REVIEWER_RUNNING

where applicable.

Validation should occur early enough that the provider is not launched with a
known-invalid configuration.

Task creation may still occur before validation if that matches current
architecture, but a known-invalid model must not enter a running role state.

⸻

Validation Rules

Provider Default

Always structurally valid for automated providers that support their own default.

It must cause omission of the provider model argument.

Alias

Valid only if declared by the selected provider adapter.

Unknown alias must be rejected before provider execution.

Raw ID with Exact Discovery

If the provider exposes a reliable authoritative list, an unknown ID may be
rejected locally.

Raw ID without Exact Discovery

A non-empty structurally valid raw ID must be forwarded.

SpecRelay must warn or explain that availability cannot be locally guaranteed,
but it must not falsely reject the ID based on an incomplete list.

Manual Provider

Model selection is not executed.

The implementation must preserve existing manual-role behavior and clearly
document whether model fields are ignored or rejected for manual roles.

No billable or automated provider call may occur for a manual role.

⸻

Actionable Errors

An invalid alias error must resemble:

specrelay: invalid executor model alias 'fable-5' for provider 'claude'
Supported aliases:
  opus
  sonnet
Use the provider default:
  model: provider-default
Or configure an exact provider model ID:
  model:
    id: <exact-provider-model-id>
Inspect model options with:
  bin/specrelay models claude

A malformed structured model error must identify:

* role
* provider
* invalid configuration
* expected forms
* config source where available

A provider-discovery failure must not be misreported as an invalid user model.

⸻

Similar-Value Suggestions

For unknown aliases, SpecRelay should provide a nearest-match suggestion when
the match is unambiguous and implementation remains lightweight.

Example:

Unknown alias: opuss
Did you mean: opus

This is optional for raw provider IDs because SpecRelay may not possess a
complete authoritative list.

Suggestions must never silently rewrite configuration.

⸻

Doctor Integration

Enhance:

bin/specrelay doctor

For each role, report:

role
provider
configured model
resolved model
model selection kind
validation level
configuration source

Example:

Executor:
  provider:          claude
  configured model: alias:opus
  resolved model:   opus
  validation:       provider-declared alias
  source:           .specrelay/config.yml

For provider default:

Reviewer:
  provider:          claude-subagent
  configured model: provider-default
  resolved model:   provider-managed default
  validation:       structural

Doctor must not claim account availability unless the provider supports reliable
non-billable discovery.

⸻

Task Show Integration

task show must display durable model information for the existing task.

It must not silently replace the task’s captured model with current project
configuration.

Where new structured metadata exists, show it in a readable form.

Old tasks containing only a string model must remain displayable.

⸻

Provider Invocation

After model selection is validated and resolved:

* provider-default omits the explicit model argument
* aliases use the adapter’s deterministic resolved argument
* raw IDs are forwarded exactly
* executor and reviewer selections remain isolated
* durable task configuration controls resume

The implementation must reuse the model-forwarding behavior introduced by
previous model-configuration work rather than creating a second invocation path.

⸻

Configuration Documentation

Update documentation with complete examples.

Provider default

roles:
  executor:
    provider: claude
    model: provider-default
    agent: none

Semantic alias

roles:
  executor:
    provider: claude
    model:
      alias: opus
    agent: none

Raw provider ID

roles:
  executor:
    provider: claude
    model:
      id: <exact-provider-model-id>
    agent: none

Different selections by role

roles:
  executor:
    provider: claude
    model:
      alias: sonnet
    agent: none
  reviewer:
    provider: claude-subagent
    model:
      alias: opus
    agent: ai-reviewer

Documentation must explain that aliases are provider-specific.

⸻

Help and Usage

The main CLI help or commands documentation must include:

specrelay models [provider]

Unknown providers must produce an actionable error and list configured or
supported provider names where safely available.

⸻

Fake Provider

Extend the fake provider capability implementation so tests can simulate:

* exact discovery
* aliases-only discovery
* structural-only validation
* unsupported explicit model selection
* discovery failure

Tests must not require live Claude, Codex, or other remote calls.

Fake invocation evidence must continue proving the selected resolved model was
passed to the correct role.

⸻

Required Tests

Configuration Parsing

* provider-default string remains valid
* legacy raw string remains valid
* structured alias parses
* structured raw ID parses
* alias plus ID is rejected
* empty alias is rejected
* empty ID is rejected
* unknown model keys are rejected
* executor and reviewer remain isolated

Alias Resolution

* known alias resolves for the correct provider
* unknown alias is rejected
* alias from one provider is rejected for another provider
* alias resolution is deterministic
* resolved alias reaches provider invocation

Raw IDs

* raw ID is preserved byte-for-byte as a string value
* raw ID reaches provider invocation
* raw ID is not prefixed or rewritten
* structural-only providers do not falsely reject valid-looking raw IDs

Provider Default

* provider-default omits provider model argument
* provider-default is displayed clearly
* literal provider-default is never forwarded remotely

Models Command

* models displays configured providers
* models <provider> displays configuration forms
* declared aliases are shown
* discovery capability is reported honestly
* discovery failure is distinguishable from invalid configuration
* output is copyable and non-interactive
* unknown provider produces useful guidance

Validation Timing

* known-invalid alias is rejected before executor claim
* known-invalid alias does not enter EXECUTOR_RUNNING
* known-invalid reviewer alias does not enter REVIEWER_RUNNING
* provider is not invoked after local validation failure

Durable State and Resume

* configured selection kind is captured
* resolved value is captured
* old task state remains readable
* changing alias mappings or config after task creation does not silently alter
    an existing task
* resume uses captured resolved values

Doctor

* configured and resolved models are displayed
* validation level is displayed
* provider-default is not misrepresented as an exact model
* doctor does not require a billable invocation

Compatibility

* existing string configurations remain valid
* existing tests remain green
* manual provider behavior remains compatible
* previous explicit model forwarding remains correct

⸻

Acceptance Criteria

This specification is accepted only when:

* users can run bin/specrelay models
* users can inspect one provider with bin/specrelay models <provider>
* supported configuration forms are displayed
* provider aliases are explicitly provider-scoped
* raw model IDs have an unambiguous structured syntax
* legacy string syntax remains compatible
* known-invalid aliases fail before role execution
* actionable errors show valid alternatives and commands
* configured and resolved model values are distinguishable
* task resume remains deterministic
* provider-default is never sent as a literal model ID
* provider capability limitations are reported honestly
* no stale global model registry is introduced
* fake-provider tests prove discovery, validation, and forwarding
* documentation is complete
* all existing tests pass

⸻

Reviewer Rejection Conditions

The independent reviewer must reject the implementation if any of the following
is true:

* model names are hard-coded globally without provider ownership
* SpecRelay claims to list all models without a reliable source
* model availability is fabricated
* aliases are accepted across unrelated providers
* raw IDs are rewritten
* validation occurs only after entering a running state
* only printed output is tested while provider invocation is not
* resume re-resolves an existing task against changed project config
* provider-default is passed literally to a real provider
* error guidance does not explain correct configuration forms

⸻

Verification

Run:

scripts/test
scripts/smoke
SPECRELAY_PROVIDER_OPTIONAL=1 bin/specrelay doctor
bin/specrelay version

Verify model guidance:

bin/specrelay models
bin/specrelay models claude

Use fake-provider fixtures to verify:

provider-default
known alias
unknown alias
raw provider ID
discovery unavailable
discovery failure

Verify a known-invalid alias never reaches:

EXECUTOR_RUNNING

Verify the provider invocation log receives the resolved alias or exact raw ID.

Verify an existing task continues to use its durable captured model selection
after project configuration changes.

⸻

Executor Deliverables

Write the standard artifacts:

03-executor-log.md
07-tests.txt
08-executor-summary.md

The executor summary must explicitly describe:

* supported model configuration forms
* backward compatibility behavior
* provider capability architecture
* alias ownership and resolution
* discovery limitations
* validation timing
* durable task-state changes
* resume behavior
* provider invocation proof
* documentation changes
* full verification results

⸻

Reviewer Focus

The reviewer must independently verify:

1. model guidance is discoverable before task execution
2. provider capabilities are honest and provider-owned
3. known-invalid aliases fail before running-state transitions
4. raw IDs are not rewritten
5. provider-default is omitted from remote invocation
6. executor and reviewer model selections remain isolated
7. resume uses durable captured selection
8. tests verify actual provider arguments, not only logs
