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

Two of these names deserve explicit clarification, because they mark two
different reviews:

- `READY_FOR_REVIEW` means **ready for the automated (AI) reviewer**. The
  executor has finished and produced evidence; the reviewer agent has not yet
  decided. Its legacy alias `READY_FOR_CODEX_REVIEW` reflects the same meaning.
  When the effective reviewer provider is not `manual`, this is an **internal
  handoff state**, not the normal endpoint of a successful run: both `specrelay
  run` and `specrelay resume` continue from `READY_FOR_REVIEW` into reviewer
  execution in the same invocation (spec 0010). A command only rests here for an
  explicit `manual` reviewer, a reviewer failure/unavailability, or an explicit
  guard (e.g. `max_iterations`), and it always logs the reason — never a silent
  stop.
- `READY_FOR_HUMAN_REVIEW` means **the automated reviewer accepted, and the
  human final gate is still pending**. Automated acceptance is *not* human
  approval — it only moves the task to the human gate. The automated decision
  is recorded separately in `review_result` (`"accepted"`); a human's approval
  to merge/ship is an out-of-band act the engine never performs on its own.

`READY_FOR_HUMAN_REVIEW` is the intended stopping point of every successful
run: the automated loop halts there and never advances past it on its own.
`BLOCKED` is the only "stuck" state the automated loop can reach. A
request-changes decision goes to `CHANGES_REQUESTED` (rework loop, §6), which
is distinct from a provider `BLOCKED`/failure (§9).

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

1. **Resolve the input and task id.** The input path is resolved safely (must
   exist, must be a regular file OR a directory, must not escape the project
   root via traversal, and must not be a special filesystem entry — spec
   0023). For a directory input the task id is the directory's **own**
   basename; for a file input it is still derived from the spec's **parent
   directory name** (the one-dir-per-spec convention, e.g.
   `specs/<task-id>/spec.md`), sanitized to a safe path segment
   `^[A-Za-z0-9._-]+$`; `--task-id` overrides either.

2. **Acquire the task lock**, then create the task if its directory does not
   yet exist.

3. **Specification-bundle analysis, staged before creation (spec 0023).**
   Before any durable task state exists, `specrelay::workflow::stage_input`
   discovers/classifies/snapshots the input into a throwaway staging
   directory and generates `02-resolved-specification.md` from it (see §3a
   below). Any failure here (missing required `spec.md`, both `tech-spec.md`
   and `tech_spec.md` present, an exceeded discovery limit, a required Jam
   reference that cannot be retrieved, …) aborts with **no task directory
   created at all** — never a partially-seeded `DRAFT`.

4. **Task creation → `DRAFT`.** `specrelay::transitions::create` makes
   `.specrelay-runs/tasks/<task-id>/`, writes `state.json` with
   `"state": "DRAFT"`, and refuses if the directory already exists (it never
   silently overwrites). `specrelay::workflow::commit_staged_input` then
   moves the already-validated `01-input-manifest.json`, `01-input-bundle/`,
   and `02-resolved-specification.md` from staging into the task directory,
   then fills `00-user-request.md`, `01-consultant-analysis.md`, and
   `02-executor-prompt.md`, always appending the mandatory
   ownership-contract footer. When the task already exists, `run` resumes it
   in place instead of recreating it — the bundle is **never** rebuilt on
   resume (§3a, "Resume never rebuilds").

5. **Approval → `READY_FOR_EXECUTOR`.** If the current state is `DRAFT` (or
   `WAITING_FOR_HUMAN`), `specrelay::transitions::approve` performs the
   human-approval gate. Running `specrelay run` **is** the human's approval for
   that spec; the decoupled equivalent is `specrelay task approve`.

6. **The iteration loop.** `run` then loops, reading the canonical state each
   pass and dispatching:
   - `READY_FOR_EXECUTOR` → run one executor round (§4).
   - `READY_FOR_REVIEW` → run one reviewer round (§5).
   - `CHANGES_REQUESTED` → requeue for the next iteration (§6), then loop.
   - `READY_FOR_HUMAN_REVIEW` → stop, exit `0` (§7).
   - `BLOCKED` → stop, exit `3`.

   An internal safety counter (`max_iterations * 2 + 6`) guards against a
   non-terminating loop and is an engine-bug backstop, not a normal outcome.

### 3a. Specification-bundle analysis phase (spec 0023)

Whether the input is one spec file or a specification directory, task
creation always produces this shared, immutable layout **before** either
role runs:

```text
<task-runtime>/
├── 01-input-manifest.json     # schema, input kind, per-file role/media
│                               # type/size/sha256/inspection capability/
│                               # external references, external-evidence
│                               # entries (e.g. Jam)
├── 01-input-bundle/
│   ├── local/                 # every accepted local file, snapshotted
│   └── external/
│       └── jam/<canonical-id>/  # redacted Jam evidence, when referenced
└── 02-resolved-specification.md   # the analysed implementation brief
```

For a directory input, `spec.md` is the primary **functional** authority and
an optional `tech-spec.md` / `tech_spec.md` is the primary **technical**
authority (both names accepted, never both at once — task creation fails
clearly if it finds both). All other accepted files are supporting evidence,
classified into an internal content class (`text-readable`, `structured-data`,
`log-or-trace`, `visual`, `document`, `source-or-config`, `unknown-binary`, …)
and an inspection-capability tier (directly inspectable, inspectable only
through provider multimodal reading, or unsupported).

`02-resolved-specification.md` assembles the Objective, Functional/Technical
Requirements, Acceptance Criteria, evidence-derived requirements (each cited
back to its snapshot path), external evidence, and an Input Coverage table
covering every discovered file. It is an **analysed brief, not a
replacement** for the original snapshot — the Executor and Reviewer must
still reopen `01-input-bundle/` directly for anything not reproduced
verbatim, and must never claim unsupported or unretrieved evidence as
inspected.

If the bundle references a Jam recording, it is retrieved, redacted, and
snapshotted beneath `01-input-bundle/external/jam/<canonical-id>/` during
this same phase — see [jam-capability.md](jam-capability.md). A required Jam
reference that cannot be retrieved blocks task creation outright (no task
directory is left behind).

**Resume never rebuilds.** `specrelay resume` (and `run` against an existing
task) drives the existing state machine forward using whatever is already on
disk; it never re-discovers, re-snapshots, or re-fetches anything. Editing the
live source file/directory after task creation, or a Jam recording changing
upstream, has **no effect** on an already-created task (spec 0023, section
10.3 / 22) — this is the same immutability guarantee `git_guard.sh` already
gives the working tree, extended to the specification input itself.

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

For a task with an input bundle (`01-input-manifest.json` present), both
completion gates above additionally require an `## Input Coverage` section:
in `08-executor-summary.md` before submission proceeds past
`EXECUTOR_RUNNING` (spec 0023, section 21.2), and in `09-consultant-review.md`
before either reviewer decision is accepted (section 21.3). A task predating
spec 0023 has no manifest and is unaffected by this additional check.

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

- **Manual reviewer.** `manual` is an explicit **opt-out / safe-bootstrap**
  mode, not the intended automated AI workflow. If `roles.reviewer.provider` is
  `manual`, no automated decision is possible: the iteration returns a distinct
  "manual" signal, the state is left unchanged at `READY_FOR_REVIEW`, and both
  `run` and `resume` stop there (exit code `2`) with an explicit log line stating
  that manual reviewer mode is configured and that a human must run
  `specrelay task accept` / `specrelay task request-changes`. When the reviewer
  provider is **not** `manual`, the same invocation instead continues into
  reviewer execution automatically (spec 0010); a reviewer failure leaves the
  task at `READY_FOR_REVIEW` with an explicit recovery reason (exit code `4`).
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
- **Decision protocol (spec 0019, mandatory marker).** The reviewer must end
  with exactly one decision marker: `DECISION: ACCEPT` or
  `DECISION: REQUEST_CHANGES`, uppercase, on its own line, and the **final
  non-empty line** of its entire output. A marker that is lowercase, not the
  final line, duplicated, or contradicted by a second marker is never
  accepted — see `lib/specrelay/marker.sh`. `ACCEPT` drives `accept` (→
  `READY_FOR_HUMAN_REVIEW`), `REQUEST_CHANGES` drives `request_changes` (→
  `CHANGES_REQUESTED`). Before applying either transition the engine also
  checks **decision consistency**: `ACCEPT` requires non-empty
  `09-consultant-review.md` + `10-business-summary.md`; `REQUEST_CHANGES`
  requires non-empty `09-consultant-review.md` +
  `11-next-executor-prompt.md`. A conflicting artifact/marker combination is
  refused rather than silently applied.
- **Smart marker-only recovery (spec 0019).** If the reviewer provider exits
  successfully but produces no valid marker, the engine does **not**
  automatically repeat the whole review. It checks whether the already-written
  artifacts strongly indicate the decision was already reached (a structured
  `Decision: ACCEPT` / `Decision: REQUEST_CHANGES` field inside
  `09-consultant-review.md`, plus the artifact the decision requires). If so,
  it runs **one** narrow corrective attempt (`lib/specrelay/marker_recovery.sh`):
  a prompt that reads only the already-written artifacts and asks for exactly
  one output line, never the original review prompt, never repository tools
  (the real Claude adapter omits `--dangerously-skip-permissions` for this one
  call, so a tool call requiring approval is refused by the CLI itself — see
  `providers/claude.sh`). At most one corrective attempt is made; a failed
  correction leaves the task in `REVIEWER_RUNNING` exactly like any other
  reviewer failure. Recovery-forbidden cases (missing/empty/contradictory
  artifacts, an unclear decision, a `REQUEST_CHANGES` decision missing
  `11-next-executor-prompt.md`, or a provider failure that happened before any
  artifacts were written) fall through to ordinary resume behavior. See
  [verification-and-timeline.md](verification-and-timeline.md).
- **Risk-based, bounded verification (spec 0019).** The reviewer is not a
  second executor: it classifies the change's risk (low/medium/high/critical),
  inspects Executor evidence and the real working tree, and independently
  verifies only the highest-risk claims, within a default verification budget
  (focused/targeted/full-suite/smoke run limits — `specrelay doctor` shows the
  effective policy). Running the full suite requires a recorded reason. See
  [verification-and-timeline.md](verification-and-timeline.md) and the
  reviewer template (`templates/claude/agents/ai-reviewer.md`).
- Any unrecognized decision is refused and the task stays `READY_FOR_REVIEW`
  (or `REVIEWER_RUNNING` for an automated reviewer, per spec 0011).
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
- `state` — the canonical current state (see §1). This is the only field
  required for a task to be operable; every other field is metadata.
- `schema_version` — integer shape version of `state.json` (currently `1`).
  Historical tasks without it are treated as an implicit v1. See
  `docs/versioning.md` for the compatibility guard.
- `created_at`
- `base_commit` — repository `HEAD` at creation time
- `requires_human_approval`
- `engine` — always `"specrelay"` for tasks this engine owns; a mutating
  command refuses any task whose `engine` is not `specrelay`
- `engine_version` — the `VERSION` of the engine that created the task (see
  `docs/versioning.md`)
- `iteration` — starts at `1`, incremented by each requeue
- `allow_pre_existing_dirty`
- `spec_source` — the spec's project-relative path (present when created from a
  spec)

**Added by transitions:**

- Approval: `approved_at`, `approved_by`
- Claim: `claimed_at`, `claimed_by` (cleared on requeue and on recover)
- Submit: `submitted_for_review_at`, `submitted_for_review_by`
- Accept: `reviewed_at`, `reviewed_by`, `review_result` (the **automated
  reviewer's** decision, `"accepted"`; not a human decision), `reviewer_provider`
- Request-changes: `changes_requested_at`, `changes_requested_by`,
  `changes_requested_reason`, `reviewer_provider`
- Requeue: `requeued_at`, `requeued_by`, updated `iteration`
- Recover: `recovered_at`, `recovered_by`, `recovered_from_state`,
  `recovery_reason`
- Block: `blocked_at`, `blocked_by`, `blocked_reason`

**Captured once, at the first executor iteration** (never overwritten
thereafter — see `docs/configuration.md`):

- `roles_effective` — normalized executor/reviewer provider/model/agent
- `context_effective` — normalized executor/reviewer context adapter/required
- `verification_policy_effective` — the effective bounded-verification policy
  (spec 0019; see `docs/verification-and-timeline.md`)

`state.json` lives under the task's runtime directory
(`.specrelay-runs/tasks/<task-id>/state.json` by default) and must never be
edited by hand — every state change goes through an audited transition.

## 12. Execution timeline and verification ledger (spec 0019)

Every `run`/`resume` invocation is timed (task initialization, approval,
executor/reviewer context preflight, provider execution, evidence capture,
submission, marker recovery, transition, finalization) into the task's own
append-only event log, `<task-runtime-path>/20-execution-events.jsonl`. The
derived, machine-readable summary lives at
`<task-runtime-path>/20-execution-timeline.json` and is regenerated (never
hand-merged) on every finalization. Timeline data survives every resume: each
invocation is retained separately, so `Invocations:` / `Resume count:` and the
per-invocation history are always honest even across many interrupted/resumed
attempts. A final human-readable execution-timeline table, verification
ledger, duplicate-work report, slowest-phases list, and phase-budget warnings
are printed at the end of every completed or explicit-stop invocation. See
[verification-and-timeline.md](verification-and-timeline.md) for the full
design and `specrelay task timeline <task-ref>` for read-only inspection.

## 13. AI Coordinator invocation points (spec 0025)

The optional, disabled-by-default coordinator role (see
[architecture.md](architecture.md), "Hybrid AI coordination model", and
[configuration.md](configuration.md), "`roles.coordinator`") runs only at
bounded decision points — never continuously and never after every command:

```text
before_executor              — about to (re)launch the Executor
executor_completion_failed   — the Executor's completion gate failed
executor_completed           — the Executor finished; gate result is known
reviewer_completed           — the Reviewer returned ACCEPT or REQUEST_CHANGES
changes_requested            — the task is sitting at CHANGES_REQUESTED
recovery_requested           — an interrupted task needs a next-step decision
human_handoff_preparation    — automatic progress is stopping; prepare a
                                human decision packet
```

At each invocation point, four things happen **in this order**, and the
coordinator only ever participates in the middle two:

1. **Deterministic state** — the engine reads the task's real, canonical
   `state.json`, completion-gate results, verification ledger, and Reviewer
   decision. Nothing here is inferred by AI.
2. **Coordinator advisory decision** — the engine computes
   `allowed_next_actions` for this exact invocation point (e.g.
   `SEND_TO_REVIEW` is never offered when the completion gate failed) and
   asks the coordinator to select exactly one. The coordinator receives a
   single bounded input snapshot and returns one structured JSON decision —
   nothing more.
3. **Engine validation** — `coordinator_lib.py` validates the decision
   strictly: schema, task/invocation-point match, decision vocabulary,
   membership in `allowed_next_actions`, path safety, constraints, and
   confidence. **A coordinator decision may be rejected here without
   changing task state at all** — an invalid or out-of-policy decision has
   zero effect, and the engine records the rejection durably
   (`23-coordinator-decisions.jsonl`) and falls back to a safe default
   (typically `REQUEST_HUMAN_DECISION`).
4. **Role invocation / human handoff** — only a validated `BLOCK_TASK` or
   `REQUEST_HUMAN_DECISION` decision is enacted immediately in this initial
   specification, and only through the SAME pre-existing, independently
   guarded transition functions every other caller uses. Every other
   decision (`START_EXECUTION`, `REPAIR_ARTIFACTS`,
   `RUN_TARGETED_VERIFICATION`, `SEND_TO_REVIEW`, `RETURN_TO_EXECUTOR`) is
   durably recorded as a recommendation for a human or a future
   specification to act on (spec 0025, section 8: full autonomous routing is
   explicitly out of this initial scope).

Coordinator context (when configured) is prepared and validated
**independently** of Executor/Reviewer context — it never inherits their
conversational state, only deterministic summaries and immutable artifacts
the engine chooses to hand it.

Inspect coordinator activity read-only with `specrelay task show <ref>`,
`specrelay task report <ref>`, or `specrelay task coordination <ref>
[--json]`; a task that never invoked the coordinator reports this honestly
as "not recorded".
