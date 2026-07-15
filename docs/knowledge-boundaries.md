# Knowledge Boundaries: Generic vs Provider-Specific vs Repository-Specific

> **Historical document.** This document historically classified generic vs.
> provider-specific vs. repository-specific knowledge for the former in-host
> SpecRelay architecture (`tools/specrelay/` incubated inside a host
> repository, `.ai/scripts/` compatibility shims, `.ai-runs/` task runtime).
> That architecture is no longer a supported current product surface. See
> README.md and docs/architecture.md for the current standalone architecture
> (`bin/specrelay` / installed `specrelay`, `.specrelay/config.yml`,
> `.specrelay-runs/`).

This document classifies what was learned reverse-engineering the current
`.ai/` workflow (see `current-workflow-contract.md`) into three categories, so
that a future SpecRelay core never hardcodes something that only happens to
be true of this repository or of the Claude Code CLI.

**Rule:** repository-specific knowledge (C3) must never be hardcoded into
`tools/specrelay/` (SpecRelay core or its adapters). It belongs in
`.specrelay/` (this repository's project-local configuration) or in project
documentation. This is the single most important review criterion for this
task (see the spec's "Human review guidance," item 2).

## C1. Generic SpecRelay core behavior

Confirmed by the current implementation, and not tied to Claude, Codex, or
Sprint Reports specifically:

- **Executor/reviewer role separation**, with role kept distinct from
  provider (any role can, in principle, be served by any capable provider).
- **Durable, file-based task state** (`state.json` plus numbered task files),
  restartable from disk with no reliance on session memory.
- **An explicit task state machine** (`DRAFT → READY_FOR_EXECUTOR →
  EXECUTOR_RUNNING → READY_FOR_REVIEW → {READY_FOR_HUMAN_REVIEW |
  CHANGES_REQUESTED → READY_FOR_EXECUTOR} `, plus a `BLOCKED` intervention
  state) with named, single-direction transitions.
- **Evidence packet capture**: git status/diff snapshots, executor
  log/tests/summary, reviewer notes/business-summary, captured independently
  of any one provider's output format.
- **Review / rework loops**: request-changes → requeue → a fresh executor
  round, repeating until accepted.
- **Runner-owned state transitions** for the specific transition that a
  running agent could otherwise abuse to self-approve its own work
  (`EXECUTOR_RUNNING → READY_FOR_REVIEW`), enforced via a short-lived,
  single-use, out-of-band authorization token minted only after the agent
  process has exited.
- **A human final gate** after the reviewer accepts, before anything is
  committed/published — the workflow's automation boundary stops there by
  design, not by omission.
- **Provider adapters as a seam**: the workflow already treats "which
  executor/reviewer CLI actually runs" as swappable configuration
  (`AI_EXECUTOR_PROVIDER`, `AI_REVIEWER_PROVIDER`), not as something baked
  into the state machine.
- **A context-capability abstraction**: "a role must prove it has real,
  working access to a context/retrieval tool before doing substantive work,
  with no silent fallback" is a generic capability-gating pattern, even
  though the only capability implemented today is Context Plus.
- **Dirty-working-tree protection**: refusing to start automated work when
  the working tree has changes the run cannot account for, is a generic
  safety property (the specific allow-list of "related" paths is
  repository policy — see C3).

## C2. Provider-specific behavior

Tied to a specific executor/reviewer CLI's actual invocation surface, not to
the workflow's own logic:

- **Claude Code CLI invocation details**: `claude --print`,
  `--dangerously-skip-permissions`, `--output-format stream-json`,
  `--verbose`, `--agent`, `--append-system-prompt`, and the fact that these
  flags are detected from `claude --help` rather than assumed.
- **The Claude sub-agent reviewer configuration** (`.claude/agents/ai-reviewer.md`)
  and its specific wrapped-prompt isolation instructions.
- **Provider-specific structured event streams**: Claude's `stream-json`
  JSONL shape and Codex's `exec --json` JSONL shape, and the
  provider-neutral renderer (`render_agent_events.py`) that normalizes both
  into the same generic "agent event" model — the *shapes* are
  provider-specific; the *renderer's normalized event model* is generic.
  the specific normalization adapters (Claude adapter, Codex adapter) are
  provider-specific code.
- **Codex CLI mode-detection** (`exec` subcommand vs `--print` flag,
  detected from `codex --help`), and Codex's separate, non-`.mcp.json` MCP
  registry (`codex mcp list` / `codex mcp add`).
- **Provider-specific permission flags** for non-interactive automation
  (`AI_CLAUDE_PERMISSION_ARGS`, `AI_CLAUDE_REVIEWER_PERMISSION_ARGS`).
- **The macOS-only native notification helper** (`.ai/runtime/macos-notifier/`,
  Swift + `UserNotifications`) is specific to the human-notification
  integration on this OS, not a generic workflow requirement (a different
  environment would need a different or no notifier).
- **Which providers currently pass the Context Plus preflight** (`claude`
  and `claude-subagent` do; `codex` does not in this environment) is a
  fact about provider capability today, not a property of the Context Plus
  abstraction itself.

## C3. Repository-specific policy

Applicable to Sprint Reports specifically, confirmed still applicable after
SDD 0082 (repository root promotion; `sprint_insights_app/` and `rails_app/`
no longer exist):

- **Specification root path**: `docs/sdd/<task-id>/spec.md` (this
  repository's SDD convention; a different project could put specs anywhere).
- **Project validation command**: `scripts/rails-test.sh` (wraps
  `bundle exec rspec` against a PostgreSQL test database, run from the
  repository root — no `cd sprint_insights_app` step anymore).
- **Forbidden/legacy paths**: `rails_app/` and `sprint_insights_app/` are
  called out by name in `CLAUDE.md` and the SDD 0083 spec as paths that no
  longer exist and must not be assumed present.
- **Canonical application boundary**: "the repository root is the single,
  canonical product app" (post-0082) is a fact about *this* repository's
  layout, not a general SpecRelay assumption — a different incubating
  repository could have a nested app directory.
- **Repository documentation requirements**: the `docs/business/` /
  `docs/updates/` Definition-of-Done rules in `CLAUDE.md` (business docs
  must be updated for behavior changes; every feature change gets a
  `docs/updates/YYYY-MM-DD-HHMM-*.md` entry with specific required
  sections) are Sprint-Reports-specific process policy, not something
  SpecRelay core enforces generically.
- **The dirty-working-tree guard's exact allow-list**: `.ai/` plus the
  *SDD-specific* `docs/sdd/<task-id>/` / `docs/SDD/<task-id>/` folder
  convention is repository policy layered on the generic "protect against
  unrelated changes" behavior (C1) — a project without an SDD convention
  would have a different (or no) second allow-listed path.
- **Context Plus as the mandatory context capability, and mandatory by
  default** (`AI_REQUIRE_CONTEXT_PLUS=1`): the *decision* to require Context
  Plus specifically, and to require it by default, is this repository's
  policy choice layered on the generic capability-gating abstraction (C1).
- **Project-specific review instructions**: the CLAUDE.md domain rules
  referenced by executor/reviewer prompts (e.g. "do not regenerate reports
  unless explicitly requested," "sick leave is private," Effective Dev Days
  rules) are pure Sprint Reports domain policy with no relevance to
  SpecRelay core at all.
- **`docs/migration/10-product-roadmap.md` and
  `docs/migration/11-spec-delivery-history.md`** as the specific
  roadmap/history documents this repository keeps updated per task — a
  different project would have different (or no) equivalent files.

## How this maps to the incubation structure

- `tools/specrelay/` (core + provider adapters) may encode C1 and, in a
  clearly-labeled adapter, C2 — but must never encode C3.
- `.specrelay/config.yml` exists specifically to hold C3 (and any
  project-specific selection of which C2 adapter to use) without leaking it
  into `tools/specrelay/`'s own code.
- Where this task's initial CLI (`workflow inspect`, `project inspect`)
  reports repository facts (e.g. the detected legacy workflow location, the
  configured spec root), those facts are *read from* `.specrelay/config.yml`
  and the filesystem at runtime — they are not literals inside
  `tools/specrelay/lib/specrelay/*.sh`.
