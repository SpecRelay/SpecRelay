# SpecRelay Engine Parity (SDD 0084, extended by SDD 0085)

This is the migration parity checklist required by SDD
`0084-migrate-ai-workflow-engine-into-specrelay`. It compares the now-frozen,
rollback-only legacy `.ai/` workflow (documented in
`current-workflow-contract.md`; SpecRelay is the sole active engine as of
SDD 0085B) against the real, executable SpecRelay engine introduced by this
task (`tools/specrelay/lib/specrelay/`).

**SDD 0085 update:** SpecRelay is now this repository's ACTIVE engine (not
merely parity-equivalent and coexisting). The table below still documents
0084's engine-internals comparison; see "Compatibility cutover (SDD 0085)"
further down for the shim/rollback/ownership evidence added by that task,
backed by real dogfood runs (`docs/dogfood-report.md`).

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
| Reviewer execution + isolation | `run-reviewer.sh`; always a brand-new `claude`/`codex` process, never `--continue`/`--resume` | `workflow.sh#reviewer_iteration` + `providers/claude.sh#reviewer_run`: reviewer prompt is reconstructed from spec/task/evidence files only (`build_reviewer_prompt`), invoked as a fresh `claude --print` (optionally `--agent ai-reviewer`, and optionally with `--verbose --output-format stream-json` when advertised — spec 0006) process | Real-provider smoke: reviewer independently re-derived spec requirements, ran its own `git status`/`diff`/`xxd` checks, and reached its own accept decision | Equivalent; simplified (no `--append-system-prompt` tier); stream-json event capture restored by spec 0006 |
| Context-capability preflight | `context-plus-preflight.sh --role <executor\|reviewer>`; mandatory by default, no silent fallback | `context/capability.sh` dispatch + `context/contextplus.sh` (same available→initialized→bounded-retrieval sequence) + `context/none.sh` (project opts out) | `.specrelay/config.yml`'s `context.adapter`/`context.required`; `workflow.sh` refuses to proceed when required and failed | Equivalent; SpecRelay generalizes this into an explicit adapter seam (`none`/`contextplus`) rather than a Context-Plus-specific script |
| State transitions / state machine | `ai_state.py` canonical states; `DRAFT → READY_FOR_EXECUTOR → EXECUTOR_RUNNING → READY_FOR_REVIEW → {READY_FOR_HUMAN_REVIEW \| CHANGES_REQUESTED} → ...`, `BLOCKED` | `py/state_lib.py` (SpecRelay's own, independent module) encodes the identical canonical states and the identical `READY_FOR_CODEX_REVIEW` read-only alias | `state_test.sh` | Equivalent (Strategy A: same persisted state names — see "State compatibility" below) |
| Transition authorization (runner-owned submit) | `authorize-submit.sh` mints a single-use, out-of-band token consumed by `submit-review.sh`; never available to a still-running executor | `auth.sh#mint`/`#consume` mints an equivalent single-use, out-of-band token (`.transition-auth/<id>.json`), consumed by `transitions::submit`; only minted by the orchestrator AFTER the executor provider subprocess has exited | `transitions_test.sh` ("submit refuses...", "token cannot be reused") | Equivalent |
| Evidence capture | `capture-evidence.sh`: `git status`/`diff --name-status`/`--stat`/patch, with intent-to-add/reset dance for untracked files | `evidence.sh#capture`: identical intent-to-add/reset dance, identical artifact names (`04`–`06`) | `evidence_test.sh` | Equivalent |
| Structured provider events | `run-executor.sh`/`run-reviewer.sh` capture `claude --output-format stream-json` to `19-executor-events.jsonl`/`20-reviewer-events.jsonl` when advertised, rendered live by `render_agent_events.py` | `providers/claude.sh` + `provider.sh#run_agent_events` + `py/render_agent_events.py`: help-driven stream-json detection, raw events to `19`/`20`, extracted final text to `12`/`15`, live semantic rendering to fd 2; honest fallback to generic streaming | `claude_semantic_events_test.sh` (35 assertions: renderer fixtures, executor/reviewer end-to-end via a fake `claude`, decision parsing, both fallback paths, exit-code preservation) | Equivalent (restored by spec 0006) |
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

## Compatibility cutover (SDD 0085)

| Capability | Legacy behavior | SpecRelay behavior | Real evidence | Status |
|---|---|---|---|---|
| `start-spec-task.sh` command surface | Runs the legacy engine directly (`run-ai-loop.sh` → `run-workflow.sh` → `run-executor.sh`/`run-reviewer.sh`) | Compatibility shim delegates to `specrelay run <spec>`, translating `--allow-dirty`→`--allow-dirty-baseline`, preserving `--task-id`, exit code, and spec paths with spaces | `compat_shim_test.sh` (18 assertions); real dogfood scenarios A/B (`docs/dogfood-report.md`) ran through this exact code path | PARITY (same lifecycle semantics; superficial banner text differs, per spec section 27) |
| `show-task.sh` command surface | Reads `.ai-runs/tasks/<exact-id>/*` directly, dumps full file contents | Compatibility shim delegates to `specrelay show <task-ref>` (also accepts numeric prefix / partial slug — legacy required the exact id) | `compat_shim_test.sh` ("numeric-prefix task ref", "never mutates") | IMPROVED (task lookup), PARTIAL (output is a compact summary, not a full multi-file dump — documented difference, not silent) |
| `approve-task.sh` command surface | Direct `state.json` rewrite (DRAFT/WAITING_FOR_HUMAN → READY_FOR_EXECUTOR) | Compatibility shim delegates to `specrelay task approve <task-ref>` | `rollback_test.sh` (default-engine + rollback comparison) | PARITY |
| `run-ai-loop.sh` command surface | Loops `run-workflow.sh --once [--reviewer]` up to `--max-rounds` | Compatibility shim loops `specrelay resume <task-id>` up to `--max-rounds`, same per-round reporting shape | Manual smoke (`.ai/scripts/run-ai-loop.sh nonexistent-task-xyz` → clear refusal, no silent abort) | PARITY |
| `start-ai-task.sh` command surface (freeform, no-spec task creation) | Creates an empty DRAFT task for manual 00/01/02 fill-in | **No safe mapping** — SpecRelay is spec-driven throughout; the shim refuses cleanly under the active engine and points at `start-spec-task.sh` or the explicit rollback | Manual smoke: exits 2 with a clear message, creates nothing | GAP (documented, not faked — spec section 7) |
| Rollback mechanism | N/A (only one engine existed) | `SPECRELAY_ENGINE=legacy` env var (or `.ai/scripts/legacy/*.sh` directly); unrecognized values are a hard error, never a silent fallback | `rollback_test.sh` (14 assertions) | NEW |
| Engine ownership (legacy → SpecRelay direction) | N/A | `transitions.sh#_require_owned` refuses to mutate a task without `"engine": "specrelay"` | `legacy_compat_test.sh` (pre-existing, SDD 0084) | PARITY (carried over) |
| Engine ownership (SpecRelay → legacy direction, Case C) | N/A | `.ai/scripts/internal/{claim-task,requeue-task,accept-review,request-changes,block-task,submit-review,finish-task}.sh` and `.ai/scripts/legacy/approve-task.sh` all refuse a task with `"engine": "specrelay"` | `rollback_test.sh`, `engine_ownership_cases_test.sh` (Case C, 3 assertions) | NEW (this was the actual gap 0084 left for 0085 to close) |
| Migration marker | N/A | `.specrelay/config.yml`'s `workflow.current_engine: specrelay` (existing config field, not a new file — spec section 54) | `specrelay doctor` ("Current engine mode: specrelay (active)") | NEW |
| Shim-loop protection | N/A | `.ai/scripts/legacy/` never references `tools/specrelay/bin/specrelay`; each public shim sources the engine-selection helper exactly once | `shim_loop_test.sh` (10 assertions, including a dynamic doctor-detects-a-deliberately-introduced-loop case) | NEW |
| `specrelay doctor` | N/A (did not exist) | Read-only diagnostics: git repo, project root, config, spec root, task runtime root, executor/reviewer provider availability, context capability, active engine, compatibility shims, rollback engine, conflicting-lock detection; non-zero exit on any failed mandatory check | Manual run against this repository: all 11 checks pass | NEW |
| Direct-vs-shim parity | N/A | For the same fixture spec, `.ai/scripts/start-spec-task.sh` and `tools/specrelay/bin/specrelay run` produce the identical state machine outcome and evidence shape (only cosmetic banner text differs) | `compat_shim_test.sh` (fixtures 1 and 5 compared) | PARITY |
| Host repository mutation safety (spec section 66 regression) | N/A | Every fixture/compat/rollback/dogfood test operates only in an isolated temp Git repository, verified via a 6-point guard before any Git-mutating command; `run_all.sh` captures and verifies host HEAD/branch/working-tree-path-set before and after the full suite | `host_repo_safety_test.sh` (16 assertions); `run_all.sh`'s own before/after check | NEW (added specifically because a prior execution attempt of this task violated this) |

Do not read "PARTIAL"/"GAP" rows above as failures: each documents an
intentional, disclosed scope decision (spec section 7: "do not fake
compatibility; document the gap"), not a silent omission.

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

1. **Structured provider event capture — CLOSED by spec 0006.** The previously
   missing `19-executor-events.jsonl` / `20-reviewer-events.jsonl` capture is now
   implemented: when `claude --help` advertises it, `providers/claude.sh` runs
   `claude --print --verbose --output-format stream-json …`, persists the raw
   JSONL stream to `19`/`20`, and extracts the final assistant text into the
   numbered `12`/`15` stdout files. It is added behind the provider-adapter seam
   (a new `specrelay::provider::run_agent_events` helper), so core `workflow.sh`
   was not touched. See `docs/providers.md` → "Semantic Claude live event
   rendering".
2. **Live semantic terminal rendering — CLOSED by spec 0006.** The standalone
   renderer `lib/specrelay/py/render_agent_events.py` turns the stream-json
   events into concise per-step activity lines (`[executor:claude] reading: …`,
   `command: …`, `result: success`) shown live on the terminal, never rendering
   private reasoning. When stream-json is not advertised (or
   `SPECRELAY_SEMANTIC_EVENTS=0`), SpecRelay falls back honestly to the generic
   spec-0003 stdout/stderr streaming — semantic events are never faked.
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
7. **Interrupted-task recovery — CLOSED by SDD 0085B.** The previously-missing
   "no supported `EXECUTOR_RUNNING → READY_FOR_EXECUTOR` recovery" gap (neither
   engine offered a safe, audited way to reclaim an interrupted/orphaned
   executor run) is now closed by the SpecRelay-native `specrelay task recover`
   command (liveness-first refusal, safe same-host stale-lock reclaim, audited
   recovery metadata, evidence preserved, never `READY_FOR_HUMAN_REVIEW`; see
   `architecture.md` H9 and `current-workflow-contract.md` §4/§5). Because the
   legacy engine is frozen as of SDD 0085B (rollback/reference only), parity is
   no longer a moving target — no new recovery path is added to `.ai/`.

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
