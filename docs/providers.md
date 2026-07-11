# SpecRelay Providers

This document describes SpecRelay's **provider adapters** — the pluggable
pieces that actually run the **executor** and **reviewer** roles of the
task lifecycle. It is the provider reference required by spec sections 30–32.

SpecRelay is a workflow engine, not an AI vendor. It ships with a
deterministic `fake` adapter (for testing) and a `claude` adapter (for the
Claude Code CLI). Any capable command-line tool can be added as a new adapter
by implementing the contract in this document — no changes to the core
lifecycle code are required.

> SpecRelay is an independent tool. It is **not** an official Anthropic or
> Claude product, and bundling a `claude` adapter does not imply any
> endorsement, affiliation, or support relationship (spec section 31). The
> `claude` adapter is simply one adapter that speaks to the Claude Code CLI if
> that CLI happens to be installed.

## Overview

A **role** is *what* needs doing (implement the change; review the change). A
**provider** is *who* does it (which CLI/adapter actually runs). The two are
kept strictly separate: the lifecycle code in `lib/specrelay/workflow.sh` calls
only the two generic dispatch functions in
`lib/specrelay/providers/provider.sh` and never knows which concrete adapter
ran.

Each role selects its provider independently through project configuration
(`.specrelay/config.yml`):

| Config key | Meaning | Default |
|---|---|---|
| `roles.executor.provider` | Adapter that runs the executor role | `claude` |
| `roles.reviewer.provider` | Adapter that runs the reviewer role | `manual` |

The defaults come from `specrelay::workflow::executor_provider` /
`specrelay::workflow::reviewer_provider`. `manual` is not an adapter — it means
"no automated reviewer; a human runs `specrelay task accept` /
`specrelay task request-changes`." When the reviewer provider is `manual`, the
automated loop stops and reports that human action is required (exit code `2`).

Currently dispatched provider names (`lib/specrelay/providers/provider.sh`):

| Role | Accepted `provider` values |
|---|---|
| executor | `fake`, `claude` |
| reviewer | `fake`, `claude`, `claude-subagent` |

`claude-subagent` is accepted **only** for the reviewer role and routes to the
same Claude reviewer implementation as `claude`. Any other value causes the
dispatcher to print `unsupported executor/reviewer provider: <name>` and return
non-zero.

`specrelay doctor` reports the availability of the configured executor and
reviewer providers as part of its read-only readiness checks (see
[Availability detection](#availability-detection-doctor)).

## The generic provider contract (section 32)

A provider adapter is a Bash file under `lib/specrelay/providers/` that defines
two functions and wires them into the dispatch `case` arms in `provider.sh`.
The full contract is described in the header comment of `provider.sh`; it is
summarized below. To add an adapter you implement exactly these two entry
points:

```
<adapter>::executor_run <project-root> <task-dir> <round> <prompt-file>
<adapter>::reviewer_run <project-root> <task-dir> <round> <prompt-file>
```

Both receive the absolute project root, the task's on-disk directory, the
1-based round number, and the path to the already-rendered prompt file for
that role. The contract for each concern:

### Availability check

The adapter is responsible for verifying that whatever it needs (an executable
on `PATH`, an environment, etc.) is present before doing real work. A missing
prerequisite must be reported and must make the run function return non-zero
rather than proceed. (`fake` needs nothing and is always available; `claude`
checks that its binary is on `PATH`.) Availability is *also* surfaced
read-only by `specrelay doctor` — see below.

### Executor invocation

`executor_run` runs the executor for one round. On success it **must** write
these three task files (the lifecycle refuses to submit for review if any is
missing or empty — `workflow.sh`):

| File | Meaning |
|---|---|
| `03-executor-log.md` | Executor's working log |
| `07-tests.txt` | Test / validation output |
| `08-executor-summary.md` | Executor's summary of the change |

It must also write its own captured streams:

| File | Stream |
|---|---|
| `12-executor-stdout.txt` | Executor process stdout |
| `13-executor-stderr.txt` | Executor process stderr |

### Reviewer invocation

`reviewer_run` runs the reviewer for one round as an **independent** unit of
work (see [Isolation](#isolation)). On success (exit 0) it must write:

| File | When |
|---|---|
| `09-consultant-review.md` | Always, on success |
| `10-business-summary.md` | On an **accept** decision |
| `11-next-executor-prompt.md` | On a **request-changes** decision |

Plus its captured streams:

| File | Stream |
|---|---|
| `15-reviewer-stdout.txt` | Reviewer process stdout |
| `16-reviewer-stderr.txt` | Reviewer process stderr |

### stdout / stderr usage

Provider process output is captured into the numbered files above (`12`/`13`
for the executor, `15`/`16` for the reviewer). These captured files are
evidence artifacts; they are **not** how a decision is communicated. The
reviewer's machine-readable decision travels on the adapter function's *own*
stdout, which the lifecycle reads via command substitution — deliberately
distinct from the redirected `15-reviewer-stdout.txt` capture file.

### Exit-code semantics

Both functions must return the *real* success/failure of the work:

- `0` = success.
- Non-zero = failure. For the executor, a non-zero exit means the round is
  not submitted for review. For the reviewer, a non-zero exit means
  **reviewer failure: no decision is made and no state change occurs** — the
  task stays `READY_FOR_REVIEW`.

### Decision extraction (accept vs request-changes)

This is the single most important reviewer rule (spec section 34: an explicit,
machine-readable decision, **never** inferred from prose). On success, the
**last line** of `reviewer_run`'s own stdout must be exactly `ACCEPT` or
`REQUEST_CHANGES`. The lifecycle takes that command-substitution output,
reads its last line, strips whitespace, and transitions the task:

- `ACCEPT` → `READY_FOR_HUMAN_REVIEW`
- `REQUEST_CHANGES` → `CHANGES_REQUESTED`
- anything else → treated as no decision; refuse to transition (non-zero).

How an adapter *derives* that final `ACCEPT`/`REQUEST_CHANGES` line from its
underlying tool is adapter-specific (the `fake` adapter is told the decision;
the `claude` adapter greps the reviewer output for an explicit marker — see
each adapter below).

### Structured-event / streaming capability

The contract does **not** require any structured live-event stream (e.g.
streaming JSON). It is an optional capability. Neither adapter shipped today
emits a structured event stream: `fake` produces fixed text, and the `claude`
adapter intentionally does not thread live semantic event streaming (this is a
known, documented gap in the Claude adapter's header comment). Adapters
communicate results purely through the numbered files and the final decision
line.

## The `fake` adapter

Source: `lib/specrelay/providers/fake.sh`.

`fake` exists for **deterministic testing** (spec section 60). It never invokes
any real CLI and is always available. Its per-round behavior is scripted by
optional **plan files** — one line per round, 1-indexed — so a test can drive
exact multi-round scenarios (accept on round 1, request-changes then accept,
executor failure, reviewer failure, max-rounds) with no real provider call. A
missing plan file, or a round past the end of the file, falls back to the
documented defaults.

Plan lines are comma-separated `key=value` pairs:

| Role | Keys (defaults) |
|---|---|
| executor | `exit=<0\|N>` (default `0`), `outputs=<0\|1>` (default `1`, writes the required output files), `touch=<0\|1>` (default `1`, appends a line to the fixture file to create a real diff) |
| reviewer | `exit=<0\|N>` (default `0`), `decision=<accept\|request_changes>` (default `accept`) |

Environment hooks (exact names from `fake.sh`):

| Variable | Purpose |
|---|---|
| `SPECRELAY_FAKE_EXECUTOR_PLAN` | Path to the executor plan file (optional) |
| `SPECRELAY_FAKE_REVIEWER_PLAN` | Path to the reviewer plan file (optional) |
| `SPECRELAY_FAKE_IMPL_FILE` | Fixture file the executor "implements" into (default `<project-root>/specrelay-fake-impl.txt`) |
| `SPECRELAY_FAKE_EXECUTOR_SLEEP` | Test-only: sleep after the claim to widen the race window for concurrency tests |

On the reviewer side, `fake` writes `09-consultant-review.md`, then writes
`10-business-summary.md` and prints `ACCEPT`, or writes
`11-next-executor-prompt.md` and prints `REQUEST_CHANGES`, according to the
plan's `decision` field. A non-zero `exit` returns immediately with no
decision.

Because `fake` is a fully independent adapter, tests that use it exercise the
generic lifecycle **without touching any Claude-specific code path**. Provider
tests must be written against `fake` (or a new fake-like adapter) and must not
patch the `claude` adapter.

## The `claude` and `claude-subagent` adapters

Source: `lib/specrelay/providers/claude.sh`.

This adapter drives the **Claude Code CLI** in non-interactive mode. It
preserves a deliberately small, proven invocation surface and is intentionally
simpler than a full-featured integration (no live event streaming, no
multi-tier flag negotiation beyond the one `--agent` check below); the omitted
behaviors are recorded as a known gap, not hidden.

**Required executable.** The `claude` CLI, resolved by
`specrelay::provider::claude::_bin` as `${SPECRELAY_CLAUDE_BIN:-claude}`. Set
`SPECRELAY_CLAUDE_BIN` to point at a specific binary; otherwise `claude` on
`PATH` is used.

**Availability detection.** Before running, both `executor_run` and
`reviewer_run` check `command -v "$bin"`. If the binary is not on `PATH`, the
adapter prints `'<bin>' was not found on PATH` and returns non-zero.

**Executor usage.** Runs, with the working directory set to the project root:

```
claude --print --dangerously-skip-permissions "<prompt>"
```

`--print` is non-interactive; `--dangerously-skip-permissions` is required
because a `--print` run cannot answer an interactive permission prompt. Stdout
and stderr are redirected to `12-executor-stdout.txt` / `13-executor-stderr.txt`
and the CLI's real exit code is returned.

**Reviewer usage.** Always a **fresh** `claude` process. If the repository
defines a reviewer sub-agent (`.claude/agents/ai-reviewer.md` is present) **and**
`claude --help` advertises `--agent`, it runs with
`--agent ai-reviewer --print --dangerously-skip-permissions`; otherwise it runs
with `--print --dangerously-skip-permissions`. This flag choice is made by
*inspecting* `claude --help`, never by guessing. Output is captured to
`15-reviewer-stdout.txt` / `16-reviewer-stderr.txt`.

**Reviewer decision extraction.** After a successful (exit 0) reviewer run, the
adapter reads `15-reviewer-stdout.txt` and looks for an explicit marker,
anchored at end of line:

- `DECISION: ACCEPT` → prints `ACCEPT`
- `DECISION: REQUEST_CHANGES` → prints `REQUEST_CHANGES`

If neither marker is present, the adapter prints
`reviewer produced no explicit 'DECISION: ACCEPT|REQUEST_CHANGES' marker;
refusing to infer a decision from prose` and returns non-zero — no decision is
guessed from surrounding text.

**Isolation.** For this adapter, "isolation" means the reviewer is always a
brand-new process — never a `--continue` or `--resume` of the executor's
session — so the reviewer forms its judgement independently of the executor's
conversational state.

**`claude-subagent`.** As a reviewer-role provider value, `claude-subagent`
dispatches to the same `claude` reviewer implementation described above. There
is no separate executor for `claude-subagent`.

**No credentials in SpecRelay config (section 31).** SpecRelay stores only the
*provider name* in `.specrelay/config.yml` (and, optionally, a binary path via
the `SPECRELAY_CLAUDE_BIN` environment variable). It never stores API keys,
tokens, or any other credential. Authentication is entirely the underlying
CLI's responsibility, handled through that tool's own login/credential
mechanism outside of SpecRelay.

## Availability detection (`doctor`)

`specrelay doctor` (`lib/specrelay/doctor.sh`) reports each configured
provider's availability read-only, mutating nothing:

- `fake` → reported as always available (deterministic).
- `claude` / `claude-subagent` → reported available only if
  `specrelay::provider::claude::_bin` is found on `PATH`; otherwise a failing
  `not found on PATH` check.
- reviewer `manual` → reported as an informational line (a human decides).
- any other configured value → reported as an unsupported provider (failing
  check).

Failing mandatory checks make `doctor` exit non-zero.

## Adapter capability summary (section 30)

| Adapter | Required executable | Detection method | Invocation contract | Output handling | Structured-event capability | Failure semantics |
|---|---|---|---|---|---|---|
| `fake` | none | always available | scripted per round via optional plan files (`SPECRELAY_FAKE_EXECUTOR_PLAN` / `SPECRELAY_FAKE_REVIEWER_PLAN`); no real process | writes required numbered task files + `12`/`13` (exec) or `09`/`10`/`11` + `15`/`16` (review); reviewer prints `ACCEPT`/`REQUEST_CHANGES` per plan `decision` | none (fixed text) | plan `exit=N` returns that code; reviewer non-zero = no decision, state unchanged |
| `claude` | `claude` CLI (`${SPECRELAY_CLAUDE_BIN:-claude}`) | `command -v "$bin"` on `PATH`; `doctor` reports the same | executor: `claude --print --dangerously-skip-permissions`; reviewer: fresh process, `--agent ai-reviewer` when advertised + repo agent present, else `--print --dangerously-skip-permissions` | streams captured to `12`/`13` (exec) or `15`/`16` (review); required task files written; decision from `DECISION: ACCEPT`/`DECISION: REQUEST_CHANGES` marker in reviewer stdout | none today (live event streaming intentionally omitted; known gap) | missing binary or CLI non-zero → return non-zero; reviewer with no `DECISION:` marker → non-zero, no decision inferred |
| `claude-subagent` (reviewer only) | same as `claude` | same as `claude` | routes to the `claude` reviewer implementation | same as `claude` reviewer | same as `claude` | same as `claude` reviewer |

## Adding a new adapter

New providers can be added without changing the lifecycle code. Implement the
[generic contract](#the-generic-provider-contract-section-32):

1. Create `lib/specrelay/providers/<name>.sh` defining
   `<ns>::executor_run` and/or `<ns>::reviewer_run`.
2. Add a `case` arm for the new provider name in the appropriate dispatcher(s)
   in `lib/specrelay/providers/provider.sh`.
3. Honor the contract exactly: availability check, the required numbered output
   files, captured stdout/stderr, real exit codes, and — for reviewers — an
   explicit final `ACCEPT`/`REQUEST_CHANGES` decision line derived from an
   explicit machine-readable marker, never inferred from prose.
4. Store no credentials in SpecRelay config (section 31); rely on the
   underlying tool's own authentication.

Optionally extend `specrelay doctor` to report the new provider's availability
so operators get the same read-only readiness signal.
