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

## Local developer configuration overlay (spec 0027)

Every key documented below lives in the **shared, committed** project
configuration (`.specrelay/config.yml`). A developer may ALSO create an
optional, personal overlay at:

```
.specrelay/config.local.yml
```

This file is never required for other developers, is Git-ignored (`specrelay
init` adds the ignore entry for you), and holds only the values you want to
change locally — you never copy the whole shared config into it.

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

### Why it exists

Editing the shared `.specrelay/config.yml` for a personal preference (a
faster local model, a longer timeout for your machine, a local-only service
command) creates Git noise and merge conflicts for every other developer.
The local overlay lets you change what you need without touching the file
everyone else shares.

### Precedence

```
built-in defaults < .specrelay/config.yml < .specrelay/config.local.yml
  < supported environment-variable overrides < explicit CLI flags
```

Higher layers override lower layers only where they actually provide a
value. No code path uses a different order.

### Deep-merge rules

- **Mappings deep-merge.** Setting `roles.executor.model` in the local file
  changes only that key; `roles.executor.provider` and `roles.executor.agent`
  keep their shared values.
- **Lists replace, never concatenate.** A list you set locally replaces the
  shared list wholesale — SpecRelay never merges list entries, since implicit
  concatenation could silently create duplicate commands or services.
- **An explicit YAML `null` removes the inherited value.** `roles.executor.agent: null`
  in the local file deletes the inherited `agent` key from the merged
  configuration entirely; SpecRelay's normal built-in default then applies
  wherever the accessor for that key defines one.
- **A type conflict fails clearly.** Replacing a mapping with a scalar (or a
  scalar with a mapping) at the same path is rejected with a path-specific
  error, e.g.:

  ```
  Invalid local configuration:
    source: .specrelay/config.local.yml
    error: roles.executor must be a mapping, got string
  ```

The local overlay is validated against the exact SAME schema as the shared
config after merging — there is no separate, reduced "local schema". Any key
documented in this file may be overridden locally, including
`roles.coordinator`, `context.*`, `verification.*`, `performance.phase_budgets.*`,
and `execution_efficiency.*`.

### Secret handling

The local overlay may hold local-only sensitive values (a personal API token,
a local-only service credential). SpecRelay never prints a secret-shaped
value: any key path whose last segment looks like `token`, `api_key`/`apikey`,
`secret`, `password`, `cookie`, `authorization`, `credential`, `private_key`,
`access_key`, or `client_secret` (case-insensitive) is redacted to
`[REDACTED]` in `specrelay doctor`, `specrelay config show`/`config explain`,
task evidence, and JSON output — the local file itself is never copied
wholesale into durable task evidence.

### Inspecting the effective configuration

```
specrelay config show [--effective] [--sources] [--json]
specrelay config explain <dotted.path>
```

`config show` reports whether the shared/local files are present and
loaded/invalid, the precedence order, and (with `--effective`) the fully
merged configuration with secrets redacted. `config explain` reports the
final value for one dotted path, which layer supplied it, and any
lower-priority value it replaced:

```
$ specrelay config explain roles.executor.model
roles.executor.model = claude-sonnet-5
source: .specrelay/config.local.yml
replaced: provider-default from .specrelay/config.yml
```

Both commands are entirely read-only: they never create a task and never
modify a configuration file.

### Task capture and resume

A task's effective configuration (shared/local presence, SHA-256 digests of
each loaded file, the precedence order, and which leaves the local overlay
actually overrode — secrets redacted) is captured into `state.json` the
first time the task reaches an executor iteration, alongside the existing
`roles_effective` / `context_effective` / `verification_policy_effective`
capture (spec 0009/0015/0019). That capture is **authoritative for the rest
of the task's life**: resuming a task never silently re-reads a
since-changed `.specrelay/config.yml` or `.specrelay/config.local.yml` and
switches its model, context adapter, or verification commands. If either
file changed since capture, `specrelay resume` prints an explicit note that
it is continuing with the captured configuration — create a new task to pick
up the new configuration. A task created before spec 0027 (or before its
first executor iteration) reports its configuration provenance honestly as
"not recorded" rather than fabricating one.

### Symlinks and discovery boundaries

`.specrelay/config.local.yml` is discovered ONLY at the current project
root — SpecRelay never searches parent directories, your home directory, or
another repository for it. If the file is a symlink, SpecRelay resolves it
and refuses to load it when the target lies outside the project root (a
clear, explicit error, never a silent skip).

### Example file

`specrelay init` also creates a committed, secret-free example at
`.specrelay/config.local.example.yml` — copy it to
`.specrelay/config.local.yml` for your own overrides. See that file for a
sparse-override starting point.

### Out of scope

This capability does not introduce a user-global configuration file (e.g.
`~/.config/specrelay/config.yml`), sync settings between developers, encrypt
the local file, or add a generic environment-variable mapping for every
configuration key — only the small, already-documented role overrides below
(`SPECRELAY_EXECUTOR_MODEL` etc.) participate in the environment layer.

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

### `tasks.archive_root`

- **Purpose:** directory (relative to the project root) where `specrelay task
  archive` moves completed (terminal-state) tasks. It is deliberately a sibling
  of `tasks.runs_root`, **outside** it, so archived tasks are never re-discovered
  by `task list`/`status`.
- **Type:** string (relative path).
- **Default:** `.specrelay-runs/archive`.
- **Note:** archiving is a plain, reversible move (nothing is deleted); to
  restore an archived task, move its directory back under `tasks.runs_root`.

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

### `roles.coordinator` (spec 0025, AI Coordinator)

The **coordinator** is an optional, advisory AI role (see
[docs/architecture.md](architecture.md), "Hybrid AI coordination model") that
recommends what should happen next; the deterministic engine alone decides
whether that recommendation is allowed and performs it. It is a distinct
concept from `roles.executor`/`roles.reviewer`: it is **disabled by default**,
and reuses `provider`/`model`/`agent` in the same shape.

```yaml
roles:
  coordinator:
    provider: claude          # default: claude
    model: provider-default   # same three forms as executor/reviewer
    agent: ai-coordinator     # default: ai-coordinator
    enabled: true              # default: false
    required: false            # default: false
    max_decision_attempts: 2   # default: 2
    timeout_seconds: 300       # default: 300
    confidence_threshold: none # one of: low, medium, high, none (default: none)
```

- **`enabled`** — `false` by default. When absent or `false`, the coordinator
  is never invoked and existing deterministic workflow behavior is
  **completely unchanged** (spec section 32, backward compatibility).
- **`required`** — whether a task's workflow depends on the coordinator being
  available (advisory policy only; the engine's own transitions never depend
  on the coordinator succeeding).
- **`max_decision_attempts`** — bounded retries (default 2) for an invalid
  coordinator response before the engine falls back to `REQUEST_HUMAN_DECISION`
  (spec section 28, "Coordinator retry policy"). Must be a non-negative
  integer.
- **`timeout_seconds`** — advisory per-invocation timeout budget (default 300).
- **`confidence_threshold`** — advisory only; a coordinator's self-reported
  `confidence` (`low`/`medium`/`high`) never weakens deterministic validation
  (spec section 13.1).
- **`provider`/`model`/`agent`** resolve through the exact same accessors as
  executor/reviewer (`roles.coordinator.model` accepts `provider-default`,
  `{ alias: ... }`, or `{ id: ... }`); `model`/`agent` may also be overridden
  per-role from the environment in the same way (see below).
- **Coordinator context** (spec 0025, section 20) is configured and captured
  **independently** of the executor/reviewer context, via the same `context:`
  block:

  ```yaml
  context:
    coordinator:
      adapter: contextplus
      required: true
  ```

  Coordinator context is read-only in purpose and never inherits Executor or
  Reviewer conversational state — it receives only deterministic summaries
  and immutable artifacts the engine chooses to hand it.
- **Effective configuration capture:** the first time a task invokes the
  coordinator, its resolved `provider`/`model`/`agent` are captured into
  `state.json` (`roles_effective.coordinator`) and remain authoritative for
  that task's whole lifetime — a later project-config change never
  retroactively changes a running task's coordinator identity (same
  capture-once contract as executor/reviewer, spec section 35).
- **Inspect readiness with `specrelay doctor`** — reports Coordinator
  disabled/configured/provider-availability/context-readiness **independently**
  of Executor/Reviewer readiness (a coordinator misconfiguration never masks,
  or is masked by, Executor/Reviewer checks).
- **Inspect activity with `specrelay task show <ref>` / `specrelay task report
  <ref>` / `specrelay task coordination <ref> [--json]`** — last invocation
  point, last validated decision, invocation/invalid/human-decision-request
  counts, and the decision-log path. A task that never invoked the
  coordinator reports this honestly as "not recorded", never fabricated.

### Role-specific environment overrides

Model and agent can be overridden per role from the environment, which takes
**precedence over both `.specrelay/config.yml` and `.specrelay/config.local.yml`**:

| Variable | Overrides |
|---|---|
| `SPECRELAY_EXECUTOR_MODEL` | `roles.executor.model` |
| `SPECRELAY_REVIEWER_MODEL` | `roles.reviewer.model` |
| `SPECRELAY_EXECUTOR_AGENT` | `roles.executor.agent` |
| `SPECRELAY_REVIEWER_AGENT` | `roles.reviewer.agent` |

The full resolution precedence for a role's effective `model`/`agent` is:

1. the role-specific env override above;
2. the value in `.specrelay/config.local.yml` (spec 0027), if set;
3. the value in `.specrelay/config.yml`;
4. normalized legacy provider behavior (e.g. reviewer `claude-subagent` →
   `agent: ai-reviewer`);
5. the provider default (`provider-default` / `none`).

An empty env override (set but blank) is treated as unset and falls through to
the config. Provider-specific env overrides may be added as future work; they
are intentionally not introduced here. `specrelay config explain` recognizes
exactly these four variables as the environment layer for their respective
paths; it does not invent a generic environment-variable mapping for every
configuration key (spec 0027, section 19).

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

### `bundle.require_functional_spec` (spec 0023)

- **Purpose:** whether a specification **directory** input must have
  `spec.md` at its root. Never applies to a single-file input (the file is
  always the specification, regardless of its name).
- **Type:** boolean.
- **Default:** `true`. SpecRelay never silently accepts a missing `spec.md`
  and guesses the objective — task creation fails with an actionable error
  instead.

### `bundle.exclude` (spec 0023)

- **Purpose:** extra comma-separated exclusion patterns for directory
  discovery, on top of the built-in defaults (`.git/`, `.specrelay-runs/`,
  `node_modules/`, `.DS_Store`, `*.tmp`, `*.swp`).
- **Type:** string (comma-separated glob/name patterns).
- **Default:** `""` (no extra exclusions).

### `bundle.max_files` / `bundle.max_total_bytes` (spec 0023)

- **Purpose:** discovery limits for a specification directory. Exceeding
  either fails task creation clearly, reporting the affected path, file
  count, bundle size, and the applicable limit — never a silent partial
  ingestion.
- **Type:** integer.
- **Default:** `max_files: 2000`, `max_total_bytes: 209715200` (200 MiB).

### `jam.retrieval_command` (spec 0023)

- **Purpose:** the real retrieval adapter for a referenced Jam recording:
  any executable invoked as `<cmd> <canonical-id> <url> <out-dir>`, expected
  to write `<evidence-class>.raw` files (e.g. `transcript.raw`,
  `network-errors.raw`) into `<out-dir>` for whatever evidence it can
  retrieve, then exit `0`. SpecRelay normalizes, redacts, and snapshots
  whatever it finds; missing evidence classes are reported honestly rather
  than failing the whole retrieval. See `jam-capability.md`.
- **Type:** string (a command; not validated beyond existence at retrieval
  time).
- **Default:** unset — a Jam reference with no configured adapter fails
  retrieval clearly rather than fabricating success.

### `jam.required` (spec 0023)

- **Purpose:** global Jam capability policy. Jam is optional by default: its
  absence never fails `specrelay doctor`'s overall readiness, and a project
  with no Jam configuration and no task referencing Jam is fully usable.
  Setting this to `true` makes Jam globally required (an unready Jam then
  fails overall `doctor` readiness too). Independently of this setting, a
  task whose bundle contains a recognised Jam reference always requires Jam
  for that task — see `jam-capability.md`.
- **Type:** boolean.
- **Default:** `false`.

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

### `verification.*` (spec 0026, verification-policy engine)

- **Purpose:** a first-class, multi-service, multi-check verification
  policy — an alternative to (never simultaneous with) the legacy
  `validation.full_test_command` string above. Coexists with the spec-0019
  keys documented in the previous section under the same `verification:`
  mapping (disjoint sub-keys: this section only recognizes `version`,
  `defaults`, `placement`, `services`, `risk_rules`).
- **Shape:**
  ```yaml
  verification:
    version: 1
    defaults:
      level: changed              # changed | full | flexible
      changed_fallback: full      # changed | full
      concurrency: 4
      timeout_seconds: 900
      shell: bash
    placement:
      executor: changed           # none | changed | targeted | full | flexible
      reviewer: targeted
      final_gate: full
    services:
      - name: backend
        root: services/backend
        affected_paths: ["services/backend/**", "shared/contracts/**"]
        checks:
          - name: unit
            kind: unit             # unit|lint|typecheck|build|integration|
                                    # contract|smoke|security|custom|ui (spec 0028)
            command: bundle exec rspec
            cwd: services/backend  # repo-relative; no absolute path or '..'
            timeout_seconds: 1200
            required: true
            levels: [changed, full]
            depends_on: []
            parallel_group: backend-fast
            enabled: true
            environment: [RAILS_ENV, DATABASE_URL]   # NAMES only, never values
    risk_rules:
      - name: shared-contract-change
        paths: ["shared/contracts/**"]
        force_level: full
        rationale: Shared contracts may affect every service.
  ```
- **Selection:** `changed` selects services matched by `affected_paths`/
  `always_affected_by` against the actual changed paths (both old and new
  path for a rename); an unmatched changed path triggers `changed_fallback`
  (default `full`), never silent omission. `full` selects every check whose
  `levels` includes `full`. `flexible` resolves deterministically (matched
  risk rules, more than one distinct affected service, or a prior recorded
  required-check failure for the task escalate to `full`; otherwise it
  resolves like `changed`) and always records why. `placement.reviewer:
  targeted` narrows to required checks (plus anything a matched risk rule
  requires) rather than repeating the Executor's full check list.
- **Dependencies:** `depends_on` (check identities `<service>.<check>`) are
  validated (unknown identity, or a cycle, fails configuration before any
  execution) and enforced at run time — a dependent check never starts
  before its dependency passes, and becomes `BLOCKED_BY_DEPENDENCY` (or
  `BLOCKED_OPTIONAL`) when its dependency fails.
- **Execution:** independent checks run concurrently up to
  `defaults.concurrency`; each check gets its own `command.json`/
  `stdout.txt`/`stderr.txt`/`result.json` (never shared/mixed between
  checks); a check exceeding its `timeout_seconds` is terminated and
  recorded `TIMED_OUT`/`TIMED_OUT_OPTIONAL` (never reported as passed).
  `environment` declares variable NAMES only — the check's real
  environment already inherits them from the running process; durable
  evidence never records a value, and any name that looks secret-shaped
  (`TOKEN`, `SECRET`, `PASSWORD`, `DATABASE_URL`, ...) is listed separately
  as `redacted_names`.
- **AI roles:** may request a level or a named, already-configured check
  subset — never arbitrary shell text, an unknown check, or a narrowing
  that excludes a required check. `specrelay verification plan` previews a
  selection with no execution; `specrelay verification run` executes it.
- **Legacy compatibility:** a project with only `validation.full_test_command`
  set is automatically treated as one service (`project`) with one check
  (`project.full-test`, `levels: [full]`); `specrelay doctor` reports this as
  `Verification-policy engine: mode=legacy ...`. A project with neither
  `validation.full_test_command` nor a `verification.services` block reports
  `Verification-policy engine (spec 0026): absent`. Configuring both
  `validation.full_test_command` and a new-style `verification.services` at
  once is an ambiguity error, not a silently-resolved default.
- **Inspection:** `specrelay doctor` reports configuration mode (new/legacy/
  absent/invalid), service/check counts, defaults, placement, missing
  service working directories, and a warning (never a failure) when the
  full suite is placed at every phase without distinct rationale.
  `specrelay task show`/`task report` show the recorded overall status,
  required/optional pass-fail counts, and evidence path; a historical task
  with no recorded run honestly reports "Verification policy: not recorded."

### `verification.ui.*` (spec 0028, UI runtime verification)

- **Purpose:** first-class UI runtime verification for tasks that change
  user-visible behaviour — a deterministic Playwright-driven (or fake,
  no-browser-required) scenario engine, compact checkpoint-screenshot
  evidence, browser-console/network capture with redaction, and optional
  expected-reference comparison. Lives under the SAME top-level
  `verification:` mapping as the sections above (a disjoint `ui` key —
  never validated by the spec-0019/0026 parsers, only recognized so they do
  not reject it as unknown).
- **Shape (defaults shown):**
  ```yaml
  verification:
    ui:
      enabled: auto                     # true | false | auto
      required_when_detected: true
      provider: playwright              # playwright | fake
      browsers: [chromium]              # chromium | firefox | webkit
      detection:
        paths: []                       # extra glob patterns, e.g. app/views/**
      runtime:
        start_command: bin/dev
        working_directory: .
        ready_url: http://127.0.0.1:3000/health
        ready_timeout_seconds: 120
        stop_command: null
      scenarios:
        manifest: .specrelay/ui-scenarios.yml
      screenshots:
        mode: checkpoints                # checkpoints | off
        retain_source: false
        crop: important-region           # important-region | full-viewport | full-page
        max_width: 1600
        max_height: 1200
        max_file_bytes: 750000
        format: png                      # png | jpeg
      video:
        mode: off                        # off | on-failure | explicit
      trace:
        mode: on-failure                 # off | on-failure | always
      console:
        fail_on: [error]                 # error | warning
      network:
        fail_on_status: ["500-599"]      # ranges or exact codes
      expected_references:
        policy: compare-when-present     # ignore | compare-when-present | required
      publication:
        enabled: true
        destination: spec-directory
        path: verification/ui
  ```
- **`enabled`:** `true` always requires UI verification; `false` disables it
  UNLESS the task is explicitly marked UI-impacting AND
  `required_when_detected: true`, which produces a configuration-conflict
  error rather than a silent skip; `auto` (default) detects impact from
  changed paths matching `detection.paths`, specification language (page,
  form, button, link, view, layout, screenshot, Playwright, CSS, JavaScript,
  template, visual), supplied expected references, or explicit task
  metadata — every detection result is recorded WITH its reasons.
- **Scenarios:** come from the configured manifest, the specification
  bundle, or acceptance criteria resolved into reusable flows — never
  unbounded browser exploration. Each scenario has an `id`, `title`,
  non-empty `acceptance_criteria`, `steps` (closed action vocabulary:
  `goto`/`click`/`fill`/`select`/`check`/`uncheck`/`hover`/`press`/
  `wait_for`), `assertions` (`visible`/`absent`/`text`/`value`/`url`/
  `count`), and optional `checkpoints` (a locator or bounding region — see
  docs/verification-and-timeline.md, "UI runtime verification", for the
  full example).
- **Local override compatibility (spec 0027):** every key above participates
  in the generic `.specrelay/config.local.yml` deep-merge; a developer can
  override just `runtime.start_command`/`runtime.ready_url`/`browsers`
  locally without repeating the rest of the committed configuration.
- **Screenshots:** locator/element capture is preferred over a full-page
  screenshot (disabled by default); an intermediate source image used only
  to produce a crop is deleted, never published (`retain_source: false`);
  exact-digest duplicates are never published twice; a screenshot that
  cannot meet `max_width`/`max_height`/`max_file_bytes` without becoming
  unreadable BLOCKS the scenario with an explicit reason rather than
  guessing.
- **Video/trace:** video is disabled by default and never published even
  when enabled; trace is captured only per `trace.mode` (default
  `on-failure`), stays in task runtime evidence, and is never published.
- **Expected references:** `ignore` skips visual comparison entirely;
  `compare-when-present` compares whenever a mapped reference exists and
  otherwise states plainly that visual equivalence was not assessed;
  `required` BLOCKS when a mapped reference is missing. This reference
  implementation's comparison method is exact-digest equality
  (`sha256-exact`) — recorded honestly as such, since no new image-diff
  dependency is introduced.
- **Publication:** `specrelay ui publish <task-ref> <spec-relpath>
  [--dry-run]` writes only the compact, Reviewer-validated package to
  `<spec-directory>/<publication.path>/` (default `verification/ui/`) —
  never source screenshots, videos, traces, or raw runtime logs.
  Publication REFUSES (even `--dry-run`) until the task's Reviewer evidence
  file contains a `## UI Verification Evidence Review` section.
- **Completion gate:** a UI-impacting task cannot reach
  `READY_FOR_HUMAN_REVIEW` while UI verification is required but missing,
  incomplete, FAILED, BLOCKED, or unreviewed — enforced in
  `transitions.sh::accept`, the only path into that state (see
  docs/task-lifecycle.md).
- **Inspection:** `specrelay ui plan <task-ref>` (detection reasons,
  selected scenarios, coverage, runtime-readiness projection — no browser
  execution), `specrelay ui run <task-ref> [--resume]`, `specrelay ui report
  <task-ref>`, and `specrelay doctor` (configuration readiness: provider/
  browser availability, scenario manifest validity, expected-reference
  policy, publication destination — never task-specific runtime readiness).

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

`specrelay init` also adds `.specrelay/config.local.yml` to your `.gitignore`
(spec 0027) — unlike the runtime-evidence entry above, this one should NOT be
removed: the local overlay is personal-only by design and may contain
local-only sensitive values. `specrelay doctor` reports a warning (or a
mandatory failure, if the file contains a secret-shaped key and is
trackable) if a local overlay exists but is not Git-ignored. `specrelay
init`/an explicit future repair command are the only things that change your
`.gitignore` — `run`, `resume`, and `doctor` never modify it.
