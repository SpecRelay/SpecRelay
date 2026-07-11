# SpecRelay Context Adapters

A **context adapter** is a capability preflight that SpecRelay runs for a role
(executor or reviewer) *before* that role does any substantive work. Its only
job is to prove — or decline to prove — that the role has real, working access
to whatever context/retrieval capability the project requires. It does not
supply model context by itself; it is a gate that runs first and either clears
the role to proceed or refuses.

This is a generic capability-gating seam in the engine core. SpecRelay's
lifecycle code calls exactly one entry point,
`specrelay::context::preflight`, and never hardcodes any branded provider (see
`architecture.md`, and `knowledge-boundaries.md` for why this is kept generic).
Which adapter runs, and whether a failed preflight is fatal, come purely from
project configuration.

## Configuration

Two keys under `context:` in a project's `.specrelay/config.yml` control this
seam:

| Key | Default | Meaning |
|---|---|---|
| `context.adapter` | `none` | Which context adapter runs the preflight. |
| `context.required` | `false` | Whether a failed preflight blocks the role. |

The defaults (`adapter: none`, `required: false`) mean that, out of the box,
**SpecRelay requires no context capability at all** — the preflight is a no-op
that always succeeds. A consumer project opts in to a stricter policy by
setting these keys; it is never assumed for you.

> A consumer project **may** choose to require an adapter by setting
> `context.required: true` (optionally alongside a concrete
> `context.adapter`). That is a per-project policy decision expressed in that
> project's own `.specrelay/config.yml`, not a SpecRelay default.

## The context-adapter contract

Every adapter implements one function with this signature (from
`lib/specrelay/context/capability.sh`):

```
preflight <role> <project-root> <task-id> <provider>
```

The dispatcher `specrelay::context::preflight <adapter> <role> <root>
<task-id> <provider>` routes to the configured adapter (`none` or
`contextplus`); an unknown adapter name is a hard error (it prints
`no context-capability adapter is defined for '<adapter>'` and returns
non-zero).

The contract each adapter honors:

- **Availability.** The adapter prints observable, non-secret progress
  (checking → available → initialized → retrieval) and returns `0` when the
  capability requirement is satisfied (or not applicable), non-zero otherwise.
- **No silent fallback.** A non-zero return means the capability could not be
  proven. The adapter never quietly downgrades or substitutes a different
  capability; the decision about what to do next belongs to the caller.
- **Required-vs-optional policy is the caller's, not the adapter's.** The
  adapter only reports success/failure. The workflow then applies
  `context.required`:
  - If the preflight **fails** and `context.required` is truthy
    (`1`/`true`/`True`/`TRUE`/`yes`), the workflow **refuses to launch that
    role** and stops. For the executor it refuses to claim/launch; for the
    reviewer it refuses to launch the reviewer.
  - If the preflight **fails** and `context.required` is not truthy (the
    default `false`), the workflow prints that the preflight failed but is not
    required by policy, and **proceeds** with that role anyway.
  - If the preflight **succeeds**, the role proceeds normally.

### Executor preflight

In `specrelay::workflow::executor_iteration` (`workflow.sh`), the context
preflight runs **after** the working-tree guard and **before** the task is
claimed and the executor provider is launched. On a required-and-failed
preflight the executor is never claimed or run. On success (or on a
non-required failure) the executor proceeds to claim, run, capture evidence,
and submit.

### Reviewer preflight (independent)

The reviewer runs its **own, separate** context preflight in
`specrelay::workflow::reviewer_iteration`. It is not a continuation of, and
does not reuse, the executor's preflight — it is invoked independently with
`role = reviewer` and the reviewer's own provider, consistent with the
reviewer being a fresh, isolated context (it reconstructs its prompt from the
task/evidence files, never from the executor's session). The same
required-vs-optional policy is applied independently to the reviewer's result.

Note: if the reviewer provider is `manual`, the reviewer iteration returns
before any preflight — no automated review (and therefore no reviewer
preflight) runs, because a human decides accept/request-changes.

### Context retrieval

An adapter that proves a real retrieval capability performs its retrieval as
part of the preflight itself (see `contextplus` below). The core does not
define a separate "retrieve context" step; retrieval, where it happens, is the
adapter's own bounded action performed while proving availability.

### Failure behavior

Failure is always surfaced (an error line is printed) and always returns
non-zero. What happens next is decided entirely by `context.required` as
described above. An adapter never masks a failure as success.

## The `none` adapter (default)

`lib/specrelay/context/none.sh` is the "no context capability required"
adapter and is the configured default. Its preflight performs **no checks**:
it prints a single line —

```
[<role>] context: adapter 'none' configured; no preflight required
```

— and returns `0`. Use it for any project (or test run) that has no
context-retrieval requirement, or that deliberately does not want to spend on
a real retrieval call.

## The `contextplus` adapter (optional, configured)

`lib/specrelay/context/contextplus.sh` is an **optional** adapter that a
project may configure (`context.adapter: contextplus`) when it wants roles to
prove real access to a Context Plus retrieval tool before working. It is not
enabled unless a project's config selects it.

What its preflight does, in order:

1. **Not-applicable short-circuit.** If the role's `provider` is `manual` or
   `fake`, the adapter prints that it is not applicable (that provider runs no
   automated agent) and returns `0`.
2. **Binary present.** It requires the configured Claude-compatible binary on
   `PATH`; if it is missing, it fails.
3. **Availability via a real health check.** It runs `<claude-bin> mcp list`
   and fails if that command errors, produces no output, does not list the
   configured server, or lists it as registered but **not connected**. This is
   a live check, not an inference from `.mcp.json` being present.
4. **One bounded, real retrieval.** On success it performs exactly one scoped,
   budget-capped Claude `--print` call constrained to the server's
   `semantic_code_search` tool, and fails unless the response shows evidence
   that the tool was actually called. On success it prints
   `query completed` / `context loaded` and returns `0`.

Any failed step is a hard refusal (non-zero return, no silent fallback);
whether that refusal blocks the role is then governed by `context.required`.

### Environment variables

These are **test-only hooks**; normal operation needs none of them (quoted
verbatim from `contextplus.sh`):

| Variable | Default | Purpose |
|---|---|---|
| `SPECRELAY_CONTEXTPLUS_CLAUDE_BIN` | `claude` | Claude-compatible binary to invoke. |
| `SPECRELAY_CONTEXTPLUS_SERVER_NAME` | `contextplus` | Registered MCP server name to look for. |
| `SPECRELAY_CONTEXTPLUS_MAX_BUDGET_USD` | `0.50` | Spend cap for the single bounded retrieval call. |

(The adapter also uses an internal `SPECRELAY_CONTEXTPLUS_TMP_DIR` for
temporary files, which it sets and cleans up itself; it is not an operator
setting.)

## `doctor` reporting

`specrelay doctor` reports the configured context capability read-only, based
on `context.adapter` / `context.required`:

- `none` → informational: `Context capability: none (no context adapter
  configured)`.
- `contextplus` → `Context capability: contextplus (adapter registered;
  required=<value>)`.
- any other adapter name → a mandatory-check failure: `Context capability:
  unknown adapter '<name>'`.

`doctor` inspects configuration only; it does not run the adapter's preflight.

## Testing adapters

Adapters are testable without spending on any real retrieval: configure
`context.adapter: none` for a deterministic, always-succeeds preflight. The
`contextplus` adapter additionally treats the `manual` and `fake` role
providers as not-applicable, so a `fake`-provider run exercises the workflow's
preflight wiring without making a real Context Plus call, and its test-only
environment hooks above let a test point it at a substitute binary.
