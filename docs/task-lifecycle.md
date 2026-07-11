# SpecRelay Task Lifecycle

This document describes the **actual, as-built** task state machine that
SpecRelay runs when you invoke `specrelay run <spec>`. Every state name and
`state.json` field named here is quoted verbatim from the engine code
(`lib/specrelay/state.sh`, `lib/specrelay/transitions.sh`,
`lib/specrelay/workflow.sh`, `lib/specrelay/task.sh`,
`lib/specrelay/evidence.sh`, and `lib/specrelay/py/state_lib.py`). It is a
companion to `current-workflow-contract.md` (the authoritative behavior
contract) and `commands.md` (the command reference); where they overlap, this
document summarizes and does not contradict them.

Paths in this document use SpecRelay's provider-neutral **public defaults**:
specs live under `specs/` and per-task runtime evidence lives under
`.specrelay-runs/tasks/<task-id>/`. A consumer project may point these
elsewhere by setting `specs.root` and `tasks.runs_root` in its
`.specrelay/config.yml`; the engine never hardcodes them.

## 1. Canonical states

The canonical states, defined in `py/state_lib.py` and enforced by every
transition, are:

- `DRAFT`
- `READY_FOR_EXECUTOR`
- `EXECUTOR_RUNNING`
- `READY_FOR_REVIEW`
- `CHANGES_REQUESTED`
- `READY_FOR_HUMAN_REVIEW`
- `BLOCKED`

Two additional recognized names are read but never freshly written by
SpecRelay:

- `WAITING_FOR_HUMAN` — accepted only as an alternate source state for the
  human-approval transition (see §3).
- `READY_FOR_CODEX_REVIEW` — a **legacy alias** that `state.sh`'s
  `specrelay::state::normalize` / `state_lib.py`'s `normalize_state()` map
  read-only to `READY_FOR_REVIEW`. SpecRelay never writes this name; it only
  reads it for backward-compatible inspection of tasks created by the legacy
  engine.

`READY_FOR_HUMAN_REVIEW` is the intended stopping point of every successful
run: the automated loop halts there and never advances past it on its own.
`BLOCKED` is the only "stuck" state the automated loop can reach.

## 2. State diagram

```text
                    specrelay run <spec>  (no task dir yet)
                              │  transitions::create
                              ▼
                          ┌───────┐
                          │ DRAFT │
                          └───┬───┘
                              │  transitions::approve
                              │  (human-approval gate; also from WAITING_FOR_HUMAN)
                              ▼
                  ┌──────────────────────┐
        ┌────────▶│  READY_FOR_EXECUTOR  │◀────────┐
        │         └──────────┬───────────┘         │
        │                    │  transitions::claim │
        │                    │  (needs non-empty   │
        │                    │   02-executor-      │
        │                    │   prompt.md)        │
        │                    ▼                     │
        │         ┌──────────────────────┐         │  transitions::requeue
        │         │   EXECUTOR_RUNNING   │         │  (promotes 11 -> 02,
        │         └──────────┬───────────┘         │   iteration += 1)
        │                    │  transitions::submit│
        │  transitions::     │  (runner-owned,     │
        │  recover           │   token-gated,      │
        │  (interrupted/     │   needs evidence)   │
        │   orphaned run,    ▼                     │
        │   audited)  ┌──────────────────┐         │
        │             │ READY_FOR_REVIEW │         │
        │             └───┬──────────┬───┘         │
        │   accept        │          │  request_changes
        │   (needs 09+10) │          │  (needs 09+11)
        │                 ▼          ▼             │
        │   ┌────────────────────┐  ┌──────────────────────┐
        │   │READY_FOR_HUMAN_    │  │  CHANGES_REQUESTED    │─┘
        │   │REVIEW (human gate) │  └──────────────────────┘
        │   └────────────────────┘
        │
        │             ┌──────────────────────┐
        └─────────────│   EXECUTOR_RUNNING   │
                      └──────────┬───────────┘
                                 │  transitions::block
                                 ▼
                             ┌─────────┐
                             │ BLOCKED │
                             └─────────┘
```

## 3. The full lifecycle from `specrelay run <spec>`

`specrelay::workflow::run` composes the entire lifecycle. In order:

1. **Resolve the spec and task id.** The spec path is resolved safely (must
   exist, must be a regular file, must not escape the project root via
   traversal). The task id is derived from the spec's **parent directory name**
   (the one-dir-per-spec convention, e.g. `specs/<task-id>/spec.md`), sanitized
   to a safe path segment `^[A-Za-z0-9._-]+$`; `--task-id` overrides it.

2. **Acquire the task lock**, then create the task if its directory does not
   yet exist.

3. **Task creation → `DRAFT`.** `specrelay::transitions::create` makes
   `.specrelay-runs/tasks/<task-id>/`, writes `state.json` with
   `"state": "DRAFT"`, and refuses if the directory already exists (it never
   silently overwrites). `specrelay::workflow::seed_task_from_spec` then fills
   `00-user-request.md`, `01-consultant-analysis.md`, and
   `02-executor-prompt.md` from the spec, always appending the mandatory
   ownership-contract footer. When the task already exists, `run` resumes it
   in place instead of recreating it.

4. **Approval → `READY_FOR_EXECUTOR`.** If the current state is `DRAFT` (or
   `WAITING_FOR_HUMAN`), `specrelay::transitions::approve` performs the
   human-approval gate. Running `specrelay run` **is** the human's approval for
   that spec; the decoupled equivalent is `specrelay task approve`.

5. **The iteration loop.** `run` then loops, reading the canonical state each
   pass and dispatching:
   - `READY_FOR_EXECUTOR` → run one executor round (§4).
   - `READY_FOR_REVIEW` → run one reviewer round (§5).
   - `CHANGES_REQUESTED` → requeue for the next iteration (§6), then loop.
   - `READY_FOR_HUMAN_REVIEW` → stop, exit `0` (§7).
   - `BLOCKED` → stop, exit `3`.

   An internal safety counter (`max_iterations * 2 + 6`) guards against a
   non-terminating loop and is an engine-bug backstop, not a normal outcome.

### Executor round: `READY_FOR_EXECUTOR → EXECUTOR_RUNNING → READY_FOR_REVIEW`

`specrelay::transitions::claim` moves `READY_FOR_EXECUTOR → EXECUTOR_RUNNING`
and requires a non-empty `02-executor-prompt.md`. After the provider runs and
evidence is captured, `specrelay::transitions::submit` moves
`EXECUTOR_RUNNING → READY_FOR_REVIEW`. `submit` is **runner-owned**: it
requires a valid, single-use authorization token minted only after the
provider process has exited, and it refuses a direct call that lacks one.

### Reviewer round: accept or request-changes

From `READY_FOR_REVIEW` the reviewer decides exactly one of:
- `specrelay::transitions::accept` → `READY_FOR_HUMAN_REVIEW` (requires
  `09-consultant-review.md` and `10-business-summary.md` non-empty), or
- `specrelay::transitions::request_changes` → `CHANGES_REQUESTED` (requires
  `09-consultant-review.md` and `11-next-executor-prompt.md` non-empty).

## 4. Executor round detail

`specrelay::workflow::executor_iteration` requires the task to already be
`READY_FOR_EXECUTOR` and runs, in order:

1. **Working-tree guard** (`git_guard::check`) — refuses to run over unrelated
   uncommitted changes; evaluated **before** claiming, so a blocked run never
   touches task state.
2. **Context-capability preflight** for the `executor` role. If it fails and
   `context.required` is truthy, the executor is not claimed/launched; if not
   required, the run proceeds with a diagnostic.
3. **Claim** → `EXECUTOR_RUNNING`.
4. **Run the executor provider** with `02-executor-prompt.md` for the current
   round.
5. **Capture evidence** (§8) — always attempted after the provider exits,
   regardless of exit code.
6. **Fail-safe checks** — if the provider exited non-zero, or if any of
   `03-executor-log.md` / `07-tests.txt` / `08-executor-summary.md` is missing
   or empty, the task is **not** submitted and stays `EXECUTOR_RUNNING` with a
   clear diagnostic.
7. **Snapshot task-owned working-tree paths**, then **mint token → submit →
   clean up token** to move `EXECUTOR_RUNNING → READY_FOR_REVIEW`.

## 5. Reviewer round detail and executor/reviewer isolation

`specrelay::workflow::reviewer_iteration` requires the task to already be
`READY_FOR_REVIEW`.

- **Manual reviewer.** If `roles.reviewer.provider` is `manual`, no automated
  decision is possible: the iteration returns a distinct "manual" signal, the
  state is left unchanged, and a human must run
  `specrelay task accept` / `specrelay task request-changes`.
- **Independent context.** An automated reviewer runs its **own**
  context-capability preflight for the `reviewer` role; it is never satisfied
  by the executor's preflight having passed.
- **Fresh, isolated context.** The reviewer prompt is reconstructed by
  `specrelay::workflow::build_reviewer_prompt` **only** from the spec / task /
  evidence files on disk — never from any executor conversation state (there is
  none to reuse: the reviewer provider is always a brand-new process). The
  prompt tells the reviewer explicitly that it is "a fresh context … NOT a
  continuation of the executor's session," and instructs it to independently
  inspect the real working tree (`git status --short`, `git diff`) rather than
  trust the executor's narrative.
- **Decision protocol.** The reviewer must end with exactly one verbatim line,
  `DECISION: ACCEPT` or `DECISION: REQUEST_CHANGES`. The engine reads the last
  line: `ACCEPT` drives `accept` (→ `READY_FOR_HUMAN_REVIEW`),
  `REQUEST_CHANGES` drives `request_changes` (→ `CHANGES_REQUESTED`). Any
  unrecognized decision is refused and the task stays `READY_FOR_REVIEW`.
- **State-aware, single transition.** The runner applies the decision's
  transition **only when the task is still `READY_FOR_REVIEW`**. A real reviewer
  agent runs under `claude --print --dangerously-skip-permissions` and can
  itself enact `accept` / `request_changes` (neither is runner-owned), so the
  task may already be in the decision's target state by the time control returns
  to the runner. In that case the runner recognizes the enacted transition and
  **stops cleanly** — it never attempts a second, invalid transition out of an
  already-final state. The transition guards are unchanged: `transitions.sh`
  still refuses genuinely invalid transitions; the runner simply does not make
  the redundant call. So an accepted review reaches `READY_FOR_HUMAN_REVIEW`
  exactly once, and `run` exits `0` with no `Refusing to transition task in
  state 'READY_FOR_HUMAN_REVIEW'` warning.

The reviewer runs **synchronously** while the task sits in `READY_FOR_REVIEW`;
there is no distinct reviewer-running state. An interrupted reviewer is simply
re-run from `READY_FOR_REVIEW` via `specrelay resume`.

## 6. Rework loop and `max_iterations`

When the reviewer requests changes, the task is `CHANGES_REQUESTED`. The loop
then calls `specrelay::transitions::requeue`, which:

- validates the current state is `CHANGES_REQUESTED` before touching any file;
- **archives the current round** under `iterations/round-<N>/` (§8);
- backs up the old `02-executor-prompt.md` non-destructively (timestamped);
- promotes `11-next-executor-prompt.md` to `02-executor-prompt.md` and
  re-appends the ownership-contract footer;
- increments the `iteration` counter and clears the previous `claimed_at` /
  `claimed_by` stamp, so the next executor round re-claims cleanly.

This returns the task to `READY_FOR_EXECUTOR` for a fresh executor round.

**Iteration cap.** `tasks.max_iterations` (public default `3`) bounds the
number of executor iterations. When the loop is about to run an executor round
whose `iteration` exceeds `max_iterations`, `run` stops and reports
"reached the maximum of `<N>` iteration(s) without acceptance," exiting `5`. It
**never** fabricates an acceptance or advances to `READY_FOR_HUMAN_REVIEW` at
the cap — hitting the cap is an explicit, honest stop.

## 7. The human final gate

Project policy `policy.human_final_review_required` (default `true`,
`.specrelay/config.yml`) is realized directly in the engine: the automated loop
**halts at `READY_FOR_HUMAN_REVIEW`** and performs no transition beyond it. The
only transitions that reach `READY_FOR_HUMAN_REVIEW` are the reviewer's `accept`
paths (`specrelay::transitions::accept`), never a self-submission by the
executor. A human then runs `specrelay task accept` (already done by an
automated reviewer's accept) or, to rework, inspects the task and requests
changes. Nothing downstream of `READY_FOR_HUMAN_REVIEW` is automated: no commit,
push, merge, deploy, or publish.

Reaching `READY_FOR_HUMAN_REVIEW` leaves the working tree holding exactly the
uncommitted (and, for new files, untracked) changes the executor produced; the
evidence-capture `--intent-to-add` / `reset` dance is reverted so nothing is
left staged.

## 8. Evidence capture and per-round archiving

**Per-round evidence.** After each executor run,
`specrelay::evidence::capture` writes four git evidence files into the task
directory, always (they may be empty but must exist to submit):

- `04-git-status.txt` — `git status --short`
- `05-changed-files.txt` — `git diff --name-status`
- `05-git-diff-stat.txt` — `git diff --stat`
- `06-git-diff.patch` — `git diff`

Untracked files are made visible as full additions via
`git add --intent-to-add`, then restored to untracked with `git reset`, so new
files appear in the diff without ever being left staged.

The executor itself writes `03-executor-log.md`, `07-tests.txt`, and
`08-executor-summary.md` (all three gate submission). The reviewer writes
`09-consultant-review.md`, and — depending on its decision —
`10-business-summary.md` (accept) or `11-next-executor-prompt.md`
(request-changes).

**Round archiving.** Because the live numbered files are overwritten by each
subsequent round, `specrelay::transitions::_archive_round` copies the current
round's artifacts into `iterations/round-<N>/` at every iteration boundary
(inside both `requeue` and `accept`), **without** removing or renaming the live
files. This makes multi-round history genuinely reconstructable rather than
inferred. The archived set (each copied only if present) is:

```text
02-executor-prompt.md   03-executor-log.md      07-tests.txt
08-executor-summary.md  04-git-status.txt       05-changed-files.txt
05-git-diff-stat.txt    06-git-diff.patch       12-executor-stdout.txt
13-executor-stderr.txt  09-consultant-review.md 10-business-summary.md
11-next-executor-prompt.md  15-reviewer-stdout.txt  16-reviewer-stderr.txt
```

Archiving is idempotent for a given round (it overwrites that round's own
archive, never a different round's).

## 9. Failure semantics — no false accept

The engine is built so that neither an executor failure nor a reviewer failure
can produce a false acceptance:

- **Executor provider exits non-zero.** Evidence is still captured, but the task
  is **not** submitted; it stays `EXECUTOR_RUNNING` with a diagnostic.
- **Executor exits 0 but required outputs missing/empty.** Not submitted; stays
  `EXECUTOR_RUNNING`.
- **`submit` guard.** `specrelay::transitions::submit` independently re-checks
  that `03`/`07`/`08` are non-empty and that `04`/`05`/`06` exist before writing
  any state, and refuses without a valid runner token.
- **Reviewer provider exits non-zero or produces no clear decision.** The task
  stays `READY_FOR_REVIEW`; no accept/request-changes decision is written.
- **Unrecognized reviewer decision.** Refused; state unchanged.
- **`accept` guard.** `accept` refuses unless `09` and `10` are non-empty, so a
  task can never reach `READY_FOR_HUMAN_REVIEW` without a real review and
  business summary on disk.

## 10. Interrupted-run recovery

The only supported way out of an **interrupted** `EXECUTOR_RUNNING` task (one
whose provider process exited or was orphaned) — other than the normal
runner-owned `submit` (→ `READY_FOR_REVIEW`) or an operator `block`
(→ `BLOCKED`) — is `specrelay task recover`, backed by
`specrelay::transitions::recover`. It supports exactly one transition,
`EXECUTOR_RUNNING → READY_FOR_EXECUTOR`, refuses any other (source, target)
pair, and records audited metadata (`recovered_at`, `recovered_by`,
`recovered_from_state`, `recovery_reason`) while leaving all evidence files
untouched. It never fabricates success, never moves a task to
`READY_FOR_HUMAN_REVIEW`, and never mutates a task owned by another engine. See
`operator-recovery.md` for the operator procedure.

## 11. `state.json` fields

`state.json` is always a JSON object, written atomically. The fields below are
the ones written by the engine code and are safe to rely on when inspecting a
task:

**Set at creation** (`transitions::create`):

- `task_id`
- `state` — the canonical current state (see §1)
- `created_at`
- `base_commit` — repository `HEAD` at creation time
- `requires_human_approval`
- `engine` — always `"specrelay"` for tasks this engine owns; a mutating
  command refuses any task whose `engine` is not `specrelay`
- `iteration` — starts at `1`, incremented by each requeue
- `allow_pre_existing_dirty`
- `spec_source` — the spec's project-relative path (present when created from a
  spec)

**Added by transitions:**

- Approval: `approved_at`, `approved_by`
- Claim: `claimed_at`, `claimed_by` (cleared on requeue and on recover)
- Submit: `submitted_for_review_at`, `submitted_for_review_by`
- Accept: `reviewed_at`, `reviewed_by`, `review_result`, `reviewer_provider`
- Request-changes: `changes_requested_at`, `changes_requested_by`,
  `changes_requested_reason`, `reviewer_provider`
- Requeue: `requeued_at`, `requeued_by`, updated `iteration`
- Recover: `recovered_at`, `recovered_by`, `recovered_from_state`,
  `recovery_reason`
- Block: `blocked_at`, `blocked_by`, `blocked_reason`

`state.json` lives under the task's runtime directory
(`.specrelay-runs/tasks/<task-id>/state.json` by default) and must never be
edited by hand — every state change goes through an audited transition.
