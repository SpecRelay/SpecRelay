# Bounded Verification, Reviewer Policy v2, and Execution Timeline (spec 0019)

This is the design reference for spec 0019: bounded verification policy,
risk-based reviewer verification, the structured AI reviewer contract,
mandatory decision-marker guarantees, narrow decision-marker recovery,
execution-timeline instrumentation, the verification ledger, duplicate-work
reporting, phase budgets, and the final human-readable performance report.

The objective is to reduce execution time — repeated full-suite runs,
repeated focused tests, duplicate smoke/doctor checks, broad exploration, and
review repetition after only a missing marker — **without** weakening
correctness, independent review, evidence quality, or the final human
approval gate. Nothing here reduces CI's own full verification, removes
independent Reviewer judgment, or removes the human final-review gate.

## A. Bounded verification policy

### Verification levels

- **focused** — one or more directly relevant test files, e.g.
  `scripts/test test/contextplus_adapter_test.sh`.
- **targeted** — change-aware test selection, e.g.
  `scripts/test --changed --jobs auto --timings --explain`.
- **full** — the complete standalone suite, e.g.
  `scripts/test --jobs auto --timings`.
- **smoke** — packaging/installation validation, e.g. `scripts/smoke --skip-tests`.

Preferred Executor workflow: **implementation → targeted/change-aware
verification → final full suite once → `smoke --skip-tests`**. The Executor
must not run the full suite after every edit.

### Default policy (`.specrelay/config.yml`, `verification:`)

```yaml
verification:
  executor:
    full_suite_max_runs: 1
    smoke_max_runs: 1
    doctor_max_runs: 1
    version_max_runs: 1
  reviewer:
    default_mode: targeted
    focused_max_runs: 3
    targeted_max_runs: 1
    full_suite_max_runs: 0
    smoke_max_runs: 0
    doctor_max_runs: 1
    version_max_runs: 1
```

This is a **default policy, not an absolute ban** — additional runs are
allowed with a recorded reason. See `docs/configuration.md`,
`verification.*`, for the full field reference, validation rules, and how the
effective policy is captured durably per task
(`state.json.verification_policy_effective`) and displayed by
`specrelay doctor`.

### Soft limit, not hard refusal

Enforcement is **prompt-level policy plus engine-level observation/
reporting**, per spec 0019's "Soft Limit versus Hard Refusal": the
Executor/Reviewer prompts (`lib/specrelay/workflow.sh`'s
`seed_task_from_spec` and `build_reviewer_prompt`, and
`templates/claude/agents/ai-reviewer.md`) state the effective budget and
require a recorded `ADDITIONAL_VERIFICATION_REASON:` /
`FULL_SUITE_REASON:` for exceeding it. SpecRelay does not kill arbitrary
agent-issued commands to enforce this — it does not own those commands, and
claiming otherwise would be dishonest. What it **does** own is recording and
reporting what actually ran (the verification ledger below) and flagging
unjustified duplicates.

### Verification operation classification

`lib/specrelay/verification.sh`'s `specrelay::verification::classify`
recognizes, at minimum:

| Command shape | Classification |
|---|---|
| `scripts/test <explicit test files>` | `test_focused` |
| `scripts/test --changed` / `--changed-files` | `test_targeted` |
| `scripts/test` / `scripts/test --jobs ... --timings` | `test_full` |
| `scripts/smoke` / `scripts/smoke --skip-tests` | `smoke` |
| `bin/specrelay doctor` | `doctor` |
| `bin/specrelay version` | `version` |
| anything else | `agent_tool_execution_unclassified` |

Classification never guesses from vague command text — an unrecognized
command is always `agent_tool_execution_unclassified`, never fabricated.

### Coordinator-requested verification (spec 0025)

The optional AI Coordinator's `RUN_TARGETED_VERIFICATION` decision may
recommend verification **categories** — `test_focused`, `test_targeted`,
`test_full`, `smoke`, `doctor`, `version` — the exact same closed vocabulary
as the classification table above. The coordinator never specifies or runs
an actual command: `requested_verification` is validated as a list of
category names, and the deterministic engine alone selects and runs the real
allowlisted command from configured policy (spec 0025, section 11.3). A
coordinator recommendation naming an unrecognized category is rejected by
`coordinator_lib.py`'s structured validator before it can influence anything.
Coordinator invocation time (`coordinator_context_preflight`,
`coordinator_input_preparation`, `coordinator_provider_execution`,
`coordinator_decision_validation`, `coordinator_action_dispatch`) is recorded
independently of Executor/Reviewer phases — see
`specrelay task coordination <task-ref>` for the coordinator's own activity
summary (invocation counts, invalid decisions, human-decision requests), kept
separate from the execution timeline below.

## B. Reviewer Policy v2

The Reviewer is **not a second Executor**. It identifies defects, validates
acceptance criteria, inspects real code and evidence, tests high-risk
behavior independently, assesses residual risk, and rejects unsupported
claims — while avoiding unrelated implementation work, broad unjustified
exploration, and repeating every Executor command automatically.

### Risk classification

`low` / `medium` / `high` / `critical` — see
`templates/claude/agents/ai-reviewer.md` for the full table and expected
verification per level. Low risk (docs-only, narrow non-behavioral changes)
expects no full suite by default; high/critical risk (state machine,
orchestration, provider execution, Git guard, test runner, security/secret
handling, destructive operations) expects explicitly documented verification.

### Reviewer template structure

The template (and the plain, non-Claude-subagent reviewer prompt built by
`specrelay::workflow::build_reviewer_prompt` — the critical policy never
depends exclusively on the Claude sub-agent file being installed) requires
this sequence: read the spec and extract acceptance criteria → inspect the
real working tree and diff → inspect Executor evidence → classify risk →
select the minimum sufficient independent verification → record a reason for
anything beyond budget → evaluate every acceptance criterion → record
findings/residual risks → write artifacts → emit exactly one decision
marker.

### Severity contract

`BLOCKER` / `HIGH` → `REQUEST_CHANGES`; `MEDIUM` → judgment, explained;
`LOW` / `NOTE` → `ACCEPT`. Never reject solely for style preference.

### Stop condition

Stop once every acceptance criterion is assessed, sufficient independent
evidence exists, blocking findings (if any) are recorded, required artifacts
are written, and a decision is justified. Do not keep exploring past that
point.

## C. Mandatory decision marker

The Reviewer's final output must end with exactly one of `DECISION: ACCEPT`
or `DECISION: REQUEST_CHANGES` — uppercase, on its own line, the final
non-empty line. `lib/specrelay/marker.sh`'s
`specrelay::marker::parse` is the single, shared parser (used by
`providers/claude.sh` and marker recovery) enforcing: exactly one marker,
never both, never duplicated, never merely somewhere in the output. Prose
("I accept this implementation.", "looks good overall") is never inferred as
a decision.

**Decision consistency** (`specrelay::marker::artifacts_consistent`,
`transitions.sh`): `ACCEPT` requires non-empty `09-consultant-review.md` +
`10-business-summary.md`; `REQUEST_CHANGES` requires non-empty
`09-consultant-review.md` + `11-next-executor-prompt.md`. A conflicting
artifact/marker combination fails clearly rather than transitioning.

### Smart marker-only recovery

When the reviewer provider exits successfully (rc 0) but no valid marker is
found, the real Claude adapter returns a distinguishable exit code (**2**,
not the generic failure code **1**) so `workflow.sh`'s reviewer loop can tell
"the process itself failed" apart from "it succeeded but forgot the marker."
On rc 2, `lib/specrelay/marker_recovery.sh` checks
`specrelay::marker_recovery::eligible`: does `09-consultant-review.md`
contain a clear, structured `Decision: ACCEPT` / `Decision: REQUEST_CHANGES`
field, AND does the artifact that decision requires (`10-business-summary.md`
/ `11-next-executor-prompt.md`) exist and is non-empty? If so, it builds a
**narrow** corrective prompt — reads only the three already-written
artifacts, explicitly told not to repeat the review, not to run tests, and
not to inspect the repository again — and makes **exactly one** corrective
attempt (`specrelay::provider::reviewer_recover_marker`).

For the real Claude provider, the corrective attempt is enforced structurally,
not just by prompt text: it omits `--dangerously-skip-permissions`, so a tool
call requiring approval is refused by the CLI itself (there is no interactive
channel in `--print` mode to grant it) — the same mechanism this codebase
already relies on elsewhere to make `--print` non-interactive, reused here as
the enforcement boundary. It also never selects `--agent ai-reviewer` (that
sub-agent's whole purpose is the full review contract, not this follow-up).

Recovery is **forbidden** (falls through to ordinary "stays
`REVIEWER_RUNNING`" behavior) when: artifacts are missing or empty, they
contradict each other, no clear decision exists, a `REQUEST_CHANGES` decision
is missing `11-next-executor-prompt.md`, or the provider failed (rc 1) before
any artifacts were written at all. A failed corrective attempt also leaves
the task in `REVIEWER_RUNNING` — there is no automatic second attempt; a
human-initiated `specrelay resume` is a fresh, independent invocation, not a
second attempt inside the same failed one. Every attempt (success or
failure) is recorded in the execution timeline
(`reviewer_marker_recovery` phase + a `marker_recovery` event).

## D. Execution timeline

### Architecture

- **`<task-runtime-path>/20-execution-events.jsonl`** — the single source of
  truth: an append-only log of `phase_start` / `phase_finish` /
  `invocation_start` / `invocation_finish` / `verification` /
  `marker_recovery` events, written by `lib/specrelay/timeline.sh`
  (a thin wrapper) and `lib/specrelay/py/timeline_lib.py` (the actual
  aggregation/rendering engine — mirrors `state.sh` → `py/state_lib.py`).
  Never truncated; concurrent writers are already serialized by the existing
  per-task lock `run`/`resume` hold for their whole invocation — no new lock
  namespace.
- **`<task-runtime-path>/20-execution-timeline.json`** — a derived summary,
  fully **regenerated** from the event log on every render and written
  atomically (temp file + `os.replace`), never hand-merged. An interrupted
  write can only fail to update the file, never corrupt a previously valid
  one.

Required timeline phases: `task_initialization`, `task_approval`,
`executor_context_preflight`, `executor_claim`, `executor_provider_execution`,
`executor_evidence_capture`, `executor_submission`,
`reviewer_context_preflight`, `reviewer_start`, `reviewer_provider_execution`,
`reviewer_marker_recovery`, `reviewer_transition`, `finalization`.

### Timing honesty

- `monotonic` (`time.monotonic()`, `CLOCK_MONOTONIC`) pairs a phase's start/
  finish reliably across the separate process invocations that make up one
  `run`/`resume` (it is a boot-session-wide clock, not per-process).
- `recorded_at` is always a UTC wall-clock ISO-8601 timestamp, used for the
  **total wall time**, which honestly spans every invocation (first
  invocation's start to the last invocation's finish) — including any real
  calendar time between resumes, because "how long did the whole task take"
  is a calendar-time question monotonic time cannot answer across a possible
  reboot.
- Provider execution is recorded as one phase
  (`executor_provider_execution` / `reviewer_provider_execution`); SpecRelay
  never claims a fabricated split into "coding time" / "analysis time" /
  "waiting time" it cannot actually measure.
- Provider metrics (tokens, cost, model) are captured only where the provider
  reliably reports them; otherwise `not_available` is recorded, never an
  estimate.

### Multi-resume

Each `run`/`resume` invocation gets its own `invocation_start` /
`invocation_finish` pair (invocation id, start/finish timestamp, initial/
final state, exit code). `Invocations:` / `Resume count:` in the final report
are derived by counting these — a resumed task always shows the correct
cumulative count, and no previous invocation's data is ever lost.

### Verification ledger

Aggregates `verification` events by `(role, operation)`: count and total
duration (when available). Populated from two honest sources:

1. **Real Claude transcripts** — after an executor/reviewer provider run,
   `specrelay::verification::extract_from_events` scans the captured
   semantic-event JSONL (`19-executor-events.jsonl` /
   `20-reviewer-events.jsonl`) for `Bash` tool-use commands, classifies each,
   and records it. Durations are intentionally left `not_available` here —
   the transcript does not reliably pair a command's start/finish, and
   guessing one would violate spec 0019's "Metrics Must Be Honest."
2. **Deterministic test fixtures** — the `fake` provider's `verify_ops=`
   plan key records already-classified operations with real, test-controlled
   durations, for exercising counting/duplicate-detection without a live
   provider.

### Duplicate-work reporting

An operation that ran more than once is reported with its count, measured
total duration, and whether the extra runs are **justified** (a recorded
reason exists for at least `count - 1` of them) or **unjustified**. SpecRelay
never claims all duplicate work was avoidable — only what was measured and
whether a reason was recorded.

### Final report

Printed at the end of every completed-or-explicit-stop invocation
(`READY_FOR_HUMAN_REVIEW`, `BLOCKED`, a manual-reviewer stop, a provider
failure leaving `REVIEWER_RUNNING`/`EXECUTOR_RUNNING`, or the max-iterations
stop): the execution-timeline table (phase/status/duration/share of total
wall time), invocation/resume counts, the verification ledger, duplicate-work
detection, the 5 slowest measured phases, a performance summary, and phase-
budget warnings. Labeled **FINAL** only when the task reached
`READY_FOR_HUMAN_REVIEW` / `BLOCKED` / the max-iterations stop; **PARTIAL**
otherwise. Output is plain text, append-only, with no ANSI escapes or cursor
movement — safe to redirect or pipe.

## E. Phase budgets

Soft, advisory per-phase duration budgets
(`.specrelay/config.yml`, `performance.phase_budgets.*` — see
`docs/configuration.md`). Exceeding one only ever adds a warning to the final
report (`within_budget` / `exceeded` / `not_configured` / `not_measurable`);
it **never** changes task state. Executor provider execution intentionally
has no strict default budget (implementation complexity varies too widely).

## F. Agent execution efficiency and completion gate (spec 0021)

An explicit completion gate, enforced independently of provider exit code:

- **Policy**: `.specrelay/config.yml`, `execution_efficiency.*` (see
  `docs/configuration.md`) — `enabled`, and per-role
  `exploration_warning_calls` / `repeated_verification_limit` /
  `unresolved_wait_is_failure` / `require_artifacts_before_success`. Captured
  durably into `state.json` (`execution_efficiency_effective`) the first time
  a task reaches an executor iteration; resume uses the captured policy, not
  a later config change.
- **Required-artifact gate**: after a zero-exit provider run, SpecRelay checks
  that the required role artifacts are non-empty (Executor:
  `03-executor-log.md`/`07-tests.txt`/`08-executor-summary.md`; Reviewer:
  `09-consultant-review.md` plus `10-business-summary.md` for `ACCEPT` or
  `11-next-executor-prompt.md` for `REQUEST_CHANGES` — the spec 0019
  marker/artifact-consistency rules remain authoritative and are not
  weakened). Missing/empty artifacts print `Executor Result: INCOMPLETE`
  (never a false `SUCCESS`) and leave the task in its running state.
- **Unresolved-waiting gate**: SpecRelay inspects ONLY the provider's final
  extracted output (`12-executor-stdout.txt` / `15-reviewer-stdout.txt` —
  never intermediate streaming prose) for an explicit, present/future
  statement of unresolved waiting (e.g. "I will wait for the background
  task"). Conservative and word-bounded: historical narration ("I waited...
  and it completed successfully") and unrelated words that merely contain
  "wait" never match. When `unresolved_wait_is_failure` is enabled for the
  role, a match produces the same `INCOMPLETE` result as a missing artifact.
- **Background-process check**: advisory only. SpecRelay's provider adapters
  always synchronously wait for the provider process before this check runs,
  so ownership of any process it may have spawned and detached can no longer
  be established reliably — this is honestly reported as `not_verifiable`
  rather than guessed from a process/command name, and it never blocks
  completion or kills anything.
- **Observable-work classification and reporting**: reuses the spec 0020
  command-timing ledger (`21-command-timing-events.jsonl`) to classify each
  observable operation as exploration / implementation / verification /
  waiting / artifact_writing / inspection / other, and reports
  post-verification timing (`final_required_verification_at` ->
  `provider_completed_at`) and unjustified repeated verification. Written to
  `22-agent-efficiency.json` (task-scoped; no new top-level runtime
  directory) and referenced from `20-execution-timeline.json` as
  `agent_efficiency_summary`. Printed at finalization as an "Agent
  Efficiency" table (or a short gate-failure block when a role's completion
  gate failed), immediately after the command-timing report.
- **Completion-gate results** are recorded as `completion_gate` events in the
  SAME `20-execution-events.jsonl` event log spec 0019 already writes — no
  new event-log namespace.

## G. Verification-policy engine (spec 0026)

Everything above (A) is a bounded *count* of how many times a role may run a
loosely-classified command. Spec 0026 adds a separate, deterministic
*policy engine* that a project may configure instead of (never alongside)
`validation.full_test_command`: multiple services, multiple checks per
service, changed-path-aware selection, dependencies, bounded parallel
execution, and durable per-check evidence. See `docs/configuration.md`
(`verification.*`, spec 0026) for the full schema.

- **Levels.** `changed` selects only the services affected by actually
  changed paths (both old/new path for a rename); an unmatched changed path
  is never silently ignored — it triggers the configured `changed_fallback`
  (default `full`). `full` selects every check configured for the full
  level. `flexible` is resolved by deterministic rules (matched risk rules,
  more than one distinct affected service, or a prior recorded required
  failure for this task escalate to `full`) — never an arbitrary AI choice
  — and the engine always records why.
- **Placement.** `verification.placement` controls which level applies at
  the Executor, Reviewer, and final gate (defaults: `changed` / `targeted` /
  `full`). `targeted` narrows to required checks (plus anything a matched
  risk rule requires), never simply repeating the complete Executor check
  list.
- **Dependencies and parallelism.** `depends_on` edges are validated (an
  unknown dependency or a cycle fails configuration before any execution
  starts) and enforced at run time: a dependent check never starts before
  its dependency passes, and becomes `BLOCKED_BY_DEPENDENCY` when its
  dependency fails or is blocked. Independent checks execute concurrently up
  to `defaults.concurrency`, but final report ordering is always
  deterministic (service declaration order, then dependency order, then
  check declaration order) regardless of actual completion order.
- **Required/optional and timeouts.** A required check must reach `PASSED`
  — `FAILED`/`TIMED_OUT`/`BLOCKED`/`BLOCKED_BY_DEPENDENCY`/
  `CONFIGURATION_ERROR` all fail the gate. An optional check's
  `FAILED_OPTIONAL`/`TIMED_OUT_OPTIONAL`/`BLOCKED_OPTIONAL` stays visible in
  the summary but never fails the gate on its own. A missing configured
  command/cwd/tool is always `CONFIGURATION_ERROR` — never a silent pass or
  a silent skip.
- **Evidence.** `26-verification-plan.json`, `27-verification-summary.json`,
  and `28-verification-summary.md` in the task directory, plus
  `verification/selection.json` and one
  `verification/services/<service>/<check>/{command.json,stdout.txt,
  stderr.txt,result.json}` directory per selected check — stdout/stderr are
  always separate files, so concurrent checks can never mix output.
  Environment variable NAMES a check declares are recorded as
  `environment_names`; any name that looks secret-shaped is additionally
  listed as `redacted_names` — a VALUE is never written to durable
  evidence.
- **Effective-configuration capture.** The first time a task plans
  verification, the engine snapshots a digest of the effective
  configuration into `verification/effective-config.json`. A later
  planning pass for the SAME task that finds the project's configuration
  has since changed refuses (rather than silently switching policy
  mid-task) — see `docs/operator-recovery.md`.
- **Duplicate detection.** An identical check re-run for the same task,
  iteration, phase, effective configuration, and working-tree state is
  reported (`duplicate_of`, a timestamp) rather than silently claimed as
  fresh evidence.
- **Legacy compatibility.** `validation.full_test_command` alone continues
  to work, unmodified, translated internally to a one-service, one-check
  `full` configuration. Configuring both it and `verification.services` at
  once is an ambiguity error. A historical task with no recorded run
  reports "Verification policy: not recorded" — never a fabricated result.
- **CLI.** `specrelay verification plan [--level ...] [--phase ...]
  [--changed-from <ref>] [--json]` is read-only (validates configuration,
  shows selection/dependencies/fallback reasoning, executes nothing).
  `specrelay verification run [--level ...] [--phase ...]` executes the
  selected checks and exits non-zero unless the overall status is
  `PASSED`/`NOT_REQUIRED`.
- **UI verification.** `kind: ui` is reserved in the check schema for a
  later specification; this engine implements no UI-runtime, browser, or
  screenshot behavior.

## Task inspection

`specrelay task timeline <task-ref> [--json]` (see `docs/commands.md`) prints
the current report **read-only** — it recomputes the summary from the event
log in memory but never writes `20-execution-timeline.json` (that write only
happens as part of a real `run`/`resume` invocation's finalization). Unknown
tasks fail clearly; a legacy task with no recorded timeline data is reported
as "not recorded" rather than fabricated. `specrelay task show` prints a
short summary (total wall time, invocation/resume counts, full-suite run
count, marker-recovery outcome, budget-warning count, and the timeline JSON
path) when timeline data exists.

## Security and privacy

No full prompts, secrets, MCP configuration values, API keys, environment
credentials, or authorization headers are ever recorded in the event log or
verification ledger. Verification commands that look like they carry an
inline secret assignment (name-based heuristic: `API_KEY`, `SECRET`,
`TOKEN`, `PASSWORD`, `AUTHORIZATION`, `CREDENTIAL`, `PRIVATE_KEY` substrings)
are redacted to `<redacted: contains sensitive environment assignment>`
rather than silently dropped — the operation is still counted, just without
the sensitive command text.

## Known limitations

- Verification-operation duration for commands extracted from a real Claude
  transcript is not available (see "Timing honesty" above) — only count and
  classification are real for that source. Durations ARE available for
  phase-level timing (which is measured directly by the orchestrator) and for
  deterministic test fixtures.
- Hard, engine-enforced blocking of arbitrary Executor/Reviewer verification
  commands is out of scope by design (spec 0019, "Soft Limit versus Hard
  Refusal") — the policy is prompt-level plus observation/reporting, except
  for the ONE place SpecRelay can safely and directly enforce something: the
  single marker-recovery attempt, which is capped programmatically (one call
  site) rather than by convention.
- The corrective marker-recovery attempt's "no repository tools" guarantee
  for the real Claude provider relies on omitting
  `--dangerously-skip-permissions`, which blocks *permission-gated* tool
  calls; it is not a sandboxed process boundary.
