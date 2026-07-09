# Current Workflow Contract (as-built)

This document describes the **actual behavior** of the existing local AI
workflow implemented under `.ai/` in this repository, as reverse-engineered
from its real scripts (`.ai/scripts/`, `.ai/scripts/internal/`), its protocol
and reviewer documents (`.ai/protocol.md`, `.ai/reviewer.md`), and real task
artifacts under `.ai-runs/tasks/`. It is not an aspirational redesign. Where
the workflow has a known limitation, that limitation is recorded here rather
than hidden.

This is the primary deliverable of SDD 0083 (incubate SpecRelay from the
existing AI workflow). It is written to survive the eventual engine migration
(future SDD 0084) as the ground truth of "what must keep working."

Repository layout note: SDD 0082 promoted the Rails app from
`sprint_insights_app/` to the repository root and removed `rails_app/`
entirely. Both no longer exist. Historical task evidence written before 0082
references the old paths; this document describes current behavior only.

## 1. Purpose

The workflow exists to let a human collaborate safely with two AI roles
(executor, reviewer) to turn an approved task description into a reviewed,
evidence-backed code change — without ever auto-committing, auto-publishing,
or skipping human judgment. Its stated design goals (from `.ai/protocol.md`
and `.ai/README.md`):

- Every agent run must be **restartable from files only**. Session memory is
  not the source of truth; the repository plus `.ai/` and `.ai-runs/` are.
- Keep an auditable path from "task described" to "ready for review."
- Keep a human in control: nothing commits automatically; human approval
  gates execution (`READY_FOR_EXECUTOR`); human final review always follows
  `READY_FOR_HUMAN_REVIEW`.

## 2. Roles

Role and **provider** are explicitly separate concepts in this workflow.

| Role | What it does | Provider selection |
|---|---|---|
| **Human** | Final decision maker. Approves tasks (`approve-task.sh`), performs final review after `READY_FOR_HUMAN_REVIEW`, decides whether/when to commit. Nothing downstream of `READY_FOR_HUMAN_REVIEW` is automated. | n/a |
| **Consultant / planner** | Analyzes the request and writes `00-user-request.md` / `01-consultant-analysis.md` / `02-executor-prompt.md`. Manual and **not** provider-configurable — no `AI_PLANNER_PROVIDER` exists. Typically a human using Codex UI / ChatGPT, or (for SDD tasks) `start-spec-task.sh` itself, which fills these files programmatically from `spec.md`. | n/a (manual/scripted) |
| **Runner / orchestrator** | The shell scripts (`run-executor.sh`, `run-reviewer.sh`, `run-workflow.sh`, `run-ai-loop.sh`) that own state transitions, evidence capture, and provider dispatch. Never itself an LLM. | n/a |
| **Executor agent** | Implements the approved task's prompt, writes `03-executor-log.md` / `07-tests.txt` / `08-executor-summary.md`. Never creates the next task, never continues automatically, never owns its own state transition. | `AI_EXECUTOR_PROVIDER` (`claude` — the only supported value today) |
| **Reviewer agent** | Reviews the executor's evidence against the spec/prompt and the real working tree, decides accept / request-changes. Never implements, never commits. | `AI_REVIEWER_PROVIDER` (`codex` default, `manual`, or `claude-subagent`) |

Provider selection never changes what a role is allowed to do; it only
chooses which concrete tool performs that role. This separation is the
central generic concept SpecRelay's core must preserve (see
`knowledge-boundaries.md`).

## 3. Task identity

- **Task ID.** A safe path-segment string matching `^[A-Za-z0-9._-]+$` (no
  slashes, whitespace, or shell metacharacters). For ordinary tasks the human
  chooses it (`start-ai-task.sh <task-id>`). For SDD tasks,
  `start-spec-task.sh` derives it from the spec's parent folder name (e.g.
  `docs/sdd/0083-incubate-specrelay-from-existing-ai-workflow/spec.md` →
  `0083-incubate-specrelay-from-existing-ai-workflow`), preserving ticket-like
  prefixes; `--task-id` can override it.
- **Task directory.** Always `.ai-runs/tasks/<task-id>/`, resolved from the
  git repository root (`git rev-parse --show-toplevel`), never from the
  caller's current working directory. `.ai-runs/` is gitignored — task
  folders are durable local state, never committed, never part of the
  reviewed diff.
- **Spec source-of-truth relationship.** For an SDD task, `spec.md` on disk
  (under the configured spec root, `docs/sdd/<task-id>/spec.md` in this
  repository) is the single source of truth for what to build.
  `00-user-request.md` embeds it (verbatim, or a marked excerpt for specs
  over 400 lines) but explicitly defers to the file on disk if they disagree.
  For a non-SDD task, the consultant-authored `02-executor-prompt.md` plays
  the equivalent role; there is no separate spec file.

## 4. Task lifecycle (state machine, derived from code)

Canonical states, defined in `.ai/scripts/internal/lib/ai_state.py` and used
consistently by every transition script:

```text
DRAFT
  ↓ approve-task.sh            (human approval gate; also allowed from WAITING_FOR_HUMAN)
READY_FOR_EXECUTOR
  ↓ claim-task.sh (via run-executor.sh)
EXECUTOR_RUNNING
  ↓ authorize-submit.sh -> submit-review.sh   (or authorize-finish.sh -> finish-task.sh)
READY_FOR_REVIEW
  ├─ accept-review.sh ──────────────→ READY_FOR_HUMAN_REVIEW
  └─ request-changes.sh ────────────→ CHANGES_REQUESTED
                                         ↓ requeue-task.sh (re-enters as a fresh executor round)
                                    READY_FOR_EXECUTOR
EXECUTOR_RUNNING
  ↓ block-task.sh (intervention path; executor cannot complete)
BLOCKED
```

`READY_FOR_HUMAN_REVIEW` is non-terminal from the workflow's point of view
(nothing further is automated) but is the intended stopping point of every
successful run; `DONE`, `FAILED`, and `WAITING_FOR_HUMAN` are recognized
state names in the protocol/state model but no current transition script
writes them — `WAITING_FOR_HUMAN` is only read as an alternate
pre-`READY_FOR_EXECUTOR` state that `approve-task.sh` accepts, and `BLOCKED`
is the only implemented "stuck" terminal-ish state. A legacy alias,
`READY_FOR_CODEX_REVIEW`, is normalized read-only to `READY_FOR_REVIEW` by
`ai_state.normalize_state`; nothing new is ever written with the legacy name.

## 5. Transition ownership

| Transition | Owner / helper | Authorization | May an agent perform it directly? |
|---|---|---|---|
| `DRAFT`/`WAITING_FOR_HUMAN` → `READY_FOR_EXECUTOR` | Human, via `approve-task.sh` | None beyond being run by a human | No — this is the human-approval gate itself (`.ai/protocol.md` Safety Rules: "Human approval is required before any task becomes READY_FOR_EXECUTOR"). |
| `READY_FOR_EXECUTOR` → `EXECUTOR_RUNNING` | Runner, via `claim-task.sh` (called by `run-executor.sh`) | None (idempotency comes from the allowed-source-state check) | Not meaningfully — an executor agent is only launched *after* this transition already happened. |
| `EXECUTOR_RUNNING` → `READY_FOR_REVIEW` | Runner ONLY, via `submit-review.sh` (normal path) or `finish-task.sh` (manual-recovery path) | **Runner-owned, code-enforced.** Both scripts refuse to run without a short-lived, single-use transition token minted by `authorize-submit.sh` / `authorize-finish.sh` respectively, stored outside the task folder (`.ai-runs/.transition-auth/`, gitignored), passed only as a scoped env var, and destroyed on first use or on any exit path. The token is only minted *after* the executor provider process has already exited. | No — an executor agent calling either script directly is refused (no valid token exists while it is still running). `authorize-submit.sh`/`authorize-finish.sh` themselves are supported **human** manual-recovery entry points and do not verify the caller is human — this is a documented, accepted gap (see §11). |
| `READY_FOR_REVIEW` → `READY_FOR_HUMAN_REVIEW` | Reviewer agent/human, via `accept-review.sh` | Requires `09-consultant-review.md` and `10-business-summary.md` to be non-empty first | This IS the reviewer's job; it is the reviewer decision path, not runner-owned. |
| `READY_FOR_REVIEW` → `CHANGES_REQUESTED` | Reviewer agent/human, via `request-changes.sh` | Requires `09-consultant-review.md` and `11-next-executor-prompt.md` to be non-empty first | This IS the reviewer's job. |
| `CHANGES_REQUESTED` → `READY_FOR_EXECUTOR` | Orchestrator, via `requeue-task.sh` | Requires `11-next-executor-prompt.md` non-empty; backs up the old `02-executor-prompt.md` (non-destructively, timestamped) and promotes `11-next-executor-prompt.md` to `02-executor-prompt.md`, always re-appending the mandatory ownership-contract footer | Not meaningfully agent-callable in the normal flow; called by `run-workflow.sh` when it dispatches a `CHANGES_REQUESTED` task. |
| `EXECUTOR_RUNNING` → `BLOCKED` | Human/operator, via `block-task.sh` | None beyond the allowed-source-state check | Intervention path; not part of automated dispatch. |

`run-workflow.sh` (the one-step orchestrator used by `run-ai-loop.sh`)
composes these helpers by state, and is itself the enforcement point that no
execute/review loop can happen in a single call: executor-side states
(`READY_FOR_EXECUTOR`, `CHANGES_REQUESTED`) always stop at
`READY_FOR_REVIEW`, even when `--reviewer` is passed; the reviewer only runs
when the task is *already* `READY_FOR_REVIEW` and `--reviewer` was passed
explicitly.

## 6. Executor contract

Implemented by `run-executor.sh`, per task, in this order:

1. **Provider resolution** — loads/validates `AI_EXECUTOR_PROVIDER` via
   `load-ai-config.sh` (env → `.ai/config.env` → default `claude`; `claude` is
   the only currently-supported value).
2. **Task selection** — an explicit task id, or the single task currently
   `READY_FOR_EXECUTOR` (refuses if more than one is eligible and none was
   named).
3. **Dirty-working-tree guard** — refuses to run if `git status --porcelain`
   shows anything outside `.ai/` and (for an SDD task) the exact matching
   `docs/sdd/<task-id>/` (or `docs/SDD/<task-id>/`) folder/spec/expect files,
   or the exact "Spec source path" recorded in `00-user-request.md`. This is
   evaluated *before* claiming, so a blocked run never touches task state.
   See §9 for the known limitation this guard has on the requeue path.
4. **Mandatory Context Plus preflight** (`context-plus-preflight.sh --role
   executor`) — see §10. Runs BEFORE claiming; a failed preflight leaves the
   task at `READY_FOR_EXECUTOR`, un-claimed.
5. **Claim** (`claim-task.sh`) — `READY_FOR_EXECUTOR` → `EXECUTOR_RUNNING`.
6. **Stale-artifact reset** — `03-executor-log.md` / `07-tests.txt` /
   `08-executor-summary.md` are backed up (if non-empty, e.g. from a previous
   rejected round) and truncated, so a pass can only occur if *this* run
   actually (re)writes them — closes a gap where a requeued executor that
   exits 0 without writing new outputs could otherwise be submitted describing
   stale prior-round work.
7. **Execution** — runs the provider CLI non-interactively
   (`claude --print "<02-executor-prompt.md contents>"`, with
   `--dangerously-skip-permissions` by default since `--print` cannot answer
   interactive prompts), streaming stdout/stderr live (unless
   `AI_LIVE_OUTPUT=0`) while persisting to `12-claude-stdout.txt` /
   `13-claude-stderr.txt` (and, when the installed CLI advertises
   `stream-json`, the raw structured event stream to
   `19-executor-events.jsonl`, rendered live as concise activity lines with
   private reasoning never shown).
8. **Evidence capture** (`capture-evidence.sh`) — always attempted after the
   provider exits, regardless of its exit code; writes `04-git-status.txt`,
   `05-changed-files.txt`, `05-git-diff-stat.txt`, `06-git-diff.patch` (using
   `git add --intent-to-add` + `git reset` around the diff so new untracked
   files show up as full additions, then are restored to untracked).
9. **Required-outputs check** — `03-executor-log.md`, `07-tests.txt`,
   `08-executor-summary.md` must all exist and be non-empty.
10. **Submit-for-review, ONLY if** the provider exited 0 AND the required
    outputs are present AND evidence capture succeeded — via
    `authorize-submit.sh` (mints a one-time token, then calls
    `submit-review.sh`). Any other combination leaves the task
    `EXECUTOR_RUNNING` with a clear diagnostic (inspect logs, then
    `block-task.sh` or re-run).

The executor's own written contract (in every generated executor prompt, via
`.ai/scripts/internal/lib/executor-ownership-contract.md`) states explicitly
that it owns implementation/tests/the three required artifacts only, and
must not touch any transition script, `run-workflow.sh`/`run-ai-loop.sh`, or
edit `state.json` directly. This is a **prompt contract** for most of those
prohibitions, but the `EXECUTOR_RUNNING → READY_FOR_REVIEW` transition
specifically is also **code-enforced** (§5, §11).

## 7. Reviewer contract

Implemented by `run-reviewer.sh`, gated to run only from `READY_FOR_REVIEW`
(legacy `READY_FOR_CODEX_REVIEW` accepted as an alias):

- **Isolation.** For `claude-subagent`, the reviewer is always a brand-new,
  non-interactive `claude` invocation — never `--continue`/`--resume` of the
  executor's session. `run-reviewer.sh` prefers `claude --agent ai-reviewer`
  (the agent defined in `.claude/agents/ai-reviewer.md`) when the installed
  CLI advertises `--agent`, else `--append-system-prompt` with an equivalent
  isolated-reviewer system prompt, else a plain wrapped `--print` — chosen
  by inspecting `claude --help`, never by guessing flags.
- **Independent context.** A fresh, independent Context Plus preflight
  (`--role reviewer`) runs before the reviewer is launched; it is never
  satisfied by the executor's preflight having passed (§10).
- **Evidence review.** The reviewer is instructed (`.ai/reviewer.md`,
  `.claude/agents/ai-reviewer.md`) to read the full task file set AND
  independently inspect the real working tree (`git status --short`,
  `git diff`) rather than trust the executor's narrative or only the
  captured evidence files.
- **Independent test execution.** Real task evidence (e.g. task `0070`'s
  `09-consultant-review.md`) shows reviewers independently re-running the
  full test suite rather than only reading `07-tests.txt`; this is expected
  practice per `.ai/reviewer.md`'s "git diff and tests are the source of
  truth," though it is not itself a code-enforced gate.
- **Accept/request-changes behavior** — see §5's table; both require the
  reviewer to have written specific artifacts first (`accept-review.sh`
  requires `09`+`10`; `request-changes.sh` requires `09`+`11`).
- Other supported reviewer providers: `codex` (default; runs only if
  `codex --help` clearly advertises a non-interactive mode, else falls back
  to printing the prompt and leaving state unchanged) and `manual` (never
  invokes a CLI at all; always leaves state unchanged and prints instructions
  for a human).
- The reviewer never modifies implementation/application files, never
  commits, never runs the executor or the daemon, and never skips human
  final review — stated identically in `.ai/reviewer.md`,
  `.claude/agents/ai-reviewer.md`, and the wrapped prompt built for
  `claude-subagent`.

## 8. Evidence contract

Classification of every artifact named in `.ai/protocol.md`'s "Required Task
Files" and observed across real task folders (`.ai-runs/tasks/0045`, `0055`,
`0070`, `0082`, and others):

| File | Required? | Raw / Derived / Human-readable | Provider-specific? |
|---|---|---|---|
| `00-user-request.md` | Required | Human-readable (source content) | Generic |
| `01-consultant-analysis.md` | Required | Human-readable | Generic |
| `02-executor-prompt.md` | Required (must be non-empty to claim) | Human-readable | Generic |
| `03-executor-log.md` | Required (gates submission) | Human-readable | Generic |
| `04-git-status.txt` | Required to exist (may be empty) | Raw evidence | Generic |
| `05-changed-files.txt` | Required to exist (may be empty) | Raw evidence | Generic |
| `05-git-diff-stat.txt` | Required to exist (may be empty) | Raw/derived evidence | Generic |
| `06-git-diff.patch` | Required to exist (may be empty) | Raw evidence | Generic |
| `07-tests.txt` | Required (gates submission) | Human-readable / raw output | Generic |
| `08-executor-summary.md` | Required (gates submission) | Human-readable | Generic |
| `09-consultant-review.md` | Required to accept or request-changes | Human-readable | Generic |
| `10-business-summary.md` | Required to accept | Human-readable | Generic |
| `11-next-executor-prompt.md` | Required to request-changes/requeue | Human-readable | Generic |
| `12-claude-stdout.txt` | Conditional (executor ran) | Raw (legacy-named capture file) | Provider-specific (name is a Claude legacy artifact, kept for compatibility) |
| `13-claude-stderr.txt` | Conditional | Raw | Provider-specific (name) |
| `14-run-executor.log` | Conditional (appended across re-runs) | Derived/raw runner log | Generic (runner-authored) |
| `15-reviewer-stdout.txt` | Conditional (reviewer ran) | Raw | Generic (shared name across Codex/Claude reviewer) |
| `16-reviewer-stderr.txt` | Conditional | Raw | Generic |
| `17-run-reviewer.log` | Conditional | Derived/raw runner log | Generic |
| `18-iteration-summary.md` | Conditional, best-effort, generated | Human-readable (derived) | Generic |
| `19-executor-events.jsonl` | Conditional (only in semantic live-event mode) | Raw structured event stream | Provider-specific (Claude `stream-json`) |
| `20-reviewer-events.jsonl` | Conditional (only in semantic live-event mode) | Raw structured event stream | Provider-specific |
| `state.json` | Required | Derived (machine state) | Generic |
| `02-executor-prompt.before-requeue-<ts>.md` | Conditional (only after a requeue) | Raw backup | Generic |
| `03/07/08-*.before-run-<ts>.*` | Conditional (only when a re-run resets stale artifacts) | Raw backup | Generic |

Not every artifact exists in every task: a task that never reached
`READY_FOR_REVIEW` has no `09`–`11`/`15`–`18`/`20` files; a task never run
under semantic live-event mode has no `19`/`20` files; a task that was never
requeued has no `.before-requeue-` backup.

## 9. Dirty-working-tree semantics

`run-executor.sh`'s guard (§6, step 3) classifies every path from
`git status --porcelain` as related (allowed) or unrelated (blocks the run):
related paths are anything under `.ai/` (workflow tooling) plus, for an SDD
task, its own exact `docs/sdd/<task-id>/` (or `docs/SDD/<task-id>/`) folder,
`spec.md`/`expect.md` inside it, and the exact recorded "Spec source path."
Everything else blocks the run with a clear listing.

**Known limitation (evidence-backed).** This guard cannot distinguish a
task's *own* still-uncommitted round-1 implementation diff from a genuinely
unrelated change. Real evidence from `docs/migration/12-autonomous-roadmap-progress.md`
(covering tasks `0055` and `0059`) and from the task folders themselves
(`0055`, `0059`, `0063`, `0070` all have `requeued_at` set in `state.json` but
are still sitting in `READY_FOR_EXECUTOR`, days after being requeued) confirms:
when a reviewer requests changes for reason X but the round-1 implementation
(application code, outside `.ai/` and outside the SDD folder) is still
uncommitted in the working tree, `requeue-task.sh` succeeds (it only touches
`state.json` and the prompt files) but the *next* `run-executor.sh` invocation
refuses to start, because the round-1 diff itself now reads as "unrelated
changes." There is no supported override flag on `run-executor.sh` for this
case, and stashing to satisfy the guard would hide the very code the next
round needs to build on (or, for the two real 0055/0059 cases, browser-test).
In practice this was worked around by a human committing the round-1 work
directly and moving on, bypassing the stuck automated retry entirely. This is
recorded here, not fixed, per SDD 0083's explicit instruction not to modify
`.ai/` in this task — it is a compatibility requirement for the future
SpecRelay engine migration (SDD 0084+).

## 10. Context capability semantics (Context Plus)

- **Mandatory by default** for both automated roles: `AI_REQUIRE_CONTEXT_PLUS`
  defaults to `1`; `0` disables it explicitly (never silently).
- **Executor preflight** — `run-executor.sh` calls
  `context-plus-preflight.sh --role executor` BEFORE claiming the task.
- **Reviewer preflight** — `run-reviewer.sh` calls it independently
  (`--role reviewer`) BEFORE launching an automated reviewer
  (`claude-subagent` or `codex`); `manual` mode is exempt (no automated agent
  runs).
- **What the preflight proves**, per role, in order: checking → available
  (`claude mcp list` / `codex mcp list` shows the server registered AND
  connected — a real health check, not an assumption from `.mcp.json`'s mere
  presence) → initialized → a single bounded, real tool call
  (`semantic_code_search`, restricted via `--strict-mcp-config`/
  `--allowedTools`, capped by `--max-budget-usd`) that must show real evidence
  of having been invoked → "query completed" / "context loaded."
- **Provider capability differs**: Codex maintains its own MCP registry and
  does not read Claude Code's `.mcp.json`; in this repository `contextplus` is
  not registered for Codex, so the `codex` reviewer preflight fails honestly
  and the automated Codex reviewer never runs — this is not a fallback case,
  it is a hard refusal.
- **No silent fallback, either role.** If the preflight fails, the caller does
  not proceed: the executor is not claimed (stays `READY_FOR_EXECUTOR`); the
  reviewer is not launched and no accept/request-changes decision is made
  (stays `READY_FOR_REVIEW`). Ordinary Read/Grep/Find/Bash tools remain
  allowed *alongside* Context Plus at all times — they never substitute for
  it when it is required.
- **Independence.** The reviewer's preflight is always a fresh, separate
  process; it is never inherited or assumed from the executor's.
- This is generic **capability behavior** (mandatory-and-verified access to a
  context tool before substantive work) layered over **repository policy**
  (Context Plus specifically, and mandatory-by-default) — see
  `knowledge-boundaries.md` for the split.

## 11. Failure semantics

| Situation | What happens |
|---|---|
| Executor provider exits non-zero | Not submitted; task remains `EXECUTOR_RUNNING`; clear diagnostic printed pointing at `12`/`13` capture files; next steps are inspect-and-fix-and-rerun, or `block-task.sh`. |
| Executor exits 0 but required outputs (`03`/`07`/`08`) missing/empty | Not submitted; same `EXECUTOR_RUNNING` state; explicit message distinguishing this from a hard provider failure. |
| Executor exits 0, outputs present, but evidence capture fails | Not submitted; explicit warning that evidence may be stale/incomplete; task stays `EXECUTOR_RUNNING`. |
| Task somehow already `READY_FOR_REVIEW` before the runner minted an authorization | Treated as an ownership-violation and fails safely with a clear error (guards against the exact task-0037 double-submit class), rather than a confusing "wrong state" message. |
| Reviewer CLI exits non-zero (`codex` or `claude-subagent`) | Runner does not change task state; the reviewer's exit code is propagated; the task stays `READY_FOR_REVIEW` for manual follow-up. |
| Evidence files missing at submit time | `submit-review.sh` / `finish-task.sh` refuse before any state write if `03`/`07`/`08` are empty or if `04`–`06` don't exist at all. |
| Context Plus preflight fails (executor) | Executor is never claimed/launched; task stays `READY_FOR_EXECUTOR`. |
| Context Plus preflight fails (reviewer, automated provider) | Reviewer is never launched; no accept/request-changes decision; task stays `READY_FOR_REVIEW`. This is explicitly NOT treated the same as "Codex CLI simply isn't installed" (which is an honest manual-fallback case) — a present-but-unverified provider is a hard refusal. |
| Transition authorization missing/invalid (`submit-review.sh`/`finish-task.sh` called directly) | Refused immediately, before any other check, with no state change. |
| `run-ai-loop.sh` reaches `--max-rounds` (default 3) without `READY_FOR_HUMAN_REVIEW` | Prints current state and exits 0 (explicitly **not** treated as success); re-run or raise `--max-rounds`. |
| Dirty-working-tree guard blocks a run | Executor is never claimed; the exact unrelated paths are listed; task stays in its current state (see §9 for the specific requeue-path limitation). |

## 12. Human gate

`READY_FOR_HUMAN_REVIEW` means: the executor implemented the task, the
reviewer (agent or human, depending on `AI_REVIEWER_PROVIDER`) verified the
evidence and the real working tree and accepted it, `09-consultant-review.md`
and `10-business-summary.md` were written, and a best-effort desktop
notification was attempted. **It does not commit, push, merge, or deploy
anything, and it does not publish to Slack.** The working tree still holds
only uncommitted (or, for untracked files, unstaged) changes exactly as the
executor left them; `capture-evidence.sh`'s `--intent-to-add`/`reset` dance
around the diff is carefully reverted so it never leaves files staged. The
human is expected to run `show-task.sh <task-id>`, perform their own review,
and decide whether/how to commit — nothing in the workflow does this for
them, matching `CLAUDE.md`'s validation-discipline rule ("do not commit
unless explicitly asked").

## 13. Known gaps (evidence-backed)

1. **Dirty-tree guard blocks the automated requeue retry path.** See §9.
   Confirmed by `docs/migration/12-autonomous-roadmap-progress.md` and by
   task folders `0055`, `0059`, `0063`, `0070` (all `requeued_at`-set but
   stuck in `READY_FOR_EXECUTOR`). Explicitly **not fixed** in this task per
   SDD 0083's own instructions; recorded as a compatibility requirement for
   the SpecRelay engine migration.
2. **`authorize-submit.sh` / `authorize-finish.sh` do not verify the caller
   is human.** They are supported manual-recovery entry points; an executor
   agent that disobeys its prompt and calls one of them directly (instead of
   the guarded `submit-review.sh`/`finish-task.sh`) would succeed. Documented
   explicitly in `.ai/protocol.md` as an accepted limitation, mirroring the
   equivalent limitation for direct `state.json` edits (a prompt contract,
   not a code-enforced boundary).
3. **Only one executor provider (`claude`) and one fully-context-plus-capable
   reviewer provider (`claude-subagent`) are supported today**; `codex` as a
   reviewer works for the review itself but cannot pass its own Context Plus
   preflight in this environment (§10), so automated Codex review currently
   always refuses here.
4. **`18-iteration-summary.md`'s timeline is a best-effort reconstruction**,
   not an authoritative log — later rounds overwrite `08`/`09`/`11`, so the
   summary infers history from prompt backups and `state.json` timestamps.
