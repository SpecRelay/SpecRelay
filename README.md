# SpecRelay

From spec to reviewed change.

SpecRelay is a small, dependency-light command-line tool that runs a
specification through an **executor → reviewer → human** workflow: an AI
executor implements the spec, an independent AI reviewer accepts it or requests
changes, evidence is captured at every step, and a human always gives the final
review before anything is considered done.

> **Project status:** SpecRelay now lives in its own standalone GitHub
> repository (`git@github.com:SpecRelay/SpecRelay.git`, default branch `main`,
> which tracks `origin/main`). It grew out of a real, dogfooded AI development
> workflow and runs its own tests, installs itself, initializes other projects,
> and drives full workflows. It is **not** yet published to any package
> manager, and **open-source licensing is still pending a human decision** (see
> [`LICENSE.TODO`](LICENSE.TODO)). See
> [Current project status](#current-project-status).

---

## What is SpecRelay?

SpecRelay turns a written spec into a reviewed change through a disciplined,
evidence-producing loop:

1. You write a spec (`specs/0001-add-login/spec.md`).
2. `specrelay run <spec>` creates a task, has the **executor** provider
   implement it, captures the diff and evidence, then hands the result to an
   **independent reviewer** provider.
3. The reviewer either **accepts** (→ the task reaches
   `READY_FOR_HUMAN_REVIEW`) or **requests changes** (→ the executor does
   another round, up to a configured maximum).
4. A **human** performs the final review and accepts or rejects. SpecRelay
   never marks a task done on the AI's word alone.

Every step is recorded as durable, versionable evidence, so a task's history is
auditable long after it ran.

## Why it exists

AI coding agents are good at producing changes and bad at policing their own
work. SpecRelay adds the missing structure around them:

- **Separation of roles.** The thing that writes the change is never the thing
  that approves it. The reviewer runs in its own isolated context.
- **Evidence over vibes.** Decisions are backed by captured diffs, logs, and
  test output — not by a chat message that says "done."
- **A human gate that cannot be skipped.** The automated loop stops *before*
  the final decision; a person makes it.
- **Provider-neutral.** SpecRelay is not tied to one AI vendor. Providers are
  adapters; a deterministic `fake` provider makes the whole workflow testable
  without any AI at all.

## Workflow overview

```
spec ─▶ specrelay run
          │
          ▼
     ┌──────────┐     accept      ┌───────────────────────┐  human   ┌──────┐
     │ EXECUTOR │ ─▶ REVIEWER ─▶  │ READY_FOR_HUMAN_REVIEW │ ─review▶ │ done │
     └──────────┘                 └───────────────────────┘          └──────┘
          ▲     request changes         │
          └─────────────────────────────┘   (up to tasks.max_iterations rounds)
```

See [docs/task-lifecycle.md](docs/task-lifecycle.md) for the exact state
machine.

## Executor vs Reviewer

- **Executor** — the provider that implements the spec, produces the change,
  and writes evidence (executor log, tests output, executor summary).
- **Reviewer** — an *independent* provider that judges the executor's work
  against the spec, in a fresh context, and returns `accept` or
  `request_changes`. Because it does not share the executor's context, it is
  not primed to agree.

Both roles are selected in configuration and can be any adapter (`claude`,
`fake`, or a future one). See [docs/providers.md](docs/providers.md).

## Evidence-driven development

Each round writes durable artifacts (executor log, captured tests, executor
summary, Git diff/status snapshots). When the reviewer requests changes, the
prior round is **archived** (never overwritten) under `iterations/round-N/`,
so the full history of a task survives. Evidence is plain files you can read,
diff, and keep in version control.

## Human final gate

`policy.human_final_review_required: true` keeps a human in the loop by design.
The automated loop can only *reach* `READY_FOR_HUMAN_REVIEW`; it can never
perform the final accept. A person runs the final review. This is enforced by
the workflow engine, not just documented.

## Installation

No sudo, no system directories. Copy-based user installation into a prefix
(default `~/.local`):

```sh
./install/install.sh                 # installs to ~/.local
./install/install.sh --prefix "$HOME/.local"
```

This installs `<prefix>/bin/specrelay` (the CLI) and
`<prefix>/share/specrelay/` (its library, templates, and version). Add
`<prefix>/bin` to your `PATH` if it isn't already — the installer tells you if
it isn't. Update an installed copy from a local source with
`./install/update.sh --from /path/to/specrelay`. Full details:
[docs/installation.md](docs/installation.md).

**Requirements:** `bash`, `git`, `ruby` (YAML config parsing), and `python3`
(task state), plus standard POSIX tools. The `claude` provider additionally
needs the Claude CLI on `PATH`; the `fake` provider needs nothing extra.

## Quick start

```sh
./install/install.sh
cd my-project
specrelay init
specrelay run specs/0001-add-login/spec.md
```

`specrelay init` creates `.specrelay/config.yml` from the built-in template,
creates the spec root, and adds a safe `.gitignore` entry for runtime
evidence. Edit the config to choose your providers, then run a spec.

## Configuration

Project configuration lives in `.specrelay/config.yml` (created by
`specrelay init`). The public defaults are minimal and provider-neutral:

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
  full_test_command: "echo 'set validation.full_test_command'"
policy:
  human_final_review_required: true
```

Config holds only project policy — never secrets, credentials, or
machine-specific absolute paths. Every key is documented in
[docs/configuration.md](docs/configuration.md).

## Providers

Providers are adapters that implement the executor and reviewer roles:

- **`fake`** — deterministic, scriptable; used for testing the workflow with no
  AI involved.
- **`claude`** / **`claude-subagent`** — drive the Claude CLI. SpecRelay
  detects availability and never stores credentials in config.
- **`manual`** (reviewer only) — no automated decision; a human runs
  `specrelay task accept` / `specrelay task request-changes`.
- **your own** — implement the provider contract.

See [docs/providers.md](docs/providers.md).

## Context adapters

Before a role does substantive work, an optional **context capability**
preflight can run (e.g. to prove a code-context retriever is available). The
default adapter is `none`. `contextplus` is an optional, configured adapter.
See [docs/context-adapters.md](docs/context-adapters.md).

## Task lifecycle

`DRAFT → READY_FOR_EXECUTOR → EXECUTOR_RUNNING → READY_FOR_REVIEW →`
(`READY_FOR_HUMAN_REVIEW` on accept, or `CHANGES_REQUESTED →
READY_FOR_EXECUTOR` on request-changes, up to `tasks.max_iterations`). Full
detail and the evidence layout: [docs/task-lifecycle.md](docs/task-lifecycle.md).

## Safety model

- The executor cannot self-approve; the review submission requires a separate,
  short-lived authorization the executor process cannot obtain.
- A human always performs the final review.
- Task state (`state.json`) is only written through audited transitions, never
  by hand.
- Task IDs and runtime paths are validated; path traversal is refused.
- No credentials are stored in config; provider logs are not designed to carry
  secrets.
- Installing/updating the tool never rewrites a consumer project's config.

See [docs/architecture.md](docs/architecture.md) and
[SECURITY.md](SECURITY.md).

## Current project status

- **Standalone repository.** SpecRelay now lives in its own GitHub repository
  (`git@github.com:SpecRelay/SpecRelay.git`); the default branch `main` tracks
  `origin/main`. Its history was extracted from the origin host repository
  where it was incubated (see [docs/extraction.md](docs/extraction.md)); that
  extraction history is recorded honestly, which is why some reference docs
  still mention the old in-host path.
- **Providers supported today:** `fake` (deterministic) and `claude` /
  `claude-subagent`; `manual` for human review. Others can be added via the
  provider contract.
- **Not yet done (on purpose):** no package (Homebrew/npm/gem) is published and
  no release has been tagged. **Open-source licensing is still pending a human
  decision** — the GitHub repository exists and is visible, but no `LICENSE`
  has been granted yet (see [`LICENSE.TODO`](LICENSE.TODO)). Those remain later,
  explicitly-authorized steps.

Standalone readiness is tracked in
[docs/standalone-verification.md](docs/standalone-verification.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, the test command
(`scripts/test`), the architecture boundaries, and how to add provider or
context adapters.

## License

**Undecided.** No open-source license has been granted yet, so this project
does not include a `LICENSE` file. Candidate licenses under consideration
(recorded as options only, not applied) are **Apache-2.0** and **MIT**; a
maintainer must make the explicit decision. Until then, see
[`LICENSE.TODO`](LICENSE.TODO). Do not assume any usage rights beyond viewing
the source until a license is chosen.
