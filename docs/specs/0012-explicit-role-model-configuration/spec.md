
# Explicit Role Model Configuration
- Spec: 0012
- Status: Draft
---
# Summary
Add explicit, role-specific model configuration for SpecRelay executors and
reviewers.
SpecRelay already distinguishes between:
- provider
- model
- agent
and records a `model` value under `roles_effective` in task state.
However, current project configuration does not clearly expose or enforce model
selection. As a result, executions commonly use:
```text
model: provider-default

This delegates model selection to the underlying provider CLI and makes runs
less deterministic.

This specification makes the model identifier explicitly configurable for each
role and verifies that the configured model is actually passed to the selected
provider.

⸻

Problem

Current task state can contain:

{
  "roles_effective": {
    "executor": {
      "provider": "claude",
      "model": "provider-default",
      "agent": "none"
    },
    "reviewer": {
      "provider": "claude",
      "model": "provider-default",
      "agent": "ai-reviewer"
    }
  }
}

Although SpecRelay has an internal model concept, users cannot currently rely on
the repository configuration to select the exact model used by each role.

With provider-default, the effective model may change when:

* the provider CLI changes its default model
* the provider account configuration changes
* the provider releases a new default
* local user configuration differs between machines

This weakens reproducibility, auditability, cost control, and comparison between
runs.

⸻

Goals

* Allow the executor model to be configured explicitly.
* Allow the reviewer model to be configured explicitly.
* Preserve independent provider, model, and agent configuration per role.
* Pass the configured model to the actual provider command.
* Record the configured model in durable task state.
* Display the effective role configuration before execution.
* Preserve provider-default for backward compatibility.
* Add automated tests proving that model configuration affects provider
    invocation.

⸻

Non-Goals

This specification does not:

* create a hard-coded global allowlist of model names
* verify remotely whether a model currently exists
* select models automatically based on task complexity
* add fallback chains between different models
* add cost calculation
* change provider authentication
* change agent definitions
* change reviewer continuation or reviewer state semantics
* pin or manage the installed Claude Code or Codex CLI binary version

Model identifiers evolve independently of SpecRelay. SpecRelay must validate
configuration shape and forwarding behavior, but provider CLIs remain
responsible for rejecting unknown or unavailable model identifiers.

⸻

Terminology

Provider

The execution backend, for example:

claude
codex
fake
manual

Model

The provider-specific model identifier requested for execution, for example:

provider-default
<provider-specific-model-id>

SpecRelay must treat model identifiers as opaque provider-specific strings.

Agent

An optional provider-side or SpecRelay role profile, for example:

none
ai-reviewer

Provider, model, and agent are separate configuration values and must not be
merged into a single string.

⸻

Required Configuration Contract

SpecRelay must support explicit model configuration independently for:

executor
reviewer

The implementation must extend the repository’s existing configuration schema
and conventions rather than introducing a second competing configuration
format.

The effective configuration must conceptually represent:

roles:
  executor:
    provider: claude
    model: <explicit-model-id>
    agent: none
  reviewer:
    provider: claude
    model: <explicit-model-id>
    agent: ai-reviewer

The exact file format and key placement must follow the current SpecRelay config
parser and existing project conventions.

The implementation must document the exact supported syntax in the repository.

⸻

Backward Compatibility

Existing configurations that do not define a model must remain valid.

When no model is configured for a role, SpecRelay must resolve it as:

provider-default

Existing behavior must therefore remain unchanged unless a project explicitly
selects a model.

The following must remain valid:

provider: claude
model: provider-default

Manual providers must also remain valid. A manual role does not invoke an AI
model, but its normalized role configuration may continue to report:

model: provider-default

or another clearly documented non-executed value consistent with existing
behavior.

⸻

Effective Role Resolution

For each role, SpecRelay must resolve and retain:

provider
model
agent

Resolution must happen before role execution.

The resolved values must be used consistently by:

* executor invocation
* reviewer invocation
* task state initialization
* task status or diagnostic output
* execution logs
* tests

The executor and reviewer must be allowed to use different providers and
different models.

Example:

executor:
  provider: codex
  model: <codex-model-id>
reviewer:
  provider: claude
  model: <claude-model-id>

No role may accidentally inherit the other role’s model.

⸻

Provider Invocation

When a role has an explicit model other than:

provider-default

the corresponding provider adapter must pass that model to the provider CLI
using the provider’s supported model-selection argument.

Conceptually:

claude <model-option> <configured-model>

or:

codex <model-option> <configured-model>

The implementation must inspect the existing provider adapters and use their
current command-construction conventions.

The implementation must not merely:

* parse the model
* print the model
* save the model in state

without forwarding it to the actual provider command.

That would not satisfy this specification.

⸻

Provider Default Behavior

When the effective model is:

provider-default

SpecRelay must preserve the current provider invocation behavior.

It must not pass the literal string:

provider-default

as a model name to Claude Code, Codex, or another real provider.

Instead, it must omit the explicit model-selection argument and allow the
provider to select its configured default.

⸻

Execution Logging

Before starting an executor or reviewer provider, SpecRelay must display the
effective execution selection.

The output must clearly include:

provider
model
agent

Example shape:

[executor] provider=codex model=<configured-model> agent=none
[reviewer] provider=claude model=<configured-model> agent=ai-reviewer

Existing log formatting may be retained as long as all three values are visible
and unambiguous.

For provider-default, the output must explicitly say:

model=provider-default

so users know that model selection was delegated to the provider.

⸻

Durable Task State

Task initialization must continue to persist the resolved role configuration
under:

roles_effective

For example:

{
  "roles_effective": {
    "executor": {
      "provider": "codex",
      "model": "<configured-codex-model>",
      "agent": "none"
    },
    "reviewer": {
      "provider": "claude",
      "model": "<configured-claude-model>",
      "agent": "ai-reviewer"
    }
  }
}

This state must represent the configuration SpecRelay requested for the run.

If the provider exposes a reliable machine-readable actual model identifier,
SpecRelay may additionally record it separately, but it must not fabricate an
“actual model” value based only on assumptions or human-readable output.

The required contract for this specification is:

configured/resolved model is durable
configured/resolved model is passed to provider

⸻

Validation

SpecRelay must reject malformed model configuration before provider execution.

At minimum, the following must be rejected:

* non-string model values
* empty explicit model values
* whitespace-only explicit model values
* structurally invalid role configuration

The error must identify:

* the affected role
* the invalid model configuration
* the configuration source when available

SpecRelay must not maintain a hard-coded list of valid remote model names.

Unknown but structurally valid model identifiers must be forwarded to the
provider, which may reject them with its normal error.

⸻

Doctor Command

bin/specrelay doctor must report the resolved execution configuration for both
roles.

It must show:

executor provider
executor model
executor agent
reviewer provider
reviewer model
reviewer agent

The doctor command must distinguish between:

explicit model
provider-default

Doctor does not need to perform a billable model invocation.

Doctor must not claim that a provider-specific model is available unless it has
a reliable non-billable way to verify that claim.

⸻

Status and Diagnostic Output

Where SpecRelay already displays task role configuration, it must include the
model.

For an existing task, diagnostic output must prefer the durable
roles_effective values captured at task creation rather than silently
re-resolving changed project configuration.

This preserves the audit trail for runs created before a configuration change.

⸻

Provider Adapter Requirements

Each automated provider adapter that supports model selection must have explicit
test coverage.

At minimum, current supported automated providers must be inspected.

For each supported provider:

Explicit model

Given:

model: some-model-id

the generated provider command must include:

some-model-id

through the correct model-selection argument.

Provider default

Given:

model: provider-default

the generated provider command must not pass:

provider-default

to the provider CLI.

Isolation

An executor model must not leak into reviewer invocation.

A reviewer model must not leak into executor invocation.

⸻

Fake Provider Support

The fake provider must expose enough invocation evidence for tests to assert:

* which role invoked it
* which provider was resolved
* which model was resolved
* which agent was resolved

Fake-provider tests must prove forwarding behavior without requiring live Claude
or Codex calls.

⸻

Resume Behavior

A task’s durable roles_effective configuration must remain authoritative for
that task after creation.

If project configuration changes after a task has started, resume must not
silently switch the task to a different model unless existing SpecRelay
semantics explicitly require re-resolution and that behavior is documented.

The implementation must inspect current task/resume behavior and preserve
deterministic execution.

At minimum, tests must prove what happens when:

1. a task is created with model A
2. project configuration is changed to model B
3. the existing task is resumed

The expected behavior should be:

existing task continues with its captured effective role configuration

unless the current architecture makes that impossible. If architectural work is
required, it must be implemented as part of this specification rather than
leaving resume behavior ambiguous.

⸻

Documentation

Update the relevant project documentation with:

* exact model configuration syntax
* executor and reviewer examples
* mixed-provider example
* provider-default behavior
* distinction between provider, model, and agent
* behavior for existing tasks and resume
* validation behavior
* doctor output

Documentation must not use model identifiers that are falsely presented as
permanently valid.

Examples may use placeholders such as:

<claude-model-id>
<codex-model-id>

or clearly state that concrete identifiers are provider-specific and may
change.

⸻

Required Tests

Add or update tests covering all of the following.

Configuration parsing

* executor explicit model is parsed
* reviewer explicit model is parsed
* roles may use different models
* missing model resolves to provider-default
* invalid empty model is rejected
* invalid non-string model is rejected where the config format permits it

Effective task state

* executor model is stored under roles_effective
* reviewer model is stored under roles_effective
* existing no-model configuration stores provider-default

Provider forwarding

* explicit executor model reaches executor provider invocation
* explicit reviewer model reaches reviewer provider invocation
* provider-default is not forwarded as a literal remote model
* executor and reviewer model values remain isolated

Logging

* executor start output includes provider, model, and agent
* reviewer start output includes provider, model, and agent

Doctor

* doctor displays both effective role models
* doctor distinguishes explicit model from provider-default

Resume

* an existing task retains its captured model after project config changes
* resumed executor uses the task’s captured executor model
* resumed reviewer uses the task’s captured reviewer model

Compatibility

* all existing tests remain green
* manual executor/reviewer behavior remains unchanged
* existing configuration without model keys remains valid

⸻

Acceptance Criteria

This specification is accepted only when all of the following are true:

* model can be configured independently for executor and reviewer
* model configuration follows the existing SpecRelay config schema
* missing model resolves to provider-default
* explicit model is actually passed to the provider adapter
* provider-default is not passed literally to real provider CLIs
* executor and reviewer may use different model identifiers
* effective provider/model/agent are visible in execution logs
* effective provider/model/agent are persisted in task state
* doctor displays the effective model for both roles
* existing tasks retain deterministic model selection on resume
* malformed model configuration fails before provider execution
* fake-provider tests prove model forwarding
* all existing tests remain green
* documentation explains the complete contract

⸻

Verification

Run the complete standalone test suite:

scripts/test

Run smoke verification:

scripts/smoke

Run doctor:

SPECRELAY_PROVIDER_OPTIONAL=1 bin/specrelay doctor

Run version:

bin/specrelay version

Create or use an automated test fixture with different executor and reviewer
models and verify that logs contain both distinct values.

Verify task state contains:

{
  "roles_effective": {
    "executor": {
      "model": "<executor-model>"
    },
    "reviewer": {
      "model": "<reviewer-model>"
    }
  }
}

Verify fake-provider invocation evidence proves that each configured model was
passed to the correct role.

Verify provider-default does not appear as a literal provider CLI model
argument.

Verify changing project configuration after task creation does not silently
change the model used when that existing task is resumed.

⸻

Executor Deliverables

The executor must write the standard task artifacts, including:

03-executor-log.md
07-tests.txt
08-executor-summary.md

The executor summary must explicitly state:

* config files changed
* resolved configuration syntax
* provider adapters changed
* how explicit models are forwarded
* how provider-default is handled
* resume behavior
* tests added
* verification results

⸻

Reviewer Focus

The independent reviewer must not accept this implementation merely because a
model value appears in logs or state.json.

The reviewer must verify directly that:

1. the configured model reaches provider command construction
2. provider-default is omitted from real provider model arguments
3. executor and reviewer model values remain isolated
4. resume uses durable task model configuration
5. tests prove behavior rather than only testing printed strings

A configuration field that is parsed and recorded but not used by the provider
is a rejection-level defect.
EOF
