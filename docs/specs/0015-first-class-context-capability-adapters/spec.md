# First-Class Context Capability Adapters
- Spec: 0015
- Status: Draft
---
# Summary
Promote SpecRelay context integration from a minimal preflight hook into a
first-class, provider-independent capability system.
SpecRelay currently supports:
```yaml
context:
  adapter: none
  required: false

and performs a context-capability preflight before executor and reviewer
execution.

However, the current context layer is not yet a complete capability contract.
It does not provide a consistent way to:

* discover available context adapters
* inspect adapter capabilities
* validate configuration
* prepare role-specific context
* capture durable context evidence
* distinguish executor and reviewer context
* expose degradation or failure clearly
* add future adapters without modifying workflow internals

This specification introduces a stable context-adapter contract and CLI surface
that can support adapters such as Context+, repository indexes, workspace
knowledge systems, or future external context providers.

⸻

Problem

Current output commonly shows:

[executor] context-capability preflight (adapter: none)
[executor] context: adapter 'none' configured; no preflight required

This proves the workflow has a hook, but the context integration remains shallow.

The workflow should not need provider-specific or adapter-specific knowledge.

Without a formal adapter contract:

* each future integration may add bespoke workflow conditions
* executor and reviewer may accidentally share inappropriate context
* preflight success may not prove the context is usable
* required versus optional behavior may be inconsistent
* context provenance may not be captured
* resume may silently use different context than the original run
* adapters may become tightly coupled to Claude or Codex
* context failures may be confused with provider failures

⸻

Goals

* Define a stable context-adapter capability contract.
* Keep context adapters independent from AI providers.
* Support different context behavior for executor and reviewer.
* Add adapter discovery and diagnostics.
* Validate context configuration before role execution.
* Preserve adapter: none behavior.
* Support required and optional context policies.
* Capture durable context metadata for each task and role.
* Make context preparation observable in logs.
* Preserve isolated reviewer context.
* Enable future Context+ integration without changing workflow semantics.
* Keep adapters testable without remote services.

⸻

Non-Goals

This specification does not:

* implement the full Context+ adapter
* build or populate a repository index
* select business knowledge automatically
* define retrieval-ranking algorithms
* change executor or reviewer prompts beyond context handoff wiring
* merge executor and reviewer context
* add vector databases
* require network access
* couple context adapters to Claude, Codex, or another AI provider
* replace normal repository file access
* expose secrets or raw credentials in task evidence

⸻

Design Principles

Provider Independence

Context selection must be independent from execution provider selection.

Valid combinations must include:

Claude executor + Context+ adapter
Codex executor + Context+ adapter
Claude reviewer + local-files adapter
Fake provider + fake context adapter

The workflow must not assume that a context adapter belongs to a specific AI
provider.

Role Isolation

Executor and reviewer context must remain logically separate.

The reviewer must not automatically receive:

* executor private reasoning
* executor transient session state
* unreviewed executor narration

The reviewer may receive durable task evidence and independently prepared
repository context according to adapter policy.

Honest Capability Reporting

Adapters must report what they can actually do.

SpecRelay must not claim:

indexed
ready
fresh
complete

unless the adapter can verify that state reliably.

Durable Provenance

A task must retain enough metadata to explain:

* which adapter was requested
* which adapter was resolved
* whether context was required
* whether preparation succeeded
* what durable context artifact or reference was provided
* when preparation occurred

Secrets and credentials must never be persisted.

⸻

Configuration Contract

Preserve the current global form:

context:
  adapter: none
  required: false

Extend configuration to support role-specific overrides.

Conceptual form:

context:
  adapter: context-plus
  required: false
  executor:
    adapter: context-plus
    required: true
  reviewer:
    adapter: context-plus
    required: true

The exact syntax must follow existing configuration conventions.

Resolution order should be:

role-specific context configuration
→ global context configuration
→ adapter: none / required: false

Executor and reviewer may use different adapters.

Example:

context:
  executor:
    adapter: context-plus
    required: true
  reviewer:
    adapter: local-repository
    required: false

⸻

Adapter Capability Contract

Every context adapter must expose a common capability interface.

Conceptually, an adapter must support some or all of:

name
description
availability
configuration validation
preflight
prepare
resume compatibility
cleanup policy
durable artifact support
role support
network requirement
freshness reporting

The exact shell or Python interface should follow repository conventions.

Generic workflow code must call the common contract and must not contain
adapter-specific branches such as:

if adapter == context-plus

outside the central adapter dispatcher.

⸻

Capability Levels

Adapters must report capabilities honestly.

None

No external context preparation.

adapter: none

Behavior:

* always available
* no context artifact
* no network
* no preparation
* valid for executor and reviewer
* preserves current behavior

Preflight Only

The adapter can confirm basic installation or configuration but cannot prepare a
durable context artifact.

Prepared Context

The adapter can prepare a role-specific context artifact or reference.

Indexed Context

The adapter can verify that a repository or workspace index exists and is
usable.

Freshness-Aware Indexed Context

The adapter can reliably determine whether the index reflects the current
repository state.

SpecRelay must not infer a higher capability level from branding or adapter
name.

⸻

New CLI Command

Introduce:

bin/specrelay contexts

and:

bin/specrelay contexts <adapter>

Examples:

bin/specrelay contexts
bin/specrelay contexts none

Future example:

bin/specrelay contexts context-plus

The command must be:

* non-interactive
* append-only
* copyable
* usable in CI
* usable without color

⸻

Contexts Command Output

Example:

Context adapter: none
Description:
  No external context preparation.
Availability:
  available
Capabilities:
  preflight:        yes
  prepare:          no
  durable artifact: no
  role isolation:   yes
  network required: no
  freshness check:  no
Configuration:
  context:
    adapter: none
    required: false

For unavailable adapters:

Context adapter: context-plus
Availability:
  unavailable
Reason:
  required executable or configuration was not found
This adapter was not invoked.

The command must never perform a billable AI-provider invocation.

⸻

Adapter Discovery

bin/specrelay contexts must list adapters known to the installed SpecRelay
version.

It must distinguish:

* built-in adapters
* installed adapters
* configured adapter
* unavailable adapter
* adapter discovery failure

The generic engine must not claim that an adapter is usable merely because its
name appears in configuration.

⸻

Configuration Validation

Known-invalid context configuration must fail before role execution.

At minimum reject:

* empty adapter name
* non-string adapter name
* unknown adapter
* invalid boolean required
* unsupported role/adapter combination
* malformed role-specific configuration
* configuration keys not recognized by the adapter where strict validation is
    possible

Errors must identify:

* role
* adapter
* configuration source
* expected syntax
* inspection command

Example:

specrelay: invalid executor context adapter 'context-pluss'
Known adapters:
  none
  fake
Inspect adapters with:
  bin/specrelay contexts

⸻

Preflight Contract

Before executor or reviewer claims its running state, SpecRelay must perform
context validation and preflight.

Executor ordering:

READY_FOR_EXECUTOR
→ context validation
→ context preflight
→ context preparation when supported
→ EXECUTOR_RUNNING

Reviewer ordering:

READY_FOR_REVIEW
→ context validation
→ context preflight
→ independent reviewer context preparation
→ REVIEWER_RUNNING

Known context failures must therefore occur before:

EXECUTOR_RUNNING
REVIEWER_RUNNING

⸻

Required and Optional Policy

Required Context

When:

required: true

any of the following must block role execution:

* adapter unavailable
* configuration invalid
* preflight failure
* preparation failure
* required artifact missing
* required artifact unreadable

The role must not enter its running state.

Optional Context

When:

required: false

the same failures may degrade to a warning.

SpecRelay must clearly log:

context unavailable; continuing without external context because required=false

It must not pretend context preparation succeeded.

The durable task state must record the degraded result.

⸻

Preparation Contract

Adapters that support preparation must produce a structured result.

Conceptually:

status
adapter
role
prepared_at
artifact_kind
artifact_reference
freshness
warnings

Possible artifact kinds include:

none
file
directory
manifest
provider-reference
opaque-handle

SpecRelay must not assume every adapter returns a text file.

⸻

Context Handoff

Prepared context must reach the relevant provider invocation through a stable
handoff contract.

The adapter may provide:

* a file path
* a directory path
* a manifest
* a prompt fragment
* a provider-readable reference

The generic workflow must not parse provider-specific context formats.

The provider layer must receive only the normalized context handoff required for
that role.

⸻

Executor and Reviewer Isolation

The executor and reviewer must receive separately prepared context results.

They may reference the same repository index, but each preparation event must be
role-specific and independently logged.

Required behavior:

executor context preparation
reviewer context preparation

The reviewer must not reuse the executor’s transient context session unless an
adapter explicitly provides a safe durable shared reference and the contract
allows it.

Even when a durable index is shared, role-specific preparation metadata must
remain distinct.

⸻

Durable Task State

Extend task state to capture effective context configuration and result.

Conceptual example:

{
  "context_effective": {
    "executor": {
      "adapter": "context-plus",
      "required": true,
      "status": "prepared",
      "prepared_at": "2026-07-13T10:00:00Z",
      "artifact_kind": "provider-reference",
      "artifact_reference": "workspace-index"
    },
    "reviewer": {
      "adapter": "context-plus",
      "required": true,
      "status": "prepared",
      "prepared_at": "2026-07-13T10:20:00Z",
      "artifact_kind": "provider-reference",
      "artifact_reference": "workspace-index"
    }
  }
}

Requirements:

* old task state remains readable
* missing context metadata means legacy/default behavior
* secrets are not persisted
* credentials are not persisted
* absolute paths should be avoided when a safe project-relative reference is
    sufficient
* resume behavior remains deterministic

⸻

Resume Behavior

An existing task must retain its captured context configuration.

If project configuration changes after task creation, resume must not silently
switch adapters.

For a prepared durable artifact, resume should reuse it only when:

* adapter declares it reusable
* artifact still exists or reference remains valid
* freshness requirements are satisfied
* task state records the original preparation

Otherwise the adapter must explicitly re-prepare or fail according to required
policy.

The implementation must define and test:

reuse
reprepare
degrade
fail

It must not silently choose one.

⸻

Context Freshness

Adapters may report:

unknown
fresh
stale
not-applicable

SpecRelay must not infer freshness from file timestamps alone unless the adapter
contract defines that method.

For required adapters:

stale

may block execution if the adapter policy says freshness is mandatory.

For optional adapters, stale context may produce a warning and continue.

⸻

Logging

Before role execution, print clear context information.

Example:

╭─ Executor Context ─────────────────────────╮
│ Adapter   context-plus                    │
│ Required  yes                             │
│ Status    prepared                        │
│ Artifact  workspace-index                 │
│ Freshness fresh                           │
╰───────────────────────────────────────────╯

For none:

[executor] context: adapter 'none'; no external context requested

For degradation:

[executor] context: adapter 'context-plus' unavailable
[executor] context: continuing without external context because required=false

All output remains append-only and stream-friendly.

⸻

Doctor Integration

Enhance:

bin/specrelay doctor

For executor and reviewer, show:

configured adapter
resolved adapter
required policy
availability
capability level
network requirement
validation result

Doctor must not mutate task state or create context artifacts unless existing
doctor conventions explicitly allow a non-destructive preflight.

Doctor must not perform billable provider calls.

⸻

Task Show Integration

task show must display durable context information for existing tasks.

Example:

Executor context adapter: context-plus
Executor context required: true
Executor context status: prepared
Reviewer context adapter: context-plus
Reviewer context required: true
Reviewer context status: pending

Old tasks without context metadata remain displayable.

⸻

Fake Context Adapter

Implement a fake adapter for deterministic tests.

It must support simulation of:

* available
* unavailable
* preflight success
* preflight failure
* preparation success
* preparation failure
* reusable artifact
* missing artifact
* fresh
* stale
* optional degradation
* required blocking
* executor/reviewer isolated outputs

Fake adapter behavior must be controlled without network access.

⸻

None Adapter

The existing none behavior must become a proper adapter implementation using
the same capability contract.

It must not remain a special-case scattered through workflow code.

Expected behavior:

available
no network
no preparation
no artifact
freshness not-applicable

⸻

Provider Independence Tests

Tests must prove context behavior does not depend on the AI provider.

At minimum:

* fake executor + fake context
* fake reviewer + fake context
* Claude provider configuration + fake context preflight without live Claude
* different executor and reviewer adapters
* context failure prevents provider invocation when required
* optional context failure still permits provider invocation

⸻

Context Evidence

When preparation produces a durable artifact or manifest, evidence capture must
record sufficient provenance.

Possible task artifacts:

14-executor-context.json
15-reviewer-context.json

or another repository-consistent naming scheme.

Evidence must contain metadata, not credentials or secret payloads.

The executor and reviewer context evidence must remain distinct.

⸻

Security Requirements

The implementation must not persist:

* API keys
* authentication tokens
* session cookies
* complete environment dumps
* provider credentials
* secrets embedded in adapter configuration

Adapter errors must redact sensitive values.

Context artifacts must not automatically copy arbitrary private external data
into the repository or task evidence.

⸻

Documentation

Update relevant documentation with:

* context configuration syntax
* global and role-specific overrides
* required versus optional behavior
* adapter capability levels
* discovery command
* preflight ordering
* role isolation
* durable context metadata
* resume behavior
* freshness semantics
* security restrictions
* none adapter behavior
* fake adapter usage for tests

Add:

specrelay contexts [adapter]

to command documentation.

⸻

Required Tests

Configuration

* global adapter parses
* executor override parses
* reviewer override parses
* missing configuration resolves to none
* required defaults safely
* invalid adapter rejected
* malformed required value rejected
* role-specific resolution is isolated

Discovery

* contexts lists known adapters
* contexts none shows accurate capabilities
* unknown adapter produces guidance
* unavailable adapter is not reported as usable
* output is non-interactive and copyable

Validation Timing

* invalid executor context fails before EXECUTOR_RUNNING
* required executor preflight failure fails before provider invocation
* invalid reviewer context fails before REVIEWER_RUNNING
* required reviewer preflight failure fails before reviewer invocation

Optional Policy

* optional preflight failure emits warning
* optional failure records degraded state
* provider invocation continues
* logs do not claim context success

Required Policy

* required preflight failure blocks
* required preparation failure blocks
* missing required artifact blocks
* provider is not invoked

Preparation

* executor artifact is prepared
* reviewer artifact is prepared independently
* normalized handoff reaches the correct role
* executor context does not leak into reviewer context
* reviewer context does not leak into executor context

Durable State

* effective adapters are captured
* required flags are captured
* preparation status is captured
* artifact metadata is captured safely
* old task state remains readable
* secrets are not written

Resume

* task retains captured adapter after config changes
* reusable artifact is reused only when adapter permits
* missing artifact triggers documented behavior
* stale artifact triggers documented behavior
* reprepare behavior is deterministic
* executor and reviewer remain isolated

Doctor and Task Show

* doctor reports adapter capability honestly
* task show uses durable context metadata
* old tasks display without errors

Compatibility

* adapter: none preserves current behavior
* existing workflows remain green
* existing tests remain green
* model/provider configuration remains unaffected
* stream-friendly output remains append-only

⸻

Acceptance Criteria

This specification is accepted only when:

* context adapters have a stable capability contract
* none is implemented through that contract
* bin/specrelay contexts exists
* executor and reviewer context can be configured independently
* required context failures block before running-state transitions
* optional failures degrade honestly
* context preparation results are role-specific
* provider invocation receives normalized context handoff
* task state captures durable context provenance
* resume behavior is deterministic
* adapter freshness is not fabricated
* no secrets are stored
* fake adapter tests cover success, failure, degradation, reuse, and staleness
* workflow contains no scattered adapter-specific conditions
* all existing tests pass
* documentation is complete

⸻

Reviewer Rejection Conditions

The reviewer must reject the implementation if:

* workflow contains hard-coded Context+ branches
* context adapters are coupled to Claude or Codex
* executor and reviewer reuse transient context unsafely
* required failures occur after entering running state
* optional failures are reported as success
* context freshness is guessed
* resume silently switches adapters
* credentials or secrets appear in evidence
* tests verify logs only without proving provider handoff
* none remains an unrelated special-case outside the adapter contract
* adapter discovery claims unavailable integrations are ready

⸻

Verification

Run:

scripts/test
scripts/smoke
SPECRELAY_PROVIDER_OPTIONAL=1 bin/specrelay doctor
bin/specrelay version

Verify discovery:

bin/specrelay contexts
bin/specrelay contexts none

Use fake adapters to verify:

available
unavailable
required failure
optional degradation
prepared artifact
missing artifact
fresh artifact
stale artifact
resume reuse
resume reprepare
executor/reviewer isolation

Verify known context failure never reaches:

EXECUTOR_RUNNING
REVIEWER_RUNNING

Verify optional degradation still invokes the role provider and records:

status: degraded

Verify task evidence contains no credentials or secrets.

⸻

Executor Deliverables

Write:

03-executor-log.md
07-tests.txt
08-executor-summary.md

The executor summary must explicitly describe:

* context adapter contract
* discovery architecture
* configuration resolution
* required/optional behavior
* validation timing
* executor/reviewer isolation
* normalized provider handoff
* durable state metadata
* resume behavior
* freshness handling
* security protections
* fake adapter coverage
* verification results

⸻

Reviewer Focus

The reviewer must independently verify:

1. context capability is provider-independent
2. required failures occur before running-state transitions
3. optional degradation is honest and durable
4. executor and reviewer context remain isolated
5. prepared context reaches the correct provider invocation
6. resume uses captured context configuration
7. freshness is not fabricated
8. no secrets are persisted
9. tests prove actual handoff and state behavior
