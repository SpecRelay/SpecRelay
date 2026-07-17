# Spec 0029 — Engine-Owned Executor Finalization and Supervised Verification

## 1. Status

```yaml
status: proposed
```

## 2. Release metadata

```yaml
release:
  impact: minor
  rationale: >-
    Moves executor verification and required evidence finalization into the
    deterministic engine, prevents provider exit with pending background work
    from masquerading as successful executor completion, and adds safe
    recovery for interrupted rounds with proven task-owned changes.
```

## 3. Task identity

```text
0029-engine-owned-executor-finalization-and-supervised-verification
```

## 4. Objective

Make the recurring "provider exited successfully but the executor round was
never actually finished" failure class **impossible or deterministically
recoverable**.

SpecRelay currently relies on the AI Executor to supervise long-running
verification, wait for its real completion, write the mandatory execution
artifacts (`03-executor-log.md`, `07-tests.txt`, `08-executor-summary.md`),
and finish every finalization step before its non-interactive provider process
returns. A non-interactive provider cannot safely honour a promise to "wait for
a background notification" after its process has already exited, so this
repeatedly leaves a legitimate diff behind an `INCOMPLETE` completion gate with
no engine-owned way forward except manual intervention.

This spec moves **command supervision, verification execution, required
evidence generation, completion-gate inputs, and safe interrupted-round
recovery** into the deterministic SpecRelay engine. The AI Executor implements
and explains; the engine owns everything that must be true, durable, and
observed before a round is accepted as complete. The engine must never
fabricate success, test results, or AI-authored claims.

## 5. Background

### 5.1 The recurring failure pattern

Two recent real tasks failed the same way:

- **Task 0027.** The Executor implemented the work, launched the full test
  suite in the background, said it would wait for a completion notification,
  and the non-interactive provider process exited successfully *before* the
  background verification finished. `07-tests.txt` was never written and the
  Completion Gate correctly refused submission.
- **Task 0028.** The Executor implemented the UI verification subsystem, again
  launched the full suite and relied on background/`ScheduleWakeup` behaviour,
  the provider exited successfully, `03-executor-log.md` was missing or empty,
  test evidence was not recorded, and the Completion Gate again correctly
  returned `INCOMPLETE`.

In both cases the Completion Gate (spec 0021) behaved **correctly** and must
not be weakened. The defect is architectural: too much finalization
responsibility lives inside a process that can return before the work it
promised is durable.

### 5.2 The interrupted-round recovery gap (task 0027)

The same class produced a second, compounding failure:

- an executor round produced a legitimate diff;
- the round did not submit because a required artifact was missing;
- `specrelay task recover` returned the task to `READY_FOR_EXECUTOR`;
- the next claim was blocked by the working-tree guard, because the previous
  round's legitimate diff had **never been recorded as task-owned**
  (`git_guard::snapshot_owned` runs only *after* the completion gate passes and
  *before* submission — see `lib/specrelay/workflow.sh`);
- an operator had to hand-edit `.git-owned-snapshot.txt` to proceed.

The recovery log attached to this task confirms the same shape: an execution
that completed most implementation work but exited before producing the
required completion artifacts, after which SpecRelay recovery had to
**reconstruct executor artifacts, execute verification, process reviewer
feedback, perform rework, and continue the workflow** — every one of those
steps a manual intervention this spec must eliminate.

### 5.3 What already exists (and is reused, not re-invented)

- **Completion Gate (spec 0021).** `03/07/08` non-empty check,
  unresolved-wait detection, input-coverage clause, `completion_gate` events in
  `20-execution-events.jsonl`, `22-agent-efficiency.json`. Stays strict.
- **Verification-policy engine (spec 0026).** `verification_policy.sh`,
  `verification_runner.sh`, `py/verification_policy_lib.py`. Multi-service,
  multi-check, level-aware (`changed`/`full`/`flexible`), dependency-aware,
  bounded parallel execution. `verification_runner::run` already returns `0`
  only for overall `PASSED`/`NOT_REQUIRED`. Placement keys `executor`,
  `reviewer`, `final_gate`. Evidence: `26-verification-plan.json`,
  `27-verification-summary.json`, `28-verification-summary.md`,
  `verification/services/<service>/<check>/{command.json,stdout.txt,stderr.txt,result.json}`,
  `verification/effective-config.json`.
- **UI runtime verification (spec 0028).** `ui_verification.sh`,
  `py/ui_verification_lib.py`, `js/ui_playwright_runner.js`, artifacts under
  `29-ui-verification/` (`summary.json` with per-scenario `PASS`/`FAIL`/`BLOCKED`),
  and a `transitions.sh::accept` gate that already refuses accept when required
  UI evidence is missing/incomplete. The Playwright/fake runner is already an
  engine-invoked subprocess.
- **Working-tree guard (`git_guard.sh`).** `.git-baseline.txt` (task-creation
  dirt) and `.git-owned-snapshot.txt` (accumulated task-owned diff). Claim is
  refused when the tree is not a subset of `baseline ∪ owned`.
- **Evidence capture (`evidence.sh`).** `04-git-status.txt`,
  `05-changed-files.txt`, `05-git-diff-stat.txt`, `06-git-diff.patch`, using
  the intent-to-add / reset dance for untracked files.
- **Provider adapter contract (`providers/provider.sh`).** Foreground,
  synchronously-`wait`ed children via `run_streamed` / `run_agent_events`.
  Bounded read-only auxiliary calls already exist: `reviewer_recover_marker`
  and `coordinator_run` both run without `--dangerously-skip-permissions`.
- **Locking (`lock.sh`).** `.specrelay-runs/tasks/.specrelay-locks/<task-id>.lock/owner`
  records `pid`, `host`, `acquired_at`; `cli::task_recover` already classifies
  owner liveness (`stale` / `live-local` / `live-foreign`).
- **Coordinator (spec 0025).** Advisory-only decision vocabulary including
  `REPAIR_ARTIFACTS`, `RUN_TARGETED_VERIFICATION`, `SEND_TO_REVIEW`; engine
  computes the allowed-next-actions set and validates every decision against
  it.
- **Recover transition (`transitions.sh::recover`).** The one supported
  interrupted-task recovery `EXECUTOR_RUNNING -> READY_FOR_EXECUTOR`, audited.
- **Effective-config capture-once + drift note (specs 0012/0015/0019/0021/0027).**

This spec is the real, engine-executed form of the roadmap's already-named
"**Bounded artifact repair — a real, engine-executed `REPAIR_ARTIFACTS`**"
(current-plan.md, "Next objective"), extended with supervised verification and
safe interrupted-round recovery.

## 6. Product decision

Executor finalization and verification-evidence ownership move into the
deterministic engine.

- The **AI Executor** implements and explains. It may run focused checks during
  implementation. It writes the implementation summary before returning.
- The **deterministic engine** owns: command supervision, post-provider
  finalization, evidence generation from observed facts, completion-gate
  inputs, and safe interrupted-round recovery.
- The engine **never** fabricates success, test results, or AI-authored claims.
  Every engine-generated artifact clearly separates *facts observed by the
  engine*, *text reported by the AI*, and *unavailable information*.

## 7. Scope

1. Explicit, durable executor **phases** with independent results (§10).
2. A precise **finalization-only-resume vs. implementation-rerun** rule (§11).
3. Engine-generated `03-executor-log.md` from observed durable sources (§12).
4. Engine-owned **verification execution** (spec 0026 engine) as a supervised,
   synchronously-waited child (§13).
5. An **authoritative-placement / reusable-result** rule preventing duplicate
   full-suite execution across roles/placements (§14).
6. Integration of **spec 0028 UI runtime verification** into completion
   validation (§15).
7. Engine-generated `07-tests.txt` from real verification artifacts, with
   pre-existing-failure classification only from existing evidence (§16).
8. A hardened, **sandboxed** `08-executor-summary.md` finalizer (§17).
9. The durable **finalization record** `30-executor-finalization.json` (§18).
10. A **no-background-wait completion rule** authoritative on process ownership
    and durable state (§19).
11. Additive, provider-neutral **Executor prompt-contract** changes (§20).
12. A durable **execution-owner lease** (§21) and **portable process-group
    supervision** (§22).
13. Safe **interrupted-round recovery**, including interruption before evidence
    capture, and preservation of the existing `git_guard` API (§23).
14. An explicit deterministic **failure/outcome model** (§24).
15. Minimal **configuration** with an explicit **degraded-legacy** rollback
    mode (§25, §26).
16. Deterministic **resume** per phase, gated on input digests (§27).
17. **Artifact-layout compatibility** (§28), **operator visibility** (§29),
    **Coordinator** integration (§30), **security** (§31).

## 8. Out of scope

- The full `00-task/ … 06-telemetry/` artifact-layout migration (roadmap
  Phase 6).
- Per-task isolated workspaces / parallel task execution (Phases 8–9). In
  particular, **no base-commit checkout-and-execute** for pre-existing-failure
  classification is introduced here (§16.3); that needs an isolated workspace.
- New reviewer-side verification *ownership* — the reviewer's independent
  verification (spec 0019/0026) is unchanged except for the reuse rule in §14.
- Any change to the human final gate at `READY_FOR_HUMAN_REVIEW`.

## 9. Terminology

- **Provider execution** — one invocation of the executor provider adapter for
  a round. It **implements and explains**. Its exit code is a fact, not a
  completion verdict.
- **Executor completion** — all engine-owned finalization phases for a round
  reached their required results. Strictly distinct from provider execution.
- **Finalization pipeline** — the ordered engine-owned phases that run after
  provider execution returns.
- **Finalization-only resume** — a resume that reuses a durably-recorded
  provider terminal result and re-enters the finalization pipeline **without
  rerunning the provider** (§11).
- **Implementation rerun** — a resume/round that runs the provider again,
  because no durable terminal provider result exists for the current prompt, or
  a new iteration's prompt is in force, or the last result was a failure (§11).
- **Engine-owned verification** — required verification executed by the engine
  (spec 0026 runner + spec 0028 UI runner) as a supervised child, distinct from
  focused checks the Executor may run during implementation.
- **Authoritative placement** — the single placement (spec 0026 `executor` /
  `reviewer` / `final_gate`) at which a required check MUST execute once; other
  placements reuse its result when digests match (§14).
- **Supervised child** — a child process the engine starts as a process-group
  leader (§22), waits for synchronously, and can time out and terminate by
  process group.
- **Execution-owner lease** — the durable record proving which live process
  owns a running task, defeating PID reuse and hung-process ambiguity (§21).
- **Proven task-owned paths** — repository paths the engine has durable
  evidence were changed by a specific executor round.
- **Degraded-legacy mode** — an explicit, visibly-reported configuration in
  which engine-owned finalization is disabled; forbidden for tasks with any
  required verification or UI verification (§26).

## 10. Explicit executor phases

The executor round is modelled as an ordered pipeline of durable phases. Each
phase has a recorded result. **Provider exit does not imply executor
completion**; only `executor_completion_validation` passing does.

| Phase | Owner | Purpose | Gates round on failure |
|-------|-------|---------|------------------------|
| `executor_provider_execution` | provider | Implement + explain; may run focused checks | yes (provider non-zero) |
| `executor_evidence_capture` | engine | Capture git evidence (`04/05/06`); record proven round-owned paths; generate/repair `03-executor-log.md` | yes |
| `executor_verification` | engine | Run required verification (spec 0026 engine + spec 0028 UI runner) as a supervised child at its authoritative placement; generate `07-tests.txt` | yes (FAILED/BLOCKED) |
| `executor_summary_finalization` | engine (+ sandboxed finalizer) | Ensure `08-executor-summary.md` exists and is structurally valid | yes |
| `executor_completion_validation` | engine | The strict Completion Gate over all durable inputs, incl. multi-service and UI verification | yes |
| `submission_to_review` | engine | Mint single-use token; `EXECUTOR_RUNNING -> READY_FOR_REVIEW` | yes |

### 10.1 Execution order and the one deviation from the scope list

Evidence capture runs **before** verification, because the `changed`/`flexible`
levels select checks from the round's changed paths (spec 0026,
`changed_paths`), known only after the diff is captured. This deviation from the
scope ordering is deliberate; the phase *set* is unchanged.

### 10.2 Phase results are durable

Each phase records `pending | running | passed | failed | skipped` plus, on
failure, a stop reason (§24) into `30-executor-finalization.json` (§18) and as
timeline phases (`executor_verification`, `executor_summary_finalization`,
`executor_completion_validation` are new; `executor_provider_execution`,
`executor_evidence_capture`, `executor_submission` already exist in
`timeline.sh`).

### 10.3 Phases are not new lifecycle states

To avoid state explosion (§24), phases and their results are recorded **inside**
the existing `EXECUTOR_RUNNING` state. No new canonical `state.json` value is
introduced. A round that fails any finalization phase stays `EXECUTOR_RUNNING`
and is recoverable; a round that passes all phases reaches `READY_FOR_REVIEW`.


### 10.4 Finalization source of truth and pipeline version

`30-executor-finalization.json` is the **authoritative source of truth for the
executor-finalization pipeline**. Other artifacts have narrower ownership:

- `state.json` remains authoritative for the canonical lifecycle state;
- `27-verification-summary.json` and `29-ui-verification/summary.json` remain
  authoritative for their respective verification results;
- `20-execution-events.jsonl` and the timeline are append-only event history;
- `03`/`07`/`08` are human-readable evidence derived from, or validated against,
  those authoritative machine-readable sources.

Where duplicated fields disagree, the engine must fail closed and report
`FINALIZATION_RECORD_CONFLICT`; it must never silently select one value.

The finalization record contains both:

```json
{
  "schema_version": 1,
  "pipeline_version": 1
}
```

`schema_version` governs the JSON shape. `pipeline_version` governs phase order,
phase semantics, digest rules, and resume behaviour. Resume may continue a task
only when its pipeline version is supported. Unsupported historical versions
remain readable but require an explicit migration or compatible legacy reader;
they are never silently interpreted using current semantics.

### 10.5 Implementation boundaries

This spec must not turn `workflow.sh` into a larger orchestration monolith.
Responsibilities are divided as follows:

- `workflow.sh` coordinates lifecycle order only;
- `finalization.sh` owns phase orchestration and phase transitions;
- `py/finalization_lib.py` owns deterministic record generation, validation,
  digest comparison, and human-readable artifact rendering;
- `py/proc_supervisor.py` owns portable process/session supervision only;
- `lock.sh` owns leases and liveness classification only;
- `git_guard.sh` owns provenance and task-owned-path derivation only;
- verification and UI runners remain authoritative for executing their checks.

No module may reach across these boundaries by directly mutating another
subsystem's private files. Public shell functions / JSON contracts are required
for cross-module interaction. A maintainability test must fail when
`workflow.sh` directly implements artifact rendering, lease parsing, process
termination, or ledger reconstruction.

## 11. Finalization-only resume vs. new implementation round

A provider invocation that has a **durably recorded terminal result** must not
be rerun merely because a later finalization phase was interrupted. This is the
single rule that makes resume both safe and non-wasteful.

### 11.1 The durable provider terminal result

Immediately after the provider adapter returns and the engine's `wait`
completes — **before any finalization phase runs** — the engine atomically
records into `30-executor-finalization.json.provider_execution`:

```json
{
  "iteration": 1,
  "invocation_id": "3",
  "prompt_digest": "sha256:<sha256(02-executor-prompt.md)>",
  "exit_code": 0,
  "completed_at": "…Z",
  "process_group_terminated": false
}
```

This record is the authoritative "the provider already ran and produced this
terminal result for this prompt" fact.

### 11.2 When implementation is rerun (exactly)

The provider is rerun **only** when at least one holds:

1. **No durable terminal result** exists for the current iteration whose
   `prompt_digest` matches the current `02-executor-prompt.md` (the provider was
   killed before it recorded a terminal exit — §32 boundary 1).
2. **The prompt changed** — a requeue promoted `11-next-executor-prompt.md` to
   `02-executor-prompt.md` and incremented `iteration`, so the recorded digest
   no longer matches (a genuinely new implementation round — §32 boundary 9).
3. **The recorded result was a failure** (`exit_code != 0`,
   `PROVIDER_FAILED`) — a failed implementation must be re-attempted, never
   silently finalized.

### 11.3 Otherwise: finalization-only resume

When a matching terminal result with `exit_code == 0` exists, resume is
**finalization-only**: the engine does **not** rerun the provider. It re-enters
the finalization pipeline from the first phase whose durable inputs are missing
or stale (§27), reusing everything already valid. This is what turns "the
provider exited but finalization was interrupted" from a manual-recovery event
into an automatic continuation.

## 12. Engine-owned `03-executor-log.md`

`03-executor-log.md` must no longer depend on the Executor remembering to write
it. The engine generates it during `executor_evidence_capture` when it is
missing or empty, and always records a machine-readable provenance block.

### 12.1 Observed durable sources

Assembled **only** from durable sources already present: provider exit status
(from the §11.1 record); provider stdout/stderr (`12`/`13`); the semantic event
stream (`19-executor-events.jsonl`) when present; command-timing events
(`21-command-timing-events.jsonl`); the execution timeline
(`20-execution-events.jsonl`); changed-file / diff evidence (`04/05/06`); the
verification result (`27-verification-summary.json` / `29-ui-verification/summary.json`)
when already available, else a forward reference.

### 12.2 Provenance separation (mandatory)

Three clearly-labelled zones that MUST NOT be blurred:

```markdown
## Engine-Observed Facts
- Provider exit status: 0
- Changed files (from 05-changed-files.txt): <N>
- Tool operations observed (from 21-command-timing-events.jsonl): <N>
- Verification: see 07-tests.txt / 27-verification-summary.json / 29-ui-verification/summary.json

## Reported by the AI (unverified)
> <verbatim quoted extract of the AI's final assistant text from
> 12-executor-stdout.txt — labelled as claims, never as engine facts>

## Unavailable
- <each item the engine could not observe, named explicitly>
```

The engine MUST NOT invent actions or verification results. Absent sources are
named under "Unavailable", never fabricated.

### 12.3 Executor-written log is preserved

A non-empty Executor-written `03-executor-log.md` is not overwritten; the engine
appends only the `## Engine-Observed Facts` zone if absent.

## 13. Engine-owned verification execution

Configured verification is executed by the deterministic engine **after
provider execution**, using the spec 0026 policy/multi-service engine. The AI
must not be the lifecycle owner of long-running full-suite execution.

### 13.1 What the engine does

During `executor_verification`, when finalization is `enabled` (§26) **and** a
spec 0026 policy is configured, the engine:

1. computes changed paths (`verification_policy::changed_paths`);
2. runs `verification_runner::run` at the authoritative placement (§14) as a
   **supervised child** (§22), waiting for real completion;
3. retains every per-check exit code and terminal status;
4. enforces the configured per-check/default `timeout_seconds`, terminating
   timed-out checks by process group (§22, §31);
5. produces deterministic per-service/per-check evidence and the overall summary
   (`27-verification-summary.json`; overall status `PASSED`/`FAILED`/`BLOCKED`/
   `NOT_REQUIRED`/`NOT_RECORDED`).

`verification_runner::run` already returns non-zero for `FAILED`/`BLOCKED`; the
phase maps that to §24 stop reasons.

### 13.2 Projects without a spec 0026 policy

When no policy is configured, engine-owned multi-service verification is
`NOT_REQUIRED`: the engine does not invent a command. `07-tests.txt` is then
generated (§16) from whatever real evidence the round produced (the spec 0019
transcript-extracted verification ledger) plus the honest statement that no
engine-owned required verification was configured. (UI verification, §15, is a
separate required subsystem and is still enforced when UI-impact is detected.)

### 13.3 Executor-run focused checks do not replace engine verification

The Executor may run focused checks during implementation (spec 0019 budgets
unchanged). They are recorded but do not satisfy the required engine-owned final
verification (prompt contract, §20).

## 14. Authoritative placement and reusable results

To prevent the **same required check (especially a full suite) executing more
than once** across the Executor, engine finalization, the Reviewer, and the
final gate, every required check has a single **authoritative placement** and a
digest-based reuse rule.

### 14.1 The rule

- Each required check's authoritative placement is its configured spec 0026
  placement (`verification.placement.{executor,reviewer,final_gate}`). Engine
  finalization enacts the checks whose authoritative placement is `executor`
  (the default finalization placement, configurable via
  `executor_finalization.verification_placement`, §25).
- A required check runs **once** at its authoritative placement. It is **not**
  re-executed at a later placement when its **digest set** matches
  (§14.2); the later placement reads the existing `27-verification-summary.json`
  / per-check `result.json` and marks the result `reused: true`.
- A later placement re-executes **only** when (a) the digest set is stale, or
  (b) an explicit retry policy permits/requires another attempt.

### 14.2 Digest set

A check result is reusable iff all match the recorded values:

- `sha256(verification/effective-config.json)` (spec 0026 effective policy);
- the diff digest `sha256(06-git-diff.patch)` (the tree the check ran against);
- the requested/effective level for the check.

### 14.3 Reviewer independence knob

The Reviewer's independent verification (spec 0019 "tests are the source of
truth") is reconciled with de-duplication via a new policy
`verification.reviewer_independence`:

- `reuse_when_fresh` (**default**) — the Reviewer reuses a fresh matching
  result instead of re-executing, avoiding a duplicate full suite;
- `always_rerun` — the Reviewer always re-executes required checks (the strict
  pre-0029 independence behaviour), for operators who want it.

The default eliminates the common duplicate full-suite run while leaving strict
independence available. The trade-off is documented in
`docs/verification-and-timeline.md`.

## 15. UI runtime verification in finalization

Completion validation must consume **all** required verification subsystems,
including spec 0028 UI runtime verification.

### 15.1 Engine-owned UI verification phase

When UI-impact is detected (spec 0028 §12) and `verification.ui.enabled` is
`true` or `auto`, `executor_verification` also runs (or, per §14, reuses a fresh
result of) the required UI verification via the existing engine-invoked
Playwright/fake runner, as a **supervised child** (§22). It records
`29-ui-verification/summary.json` and per-scenario results.

### 15.2 The submission gate

The task **cannot submit** while required UI verification is **pending, failed,
blocked, or incomplete** (missing `29-ui-verification/summary.json`, overall not
`PASS`, incomplete required-scenario coverage, or a required scenario `FAIL`/
`BLOCKED`). `executor_completion_validation` fails with `VERIFICATION_FAILED`
(FAIL), `VERIFICATION_BLOCKED` (BLOCKED / prerequisites), or
`COMPLETION_CONTRACT_FAILED` (missing/incomplete evidence), and
`30-executor-finalization.json.phases.executor_verification.ui_status` records
the UI outcome.

### 15.3 Relationship to the existing accept-gate

This is additive: the existing spec 0028 `transitions.sh::accept` UI gate (at
reviewer accept) is unchanged. Adding the check at **executor completion
validation** catches the failure **before review**, not only at accept. Both
gates remain in force.

## 16. Engine-owned `07-tests.txt`

Generated during `executor_verification` from `27-verification-summary.json`
(and `29-ui-verification/summary.json` when applicable) and the per-check
`result.json` / `command.json` files.

### 16.1 Per-check content

Exact command/check identity (`<service>.<check>`); service and `cwd`; start/end
timestamps and duration; exit code; status (`PASS`/`FAIL`/`BLOCKED`/`SKIPPED`,
mapped from spec 0026 terminal statuses); why the check was selected (level,
matched risk rule, dependency, from `26-verification-plan.json`); whether the
result came from **this run** or an explicitly-valid **reused** result (§14);
links/paths to detailed logs.

### 16.2 No fabricated pass

The file MUST NOT claim "full suite passed" unless the engine observed the full
suite complete successfully (overall `PASSED` at `full`). When engine-owned
verification was `NOT_REQUIRED`, it says so plainly.

### 16.3 Pre-existing-failure classification is evidence-only

Automatic **base-commit checkout-and-execute** for classifying a failure as
pre-existing is **removed from required scope** (it needs a mutating checkout /
isolated workspace, out of scope until Phase 8). Classification as
"pre-existing" may be made **only** from existing deterministic evidence:

- a prior task's recorded result for the **same check identity and the same
  `base_commit`** already present in the runtime, or
- a configured known-failures list.

Otherwise the failure is reported honestly as `FAIL` **without** a pre-existing
classification — never assumed, never derived by silently running against base.
If an isolated workspace already exists (future capability), classification via
base-commit execution MAY be performed there, but this spec does not require or
create one.

## 17. Executor summary finalization (sandboxed)

`08-executor-summary.md` remains an explanatory, AI-authored artifact; its
lifecycle is hardened. **Preferred design (adopted):**

1. The initial Executor writes `08-executor-summary.md` before its provider
   process exits (prompt contract, §20).
2. During `executor_summary_finalization`, the engine validates the summary:
   non-empty **and** structurally valid (required feature sections; for spec
   0023 bundle tasks, the `## Input Coverage` section).
3. If missing or structurally invalid, the engine invokes the **sandboxed**
   executor-finalizer (§17.1).
4. If the finalizer's validated candidate passes, the engine adopts it (§17.2);
   otherwise the phase fails with `FINALIZATION_FAILED` and the round stays
   recoverable.

### 17.1 The sandbox

The finalizer never runs in the repository working tree. The engine:

- creates an **isolated temporary directory** (under the session scratch dir,
  outside the repo) as the finalizer's working directory;
- populates it with **read-only copies** of the evidence the finalizer may read
  (`03-executor-log.md`, `07-tests.txt`, `04/05/06`,
  `27-verification-summary.json`, `29-ui-verification/summary.json` when
  present, and `02-executor-prompt.md`);
- provides a designated output path inside the sandbox
  (`candidate-08-executor-summary.md` and/or a structured `result.json`).

A new provider entrypoint `executor_finalize_summary` (dispatched in
`providers/provider.sh`, arms for `fake` and `claude`) runs there:

- with its **cwd = the sandbox** (it cannot see repo source — the repo is not
  its working directory and no repo paths are handed to it);
- the `claude` arm runs **without** `--dangerously-skip-permissions`;
- it returns a **candidate summary or structured output** only.

### 17.2 Engine-only adoption

Only the deterministic engine copies the validated candidate to
`08-executor-summary.md` in the task directory, after checking: non-empty;
structurally valid; secret-redacted (§31); and path/symlink-safe (§31). The AI
process never writes the real artifact.

### 17.3 Post-call diff check (defence in depth)

Even though the sandbox already prevents repo writes, the engine still verifies
that **no repository or task path changed** during the finalizer call, relative
to a pre-call snapshot. Any change → the finalizer result is rejected, the
offending change reverted where engine-owned (or the round blocked with
`FINALIZATION_FAILED` naming the exact paths), and the summary not adopted.
This makes "the finalizer tried to edit source" deterministically detectable
(§32 test I).

### 17.4 Engine-generated vs AI-authored sections

The narrative and feature-specific sections and `## Input Coverage` stay
AI-authored (finalizer). The engine may append a single deterministic
`## Engine-Observed Verification` appendix summarising verification results,
labelled as engine-observed. The engine never fabricates an Input Coverage
section — a missing one is a completion-gate failure, not an engine invention.

## 18. Durable finalization record: `30-executor-finalization.json`

Schema_version 1, written atomically, updated as phases progress:

```json
{
  "schema_version": 1,
  "pipeline_version": 1,
  "task_id": "0029-…",
  "iteration": 1,
  "mode": "enabled",
  "provider_execution": { "iteration": 1, "invocation_id": "3",
                          "prompt_digest": "sha256:…", "exit_code": 0,
                          "completed_at": "…Z", "process_group_terminated": false },
  "phases": {
    "executor_provider_execution":    { "result": "passed" },
    "executor_evidence_capture":      { "result": "passed", "log_source": "engine-generated" },
    "executor_verification":          { "result": "passed", "overall_status": "PASSED",
                                        "ui_status": "PASS", "reused": false,
                                        "authoritative_placement": "executor",
                                        "diff_digest": "sha256:…",
                                        "effective_config_digest": "sha256:…" },
    "executor_summary_finalization":  { "result": "passed", "source": "executor|finalizer" },
    "executor_completion_validation": { "result": "passed", "reason": null },
    "submission_to_review":           { "result": "passed" }
  },
  "outcome": "READY_FOR_REVIEW",
  "background": { "pending_required_jobs": 0, "surviving_children_terminated": 0,
                  "text_wait_warning": false, "supervision": "process-group" },
  "provenance": { "log": "engine-generated", "tests": "engine-generated",
                  "summary": "finalizer" },
  "updated_at": "…Z"
}
```

`outcome` is one of the §24 closed vocabulary. `mode` is `enabled` or
`degraded-legacy` (§26). Historical tasks without this file report finalization
"not recorded" (never fabricated).

## 19. No-background-wait completion rule

A provider MUST NOT be accepted as complete when any provider-started or
engine-started required verification job is still active. **Process ownership
and durable verification state are authoritative; text heuristics may only add
warnings.**

### 19.1 Authoritative signals

1. **Engine-owned verification is synchronous** (§22). Because the engine
   `wait`s for the supervised child, a required engine-started job can never be
   "still running" at completion validation; if any required check in
   `27-verification-summary.json` / `29-ui-verification/summary.json` lacks a
   terminal status, `executor_completion_validation` fails with
   `VERIFICATION_BLOCKED`.
2. **Provider-spawned surviving children.** The provider runs as a process-group
   leader (§22). After it returns, the engine inspects that group for
   survivors, terminates them (TERM → grace → KILL), and records the count. A
   survivor that was a required verification job the provider illicitly
   backgrounded fails the round with `PROVIDER_EXITED_WITH_PENDING_WORK`.
3. **Durable verification state** unresolved at completion validation → refuse.

### 19.2 Text heuristics are advisory only

`agent_efficiency::detect_unresolved_wait` records a
`background.text_wait_warning` and a `completion_gate` note and MAY strengthen
detection, but is **never** the sole source of truth. The case where the AI
*says* it is waiting but no job is actually active (§32 test D) records the
warning yet does not block, because process and durable state show nothing
pending.

## 20. Provider contract changes

`templates/prompts/executor-ownership-contract.md` gains an additive,
provider-neutral section telling the Executor:

- **Do not launch required full verification in the background.** Final required
  verification is engine-owned and runs after you return.
- **Do not rely on future notifications after your process exits.**
- **Implementation (focused) checks may be run during your work** but do not
  replace engine-owned final verification.
- **Write `08-executor-summary.md` (and, when you can, `03-executor-log.md` and
  a truthful `07-tests.txt` note) before you return.** The engine generates or
  repairs any missing ones.
- **Never claim tests passed without engine evidence.**

Additive, provider-neutral (no CLI named); every adapter inherits it.

## 21. Execution-owner lease

Auto-recovery must never rely only on PID existence. The engine records a
durable **execution-owner lease** at the existing lock path
(`.specrelay-runs/tasks/.specrelay-locks/<task-id>.lock/owner`), extending the
current `pid`/`host`/`acquired_at` file into JSON (schema_version 1):

```json
{
  "schema_version": 1,
  "hostname": "…",
  "pid": 12345,
  "pid_start_time": "…",          // process start time — defeats PID reuse
  "invocation_id": "3",
  "owner_token": "<128-bit random hex>",
  "provider_pgid": 12346,         // set once the provider group leader is known
  "heartbeat_at": "…Z",
  "heartbeat_interval_seconds": 15,
  "acquired_at": "…Z"
}
```

### 21.1 Heartbeat

While the engine owns the task it refreshes `heartbeat_at` at
`heartbeat_interval_seconds` (a lightweight in-engine heartbeat writer). The
`owner_token` lets a process prove it still holds the lease before any state
mutation (guarding against a stale process stomping a lease another process
reacquired).

### 21.2 Stale-owner classification (extends operator-recovery liveness)

| Classification | Condition | Auto-recovery |
|----------------|-----------|---------------|
| `live` | same host, pid alive **and** `pid_start_time` matches **and** heartbeat within `3×interval` | refuse |
| `stale-dead-pid` | same host, pid not alive **or** `pid_start_time` mismatch (PID reused) | **allowed** |
| `suspect-hung` | same host, pid alive, `pid_start_time` matches, but heartbeat older than `3×interval` | refuse; explicit human decision (process may be hung) |
| `foreign-host` | different hostname | refuse (conservatively live) |
| `absent` | no lease | **allowed** |

Auto-recovery (§23.3) may proceed **only** for `stale-dead-pid` and `absent`.
`pid_start_time` defeats PID reuse; the heartbeat defeats hung/zombie ambiguity.


### 21.3 Heartbeat failure semantics

The heartbeat is maintained by the engine's main ownership loop, not by an
unobserved detached helper whose death could create false liveness conclusions.
If a helper process is used for portability, the owner must supervise it and
record its terminal status.

Failure to refresh the heartbeat while the owner process remains alive does not
automatically prove the owner is hung. It produces `suspect-hung` and blocks
automatic recovery, exactly as §21.2 states. `task show` must report both the
last heartbeat age and whether the heartbeat writer itself is known failed.
Only an explicit operator decision may break a `suspect-hung` lease.

## 22. Portable process-group supervision

Do not assume an external GNU `setsid` binary exists (it is absent on macOS).
Supervision is implemented by a small helper `lib/specrelay/py/proc_supervisor.py`
(Python; a Ruby equivalent is acceptable) using OS process APIs directly:

- child starts a new session/process group via `os.setsid()`;
- the parent records the child's `pgid` (into the lease, §21) and `wait`s;
- timeout / cancellation terminates the whole group via `os.killpg(pgid, SIGTERM)`
  → bounded grace → `os.killpg(pgid, SIGKILL)`;
- process start time for the lease is read portably (`/proc/<pid>/stat` on
  Linux; `ps -o lstart= -p <pid>` on macOS), with no third-party dependency.

`providers/provider.sh` (`run_streamed` / `run_agent_events`) route the provider
child, and `verification_runner.sh` routes verification/UI children, through the
helper. The existing FIFO transport and exit-code guarantees are preserved (the
group leader's status remains the authoritative exit code).

### 22.1 Honest fallback

If the OS primitives or `python3` are unavailable, the engine falls back to the
current foreground synchronous `wait`, records
`background.supervision = "degraded-foreground"`, and reports provider-spawned
survivors as `not_verifiable` (never fabricating "clean"). **Required
verification still runs synchronously** in this mode (the engine still waits),
so the completion guarantee holds; only provider-spawned-orphan detection
degrades. This fallback does **not** enable degraded-legacy mode (§26) — it is
an honest capability report, not a bypass.


### 22.2 Supported platforms

The required process-supervision contract is supported on:

- macOS;
- Linux.

Windows is not a supported execution platform for spec 0029. `doctor` must
report it as unsupported rather than attempting partial POSIX process-group
semantics. Adding Windows support requires a separate design using Windows Job
Objects (or an equivalent group-lifecycle primitive) and corresponding tests;
it must not be approximated with single-PID termination.

## 23. Safe interrupted-round recovery

The recovery gap (§5.2) is fixed by recording proven task-owned changes
**before** the completion gate, by teaching recovery to adopt only proven paths,
and by covering interruption **before** evidence capture.

### 23.1 Enriched pre-provider snapshot

Immediately before provider launch, the engine writes
`.git-pre-provider-snapshot.json` for this invocation, recording:

- HEAD commit id;
- index state digest;
- guard-relevant already-dirty paths **with per-path content digests**;
- untracked-file digests.

This is the durable "before" fact the recovery logic diffs against.

### 23.2 Proven round-change ledger and API compatibility

- During `executor_evidence_capture` (after the diff is captured, **regardless
  of whether later phases pass**), the engine appends an audited, append-only
  record to `32-round-change-ledger.jsonl`: invocation id, timestamp, the paths
  proven changed by this round (from `05-changed-files.txt` + untracked
  additions), and `sha256(06-git-diff.patch)`.
- **API compatibility (do not silently redefine `snapshot_owned`).** New
  ledger-specific `git_guard` APIs are introduced:
  `git_guard::record_round_change`, `git_guard::derive_owned_from_ledger`
  (recomputes `.git-owned-snapshot.txt` as the baseline-excluded union of ledger
  paths), and `git_guard::reconstruct_round_change_from_snapshot` (§23.4). The
  existing `git_guard::snapshot_owned` keeps its current whole-tree semantics as
  a **compatibility wrapper** for existing callers/tests; the workflow now calls
  the ledger APIs. Which API is authoritative for the owned snapshot (the
  ledger) is documented in `git_guard.sh` and `docs/task-lifecycle.md`.
- The owned snapshot is thus derived **before** the completion gate, so a
  gate-failed or interrupted round's legitimate diff is already task-owned.

### 23.3 Recovery adoption rules

`transitions::recover` and automatic in-loop recovery adopt ownership from the
ledger/snapshot, never the raw dirty tree:

- recovery **never blindly trusts the current dirty tree**;
- only paths with durable proof (ledger, or reconstructed via §23.4) become
  recoverable task-owned changes;
- unrelated external changes (in the tree but not in `baseline ∪ proven-owned`)
  still **block**, listing the exact paths (§32 test N);
- ambiguous ownership (§23.4) **blocks and requires an explicit human decision**
  (§32 test O): commit/stash the unrelated change, or re-run with an audited
  `--adopt-unproven <path>…` acknowledgement, guarded by
  `executor_finalization.recovery.require_operator_confirmation_for_unproven_diff`
  (default `true`);
- **no manual editing of internal guard files** is ever required;
- the recovery action and its evidence are append-only and auditable
  (`recovered_*` state fields + a ledger entry).

### 23.4 Interruption before `executor_evidence_capture`

If the provider changed files but the round crashed **before** `05/06/32` were
written, the engine reconstructs the round's proven-owned set by diffing the
current tree against `.git-pre-provider-snapshot.json` (§23.1):

- a guard-relevant path whose **current content digest differs** from the
  pre-provider digest, or a **newly untracked** file whose digest was not present
  before, is attributable to the interval containing the provider run and is
  adopted as owned; a synthetic ledger entry is appended, marked
  `source: "reconstructed-from-pre-provider-snapshot"`;
- **ambiguity refusal:** if HEAD moved, the index changed unexpectedly, or a
  changed path cannot be attributed (e.g. it was already dirty with a *different*
  prior digest that also changed, suggesting a concurrent external edit),
  recovery **refuses to auto-adopt** and requires an explicit human decision
  (§23.3). The engine never guesses ownership across the crash window.

### 23.5 Operator experience (replaces "without recovery-specific workflow logic")

The intended requirement: **the operator must not need separate recovery
commands, manual state transitions, manual artifact reconstruction, or a
separate recovery workflow.** Internal deterministic recovery logic remains
necessary and is expected.

Concretely, `specrelay resume` / `workflow::drive` handle an `EXECUTOR_RUNNING`
task whose lease is `stale-dead-pid` or `absent` (§21.2) by performing the
deterministic recovery **automatically, in-loop**:

1. classify the lease; proceed only for `stale-dead-pid`/`absent` (otherwise
   stop with an explicit human-decision message — still just `resume`, no
   separate command);
2. adopt the proven owned diff from the ledger / reconstruction (§23.2–23.4);
3. perform the audited `EXECUTOR_RUNNING -> READY_FOR_EXECUTOR` recovery
   (`recovered_by: specrelay-resume`);
4. re-enter the finalization pipeline as a **finalization-only resume** (§11)
   when a terminal provider result exists, or an implementation rerun when §11.2
   applies.

The same `resume` then carries the round forward through verification, summary
finalization, the completion gate, submission, review, `CHANGES_REQUESTED`,
requeue, rework, and rework verification — using the existing loop, with no
manual transitions, hand-written artifacts, or bespoke recovery workflow. The
`specrelay task recover` command remains available for deliberate manual
operator use, but is **not required** for normal interruption recovery.

## 24. Failure and state model

Outcomes are a closed **`finalization_outcome`** vocabulary recorded in
`30-executor-finalization.json` and surfaced by `task show`/`report` — **not**
new canonical lifecycle states. Failures leave `state.json` at `EXECUTOR_RUNNING`
(recoverable); success reaches `READY_FOR_REVIEW`.

| `finalization_outcome` | Meaning | State after | Exit code |
|------------------------|---------|-------------|-----------|
| `PROVIDER_FAILED` | provider returned non-zero | `EXECUTOR_RUNNING` | 4 |
| `PROVIDER_EXITED_WITH_PENDING_WORK` | provider exited leaving a required verification child alive | `EXECUTOR_RUNNING` | 4 |
| `VERIFICATION_FAILED` | required check (incl. UI) FAILED / TIMED_OUT | `EXECUTOR_RUNNING` | 4 |
| `VERIFICATION_BLOCKED` | required check (incl. UI) BLOCKED / prerequisites unmet | `EXECUTOR_RUNNING` | 4 |
| `FINALIZATION_FAILED` | summary finalizer failed or was rejected | `EXECUTOR_RUNNING` | 4 |
| `COMPLETION_CONTRACT_FAILED` | completion gate failed (missing/invalid artifact, unresolved-wait, incomplete UI evidence) | `EXECUTOR_RUNNING` | 4 |
| `FINALIZATION_RECORD_CONFLICT` | authoritative records disagree or pipeline version is unsupported | `EXECUTOR_RUNNING` | 4 |
| `READY_FOR_REVIEW` | all phases passed; submitted | `READY_FOR_REVIEW` | 0 (loop continues) |

A combination of phase results + stop reasons; the minimum needed to make
failures observable and recoverable without expanding the state machine.

## 25. Configuration

Minimal; no arbitrary knobs. New tree under `executor_finalization`:

```yaml
executor_finalization:
  mode: enabled                 # enabled | degraded-legacy  (§26)
  verification_placement: executor   # which spec 0026 placement finalization enacts
  finalizer:
    provider: ""                # "" inherits roles.executor.provider
    model: provider-default
    agent: none
    timeout_seconds: 300
  supervision:
    heartbeat_interval_seconds: 15
    child_terminate_grace_seconds: 10
  recovery:
    require_operator_confirmation_for_unproven_diff: true
```

Plus one addition to the existing spec 0026 tree:

```yaml
verification:
  reviewer_independence: reuse_when_fresh   # reuse_when_fresh | always_rerun  (§14.3)
```

- Defaults are **safe and backward-compatible**.
- Local developer overrides (spec 0027) apply through the effective-configuration
  mechanism (`config.local.yml` deep-merge; precedence
  `defaults < shared < local < env < cli`).
- Captured **once** into `state.json` as `executor_finalization_effective`
  (mirroring the other capture-once blocks), authoritative on resume; a later
  change prints the standard drift note (spec 0027).

## 26. Rollback and degraded-legacy mode

Disabling engine-owned finalization is an **explicit, visible degraded mode**,
never a silent bypass.

- `executor_finalization.mode: degraded-legacy` disables engine-owned
  verification/finalization (restoring pre-0029 executor behaviour where the
  completion gate relies only on Executor-written evidence).
- It is **visibly reported**: `doctor` prints
  `Executor finalization: DEGRADED (degraded-legacy mode)`; each task created
  under it records `executor_finalization_effective.mode: "degraded-legacy"` and
  `30-executor-finalization.json.mode`, and `task show` / the final result card
  show a DEGRADED banner.
- **It must not silently permit required UI or verification tasks to bypass
  deterministic finalization.** If a task has any **required** multi-service
  check selected (spec 0026) or **required** UI verification (spec 0028
  UI-impact detected + required), degraded-legacy mode is **refused for that
  task**: the engine blocks with an explicit message (
  `refusing degraded-legacy finalization: task has required verification/UI that
  must be engine-finalized`) rather than allowing an un-finalized submission.
- Degraded-legacy is therefore only usable for tasks with no required
  engine-owned verification. It is intended for emergency rollback, not routine
  use.
- The `§22.1` foreground-supervision fallback is distinct from degraded-legacy:
  it is an honest capability report and does not disable finalization.

## 27. Resume behaviour

Resume reuses completed deterministic phases **only when their input digests
still match**; stale results rerun. No mutable live config silently replaces
captured effective config. The provider is rerun only per §11.2.

| Phase | Reuse condition | Otherwise |
|-------|-----------------|-----------|
| `executor_provider_execution` | reused (finalization-only resume) when a durable terminal result matches the current prompt digest with `exit_code == 0` (§11) | rerun per §11.2 |
| `executor_evidence_capture` | reuse `04/05/06` + ledger if the working tree is unchanged since capture; reconstruct via §23.4 if capture never ran | recapture |
| `executor_verification` | reuse `27`/`29` results iff `effective-config` digest, diff digest, and level match (§14.2), and `reviewer_independence`/retry policy does not force a rerun | rerun (supervised child) |
| `executor_summary_finalization` | reuse `08` if present, structurally valid, and diff digest matches | re-finalize (sandbox) |
| `executor_completion_validation` | always recomputed (cheap, deterministic) | — |
| `submission_to_review` | idempotent — no-op if already `READY_FOR_REVIEW` | mint token + submit |

The verification reuse digests are stored in
`30-executor-finalization.json.phases.executor_verification` and cross-checked
against `verification/effective-config.json` (reusing the spec 0026
configuration-drift guard, operator-recovery §6a).

## 28. Artifact-layout compatibility

Compatible with the current flat numbered layout; no `00-task/…06-telemetry/`
migration.

### 28.1 New artifacts (collision-checked)

Highest currently-allocated number is `29` (`29-ui-verification/`). New numbers
start at `30`:

- `30-executor-finalization.json` — the durable finalization record (§18).
- `31-executor-finalizer/` — sandbox invocation evidence (`input.json`,
  `prompt.md`, `raw-output.txt`, `result.json`) plus
  `31-executor-finalizer-stdout.txt` / `-stderr.txt`.
- `32-round-change-ledger.jsonl` — append-only proven round-change records
  (§23.2).
- Guard helpers (dot-prefixed, unnumbered, alongside existing
  `.git-baseline.txt` / `.git-owned-snapshot.txt`):
  `.git-pre-provider-snapshot.json` (§23.1).

`03`/`07`/`08` keep their existing names/numbers; the engine now generates or
repairs them. Number collisions verified free against `18`, dual `20`/`21`,
`23`/`24`, `25`, `26–28`, `29`.

### 28.2 Requirements

Document all new artifacts; preserve historical readability (older tasks simply
lack them and report finalization "not recorded"); do not begin the full
artifact-layout migration.

## 29. Operator visibility

`task show`, `task report`, `timeline`, and the final result card must separate
provider success from executor completion and show each phase:

```text
Provider execution:      complete   (exit 0)
Verification:            passed     (multi-service PASSED · UI PASS)
Evidence capture:        complete
Summary finalization:    complete   (source: executor | finalizer)
Completion gate:         passed     (or failed: <reason>)
Finalization outcome:    READY_FOR_REVIEW
Mode:                    enabled    (or DEGRADED)
Stop reason:             —          (or e.g. VERIFICATION_FAILED)
Safe next command:       —          (or `specrelay resume <task>`)
```

The misleading "Executor passed" while the gate says "required artifact missing"
is corrected: the card title separates **"Provider exited successfully"** from
**"Executor completed successfully"**, and the SUCCESS card prints only when
`finalization_outcome == READY_FOR_REVIEW`. The card is driven by
`30-executor-finalization.json`, so it can never contradict the completion gate.

## 30. Coordinator integration

- The coordinator **input snapshot** gains the `30-executor-finalization.json`
  facts (phase results, `finalization_outcome`, multi-service + UI verification
  status, background survivor count, mode).
- The engine-computed **allowed-next-actions** set forbids an enacted
  `SEND_TO_REVIEW` while required verification (multi-service or UI) is
  pending/failed/blocked, required finalization artifacts are absent, or
  completion validation failed.
- `REPAIR_ARTIFACTS` may recommend the sandboxed finalizer action, which the
  **engine** performs; the coordinator never edits artifacts itself.
- A new coordinator `reason_code` value `finalization_incomplete` is added
  (additive to the closed vocabulary in `coordinator_lib.py`); no decision verbs
  change.

## 31. Security

- **Command injection.** Only `verification_runner.sh` shells project-configured
  `command:` strings (spec 0026 rule); the finalizer runs no arbitrary commands
  and no AI-supplied text is ever executed.
- **Child-process ownership & termination.** Provider and verification/UI
  children run as process-group leaders via the portable helper (§22); the
  engine terminates only groups it started (`SIGTERM` → grace → `SIGKILL`),
  never unrelated system processes.
- **Finalizer isolation.** The finalizer runs in an isolated temp dir with
  read-only evidence and no repo cwd (§17.1); engine-only adoption (§17.2) plus
  the post-call diff check (§17.3) are layered defences.
- **Lease integrity.** The `owner_token` and `pid_start_time` prevent PID-reuse
  and stale-process stomping; auto-recovery refuses `live`/`suspect-hung`/
  `foreign-host` leases (§21.2).
- **Symlink / path traversal.** All generated artifacts (`03`, `07`, `08`, `30`,
  `31/*`, `32`) are written strictly within the task directory; the engine
  refuses to follow a symlink at a target path and validates canonical paths.
- **Secret redaction.** Generated `03`/`07`/`08`, the finalizer sandbox input,
  and logged evidence pass through the existing secret-shaped redaction marker
  set (`TOKEN`/`API_KEY`/`SECRET`/`PASSWORD`/`COOKIE`/`AUTHORIZATION`/
  `CREDENTIAL`/…). Raw secret-bearing environment variables are never logged.
- **No persisted authorization tokens.** The submission token stays single-use,
  minted only after the provider exited, destroyed on use; the finalizer never
  receives or mints one.
- **No base-commit checkout.** Pre-existing-failure classification never mutates
  the working tree (§16.3).
- **Malicious provider output.** AI text is quoted only in the labelled
  "Reported by the AI (unverified)" zone (§12.2), never as engine fact.

## 32. Required tests

Deterministic, fake-provider-driven, in new files
`test/executor_finalization_test.sh`, `test/executor_recovery_test.sh`, and
`test/executor_resume_matrix_test.sh`, plus additive cases in existing suites.
New `fake` executor/finalizer scenarios back each case.

### 32.1 Artifact / behaviour tests

| # | Scenario | Expected |
|---|----------|----------|
| A | Provider exits 0 without `03-executor-log.md` | engine generates an honest log with provenance zones |
| B | Provider exits 0 without `07-tests.txt` | engine runs/reads actual verification and generates it |
| C | Provider exits with a required background verification child alive | no submit; child terminated by group; `PROVIDER_EXITED_WITH_PENDING_WORK` |
| D | Provider says "waiting for background notification" but no active job | warning recorded; process/durable facts authoritative → not blocked |
| E | Required engine-owned verification passes | proceeds to summary finalization |
| F | Required verification fails | no submit; `VERIFICATION_FAILED` |
| G | Required verification BLOCKED | no submit; `VERIFICATION_BLOCKED`; prerequisites reported |
| H | Summary missing | sandboxed finalizer runs and produces a candidate; engine adopts only the summary |
| I | Finalizer tries to edit source | sandbox prevents it; post-call diff check rejects any repo change |
| J | Finalizer fails | recoverable with explicit `FINALIZATION_FAILED` |
| K | Provider exit 0 with all phases complete | `READY_FOR_REVIEW` |
| L | Provider exit 0 but completion artifact invalid | no submit; `COMPLETION_CONTRACT_FAILED` |
| M | Recovery after incomplete round with proven diff ownership | recovers without manual guard-file editing |
| N | Recovery with unrelated external dirty paths | blocks, listing unrelated paths |
| O | Recovery ownership ambiguous | requires explicit human decision / blocks |
| P | Resume reuses verification only when digests match | `reused: true` |
| Q | Stale verification evidence (diff or effective-config digest changed) | reruns |
| R | `task show`/`report` distinguish provider success from executor completion | separate lines; no false "Executor passed" |
| S | Existing fake-provider workflows | remain compatible |
| T | Existing tasks without new artifacts | readable; finalization "not recorded" |
| U | Completion Gate not weakened | all pre-0029 refusals still refuse |
| V | Full standalone test suite | runs **once** at its authoritative placement; recorded honestly |
| X | UI-impact task with UI PASS | proceeds; `ui_status: PASS` |
| Y | UI-impact task with required UI FAIL / BLOCKED / pending | no submit; `VERIFICATION_FAILED`/`VERIFICATION_BLOCKED` |
| Z | Authoritative-placement de-dup | a required full suite does not execute a second time at the Reviewer/final gate when digests match (`reviewer_independence: reuse_when_fresh`); `always_rerun` re-executes |
| AA | Pre-existing-failure classification | classified only from existing evidence; otherwise reported `FAIL` without classification; no base-commit checkout occurs |
| AB | Lease PID reuse | a reused PID with mismatched `pid_start_time` classifies `stale-dead-pid` (recoverable), not `live` |
| AC | Lease hung process | pid alive + expired heartbeat classifies `suspect-hung` → refuse auto-recovery |
| AD | Foreign-host lease | classifies `foreign-host` → refuse auto-recovery |
| AE | Portable supervision fallback | with process-group primitives unavailable, verification still runs synchronously; survivors reported `not_verifiable`; not degraded-legacy |
| AF | Degraded-legacy with required verification/UI | refused for that task with an explicit message |
| AG | Degraded-legacy reported | doctor + `task show` + `30-…json` show DEGRADED |
| AH | Pipeline version compatibility | supported version resumes; unsupported version remains readable but fails closed with migration guidance |
| AI | Finalization source conflict | disagreement between `30`, lifecycle state, or verification summaries yields `FINALIZATION_RECORD_CONFLICT`; no silent precedence |
| AJ | Heartbeat writer failure | live owner + failed/stale heartbeat becomes `suspect-hung`; no auto-recovery |
| AK | Module-boundary enforcement | workflow remains lifecycle-only; direct rendering/lease parsing/process killing/ledger reconstruction in `workflow.sh` is rejected by maintainability test |

### 32.2 Interruption-boundary matrix

Each row: interrupt at the boundary, then run **only** `specrelay resume`.
Every safe case must continue to completion (or the correct next stop) with no
separate recovery command, manual transition, or artifact reconstruction.

| # | Interruption boundary | Expected resume behaviour |
|---|-----------------------|---------------------------|
| M1 | During provider execution (killed, no terminal result) | implementation **rerun** (§11.2 case 1) |
| M2 | Post-provider / pre-capture (exit 0, crash before `05/06/32`) | ownership reconstructed from pre-provider snapshot (§23.4); **provider not rerun**; finalization continues |
| M3 | During evidence capture | recapture; provider not rerun |
| M4 | During verification (supervised child killed) | provider + evidence reused; verification rerun (stale) or reused (fresh digests) |
| M5 | During `07-tests.txt` generation | regenerate `07` from existing verification summary |
| M6 | During summary finalizer | re-finalize in sandbox; provider not rerun |
| M7 | Pre-submit (all phases passed, crash before token/submit) | validate + submit (idempotent) |
| M8 | During Reviewer execution | continue reviewer (existing `REVIEWER_RUNNING` resume) |
| M9 | At `CHANGES_REQUESTED` | requeue → new iteration; implementation rerun with new prompt (§11.2 case 2) |
| M10 | During Executor rework (new iteration provider execution) | as M1 for that iteration |
| M11 | During rework verification | as M4 for that iteration |
| M12 | Interruption with a `suspect-hung`/`foreign-host` lease | resume stops with an explicit human-decision message (still no separate command) |

Fake finalizer fixtures: `finalizer_valid_repair`, `finalizer_edits_source`,
`finalizer_fails`, `finalizer_timeout`.

## 33. Documentation

Update: `README.md`; `docs/architecture.md` (finalization pipeline, supervised-
child model, lease); `docs/current-workflow-contract.md` (engine-owned
finalization closes the §13 dirty-tree/requeue limitation);
`docs/task-lifecycle.md` (phases, artifacts `30`/`31`/`32`, lease, ledger APIs +
`snapshot_owned` compatibility, natural resume); `docs/verification-and-timeline.md`
(engine-owned verification placement, authoritative-placement/reuse, UI
integration, new phases, `07` generation); `docs/operator-recovery.md` (natural
resume, lease classification, ambiguous-ownership decision, `finalization_outcome`,
provider-vs-executor success, degraded-legacy); `docs/providers.md`
(`executor_finalize_summary`, sandbox, portable process-group supervision);
`docs/commands.md` (`task show`/`report`/`resume` output, `--adopt-unproven`);
`docs/configuration.md` (new keys, degraded-legacy); the roadmap docs (§34);
`templates/prompts/executor-ownership-contract.md` (§20 section).

## 34. Roadmap placement

An **urgent reliability-hardening milestone**, sequenced **before** additional
autonomous routing (Phase 7) or further UI-verification expansion. The roadmap
must state: **UI verification and multi-service verification cannot be trusted
operationally while the executor can exit before their evidence is finalized.**
Spec 0029 is the concrete engine-executed realisation of "Bounded artifact
repair — a real, engine-executed `REPAIR_ARTIFACTS`" (Phase 5), extended with
supervised verification and safe interrupted-round recovery, and a prerequisite
for trusting the verification substrate later phases build on.

## 35. Completion gates

### 35.1 Required Executor summary sections

`08-executor-summary.md` must contain: `## Finalization Pipeline`,
`## Supervised Verification`, `## Evidence Provenance`,
`## Interrupted-Round Recovery`, `## Backward Compatibility`, `## Input
Coverage`.

### 35.2 Required Reviewer section

`09-consultant-review.md` must contain `## Executor Finalization Safety Review`
validating: no fabricated success; completion gate not weakened; supervised-
child termination is group-scoped only; recovery adopts only proven paths;
lease auto-recovery never trusts PID alone; the finalizer sandbox + adoption
model is sound; UI/multi-service verification is enforced at completion
validation; degraded-legacy cannot bypass required verification. An ACCEPT
without this section is invalid.

## 36. Acceptance criteria

- **AC-01** Provider exit code is never, alone, treated as executor completion;
  only `executor_completion_validation` passing yields `READY_FOR_REVIEW`.
- **AC-02** A durably-recorded provider terminal result (exit 0, matching prompt
  digest) is **not** rerun on resume; implementation reruns only per §11.2.
- **AC-03** `03-executor-log.md` and `07-tests.txt` are engine-generated from
  observed durable sources when missing, with explicit provenance, and never
  invent actions or results.
- **AC-04** Required verification runs in the engine as a supervised,
  synchronously-waited child with real exit codes, timeout, and group
  termination.
- **AC-05** `07-tests.txt` never claims "full suite passed" unless the engine
  observed it; pre-existing failures are classified only from existing evidence
  (no base-commit checkout).
- **AC-06** A required check runs once at its authoritative placement; later
  placements reuse a fresh matching result; strict independence is opt-in.
- **AC-07** Required UI verification (spec 0028) is enforced at completion
  validation; the task cannot submit while it is pending/failed/blocked/
  incomplete.
- **AC-08** A missing/invalid `08-executor-summary.md` is repaired by a
  **sandboxed** finalizer that runs outside the repo, returns a candidate, and
  whose result only the engine adopts; a finalizer touching anything else is
  deterministically rejected.
- **AC-09** A provider exiting with a required verification child alive does not
  submit; the child is group-terminated; stop reason
  `PROVIDER_EXITED_WITH_PENDING_WORK`.
- **AC-10** "I will wait for the background task" text alone never blocks and
  never passes; process and durable state are authoritative.
- **AC-11** The execution-owner lease records host, PID, PID start time,
  invocation id, owner token, heartbeat, and provider pgid; auto-recovery
  proceeds only for `stale-dead-pid`/`absent` and never on PID existence alone.
- **AC-12** Process-group supervision works on macOS and Linux without a GNU
  `setsid` binary; the honest foreground fallback still runs verification
  synchronously and reports survivors `not_verifiable`.
- **AC-13** An interrupted round with a proven diff (including a crash before
  evidence capture, reconstructed from the pre-provider snapshot) recovers
  without manual guard-file editing; unrelated/ambiguous changes block or
  require an explicit human decision.
- **AC-14** The operator needs **no separate recovery command, manual
  transition, manual artifact reconstruction, or separate recovery workflow**:
  `specrelay resume` alone carries a safe interrupted execution through
  implementation, verification, review, rework, and completion (§32.2 matrix).
- **AC-15** `git_guard::snapshot_owned` retains its existing semantics as a
  compatibility wrapper; the owned snapshot is authoritatively derived via the
  new ledger APIs.
- **AC-16** Resume reuses completed verification/summary only when
  input/config/diff digests match; stale results rerun.
- **AC-17** The Completion Gate is not weakened; every pre-0029 refusal still
  refuses.
- **AC-18** `task show`/`report`/final card separate "provider exited
  successfully" from "executor completed successfully" and never contradict the
  completion gate.
- **AC-19** The Coordinator never recommends an enacted `SEND_TO_REVIEW` while
  required verification/UI is pending/failed/blocked or finalization is
  incomplete, and never edits artifacts itself.
- **AC-20** Degraded-legacy mode is explicit, reported by doctor/task evidence,
  and refused for any task with required verification or UI verification;
  defaults are backward-compatible and historical tasks report "not recorded".
- **AC-21** `30-executor-finalization.json` is the authoritative source for
  finalization facts, while lifecycle and verification sources retain their
  explicitly-scoped authority; disagreement fails closed as
  `FINALIZATION_RECORD_CONFLICT`.
- **AC-22** The finalization record includes `pipeline_version`; resume never
  silently applies current phase semantics to an unsupported historical
  pipeline version.
- **AC-23** Heartbeat failure cannot cause unsafe automatic recovery: a live
  process with a stale or failed heartbeat is `suspect-hung` and requires an
  explicit operator decision.
- **AC-24** The implementation preserves subsystem boundaries: `workflow.sh`
  coordinates but does not implement artifact rendering, lease parsing,
  process-group termination, verification execution, or ledger reconstruction.

## 37. Expected implementation order

1. `30-executor-finalization.json` schema + writer; the §11.1 provider terminal
   result recording; new timeline phases.
2. Execution-owner lease (§21) + heartbeat, extending `lock.sh`; liveness
   classification.
3. Portable `py/proc_supervisor.py` (§22); route provider + verification/UI
   children through it; foreground fallback.
4. Engine-owned `03-executor-log.md` generation with provenance
   (`finalization.sh` / `py/finalization_lib.py`).
5. Round-change ledger + enriched pre-provider snapshot; new `git_guard` ledger
   APIs + `snapshot_owned` compatibility wrapper; pre-capture reconstruction
   (§23).
6. Engine-owned verification phase; authoritative-placement/reuse (§14); UI
   integration (§15); `07-tests.txt` generation with evidence-only pre-existing
   classification (§16).
7. Sandboxed `executor_finalize_summary` entrypoint (`fake` + `claude`) with
   engine-only adoption + post-call diff check (§17).
8. Rewire `workflow::executor_iteration` into the explicit phase pipeline;
   completion validation reads the finalization record + UI status; result card.
9. Natural resume: auto-recover a dead-owner `EXECUTOR_RUNNING` task in
   `drive`/`resume`; finalization-only-resume vs rerun (§11); phase-digest reuse.
10. `executor_finalization` config + `executor_finalization_effective`
    capture-once + drift note; degraded-legacy mode + guards (§26);
    `verification.reviewer_independence`.
11. Coordinator input + allowlist wiring; `finalization_incomplete` reason code.
12. Tests §32 (A–AK + M1–M12); fake fixtures.
13. Documentation (§33); roadmap (§34).

## 38. Deliverables

- **New:** `lib/specrelay/finalization.sh`, `lib/specrelay/py/finalization_lib.py`,
  `lib/specrelay/py/proc_supervisor.py`, `test/executor_finalization_test.sh`,
  `test/executor_recovery_test.sh`, `test/executor_resume_matrix_test.sh`.
- **Modified:** `lib/specrelay/workflow.sh` (phase pipeline, §11 rule, natural
  resume, config capture), `lib/specrelay/providers/provider.sh` (process-group
  supervision, `executor_finalize_summary` dispatch), `providers/fake.sh` and
  `providers/claude.sh` (finalizer arms + fixtures), `lib/specrelay/lock.sh`
  (lease + heartbeat + classification), `lib/specrelay/evidence.sh` and
  `lib/specrelay/git_guard.sh` (ledger APIs, pre-provider snapshot,
  reconstruction, owned-snapshot derivation, `snapshot_owned` wrapper),
  `lib/specrelay/transitions.sh` (recovery adoption), `lib/specrelay/verification_runner.sh`
  (supervised children, authoritative-placement reuse), `lib/specrelay/ui_verification.sh`
  (supervised UI child; completion-validation consumption), `lib/specrelay/cli.sh`
  (`task recover --adopt-unproven`, `task show`/`report` finalization card,
  resume auto-recovery), `lib/specrelay/coordinator.sh` and `py/coordinator_lib.py`
  (finalization facts + reason code), `lib/specrelay/config.sh` (new tree +
  degraded-legacy), `lib/specrelay/doctor.sh` (finalization + degraded-legacy
  report), `lib/specrelay/agent_efficiency.sh` (background check consumes real
  supervision facts).
- Templates/docs per §20 and §33.
- A deterministic architecture-boundary test/lint rule preventing lifecycle
  orchestration code from absorbing finalization rendering, lease internals,
  process supervision, or ledger reconstruction.

## 39. Release behavior

`impact: minor` (§2). Adds engine-owned finalization and supervised verification
without breaking existing configuration, tasks, or fake-provider workflows.
Releasing it (`CHANGELOG`/`VERSION` bump) is a separate, later operational
decision. This spec does not commit, push, tag, release, or modify `VERSION`.

## 40. Input coverage

Written after inspecting: `workflow.sh` (executor iteration, drive/resume,
capture-once), `providers/provider.sh`, `evidence.sh`, `verification_runner.sh`,
`verification_policy.sh`, `ui_verification.sh`, `git_guard.sh`, `transitions.sh`
(recover/requeue/submit), `marker_recovery.sh`, `agent_efficiency.sh`,
`lock.sh`/`cli.sh` recovery, `coordinator_lib.py`, `state_lib.py`,
`templates/prompts/executor-ownership-contract.md`, artifact numbering across
`lib/` and `docs/`, docs `current-workflow-contract.md`, `task-lifecycle.md`,
`verification-and-timeline.md`, `operator-recovery.md`, `providers.md`, the
roadmap, and prior specs 0019/0020/0021/0025/0026/0027/0028. The attached
recovery log's failure classes — missing executor artifacts, reconstructed
verification, reviewer-feedback processing, rework, and continuation after an
early provider exit — are each mapped to an engine-owned phase (§10–§23) and to
a test (§32), so the design eliminates the failure *class*, not only the
specific missing artifacts observed.

## 41. Final definition of done

All of §10–§31 implemented; tests §32 (A–AK and M1–M12) passing; documentation
and roadmap updated; defaults backward-compatible; the Completion Gate
unweakened; degraded-legacy explicit and guarded; and a safe interrupted
execution demonstrably resumes to completion through a single `specrelay resume`
with no separate recovery command, manual transition, or artifact
reconstruction.
