# SpecRelay Engine Parity (SDD 0084)

This is the migration parity checklist required by SDD
`0084-migrate-ai-workflow-engine-into-specrelay`. It compares the still-
authoritative legacy `.ai/` workflow (documented in
`current-workflow-contract.md`) against the real, executable SpecRelay
engine introduced by this task (`tools/specrelay/lib/specrelay/`).

**This is not a claim of "full parity."** `specrelay run` genuinely
orchestrates a real, multi-round lifecycle — it is not a wrapper that invokes
Claude once and stops. But several legacy behaviors (live semantic event
streaming, desktop notifications, the `codex` reviewer provider, the
macOS-notifier tier ladder) are intentionally NOT migrated in this task; they
are called out below as explicit, not-yet-covered gaps rather than silently
dropped.

| Capability | Current engine (`.ai/`) | SpecRelay | Evidence | Parity status |
|---|---|---|---|---|
| Spec task creation | `start-spec-task.sh` derives task id from spec's parent dir, creates folder + `state.json` via `new-task.sh`, fills 00/01/02 | `specrelay task create <spec>` / `specrelay run <spec>` derive the id the same way (`task::id_from_spec_path`, `task::sanitize`), create the folder atomically, seed 00/01/02 from the spec | `transitions_test.sh` ("create ..." cases); `cli_workflow_test.sh` ("task create ..."); manual run in `03-executor-log.md` | Equivalent |
| Approval (human gate into `READY_FOR_EXECUTOR`) | `approve-task.sh`; `start-spec-task.sh` auto-approves a fresh `DRAFT`/`WAITING_FOR_HUMAN` task, on the stated reasoning that invoking the higher-level script IS the human's approval | `specrelay task approve` (explicit, decoupled); `specrelay run` auto-approves `DRAFT`/`WAITING_FOR_HUMAN` on the same reasoning (the human's own `run` invocation is the approval) | `transitions_test.sh` ("approve ..."); `dirty_tree_test.sh`, `workflow_fake_provider_test.sh` (`run` output shows the approval line) | Equivalent (same policy, explicitly documented in both places) |
| Executor execution (contract: dirty-tree guard, context preflight, claim, run, evidence capture, required-outputs check, submit-only-if-all-pass) | `run-executor.sh` (contract in `current-workflow-contract.md`, section 6) | `workflow.sh#executor_iteration` implements the identical ordered contract | `03-executor-log.md`; `workflow_fake_provider_test.sh` scenarios A-D; real-provider smoke (section "Real provider smoke evidence" below) | Equivalent |
| Reviewer execution + isolation | `run-reviewer.sh`; always a brand-new `claude`/`codex` process, never `--continue`/`--resume` | `workflow.sh#reviewer_iteration` + `providers/claude.sh#reviewer_run`: reviewer prompt is reconstructed from spec/task/evidence files only (`build_reviewer_prompt`), invoked as a fresh `claude --print` (optionally `--agent ai-reviewer`) process | Real-provider smoke: reviewer independently re-derived spec requirements, ran its own `git status`/`diff`/`xxd` checks, and reached its own accept decision | Equivalent; simplified (no `--append-system-prompt` tier, no stream-json event capture — see "Known gaps") |
| Context-capability preflight | `context-plus-preflight.sh --role <executor\|reviewer>`; mandatory by default, no silent fallback | `context/capability.sh` dispatch + `context/contextplus.sh` (same available→initialized→bounded-retrieval sequence) + `context/none.sh` (project opts out) | `.specrelay/config.yml`'s `context.adapter`/`context.required`; `workflow.sh` refuses to proceed when required and failed | Equivalent; SpecRelay generalizes this into an explicit adapter seam (`none`/`contextplus`) rather than a Context-Plus-specific script |
| State transitions / state machine | `ai_state.py` canonical states; `DRAFT → READY_FOR_EXECUTOR → EXECUTOR_RUNNING → READY_FOR_REVIEW → {READY_FOR_HUMAN_REVIEW \| CHANGES_REQUESTED} → ...`, `BLOCKED` | `py/state_lib.py` (SpecRelay's own, independent module) encodes the identical canonical states and the identical `READY_FOR_CODEX_REVIEW` read-only alias | `state_test.sh` | Equivalent (Strategy A: same persisted state names — see "State compatibility" below) |
| Transition authorization (runner-owned submit) | `authorize-submit.sh` mints a single-use, out-of-band token consumed by `submit-review.sh`; never available to a still-running executor | `auth.sh#mint`/`#consume` mints an equivalent single-use, out-of-band token (`.transition-auth/<id>.json`), consumed by `transitions::submit`; only minted by the orchestrator AFTER the executor provider subprocess has exited | `transitions_test.sh` ("submit refuses...", "token cannot be reused") | Equivalent |
| Evidence capture | `capture-evidence.sh`: `git status`/`diff --name-status`/`--stat`/patch, with intent-to-add/reset dance for untracked files | `evidence.sh#capture`: identical intent-to-add/reset dance, identical artifact names (`04`–`06`) | `evidence_test.sh` | Equivalent |
| Structured provider events | `run-executor.sh`/`run-reviewer.sh` capture `claude --output-format stream-json` to `19-executor-events.jsonl`/`20-reviewer-events.jsonl` when advertised | Not implemented in this task's `providers/claude.sh` | — | **Gap** (documented, not hidden — see "Known gaps") |
| Request-changes decision + requeue | `request-changes.sh` (requires 09+11) → `requeue-task.sh` (backs up 02, promotes 11→02, appends ownership footer, clears claim fields) | `transitions.sh#request_changes` / `#requeue` implement the identical sequence, PLUS archive the completed round into `iterations/round-N/` before overwriting (see "Iteration history" below) | `transitions_test.sh`; `workflow_fake_provider_test.sh` scenario B | Equivalent, and strictly improved (round history is preserved — legacy relies on a best-effort `18-iteration-summary.md` reconstruction) |
| Multi-iteration / rework loop | Known, documented limitation: the dirty-tree guard cannot distinguish a task's own round-1 diff from an unrelated change, so the automated requeue path gets stuck (`current-workflow-contract.md`, section 9) | `git_guard.sh` (baseline + owned-snapshot model) makes iteration 2+ work correctly by design | `dirty_tree_test.sh` cases 1 and 4 (must-pass); `workflow_fake_provider_test.sh` scenario B | **Improved** — this is the specific limitation SDD 0083 flagged as "not fixed, recorded as a compatibility requirement for the SpecRelay engine migration" |
| Maximum iterations | `run-ai-loop.sh --max-rounds` (default 3); prints current state and exits 0 (explicitly not success) when exceeded | `.specrelay/config.yml`'s `tasks.max_iterations` (default 3); `workflow::run` exits non-zero (5) with an explicit "maximum of N iteration(s)" message | `workflow_fake_provider_test.sh` scenario E | Equivalent in spirit; SpecRelay's exit code is non-zero (never 0) for this outcome — a deliberate improvement per this spec's section 54 ("avoid returning 0 for failed workflow completion") |
| Dirty-working-tree protection | Path-prefix allow-list (`.ai/` + the task's own SDD folder) | Baseline/owned-snapshot diffing (see above), PLUS always excludes the task-runs root and the task's own spec directory | `dirty_tree_test.sh` cases 1-4 | Equivalent goal, different (and more precise) mechanism |
| Human final gate | `READY_FOR_HUMAN_REVIEW`; nothing downstream automated | Identical; `workflow::run`/`resume` never proceed past this state | `workflow_fake_provider_test.sh` scenario A; real-provider smoke | Equivalent |
| Failure handling (executor/reviewer non-zero, missing outputs, preflight failure, transition-auth failure) | `current-workflow-contract.md`, section 11 | `workflow.sh` implements the same decision table; distinct non-zero exit codes for each class (see `cli.sh` usage text / section 54) | `workflow_fake_provider_test.sh` scenarios C, D; `transitions_test.sh` | Equivalent |
| Task inspection (`show`/`status`/`list`) | `show-task.sh`, `list-tasks.sh` | `specrelay show`/`status`/`list` (and `task` sub-forms); ALSO reads legacy-created tasks (no `engine` field) read-only | `legacy_compat_test.sh` | Equivalent, plus explicit legacy-task read compatibility |
| No auto-commit/push/merge/deploy | Never implemented anywhere in `.ai/` | Never implemented anywhere in `tools/specrelay/`; `git` is only ever invoked for `status`/`diff`/`add --intent-to-add`/`reset`/`rev-parse` | Grep of `tools/specrelay/lib` for `git commit`/`git push`: no matches | Equivalent |
| Task locking / concurrent-mutation safety | Not implemented (no lock file; two `run-executor.sh` invocations against the same task race on `claim-task.sh`'s state check only) | `lock.sh`: `mkdir`-based atomic lock with stale-owner (dead pid) reclaim | `lock_test.sh`; `concurrent_test.sh` (two real backgrounded CLI processes race; exactly one wins) | **New** (not present in the legacy engine) |
| Cross-engine mutation safety | Not applicable (only one engine exists) | Every SpecRelay-created task records `engine: specrelay`; every mutating transition refuses a task lacking that field | `transitions_test.sh` ("cross-engine..."); `legacy_compat_test.sh` ("refuses a legacy...") | **New** (required because two engines now coexist during migration — spec section 50) |

## State compatibility (Strategy A)

SpecRelay preserves the exact persisted state names the legacy engine already
writes (`DRAFT`, `READY_FOR_EXECUTOR`, `EXECUTOR_RUNNING`, `READY_FOR_REVIEW`,
`CHANGES_REQUESTED`, `READY_FOR_HUMAN_REVIEW`, `BLOCKED`), including
read-only recognition of the legacy `READY_FOR_CODEX_REVIEW` alias. No schema
versioning was introduced — Strategy B (spec section 10) was rejected as
unnecessary migration risk for this task.

## Artifact compatibility (Option A)

SpecRelay writes the same numbered artifact filenames the legacy engine uses
(`00-user-request.md` … `16-reviewer-stderr.txt`, `state.json`), so a human
comparing a SpecRelay-run task folder to a legacy one sees the same shape.
Two deliberate, minor, documented deviations:

- `12-executor-stdout.txt` / `13-executor-stderr.txt` are generic names in
  SpecRelay (any executor provider), rather than the legacy engine's
  Claude-specific historical naming — SpecRelay's provider abstraction makes
  the Claude-specific name inappropriate for core artifacts. `15`/`16`
  (reviewer stdout/stderr) were already generic in the legacy contract and
  are reused unchanged.
- A NEW, additive directory, `iterations/round-<N>/`, archives each
  completed round's full artifact set before the next round overwrites the
  live numbered files (see "Iteration history" below). This does not rename,
  remove, or repurpose any existing numbered file — it is purely additive,
  preserving Option A's compatibility guarantee while closing spec section
  36's "iteration history" requirement, which the legacy engine only
  satisfies via a best-effort `18-iteration-summary.md` reconstruction.

## Iteration history

Every time a round is about to be superseded (on `accept`, which finalizes a
round, and on `requeue`, which starts the next one), `transitions.sh`
archives that round's complete artifact set into
`<task-dir>/iterations/round-<N>/` before any file is overwritten. This makes
"what did round 1 do, what did the reviewer reject, what changed in round 2,
what was finally accepted" mechanically reconstructable, not just
best-effort. Verified in `transitions_test.sh` and
`workflow_fake_provider_test.sh` scenario B ("round 1 evidence survives...").

Known minor imperfection: a round's `iterations/round-N/` archive may include
a stale `11-next-executor-prompt.md` carried over from an earlier round when
that round's own decision was ACCEPT (which does not produce a new `11`).
This does not lose any round's own executor/reviewer artifacts — it is a
cosmetic leftover-reference issue, not a correctness gap.

## Approval semantics

`specrelay run <spec>` auto-approves a fresh task (`DRAFT`/`WAITING_FOR_HUMAN`
→ `READY_FOR_EXECUTOR`) as part of the same command, without a separate
`approve` step. This mirrors the ALREADY-PROVEN legacy precedent:
`start-spec-task.sh` does exactly this ("auto-approving task ... running
start-spec-task.sh is the approval for a spec that is already ready to
execute"). The reasoning: a human explicitly typing `specrelay run
<spec-path>` (or `start-spec-task.sh <spec-path>`) IS the deliberate act of
authorizing execution — protocol.md's Safety Rule ("Human approval is
required before any task becomes READY_FOR_EXECUTOR") is satisfied by that
explicit invocation, not bypassed by it. `specrelay task create` (without
`run`) does NOT auto-approve — it leaves a task in `DRAFT` for a human to
separately review and `specrelay task approve`, matching the decoupled
`start-ai-task.sh` → `approve-task.sh` flow for non-SDD tasks.

## Known gaps (evidence-backed, not hidden)

1. **No structured provider event capture** (`19-executor-events.jsonl` /
   `20-reviewer-events.jsonl` equivalents). `providers/claude.sh` invokes
   `claude --print` without `--output-format stream-json`; only the final
   stdout/stderr are captured. A future task can add this behind the same
   provider-adapter seam without touching core `workflow.sh`.
2. **No live semantic terminal rendering** (`[executor] reading: …` style
   lines). SpecRelay prints role-based high-level progress lines but not
   per-tool-call activity.
3. **Only `claude` (executor) and `claude`/`claude-subagent` (reviewer) are
   implemented as real provider adapters.** `codex` is not implemented as a
   SpecRelay provider in this task (the legacy `codex` reviewer path is also
   not fully usable in this repository per `current-workflow-contract.md`
   section 10, so this is not a regression).
4. **No desktop/Notification-Center integration.** `accept()` does not
   attempt any notification. This is intentionally out of scope (spec
   section 77 does not list it as required, and it is provider/OS-specific
   integration, not core lifecycle).
5. **`specrelay task submit`, `specrelay task authorize-submit` are lower-
   level, manual-recovery-oriented commands**, analogous to the legacy
   `submit-review.sh`/`authorize-submit.sh`. Like the legacy pair, they do
   not verify the caller is human — an accepted, documented limitation
   mirroring `.ai/protocol.md`'s own accepted gap for the identical
   mechanism.
6. **A round's archived `11-next-executor-prompt.md` may be stale** when
   that round's decision was ACCEPT (see "Iteration history" above).

## Real provider smoke evidence

A dedicated, disposable temporary git fixture (never this repository, never
SDD 0084 itself) was used to run a trivial real spec ("create hello.txt with
one line of text") through `specrelay run` with `roles.executor.provider:
claude` and `roles.reviewer.provider: claude-subagent`:

- The real `claude` executor correctly implemented the spec and wrote
  `03-executor-log.md` / `07-tests.txt` / `08-executor-summary.md` into the
  task's runtime folder.
- Evidence capture recorded exactly the expected single-file diff.
- The task reached `READY_FOR_REVIEW` and a real, freshly-spawned
  `claude-subagent` reviewer independently re-derived the spec's
  requirements, ran its own `git status`/`git diff`/byte-level file
  inspection (never trusting the executor's narrative alone), and reached
  its own `DECISION: ACCEPT`, writing `09-consultant-review.md` and
  `10-business-summary.md`.
- The task reached `READY_FOR_HUMAN_REVIEW`. Full transcript excerpts are in
  `03-executor-log.md` for task `0084-migrate-ai-workflow-engine-into-specrelay`.

This proves the Claude executor adapter can invoke, capture output, the
reviewer isolation path can invoke independently, and the ACCEPT/
REQUEST_CHANGES decision contract works with a real provider — not only the
deterministic fake provider.
