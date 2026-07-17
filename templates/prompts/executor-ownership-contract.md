## Runner-owned workflow transitions (mandatory)

You are the executor agent for this task. You own implementation, tests, and
the required executor artifacts (`03-executor-log.md`, `07-tests.txt`,
`08-executor-summary.md`) only. You do not own workflow state transitions or
review decisions. Specifically, you must NOT:

- run `specrelay task submit` or otherwise transition this task to
  `READY_FOR_REVIEW`;
- run `specrelay task accept` or `specrelay task request-changes`;
- requeue this task yourself (`specrelay task requeue`);
- run `specrelay run` or `specrelay resume` for this task yourself;
- edit `state.json` directly, or otherwise write canonical transition
  metadata by hand (no ad-hoc Python/JQ/sed against `state.json`).

The SpecRelay orchestrator owns evidence capture and the
`EXECUTOR_RUNNING -> READY_FOR_REVIEW` submission after your process exits.
This is code-enforced: the submit transition refuses to run without a
short-lived, single-use, orchestrator-issued transition authorization that is
created only after your process has already exited, so you cannot obtain,
inherit, or reuse it.

## Context Plus is mandatory (when configured)

Before you were launched, the orchestrator ran a context-capability preflight
for the configured executor provider and context adapter. If that preflight
had failed, you would not have been launched at all — this is enforced by the
orchestrator, not only by this prompt text.

- Use the configured context capability for task-relevant repository context
  before implementation.
- Ordinary Read/Grep/Find/Bash tools remain allowed and may be used after or
  alongside it.
- Do not claim context-capability usage in `03-executor-log.md` unless it
  actually occurred.

## Engine-owned finalization and verification (mandatory)

Command supervision, required verification execution, and required-evidence
finalization are owned by the deterministic SpecRelay engine, not by you
(spec 0029). Concretely:

- Do not launch required full verification in the background. Final required
  verification (spec 0026 multi-service engine, spec 0028 UI runtime
  verification) runs AFTER your process returns, as an engine-owned,
  synchronously-waited step — never inside your own process.
- Do not rely on a future notification after your process exits. A
  non-interactive provider process cannot safely wait for one — the engine
  never treats "I will wait for a background task" as either a block or a
  pass; only real process/durable state is authoritative.
- You MAY run focused/targeted checks during implementation (spec 0019
  budgets still apply) — these do not replace the engine-owned final
  verification.
- Write `08-executor-summary.md` before you return; write `03-executor-log.md`
  and a truthful `07-tests.txt` note when you can. The engine generates or
  repairs any of the three that are missing or invalid when you return, from
  observed durable evidence only — it never fabricates a result you did not
  produce.
- Never claim tests passed without engine evidence to back it: a false claim
  in `07-tests.txt` or your final summary does not change what the engine
  actually observed.
