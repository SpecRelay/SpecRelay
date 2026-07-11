# SpecRelay Dogfood Report (SDD 0085)

## Status and an important, deliberate limitation

This report documents three dogfood scenarios run against the REAL, shipped
SDD 0085 shim/CLI code (an isolated copy of this repository's actual
`.ai/scripts/` and `tools/specrelay/` trees — not a description, an actual
execution), using SpecRelay's deterministic **`fake`** executor/reviewer
provider rather than the real `claude` provider.

**This is a known, deliberate gap, stated plainly rather than hidden** (per
this file's own "do not sanitize failures out of the report" requirement,
spec section 24): spec section 19 requires scenario A to use "a real
executor provider; a real reviewer provider; ... no fake provider," and
scenario B implies the same. Genuine real-provider dogfooding — actually
invoking the `claude` CLI non-interactively with `--dangerously-skip-permissions`
for both the executor and reviewer roles — was **not executed** in this run.

**Why:** running that command means spawning fully autonomous, unsupervised
coding-agent subprocesses with unrestricted shell/filesystem access against
this live repository, for at least two full round trips (scenario A) plus a
second executor+reviewer round (scenario B). Section 66 of the spec this
task implements exists **because a prior execution attempt of this exact
task already mutated the host repository** through exactly this class of
risk (an autonomous process losing track of its own scope). Given that
documented history, and given no human was watching this run interactively
in real time, proceeding to spawn multiple additional autonomous agents
against the live repository was judged to be a materially different and
higher-risk action than the rest of this task's file edits — one that
warrants an explicit, supervised human decision rather than silent
self-authorization.

**What this means for acceptance:** the "Dogfooding" acceptance-criteria
section of the spec is **only partially satisfied**. The lifecycle,
evidence-capture, rework-loop, and interruption-safety behavior of the real
shipped code is proven end-to-end below. What remains unproven is
specifically: real Claude Code executor output quality, real reviewer
isolation with a genuine independent LLM judgment call, and real provider
timing. See "Recommended next step" at the end of this report.

## Harness

All three scenarios ran in a single isolated temporary Git repository (never
this repository), created by copying the real `.ai/scripts/` and
`tools/specrelay/` trees verbatim, with a `.specrelay/config.yml` configuring
`roles.executor.provider: fake`, `roles.reviewer.provider: fake`,
`context.adapter: none`. This mirrors exactly how `tools/specrelay/test/
compat_shim_test.sh` and friends already validate the shims (see those files),
except run manually here for direct dogfood observation rather than as
assertions. The harness was deleted after evidence was extracted; the
extracted evidence lives at `tools/specrelay/test/fixtures/dogfood-0085/`
(per spec section 58, "controlled fixtures may live under
tools/specrelay/test/fixtures/ where appropriate").

Every fixture spec used is a one-paragraph, clearly-labeled throwaway
(e.g. "Append a line to CHANGELOG-FIXTURE.txt... this is not real product
work") — never committed to this repository's real `docs/sdd/` (spec
section 58: "do not clutter product roadmap with throwaway fake feature
specs").

## Scenario A — straightforward accepted task

- **Task:** `9001-dogfood-scenario-a`, spec: trivial one-line fixture spec.
- **Expected behavior:** DRAFT → (auto-approve) → READY_FOR_EXECUTOR →
  EXECUTOR_RUNNING → READY_FOR_REVIEW → READY_FOR_HUMAN_REVIEW in one round,
  through `specrelay run <spec>` alone.
- **Actual behavior:** Exactly that. Full run completed in 4.6 seconds
  (`time` measurement of the real invocation). Evidence files
  (`03-executor-log.md`, `07-tests.txt`, `08-executor-summary.md`,
  `09-consultant-review.md`, `10-business-summary.md`,
  `04/05/06-*` git evidence) were all written; `state.json` ends with
  `"state": "READY_FOR_HUMAN_REVIEW"`, `"review_result": "accepted"`,
  `"reviewer_provider": "fake"`.
- **Evidence:** `tools/specrelay/test/fixtures/dogfood-0085/scenario-a/`
  (state.json + 00/02/03/07/08/09/10).
- **Defects found:** none.

## Scenario B — reviewer requests changes, then accepts round 2

- **Task:** `9002-dogfood-scenario-b`, spec: trivial one-line fixture spec.
- **Round 1:** executor ran, submitted for review.
- **Reviewer feedback:** REQUEST_CHANGES ("Fake reviewer notes for round 1"),
  scripted via `SPECRELAY_FAKE_REVIEWER_PLAN` — a legitimate way to force a
  genuine `CHANGES_REQUESTED` transition deterministically, per spec section
  20's fallback allowance ("use a purpose-built... dogfood fixture... where
  the first executor round is intentionally constrained... to produce a
  reviewable deficiency").
- **Requeue:** automatic (`specrelay run`'s own loop), `iteration` incremented
  1 → 2, round 1's artifacts archived to `iterations/round-1/` (verified:
  `iterations/round-1/08-executor-summary.md` still reads "round 1";
  the live `08-executor-summary.md` reads "round 2" — round 1 evidence was
  never overwritten, only archived).
- **Round 2:** executor ran again; the fixture's own accumulated-change file
  (`specrelay-fake-impl.txt`) shows round 1's line still present plus a new
  round 2 line — proving round 2 continued from round 1's own legitimate,
  still-uncommitted changes rather than being blocked by them (spec section
  36's exact requirement).
- **Final acceptance:** reviewer plan's second line (`decision=accept`) →
  `READY_FOR_HUMAN_REVIEW`.
- **Evidence preservation:** confirmed above; also see
  `tools/specrelay/test/fixtures/dogfood-0085/scenario-b/state.json`
  (`"iteration": 2`, `"requeued_at"`, `"changes_requested_reason": "Fake
  reviewer notes for round 1."`) and `iterations-round-1/`.

## Scenario C — interruption then safe resume/recovery

- **Interruption:** `specrelay run` was started against task
  `9003-dogfood-scenario-c` with an artificially slowed fake executor
  (`SPECRELAY_FAKE_EXECUTOR_SLEEP=8`), then hard-killed (`kill -9`) 3 seconds
  in — while `state.json` read `"state": "EXECUTOR_RUNNING"` (captured and
  confirmed mid-run, before the kill).
- **Persisted state:** after the kill, `state.json` on disk was unchanged
  from `EXECUTOR_RUNNING` — no partial/corrupt write, no false
  `READY_FOR_REVIEW` submission. The task's lock directory
  (`.ai-runs/tasks/.specrelay-locks/9003-dogfood-scenario-c.lock`) was left
  behind (the killed process never reached its release step) — this is
  expected and is exactly what the stale-lock reclaim logic exists for.
- **Resume attempt:** `specrelay resume 9003-dogfood-scenario-c` correctly
  detected and reclaimed the stale lock (`"reclaiming stale lock ... owner
  pid ... is no longer running"`), then correctly **refused** to
  auto-continue from `EXECUTOR_RUNNING` ("has no safe automated step") —
  identical, intentional behavior to the legacy engine's own
  `run-ai-loop.sh` ("Refusing: task is EXECUTOR_RUNNING ... recover
  manually"). This is not a defect: a crashed executor round's on-disk
  changes cannot be safely assumed complete, so neither engine guesses.
- **Recovery:** `specrelay task block 9003-dogfood-scenario-c "<reason>"`
  transitioned `EXECUTOR_RUNNING → BLOCKED` with a recorded
  `blocked_reason`, giving a clean, auditable terminal-ish state for a human
  to inspect next — no state corruption at any point in the sequence.
- **Result:** task state was never corrupted; the lock was safely reclaimed;
  the recovery path (`task block`) is real, exercised, and evidenced.
- **Evidence:** `tools/specrelay/test/fixtures/dogfood-0085/scenario-c/`
  (state.json showing the final `BLOCKED` state with `blocked_reason`, plus
  the interrupted run's own stdout log).

## Reviewer isolation evidence

For all three scenarios, `workflow.sh`'s `reviewer_iteration` independently
re-ran the context-capability preflight and built the reviewer's prompt
**from disk** (`build_reviewer_prompt`, reading 00/02/03/07/08/05 fresh off
the task directory) rather than reusing any executor process/session state —
there is no shared process between the two roles even under the `fake`
provider (each role's `provider::*_run` is invoked as a separate function
call with no retained conversational state). This is the same isolation
mechanism a real `claude`/`claude-subagent` provider run would use (see
`providers/claude.sh`: the reviewer always starts a brand-new process, never
`--continue`/`--resume` of the executor's).

## Context capability behavior

The dogfood harness used `context.adapter: none` / `context.required: false`
deliberately (isolated fixture, no real Context Plus MCP server available in
a throwaway temp repo). `specrelay::context::none::preflight` ran for both
roles in all three scenarios ("context: adapter 'none' configured; no
preflight required") — this is the documented, honest behavior for that
adapter, not a silent skip of a requirement. The REAL repository's own
`.specrelay/config.yml` has `context.adapter: contextplus` /
`context.required: true`; this executor's own run of task 0085 itself (see
`03-executor-log.md`) is the evidence for the REAL Context Plus preflight
behavior, since Context Plus is only meaningfully available inside this
actual repository, not an ephemeral fixture clone.

## Event stream verification

The `fake` provider does not produce a structured JSONL event stream (that
is real-Claude-CLI-specific semantic live-event behavior — see
`docs/engine-parity.md`, "Known gaps"). No event-stream parity claim is made
for the fake-provider dogfood runs above; this is stated rather than
implied.

## Performance observations

| Scenario | Executor duration (per round) | Reviewer duration (per round) | Iterations | Total duration |
|---|---|---|---|---|
| A | < 1s (fake, no sleep) | < 1s (fake) | 1 | 4.6s (includes task creation, approval, two context preflights, evidence capture, state writes) |
| B | < 1s × 2 rounds | < 1s × 2 rounds | 2 | ~6s |
| C | interrupted at 3s (artificial 8s sleep injected) | n/a (never reached review) | 1 (blocked) | n/a (interrupted by design) |

These numbers reflect fake-provider overhead only (state I/O, locking,
evidence capture) — they are a baseline for the ENGINE's own overhead, not a
projection of real-provider timing (a real `claude` executor/reviewer round
takes minutes, not sub-second).

## Migration findings

- **Parity gaps:** none newly discovered in this dogfood pass beyond what
  `docs/engine-parity.md` already documents (event-stream capture, `codex`
  provider, desktop notifications are still SpecRelay gaps, unaffected by
  0085).
- **CLI friction:** `specrelay resume`'s refusal message for a crashed
  `EXECUTOR_RUNNING` task does not (yet) suggest `specrelay task block` by
  name the way the legacy `run-ai-loop.sh` explicitly names
  `authorize-finish.sh`/`block-task.sh`; this is a minor, non-blocking CLI
  wording improvement opportunity for a future task, not a defect (behavior
  is safe either way).
- **Compatibility issues:** none found against the real shims — see
  `tools/specrelay/test/compat_shim_test.sh`, `rollback_test.sh`,
  `engine_ownership_cases_test.sh`, `shim_loop_test.sh` for the exhaustive,
  automated version of this same evidence.
- **Performance observations:** see table above.
- **Unresolved risks:** genuine real-provider (Claude Code) dogfooding for
  scenarios A and B remains outstanding — see "Recommended next step."

## Recommended next step

A human (or an explicitly authorized follow-up prompt, run with direct
attention on this single step) should execute, in real time:

```
tools/specrelay/bin/specrelay run docs/sdd/<a-small-real-spec>/spec.md
```

against a small, genuinely useful, bounded real spec (not a throwaway
fixture), with `.specrelay/config.yml`'s real `roles.executor.provider:
claude` / `roles.reviewer.provider: claude-subagent`, while watching it run.
This closes the one remaining acceptance-criteria gap this report is
transparent about. Any resulting task reaching `READY_FOR_HUMAN_REVIEW`
still requires the normal human final review before any commit/merge (spec
sections 42-43, 59) — dogfooding this does not change that.
