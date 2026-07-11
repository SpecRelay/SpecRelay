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
- **Accepted values:** `manual` means no automated decision — the loop stops and
  a human runs `specrelay task accept` / `specrelay task request-changes`. The
  automated reviewer adapters are `claude`, `claude-subagent`, and `fake`
  (deterministic, for testing). Any other value is rejected as an unsupported
  reviewer provider.

### `context.adapter`

- **Purpose:** an optional context-retrieval capability run as a preflight
  before a role does substantive work.
- **Type:** string.
- **Default:** `none`.
- **Accepted values (recognized by the capability dispatch and `doctor`):**
  `none` performs no preflight; `contextplus` runs the Context Plus preflight
  adapter. An unknown adapter name is reported as an error by `specrelay
  doctor`.

### `context.required`

- **Purpose:** whether a failed context preflight is fatal. When required and
  the preflight fails, the role does not proceed; when not required, a failed
  preflight is a warning and work continues.
- **Type:** boolean.
- **Default:** `false`.
- **Accepted truthy values:** `1`, `true`, `True`, `TRUE`, `yes` are treated as
  true; anything else (including `false`) is treated as false.

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
  reviewer:
    provider: manual

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
