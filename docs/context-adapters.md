# SpecRelay Context Adapters

A **context adapter** is a first-class, provider-independent capability that
prepares (or declines to prepare) task-relevant context for a role — executor
or reviewer — *before* that role does any substantive work. As of spec 0015
this is a stable capability contract, not just a preflight hook: adapters can
be discovered and inspected (`specrelay contexts`), validated before role
execution, asked to prepare role-specific context, and their results are
captured as durable task provenance.

This is a generic capability seam in the engine core. SpecRelay's lifecycle
code calls only the generic dispatcher (`lib/specrelay/context/capability.sh`)
and never hardcodes any branded provider; there are no adapter-specific
branches in workflow code (see `architecture.md` and
`knowledge-boundaries.md`). Which adapter runs, per role, and whether a
failure is fatal come purely from project configuration.

## Provider independence

Context selection is independent from AI-provider selection. Any adapter may
be combined with any executor or reviewer provider — a Claude executor with
the `contextplus` adapter, a fake provider with the `fake` context adapter, a
Claude reviewer with `none`, and so on. Nothing in the context layer consults
the provider adapters, and a context failure is always reported as a context
failure, never confused with a provider failure.

## Configuration

The `context:` section of `.specrelay/config.yml` supports a global form plus
role-specific overrides:

```yaml
context:
  adapter: none        # global adapter
  required: false      # global required policy
  executor:            # optional role-specific override
    adapter: contextplus
    required: true
  reviewer:
    adapter: none
    required: false
```

Resolution order, per field: role-specific value → global value → the
built-in default (`adapter: none`, `required: false`). The executor and
reviewer may use entirely different adapters.

Known-invalid configuration fails **before** role execution: an empty or
non-string adapter name, an unknown adapter, a non-boolean `required`, a
malformed role subsection, or unrecognized keys. Errors name the role, the
adapter, the configuration source, the expected syntax, and the inspection
command (`specrelay contexts`).

## Discovery: `specrelay contexts [adapter]`

```
specrelay contexts            # list known adapters, availability, configured adapters
specrelay contexts none       # inspect one adapter's capabilities
specrelay contexts fake
specrelay contexts contextplus
```

The command is non-interactive, append-only, copyable, CI-safe, and works
without color. It never performs a billable AI-provider invocation and never
runs an adapter's preflight or preparation; availability is a read-only local
check, and an unavailable adapter is reported honestly (`This adapter was not
invoked.`) rather than presumed usable. See `commands.md` for the output
shape.

## The adapter capability contract

Every adapter implements the same contract (dispatched by
`lib/specrelay/context/capability.sh`); generic engine code never contains
`if adapter == …` branches outside that central dispatcher:

| Contract function | Meaning |
|---|---|
| `describe` | one-line human description |
| `availability <root>` | `available` / `unavailable` + reason; local, never billable |
| `capability_level` | honest level: `none`, `preflight`, `prepared`, `indexed`, `freshness` |
| `capabilities` | matrix: preflight, prepare, durable_artifact, role_isolation, network, freshness_check |
| `supported_roles` | which roles the adapter may serve |
| `validate_config <root> <role>` | adapter-specific configuration validation |
| `preflight <role> <root> <task-id> <provider>` | observable, non-secret progress; non-zero = not proven |
| `prepare <role> <root> <task-dir> <task-id> <provider>` | role-specific preparation; structured result (status, artifact_kind, artifact_reference, freshness, warnings) |
| `reuse_decision …` | deterministic resume policy: prints `reuse` or `reprepare`, never silent |
| `freshness_mandatory` | whether a stale artifact must block a *required* role |

**Capability levels are reported honestly** — SpecRelay never infers a higher
level from an adapter's name or branding, and never claims `indexed`, `ready`,
`fresh`, or `complete` unless the adapter can verify that state. Artifact
kinds include `none`, `file`, `directory`, `manifest`, `provider-reference`,
and `opaque-handle`; SpecRelay never assumes every adapter returns a text
file.

## Preflight ordering

Context runs **before** a role's running-state transition:

```
Executor:  READY_FOR_EXECUTOR → context validation → context preflight
           → context preparation (when supported) → EXECUTOR_RUNNING
Reviewer:  READY_FOR_REVIEW → context validation → context preflight
           → independent reviewer context preparation → REVIEWER_RUNNING
```

A known context failure therefore never occurs after `EXECUTOR_RUNNING` /
`REVIEWER_RUNNING`, and a blocked role's provider is never invoked. (If the
reviewer provider is `manual`, the reviewer iteration returns before any
context step — no automated review runs.)

## Required vs. optional policy

- **`required: true`** — any of: adapter unavailable, invalid configuration,
  preflight failure, preparation failure, or a missing/unreadable required
  artifact **blocks** the role before its running state. The durable state
  records `status: failed`.
- **`required: false`** — the same failures degrade to an explicit warning:

  ```
  [executor] context: continuing without external context because required=false
  ```

  SpecRelay never pretends preparation succeeded; the durable task state
  records `status: degraded`, and the role's provider is invoked with **no**
  context handoff.

## Role isolation

The executor and reviewer receive **separately prepared** context results.
Each preparation event is role-specific and independently logged, evidence is
per-role, and the reviewer never reuses the executor's transient context
session — the reviewer additionally reconstructs its prompt from durable task
evidence, never from the executor's conversation (see `task-lifecycle.md`).
Even when a durable index could be shared, the role-specific preparation
metadata remains distinct.

## Normalized context handoff

A prepared context reaches the provider invocation through one stable,
normalized handoff string per role — `<artifact-kind>:<artifact-reference>`
(or `none` when nothing was prepared). The generic workflow never parses
adapter-specific context formats, and the provider layer receives only the
handoff for its own role. The fake provider records the handoff in its
invocation evidence (which is how tests *prove* delivery); the Claude
provider renders it as a short prompt fragment pointing at the prepared
artifact.

## Durable task state and evidence

The effective context configuration and per-role results are captured in the
task's `state.json` under `context_effective`:

```json
{
  "context_effective": {
    "executor": {
      "adapter": "fake",
      "required": true,
      "status": "prepared",
      "prepared_at": "2026-07-13T10:00:00Z",
      "artifact_kind": "file",
      "artifact_reference": ".specrelay-runs/tasks/0015-x/fake-context-executor.txt",
      "freshness": "fresh"
    },
    "reviewer": { "...": "..." }
  }
}
```

- The adapter and required policy are captured **once** (at the first
  executor iteration) and are authoritative thereafter.
- Statuses: `pending`, `prepared`, `degraded`, `failed`, `none` (no external
  context requested / no preparation capability).
- Real context outcomes (prepared/degraded/failed) also write per-role
  evidence files: `14-executor-context.json` and `17-reviewer-context.json`
  (15/16 are the reviewer stdout/stderr captures in this repository's
  numbering). Evidence contains metadata only.
- Old tasks without context metadata remain fully readable and displayable
  (missing metadata means legacy/default behavior).
- **No secrets are persisted** — no API keys, tokens, cookies, environment
  dumps, or provider credentials, in state or evidence. Artifact references
  are project-relative where possible.

`specrelay task show` displays the durable context metadata (adapter,
required, status, artifact) per role; `specrelay doctor` reports each role's
configured adapter, required policy, availability, capability level, and
network requirement read-only (a required-but-unavailable adapter is a
mandatory doctor failure; an optional one is an advisory warning). Doctor
never mutates task state, never prepares context, and never performs a
billable provider call.

## Resume behavior

An existing task retains its captured context configuration — changing the
project configuration never silently switches a resumed task's adapters. For
a previously prepared durable artifact the behavior is deterministic and
explicit, never silent:

- **reuse** — only when the adapter's `reuse_decision` permits it, the
  artifact reference is still valid, and freshness is satisfied; logged as
  `reusing previously prepared artifact`.
- **reprepare** — when the artifact is missing, the adapter forbids reuse, or
  the artifact is stale; logged as `re-preparing`.
- **degrade** — a re-preparation failure under `required: false` records
  `status: degraded` and continues without context.
- **fail** — a re-preparation failure under `required: true` blocks before
  the running state.

## Context freshness

Adapters report freshness as `unknown`, `fresh`, `stale`, or
`not-applicable`. SpecRelay never fabricates freshness (and never infers it
from file timestamps unless the adapter's own contract defines that method).
A `stale` report blocks a **required** role only when the adapter declares
freshness mandatory; for optional roles (or non-mandatory adapters) stale
context produces a warning and continues.

## Built-in adapters

### `none` (default)

A real adapter implemented through the same contract — not a special case in
workflow code. Always available, no network, no preparation, no artifact,
freshness not-applicable, valid for both roles. Its preflight prints:

```
[<role>] context: adapter 'none'; no external context requested
```

### `fake` (deterministic, for tests)

Everything is driven by env knobs (no network, no provider):

| Variable | Default | Simulates |
|---|---|---|
| `SPECRELAY_FAKE_CONTEXT_AVAILABLE` | `1` | `0` = adapter unavailable |
| `SPECRELAY_FAKE_CONTEXT_PREFLIGHT` | `ok` | `fail` = preflight failure |
| `SPECRELAY_FAKE_CONTEXT_PREPARE` | `ok` | `fail` = preparation failure |
| `SPECRELAY_FAKE_CONTEXT_ARTIFACT` | `ok` | `missing` = prepared reference whose file does not exist |
| `SPECRELAY_FAKE_CONTEXT_FRESHNESS` | `fresh` | `stale` / `unknown` |
| `SPECRELAY_FAKE_CONTEXT_REUSABLE` | `1` | `0` = never reuse on resume |
| `SPECRELAY_FAKE_CONTEXT_FRESHNESS_MANDATORY` | `0` | `1` = stale blocks a required role |

Every knob has per-role overrides
(`SPECRELAY_FAKE_CONTEXT_EXECUTOR_<KNOB>` /
`SPECRELAY_FAKE_CONTEXT_REVIEWER_<KNOB>`) so one run can give the roles
different behavior — this is how the executor/reviewer isolation tests work.
Its `prepare` writes a role-specific artifact file into the task's runtime
directory and reports `artifact_kind: file` with a project-relative
reference.

### `contextplus` (optional, configured)

`lib/specrelay/context/contextplus.sh` proves real access to a Context Plus
retrieval tool. Its honest capability level is **preflight** — it verifies
installation and performs one bounded retrieval, but produces no durable
artifact. Its `availability` (used by `contexts`/`doctor`) is a local,
non-billable check for the configured Claude-compatible binary; the deeper
MCP health check and the single scoped, budget-capped retrieval run in its
preflight at `run` time:

1. **Not-applicable short-circuit** for `manual` / `fake` role providers.
2. **Binary present** on `PATH`.
3. **Availability via a real health check** — `<claude-bin> mcp list` must
   list the configured server as connected.
4. **One bounded, real retrieval** constrained to the server's
   `semantic_code_search` tool, failing unless the tool call is evidenced.

Any failed step is a hard refusal; `required` decides whether that blocks the
role. Test-only env hooks: `SPECRELAY_CONTEXTPLUS_CLAUDE_BIN` (default
`claude`), `SPECRELAY_CONTEXTPLUS_SERVER_NAME` (default `contextplus`),
`SPECRELAY_CONTEXTPLUS_MAX_BUDGET_USD` (default `0.50`).

## MCP setup policy (ContextPlus)

ContextPlus is an **optional** adapter. Two policies are non-negotiable:

- **Generic `install` / `init` never silently mutates your Claude MCP
  configuration.** Any MCP/provider-specific setup must be explicit,
  user-approved, and provider-specific.
- **A required-but-missing adapter fails loudly, not silently.** With
  `context.adapter: contextplus` and `required: true` but no
  registered/connected server, the preflight fails its health check and the
  run refuses to launch the role with an actionable error.

There is no built-in command that registers the ContextPlus MCP server for
you. Register it manually:

```sh
claude mcp add contextplus <server-launch-command>
claude mcp list        # contextplus … ✔ Connected
```

Only then set `context.adapter: contextplus` (and `required: true` if a
missing capability should block work). If you cannot or do not want to
register ContextPlus, keep the default `adapter: none`.

## Security requirements

The context layer never persists API keys, authentication tokens, session
cookies, environment dumps, provider credentials, or secrets embedded in
adapter configuration — in task state, context evidence, or logs. Adapter
errors must redact sensitive values, and context artifacts never
automatically copy arbitrary private external data into the repository or
task evidence.

## Testing adapters

Use `context.adapter: none` for a deterministic no-op, and the `fake` adapter
(above) to exercise the full behavior matrix — availability, required
blocking, optional degradation, preparation, handoff delivery, reuse,
staleness, and role isolation — without any network or provider spend. The
provider-independence tests in `test/context_adapters_test.sh` prove context
behavior does not depend on the AI provider (including that a
Claude-configured executor is never launched when its required context
fails).
