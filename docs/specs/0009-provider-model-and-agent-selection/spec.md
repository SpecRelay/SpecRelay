# 0009 — Provider model and agent selection

## Goal

Make SpecRelay role configuration explicit and provider-neutral by separating:

- provider: which adapter/CLI runs the role
- model: which model id/version the provider should use
- agent: which provider-specific agent/profile/subagent should be used

This fixes the current ambiguity where `claude-subagent` behaves like a provider name even though it is really Claude provider + ai-reviewer agent.

## Context

SpecRelay currently supports role providers such as:

- executor: `claude`, `fake`
- reviewer: `claude`, `claude-subagent`, `fake`, `manual`

This is functional but conceptually confusing:

- `claude` is a real provider/adapter.
- `claude-subagent` is not really a separate provider; it is Claude reviewer execution with an optional `--agent ai-reviewer`.
- Model selection is not explicit in config.
- Runtime evidence does not clearly record the effective provider/model/agent used for each role.

After 0008, SpecRelay ships a Claude reviewer agent template at:

templates/claude/agents/ai-reviewer.md

and `specrelay init`/doctor now understand the project-side runtime copy:

.claude/agents/ai-reviewer.md

## Required design

Introduce normalized role config:

roles:
  executor:
    provider: claude
    model: provider-default
    agent: none

  reviewer:
    provider: claude
    model: provider-default
    agent: ai-reviewer

`provider-default` means SpecRelay does not pass an explicit model flag and lets the provider CLI use its default.

`agent: none` means no provider-specific agent/profile/subagent should be used.

## Backward compatibility

Existing configs must continue to work:

roles:
  reviewer:
    provider: claude-subagent

Internally normalize this to:

provider: claude
agent: ai-reviewer
model: provider-default

But docs should mark `claude-subagent` as legacy shorthand, not the preferred new form.

Existing configs that only specify provider must continue to work. Missing `model` defaults to `provider-default`. Missing `agent` defaults to:

- reviewer + legacy `claude-subagent`: `ai-reviewer`
- everything else: `none`

## Model passing

Add model support to provider invocation where safe and help-driven.

For Claude:

- If model is `provider-default`, pass no model flag.
- If model is set to anything else, pass the correct Claude CLI model flag only if `claude --help` advertises that flag.
- If an explicit model is configured but the provider CLI cannot accept model selection, fail clearly rather than silently ignoring it.

Do not validate real vendor model names in SpecRelay. Treat model as an opaque string.

Future Codex support should be documented as provider-neutral, but do not implement Codex unless an adapter already exists and can be tested deterministically.

## Environment overrides

Add role-specific env overrides:

SPECRELAY_EXECUTOR_MODEL
SPECRELAY_REVIEWER_MODEL
SPECRELAY_EXECUTOR_AGENT
SPECRELAY_REVIEWER_AGENT

Precedence:

1. role-specific env override
2. .specrelay/config.yml
3. normalized legacy provider behavior
4. provider default

Provider-specific env overrides may be documented as future work; do not add unnecessary complexity unless already present.

## Doctor

`specrelay doctor` must report effective role configuration, for example:

Executor role: provider=claude model=provider-default agent=none
Reviewer role: provider=claude model=claude-sonnet-4 agent=ai-reviewer

For `agent: ai-reviewer`, doctor must keep the 0008 behavior:

- report configured if `.claude/agents/ai-reviewer.md` exists
- warn clearly if missing
- mention the template path/remediation

If an explicit model is configured and the provider CLI does not support passing a model, doctor should report that clearly.

## Runtime evidence

Every task run must capture effective role metadata somewhere durable, preferably in state/evidence metadata, including:

- executor provider
- executor model
- executor agent
- reviewer provider
- reviewer model
- reviewer agent

This metadata must be based on the normalized effective config, not raw legacy config.

## Docs

Update:

- README.md
- docs/configuration.md
- docs/providers.md
- docs/installation.md if needed
- templates/project/config.yml

Docs must clearly explain:

provider = adapter/CLI
model = provider model id or provider-default
agent = provider-specific profile/subagent, usually none or ai-reviewer

`claude-subagent` must be documented as legacy shorthand.

## Tests

Add deterministic tests for:

1. config defaults:
   - missing model -> provider-default
   - missing agent -> none
2. legacy normalization:
   - reviewer provider `claude-subagent` normalizes to provider=claude agent=ai-reviewer
3. env precedence:
   - SPECRELAY_REVIEWER_MODEL overrides config
   - SPECRELAY_REVIEWER_AGENT overrides config
4. doctor output:
   - reports effective provider/model/agent
   - warns for missing ai-reviewer agent
   - reports ai-reviewer configured when present
5. Claude invocation:
   - provider-default passes no model flag
   - explicit model passes model flag when fake Claude help advertises it
   - explicit model fails clearly when fake Claude help does not advertise model support
6. evidence/runtime metadata:
   - task state or evidence records effective provider/model/agent
7. backward compatibility:
   - existing `claude-subagent` configs still run
8. scripts/test passes

## Non-goals

- Do not publish a release.
- Do not create a Homebrew tap.
- Do not remove `claude-subagent` yet.
- Do not require real Claude in CI/tests.
- Do not implement a full Codex adapter unless it already exists and is testable with fake binaries.
- Do not change Sprint-reports.

## Verification

Run:

scripts/test
scripts/smoke
bin/specrelay doctor
bin/specrelay version

Do not commit automatically. Report changed files, normalized config behavior, and test results.