# Configuration: `.specrelay/config.yml`

SpecRelay reads all project-specific settings from a single file at the root of
your project:

```
.specrelay/config.yml
```

This file is created by `specrelay init` (rendered from the bundled template)
and is meant to be committed with your project. It holds **only**
project-specific configuration and policy. By design it never contains:

- reusable engine code (that lives in SpecRelay itself, not your project);
- secrets or provider credentials (SpecRelay does not read credentials from
  here — provider auth is the provider CLI's own concern);
- machine-specific absolute paths (every path below is relative to the project
  root).

All defaults shipped in the template are **provider-neutral public defaults**.
Editing this file is how you point SpecRelay at your own spec layout, choose
executor/reviewer providers, and declare your validation command.

> **Generate this file with `specrelay init`, then edit it.** Creating
> `.specrelay/config.yml` by hand is a temporary bootstrap escape hatch, not the
> normal product path — a hand-written config that requires an unavailable
> context adapter is what caused an early dogfood run to fail before it could
> claim a task. `init` today writes a fixed template (it does not yet accept
> per-project spec root / providers / context adapter — a recorded follow-up),
> so some keys still need adjusting by hand afterward; see
> [installation.md](installation.md), "Preparing a repository: use `init`, not a
> hand-written config."

## Schema version

```yaml
version: 1
```

`version` declares which config schema the file targets. The current schema is
`1`. It is a forward-compatibility marker: keep it as `version: 1` for this
release. SpecRelay's config loader does not currently reject a file for its
`version` value — validation checks that the file is well-formed YAML with a
mapping at the top level (see **Config validation behavior** below) — but the
key is reserved so that future schema changes can be detected. Do not remove it.

## Key reference

Every key below appears in the template that `specrelay init` writes. Each entry
lists the key's purpose, type, default, and any accepted values that are
verifiable from the code. When a key is absent, SpecRelay falls back to the
default shown here.

### `version`

- **Purpose:** schema version marker (see above).
- **Type:** integer.
- **Default:** `1`.

### `project.name`

- **Purpose:** a human-readable label for the project. Reported by
  `specrelay status`/inspection output; not used to drive any behavior.
- **Type:** string.
- **Default:** at `init` time SpecRelay substitutes the project directory's
  basename. If the key is missing, inspection output shows `(not set)`.

### `specs.root`

- **Purpose:** directory (relative to the project root) where specification
  documents live. SpecRelay follows a one-directory-per-spec convention:
  `<specs.root>/<task-id>/spec.md`.
- **Type:** string (relative path).
- **Default:** `specs`.
- **Note:** a consumer project that keeps its specs elsewhere sets this
  explicitly. Spec paths are still resolved safely — a spec that resolves
  outside the project root is refused.

### `tasks.runs_root`

- **Purpose:** directory (relative to the project root) where SpecRelay keeps
  durable per-task run state (`state.json`) and evidence files.
- **Type:** string (relative path).
- **Default:** `.specrelay-runs/tasks`.
- **Note:** a consumer project that keeps its runtime evidence elsewhere — for
  example a repository migrating from a pre-existing `.ai-runs/tasks` workflow —
  can set this explicitly (e.g. `runs_root: .ai-runs/tasks`).

### `tasks.max_iterations`

- **Purpose:** cap on how many executor rework rounds `specrelay run` attempts
  before reporting "maximum iterations reached" instead of looping forever.
- **Type:** integer.
- **Default:** `3`.

### `roles.executor.provider`

- **Purpose:** which provider adapter implements the task in the executor role.
- **Type:** string.
- **Default:** `claude`.
- **Accepted values (verified in the provider dispatch):** `claude` (drives the
  Claude Code CLI) and `fake` (a deterministic adapter used for testing). Any
  other value is rejected at run time as an unsupported executor provider.

### `roles.reviewer.provider`

- **Purpose:** which provider adapter runs the review step.
- **Type:** string.
- **Default:** `manual`.
- **Accepted values:** `manual` is an explicit **opt-out / safe-bootstrap** mode
  — no automated decision is made, so both `specrelay run` and `specrelay resume`
  stop at `READY_FOR_REVIEW` (with a clear handoff message) and a human runs
  `specrelay task accept` / `specrelay task request-changes`. It is **not** the
  intended automated AI workflow. The automated reviewer adapters are `claude`,
  `claude-subagent`, and `fake` (deterministic, for testing). Any other value is
  rejected as an unsupported reviewer provider.
- **Automated continuation (spec 0010):** when the effective reviewer provider is
  **not** `manual`, `READY_FOR_REVIEW` is an internal handoff state, not the
  normal endpoint. Both `run` and `resume` continue from `READY_FOR_REVIEW` into
  reviewer execution in the same invocation and reach `READY_FOR_HUMAN_REVIEW`
  on acceptance. An automated reviewer failure leaves the task at
  `READY_FOR_REVIEW` with a clear recovery reason so it can be re-run/resumed.
- **`claude-subagent`:** **legacy shorthand**, not the preferred new form. It
  normalizes internally to `provider: claude` + `agent: ai-reviewer` +
  `model: provider-default`. Existing `provider: claude-subagent` configs keep
  working unchanged, but new configs should prefer the explicit three-key form
  (`provider` / `model` / `agent`) below. As before, `--agent ai-reviewer` is
  used only when the project provides `.claude/agents/ai-reviewer.md` (shipped as
  a template and installed by `specrelay init`; see
  [docs/installation.md](installation.md)) and the CLI advertises `--agent`;
  otherwise it runs as a plain `claude` reviewer.

### `roles.<role>.model`

- **Purpose:** which model the provider should use for the role (`<role>` is
  `executor` or `reviewer`).
- **Default:** `provider-default`.
- **Discover the options first:** run `specrelay models` (or
  `specrelay models <provider>`) to see, per configured provider, the supported
  configuration forms, the provider's declared aliases, and its honest
  model-discovery capability — **before** editing this key.

There are exactly **three** model-selection forms (spec 0014):

1. **Provider default** — let the provider CLI choose its own configured
   default. SpecRelay passes **no explicit model argument**; the literal string
   `provider-default` is never sent as a remote model id.

   ```yaml
   roles:
     executor:
       provider: claude
       model: provider-default
       agent: none
   ```

2. **Semantic alias** (structured form) — a provider-recognized alias such as
   `opus` or `sonnet`. **Aliases are provider-specific**: they are declared by
   the selected provider's own capability adapter and resolved through it
   deterministically. An alias declared by one provider is **never** accepted
   for another, and an alias the provider does not declare is rejected before
   the role runs.

   ```yaml
   roles:
     executor:
       provider: claude
       model:
         alias: opus
       agent: none
   ```

3. **Raw provider model ID** (structured form, advanced) — an exact
   provider-specific model identifier, passed to the provider **byte-for-byte**
   (never rewritten, prefixed, suffixed, or normalized).

   ```yaml
   roles:
     executor:
       provider: claude
       model:
         id: <exact-provider-model-id>
       agent: none
   ```

Roles select models fully independently — for example:

```yaml
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
```

- **Backward compatibility (legacy string syntax):** any non-`provider-default`
  plain string remains valid and continues to mean a raw provider model id —
  `model: some-provider-model-id` is exactly equivalent to
  `model: { id: some-provider-model-id }`. The structured `id:` form is the
  recommended syntax for **new** explicit raw identifiers. Existing
  configuration files and existing task state need no migration.
- **Provider behavior (`claude`):** for any explicit selection (alias or id),
  SpecRelay passes the Claude CLI model flag **only if `claude --help`
  advertises it** (`--model`). If an explicit model is configured but the
  installed CLI cannot accept model selection, the run **fails clearly** rather
  than silently ignoring the model, and `specrelay doctor` reports the mismatch.
- **Validation:** model configuration is validated during task preflight,
  **before the role is claimed** — a known-invalid selection never enters
  `EXECUTOR_RUNNING` or `REVIEWER_RUNNING` and the provider is never launched
  with it. The following are structural errors, each reported with the affected
  role, the config source (`.specrelay/config.yml`), and the expected forms:
  - a non-string, non-mapping model value (a YAML list, number, or boolean);
  - an **empty** or **whitespace-only** explicit model value;
  - a structurally invalid role configuration (e.g. `roles.executor` is not a
    mapping);
  - an invalid structured form: `model: {}`, an empty `alias:`/`id:`, **both**
    `alias` and `id` at once, an unknown key, or a nested (non-string)
    alias/id value. A model selection must resolve to exactly one of
    provider-default, alias, or raw id.

  Provider-aware validation is layered on top of the structural check:
  - an **unknown alias** is rejected before provider execution, with an
    actionable error listing the provider's supported aliases (plus a
    "Did you mean" suggestion when an unambiguous near-match exists) and the
    valid configuration forms;
  - a **raw id** is rejected locally only when the provider supports reliable
    (non-billable) model discovery and the id is not in that list. Otherwise a
    structurally valid raw id is **forwarded** with an honest note that its
    availability cannot be verified locally — SpecRelay keeps no global model
    allowlist and never falsely rejects an id based on an incomplete list. A
    provider **discovery failure** is reported as a discovery problem, never as
    an invalid user model.

  An **absent** model key is always valid and resolves to `provider-default`.
- **Manual roles:** a `manual` role never invokes an automated provider, so
  model selection is **not executed** for it — configured model fields on a
  manual role are **ignored** (not rejected), and no billable or automated
  provider call ever occurs for a manual role.
- **Configured vs. resolved:** SpecRelay tracks both the *configured* selection
  (e.g. `alias:opus`, `id:<raw>`, `provider-default`) and the *resolved* model
  the provider invocation actually receives (`opus` for a Claude alias; the raw
  id byte-for-byte; "provider-managed default" — no fabricated exact model —
  for `provider-default`). Both are shown by `specrelay doctor`,
  `specrelay models`, and `specrelay task show`.

### `roles.<role>.agent`

- **Purpose:** which provider-specific agent/profile/subagent the role should
  use (`<role>` is `executor` or `reviewer`).
- **Type:** string.
- **Default:** `none` — except a reviewer whose provider is the legacy
  `claude-subagent`, which defaults to `ai-reviewer` (see normalization above).
- **Meaning of `none`:** no provider-specific agent/profile/subagent is used.
- **`ai-reviewer`:** selects the bundled Claude reviewer sub-agent. As with the
  legacy shorthand, it is used only when the project provides
  `.claude/agents/ai-reviewer.md` and the CLI advertises `--agent`; otherwise the
  Claude reviewer runs as a plain reviewer and `doctor` warns.

> **provider / model / agent, summarized.** `provider` is the adapter/CLI that
> runs the role; `model` is the provider model id (or `provider-default`);
> `agent` is a provider-specific profile/subagent, usually `none` or
> `ai-reviewer`. Keeping them separate is what removes the old ambiguity where
> `claude-subagent` looked like a provider even though it is really the Claude
> provider plus the `ai-reviewer` agent.

### Role-specific environment overrides

Model and agent can be overridden per role from the environment, which takes
**precedence over `.specrelay/config.yml`**:

| Variable | Overrides |
|---|---|
| `SPECRELAY_EXECUTOR_MODEL` | `roles.executor.model` |
| `SPECRELAY_REVIEWER_MODEL` | `roles.reviewer.model` |
| `SPECRELAY_EXECUTOR_AGENT` | `roles.executor.agent` |
| `SPECRELAY_REVIEWER_AGENT` | `roles.reviewer.agent` |

The full resolution precedence for a role's effective `model`/`agent` is:

1. the role-specific env override above;
2. the value in `.specrelay/config.yml`;
3. normalized legacy provider behavior (e.g. reviewer `claude-subagent` →
   `agent: ai-reviewer`);
4. the provider default (`provider-default` / `none`).

An empty env override (set but blank) is treated as unset and falls through to
the config. Provider-specific env overrides may be added as future work; they
are intentionally not introduced here.

### Executor and reviewer models are independent

The executor and reviewer resolve their `provider` / `model` / `agent` fully
independently — they may use **different providers and different models**, and
neither role ever inherits the other's model. A mixed-provider example:

```yaml
roles:
  executor:
    provider: claude
    model: <claude-model-id>     # opaque, provider-specific — may change
    agent: none
  reviewer:
    provider: claude-subagent    # legacy shorthand for claude + ai-reviewer
    model: <claude-model-id>     # a DIFFERENT model id is allowed here
    agent: ai-reviewer
```

> Concrete model identifiers (like `claude-...` or a Codex model id) are
> **provider-specific and may change over time**. The placeholders
> `<claude-model-id>` / `<codex-model-id>` stand in for whatever your provider
> currently offers; SpecRelay treats them as opaque strings and never presents
> any identifier as permanently valid.

### Model configuration for existing tasks (resume)

The effective role configuration (provider/model/agent for both roles) is
**captured once**, into the task's durable `state.json` under `roles_effective`,
the first time the task reaches an executor iteration. The capture records the
**resolved** model value (what the provider invocation receives) plus the
configured selection metadata (`model_configured: {kind, value}` — e.g.
`{kind: alias, value: opus}`), so diagnostics can always show configured vs.
resolved. Old state files that captured only a string model remain fully
readable. That captured configuration is **authoritative for the rest of the
task's life**:

- If you change `roles.<role>.model` in `.specrelay/config.yml` **after** a task
  has started, resuming that task (`specrelay resume`) **does not** switch it to
  the new model — the executor and reviewer keep using the model captured at
  creation. This keeps a run deterministic and preserves its audit trail.
- Because the **resolved** value is captured, an alias is never silently
  re-resolved differently after task creation — even if the provider adapter's
  alias mappings change later, the existing task keeps the resolution captured
  when it started.
- A brand-new task created after the config change picks up the new model
  normally.
- `specrelay task show` prefers the captured `roles_effective` values over
  re-resolving the (possibly changed) live configuration, for the same reason.

If you deliberately want a task to adopt new model configuration, start a new
task rather than resuming the old one.

### `context.adapter`

- **Purpose:** the context capability adapter run for a role (validation →
  preflight → preparation) before that role does substantive work. See
  `context-adapters.md` for the full adapter contract.
- **Type:** string.
- **Default:** `none`.
- **Accepted values:** an adapter known to the installed SpecRelay version
  (`none`, `fake`, `contextplus`). Inspect them with `specrelay contexts`. A
  known-invalid adapter name fails **before** role execution and is reported
  as an error by `specrelay doctor`.

### `context.required`

- **Purpose:** whether a context failure (adapter unavailable, preflight
  failure, preparation failure, missing/unreadable required artifact) blocks
  the role. When required, the role never enters its running state on a
  context failure; when not required, the same failure degrades to an
  explicit warning (`continuing without external context because
  required=false`) and is recorded durably as `status: degraded`.
- **Type:** boolean (`true` / `false`). A non-boolean value is rejected
  before role execution.
- **Default:** `false`.

### `context.executor` / `context.reviewer` (role-specific overrides)

- **Purpose:** give the executor and reviewer DIFFERENT context adapters or
  required policies. Each subsection accepts the same `adapter` / `required`
  keys; resolution order per field is role-specific value → global value →
  built-in default (`adapter: none`, `required: false`).
- **Example:**

  ```yaml
  context:
    executor:
      adapter: contextplus
      required: true
    reviewer:
      adapter: none
      required: false
  ```

- Unknown keys under `context:` (or under a role subsection), a non-string or
  empty adapter name, and a non-boolean `required` are all rejected before
  role execution, with an error naming the role, the configuration source,
  the expected syntax, and the inspection command (`specrelay contexts`).
- The effective context configuration is **captured** into a task's durable
  state (`context_effective`) at its first executor iteration; resuming an
  existing task never silently switches adapters when the project
  configuration changes later (same principle as `roles_effective` above).

### `validation.full_test_command`

- **Purpose:** the command SpecRelay **reports** as this project's full
  test/validation suite. It is surfaced to operators and to prompts as the
  project's canonical validation command.
- **Type:** string.
- **Default:** a placeholder that prints a reminder to set the key:
  `echo 'set validation.full_test_command in .specrelay/config.yml'`.
- **Note:** SpecRelay does not silently execute this command on your behalf as
  part of config loading — set it to whatever validation your project actually
  supports, and treat the default as a prompt to replace it.

### `policy.human_final_review_required`

- **Purpose:** declares that a human must give the final review after the
  automated loop reaches `READY_FOR_HUMAN_REVIEW`.
- **Type:** boolean.
- **Default:** `true`.
- **Note:** the human final gate is enforced structurally by the task state
  machine — the automated loop stops at `READY_FOR_HUMAN_REVIEW` and does not
  commit or publish on its own. This key documents that policy; keep it `true`.

### `verification.*` (spec 0019, bounded verification policy)

- **Purpose:** the default number of times the Executor and Reviewer may run
  each verification operation (focused test, targeted/change-aware test, full
  standalone suite, smoke, doctor, version) before an ADDITIONAL run needs a
  recorded reason. This is a default policy, not an absolute ban — see
  [verification-and-timeline.md](verification-and-timeline.md).
- **Type:** a mapping with optional `executor:` and `reviewer:` subsections.
- **Default** (used entirely when `verification:` is omitted):

  ```yaml
  verification:
    executor:
      full_suite_max_runs: 1
      smoke_max_runs: 1
      doctor_max_runs: 1
      version_max_runs: 1
    reviewer:
      default_mode: targeted
      focused_max_runs: 3
      targeted_max_runs: 1
      full_suite_max_runs: 0
      smoke_max_runs: 0
      doctor_max_runs: 1
      version_max_runs: 1
  ```

- **Validation:** every `*_max_runs` value must be a non-negative integer;
  `reviewer.default_mode` must be one of `focused`, `targeted`, `full`;
  unknown keys under `verification:`, `verification.executor:`, or
  `verification.reviewer:` are rejected. A structurally invalid section is a
  mandatory `specrelay doctor` failure (every run with it would refuse before
  role execution).
- **Inspection:** `specrelay doctor` prints the effective policy for both
  roles. The effective policy is also captured durably into a task's
  `state.json` (`verification_policy_effective`) at its first executor
  iteration, so a later project-config change never silently changes the
  budget an in-flight task's Reviewer is held to mid-review.
- **Note:** these limits are enforced as **prompt-level policy plus
  observation/reporting** (the Executor/Reviewer prompts state the budget and
  require a recorded reason for exceeding it; the verification ledger reports
  what actually ran and flags unjustified duplicates) — SpecRelay does not
  kill arbitrary agent-issued commands to enforce this, per spec 0019's "Soft
  Limit versus Hard Refusal."

### `performance.phase_budgets.*` (spec 0019, phase budgets)

- **Purpose:** SOFT (advisory) per-phase duration budgets used only to
  produce warnings in the final execution-timeline report. Exceeding a budget
  never alters task state.
- **Type:** a mapping of `<phase>_seconds: <non-negative integer>`.
- **Default:**

  ```yaml
  performance:
    phase_budgets:
      executor_context_preflight_seconds: 30
      executor_evidence_capture_seconds: 120
      reviewer_context_preflight_seconds: 30
      reviewer_provider_seconds: 900
      reviewer_marker_recovery_seconds: 60
      finalization_seconds: 30
  ```

- **Validation:** every value must be a non-negative integer; unknown keys
  under `performance:` or `performance.phase_budgets:` are rejected.
- **Note:** Executor provider execution intentionally has no strict default
  budget (implementation complexity varies too widely); it may still get an
  advisory display in the timeline report.

## Config validation behavior

Config loading is intentionally minimal and safe. When SpecRelay validates
`.specrelay/config.yml` (for example during `specrelay doctor`), it does the
following and nothing more:

- **Requires the file to exist.** A missing config is reported with a clear
  error naming the expected path.
- **Requires a YAML parser.** SpecRelay reads the file with Ruby's standard
  YAML library using a safe loader (`YAML.safe_load` with no permitted custom
  classes and aliases disabled). This restricts parsing to plain scalars,
  arrays, and mappings and never instantiates arbitrary objects — so a config
  file cannot execute code or deserialize objects.
- **Rejects malformed structure with a clear error.** Both YAML syntax errors
  and disallowed constructs are reported as "malformed config", and a file
  whose top level is not a mapping (object) is rejected with an explicit
  message.
- **Reads values by dotted path.** Individual keys (e.g. `specs.root`) are read
  by walking the parsed mapping. A missing key returns the caller's default;
  there is no schema that rejects unknown/extra keys — unrecognized keys are
  simply never read. Field paths and the config path are passed to the parser as
  arguments, never interpolated into code, so values in the file cannot inject
  behavior.

In short: SpecRelay gives you clear errors for a missing or malformed file,
rejects a non-mapping top level, and never runs arbitrary code from your config.
It does not currently validate value ranges or reject typo'd keys, so a
misspelled key falls back to its default rather than raising.

Beyond this general shape check, SpecRelay additionally validates the **shape of
each role's `model`** before running a provider (spec 0012): a non-string,
empty, or whitespace-only explicit model, or a structurally invalid role
mapping, is rejected up front with an error naming the role and the config file
(see [`roles.<role>.model`](#rolesrolemodel) above). This is the one value-level
check the loader performs; it never validates a model id against a remote
allowlist.

### Doctor output for role models

`SPECRELAY_PROVIDER_OPTIONAL=1 specrelay doctor` reports the resolved execution
configuration for both roles and distinguishes an explicit model from the
`provider-default` sentinel — for example:

```
✓ Executor role: provider=claude model=<claude-model-id> agent=none
✓ Reviewer role: provider=claude model=provider-default agent=ai-reviewer
✓ Executor model source: explicit model '<claude-model-id>' (SpecRelay will request this exact model; the provider CLI validates that it exists)
✓ Reviewer model source: provider-default (delegated to the provider CLI; SpecRelay passes no explicit model-selection argument)
✓ Executor model selection: provider=claude kind=alias configured=alias:opus resolved=opus source=.specrelay/config.yml validation=provider-declared alias
✓ Reviewer model selection: provider=claude kind=provider-default configured=provider-default resolved=provider-managed default source=(built-in default) validation=structural (provider-managed default)
```

The `model selection` lines (spec 0014) report, per role, the provider, the
configured selection kind and value, the resolved model, the configuration
source (config file, environment override, or built-in default), and the
validation level actually applied. `provider-default` is reported as
"provider-managed default", never misrepresented as an exact model. A
structurally malformed or known-invalid selection (e.g. an alias the provider
does not declare) is a mandatory `doctor` failure, because every run with that
configuration would refuse before role execution.

`doctor` never performs a billable model invocation and never claims a specific
model is available — verifying that a model exists is the provider CLI's job
unless the provider supports reliable non-billable discovery.

## Minimal example

A minimal, working config differs from the template only where your project
does:

```yaml
version: 1

project:
  name: my-project

specs:
  root: specs

tasks:
  runs_root: .specrelay-runs/tasks
  max_iterations: 3

roles:
  executor:
    provider: claude
    model: provider-default
    agent: none
  reviewer:
    provider: manual
    model: provider-default
    agent: none

context:
  adapter: none
  required: false

validation:
  full_test_command: "make test"

policy:
  human_final_review_required: true
```

The defaults are **provider-neutral**: out of the box SpecRelay does not assume
a particular language, test runner, or repository layout. `specs.root` and
`tasks.runs_root` are generic (`specs/` and `.specrelay-runs/tasks`),
`validation.full_test_command` is a placeholder for you to replace, and the
provider keys name adapters rather than hardcoding a vendor into the engine.

## `.gitignore` guidance

By default `specrelay init` adds the top-level runtime-evidence directory
(derived from `tasks.runs_root`, e.g. `.specrelay-runs/`) to your `.gitignore`,
treating generated per-run evidence as non-source. If you prefer durable,
versioned task records, remove that entry so the runtime root is committed with
the rest of your project.
