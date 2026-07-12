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

Each role is configured with three explicit, provider-neutral keys in
`.specrelay/config.yml` (spec 0009):

| Config key | Meaning | Default |
|---|---|---|
| `roles.<role>.provider` | **provider** — adapter/CLI that runs the role | executor `claude`, reviewer `manual` |
| `roles.<role>.model` | **model** — provider model id, or `provider-default` | `provider-default` |
| `roles.<role>.agent` | **agent** — provider-specific profile/subagent, or `none` | `none` (reviewer legacy `claude-subagent` → `ai-reviewer`) |

- **provider** = the adapter/CLI. `manual` is not an adapter — it is an explicit
  **opt-out / safe-bootstrap** mode meaning "no automated reviewer; a human runs
  `specrelay task accept` / `specrelay task request-changes`." When the reviewer
  provider is `manual`, both `run` and `resume` stop at `READY_FOR_REVIEW` and
  report that human action is required (exit code `2`). This is deliberately
  **not** the intended automated AI workflow: when the reviewer provider is not
  `manual`, `READY_FOR_REVIEW` is an internal handoff state and the same
  invocation continues into reviewer execution, reaching `READY_FOR_HUMAN_REVIEW`
  on acceptance (spec 0010). An automated reviewer failure leaves the task at
  `READY_FOR_REVIEW` with a clear recovery reason (exit code `4`) — never a
  silent stop.
- **model** = the provider model id or version. The sentinel `provider-default`
  means SpecRelay passes **no** explicit model flag and lets the provider CLI use
  its own default. The model is an **opaque string** — SpecRelay never validates
  it against real vendor model names. See
  [Model passing](#model-passing-spec-0009).
- **agent** = a provider-specific profile/subagent, usually `none` or
  `ai-reviewer`. `none` means no provider-specific agent is used.

Keeping the three concerns separate is what removes the earlier ambiguity where
`claude-subagent` behaved like a provider name even though it is really the
Claude provider plus the `ai-reviewer` agent. `claude-subagent` remains
supported as **legacy shorthand** (see below), but the explicit three-key form
is the preferred way to express the same thing.

The provider defaults come from `specrelay::workflow::executor_provider` /
`specrelay::workflow::reviewer_provider`; the model/agent resolution lives in
`specrelay::workflow::role_model` / `specrelay::workflow::role_agent`.

Currently dispatched provider names (`lib/specrelay/providers/provider.sh`):

| Role | Accepted `provider` values |
|---|---|
| executor | `fake`, `claude` |
| reviewer | `fake`, `claude`, `claude-subagent` |

`claude-subagent` is accepted **only** for the reviewer role. It is a **legacy
shorthand** that routes to the same Claude reviewer implementation as `claude`:
"the Claude reviewer, preferring the `ai-reviewer` sub-agent when the project
provides one." It does **not** guarantee a sub-agent is used — see
[Reviewer usage](#the-claude-and-claude-subagent-adapters) below. Any other
value causes the dispatcher to print
`unsupported executor/reviewer provider: <name>` and return non-zero.

`specrelay doctor` reports the availability of the configured executor and
reviewer providers as part of its read-only readiness checks (see
[Availability detection](#availability-detection-doctor)).

## Model passing (spec 0009)

Model selection is explicit in config and is added to provider invocation only
where it is **safe and help-driven**. SpecRelay never validates real vendor
model names — a model is an opaque string.

For the `claude` adapter:

- If the effective model is `provider-default`, SpecRelay passes **no model
  flag**; the Claude CLI uses its own default.
- If the model is anything else, SpecRelay passes the Claude CLI model flag
  (`--model <model>`) **only if `claude --help` advertises that flag** — flags
  are never guessed.
- If an explicit model is configured but the installed CLI **cannot** accept a
  model (its `--help` does not advertise `--model`), the run **fails clearly**
  before launch rather than silently ignoring the configured model, and
  `specrelay doctor` reports the mismatch.

Codex (and other future adapters) are described here as **provider-neutral**:
the same three keys — `provider`, `model`, `agent` — would carry over, with each
adapter passing its own CLI's model flag help-driven in exactly this way. No
Codex adapter is implemented until one exists and can be tested deterministically
with fake binaries.

## Role environment overrides (spec 0009)

A role's `model` and `agent` can be overridden from the environment. These take
**precedence over `.specrelay/config.yml`**:

| Variable | Overrides |
|---|---|
| `SPECRELAY_EXECUTOR_MODEL` | `roles.executor.model` |
| `SPECRELAY_REVIEWER_MODEL` | `roles.reviewer.model` |
| `SPECRELAY_EXECUTOR_AGENT` | `roles.executor.agent` |
| `SPECRELAY_REVIEWER_AGENT` | `roles.reviewer.agent` |

Full resolution precedence for the effective `model`/`agent`: (1) the
role-specific env override, (2) `.specrelay/config.yml`, (3) normalized legacy
provider behavior (reviewer `claude-subagent` → `agent: ai-reviewer`),
(4) the provider default. An empty env override is treated as unset.
Provider-specific env overrides are possible future work and are not added here.

## The generic provider contract (section 32)

A provider adapter is a Bash file under `lib/specrelay/providers/` that defines
two functions and wires them into the dispatch `case` arms in `provider.sh`.
The full contract is described in the header comment of `provider.sh`; it is
summarized below. To add an adapter you implement exactly these two entry
points:

```
<adapter>::executor_run <project-root> <task-dir> <round> <prompt-file> [label]
<adapter>::reviewer_run <project-root> <task-dir> <round> <prompt-file> [label]
```

Both receive the absolute project root, the task's on-disk directory, the
1-based round number, and the path to the already-rendered prompt file for
that role. The optional final `label` (e.g. `executor:claude`) is supplied by
the dispatch functions and is the role/provider scope used to prefix live
terminal output — adapters pass it straight through to
`specrelay::provider::run_streamed` (see
[Live provider output streaming](#live-provider-output-streaming-spec-0003)).
The contract for each concern:

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

Adapters do not redirect the provider's streams straight into those files
themselves. Instead they run the underlying command through the shared
`specrelay::provider::run_streamed` helper (in `provider.sh`), which
simultaneously (a) writes the raw, unprefixed stream to the numbered capture
file and (b) streams a live, role/provider-prefixed copy to the operator's
terminal — see [Live provider output streaming](#live-provider-output-streaming-spec-0003).

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

The contract does **not** require any *structured* live-event stream (e.g.
streaming JSON). It remains an optional, provider-specific capability. `fake`
produces fixed text and emits no structured stream. The `claude` adapter **does**
support one when the installed CLI advertises it — Claude Code's
`--verbose --output-format stream-json` mode — and renders those events into
human-readable live activity lines (spec 0006). See
[Semantic Claude live event rendering](#semantic-claude-live-event-rendering-spec-0006).
Regardless of whether structured events are used, adapters still communicate
their *results* purely through the numbered files and the final decision line.

There are therefore **two** live-output layers, and they are independent:

- **Generic raw streaming** (spec 0003, every adapter, next section): replays
  the provider's plain stdout/stderr text to the terminal as it is produced.
- **Semantic event rendering** (spec 0006, `claude` when available): parses the
  provider's structured event stream and prints concise per-step activity.

Both are operator-visibility layers only; neither changes how a result or
decision is communicated, and the semantic layer falls back to the generic one
whenever structured events are unavailable — semantic events are never faked.

## Live provider output streaming (spec 0003)

Provider runs used to be silent at the terminal: an adapter redirected the real
CLI's stdout/stderr straight into its numbered capture files, so the operator
saw the phase banners and then nothing — sometimes for several minutes — while
a real provider such as `claude` or `claude-subagent` worked. SpecRelay now
**streams provider output live** so the operator can tell whether the provider
is progressing, waiting, erroring, or hung.

- **On by default.** Live streaming is always on; there is no flag to enable it
  (the spec 0003 human decision was "show live output by default").
- **Scoped, plain-text prefixes.** Each streamed line is prefixed with its
  role and provider — `[executor:claude]`, `[reviewer:claude-subagent]`,
  `[executor:fake]`, etc. — so executor and reviewer output are never
  ambiguous. The prefix is plain text; no color or escape codes are emitted.
- **Evidence is still the source of truth.** The live copy goes to the
  terminal; the raw, *unprefixed* stream is still written in full to the
  numbered capture files (`12`/`13` for the executor, `15`/`16` for the
  reviewer). Live terminal output is an operator-UX layer and is **not** a
  substitute for reviewing the durable evidence files.
- **Streamed on stderr (fd 2).** Live copies are written to fd 2, which keeps
  the adapter function's own stdout (fd 1) — the reviewer's machine-readable
  `ACCEPT`/`REQUEST_CHANGES` decision channel — completely clean.
- **No TTY required.** Streaming targets fd 2 and the capture files are written
  regardless, so redirected and CI runs keep complete evidence. Nothing depends
  on a terminal being attached.

How it works: every adapter runs the underlying command through
`specrelay::provider::run_streamed <label> <stdout-file> <stderr-file> <run-dir> -- cmd…`
(defined once in `provider.sh`, so the behavior is identical for every provider
and nothing is hardcoded for a single one). The helper:

- runs the command with its stdout/stderr connected to FIFOs, so the wrapped
  command's **real exit code** is returned — there is no `tee`/pipeline in the
  exit path that could let a failing provider look successful;
- has a line-buffered reader copy each line raw to the capture file and a
  prefixed copy to fd 2, and **waits** for both readers before returning, so
  the capture files are fully flushed before the lifecycle reads them (e.g. the
  reviewer decision grep) — no buffering race, no flakiness.

The `<label>` is supplied by the dispatch functions in `provider.sh`
(`executor:<provider>` / `reviewer:<provider>`) and passed to the adapter as an
optional final argument.

## Semantic Claude live event rendering (spec 0006)

Generic raw streaming (above) shows whatever plain text a provider prints. That
is enough for `fake` and for any provider that emits line output, but a real
`claude --print` run emits almost nothing while it works — so the generic layer
would show a silent terminal for minutes. This is the regression spec 0006
restores: **semantic live event rendering** for the `claude` adapter, ported
from the original workflow.

**How it is chosen.** For a Claude executor or reviewer run, the adapter uses
the structured mode **only** when all of the following hold; otherwise it falls
back to generic raw streaming (spec 0003) and says so — semantic events are
never faked:

1. semantic events are not disabled (`SPECRELAY_SEMANTIC_EVENTS` is not `0`);
2. `python3` (or `$SPECRELAY_PYTHON`) is on `PATH` and the renderer
   `lib/specrelay/py/render_agent_events.py` exists;
3. the installed `claude --help` advertises `--output-format` **and**
   `stream-json` (the flag set is read from help, never guessed; `--verbose` is
   added only when help advertises it, as the CLI requires it for `stream-json`
   with `--print`).

**What it does.** The provider is run with
`--verbose --output-format stream-json`, which makes Claude Code emit a JSONL
event stream (one JSON object per line: `system/init`, `assistant`
tool-use/text blocks, `user` tool results, and a final `result`). That stream
is piped through the standalone renderer, which:

- prints one concise, plain-text line per meaningful event to the operator
  terminal (fd 2), scoped by the same role/provider label — e.g.
  `[executor:claude] reading: docs/providers.md`,
  `[executor:claude] command: git status --short`,
  `[executor:claude] result: success (4s, 3 turns)`;
- **never renders private reasoning** (Claude `thinking` /
  `redacted_thinking` blocks are dropped) and truncates large fields;
- persists the **raw** JSONL stream verbatim to the events evidence file
  (`19-executor-events.jsonl` / `20-reviewer-events.jsonl`);
- extracts the **final assistant text** and writes it to the numbered stdout
  capture file (`12-executor-stdout.txt` / `15-reviewer-stdout.txt`), so the
  workflow's required-output checks and the reviewer `DECISION:` grep keep
  working unchanged.

**Evidence layout differs from generic mode on purpose.** In generic mode the
`12`/`15` files hold the provider's raw stdout; in semantic mode they hold the
*extracted final text* (human-readable, never raw JSON) and the raw stream lives
in the `19`/`20` events files. The stderr files (`13`/`16`) hold raw stderr in
both modes.

**Guarantees preserved.** The rendering runs in a pipeline whose
`PIPESTATUS[0]` is the provider's real exit code, captured independently of the
renderer — a renderer failure never fails a valid provider run, and never lets a
failing provider look successful. The helper waits for its readers and the
renderer writes the extracted final text at EOF, so `15-reviewer-stdout.txt` is
fully flushed before the reviewer decision grep reads it (no buffering race).
Rendered lines and stderr both go to fd 2, so the reviewer's machine-readable
`ACCEPT`/`REQUEST_CHANGES` decision channel (fd 1) is never polluted.

**Fallback is pre-launch only; no automatic retry after launch.** The choice
between semantic and generic mode is made **before** Claude is launched, from
the three checks above (`claude --help` is inspected, flags are never guessed).
Once a semantic Claude process has launched, its exit code is authoritative:
SpecRelay does **not** automatically re-run a failed semantic invocation as a
generic run. Retrying a launched provider could duplicate provider side effects
or rerun a partially completed agent task, so a non-zero semantic run is
reported as a failure exactly like any other provider failure (the executor
round is not submitted; the reviewer makes no decision and state is unchanged).
A *renderer* failure is different and non-fatal — it may warn on fd 2 but never
masks or overrides the provider's exit code, and the raw events remain in the
`19`/`20` file. Generic `run_streamed` remains the fallback path only for
known-unavailable semantic mode, never as a post-failure retry.

**Where it lives.** The renderer is a standalone SpecRelay runtime resource at
`lib/specrelay/py/render_agent_events.py` (next to `state_lib.py`); it references
no host paths and is provider-neutral (a Claude adapter today, with a retained
Codex adapter to demonstrate neutrality). The shell side is the generic
`specrelay::provider::run_agent_events` helper in `provider.sh` — parallel to
`run_streamed`, not a replacement for it.

**Controls.**

| Variable | Effect |
|---|---|
| `SPECRELAY_SEMANTIC_EVENTS=0` | Force the generic spec-0003 path even when stream-json is advertised. |
| `SPECRELAY_PYTHON` | Interpreter used for the renderer (default `python3`). |
| `SPECRELAY_CLAUDE_BIN` | The Claude binary whose `--help` is inspected and which is run. |
| `SPECRELAY_COLOR` | Color mode for all human-facing terminal output (orchestrator logs and semantic live lines): `auto` (default), `always`, or `never`. An unrecognized value is treated as `auto` (with a stderr warning). |
| `NO_COLOR` | When set (any value, per [no-color.org](https://no-color.org)), disables color unless `SPECRELAY_COLOR=always` overrides it. |

**Optional color.** `SPECRELAY_COLOR` controls ANSI color for **all** of
SpecRelay's human-facing terminal output — both the engine/orchestrator logs and
the semantic live agent events. The three modes are:

- `auto` (default) emits ANSI colors **only when the target stream is a TTY** and
  `NO_COLOR` is unset, so CI and other non-TTY output stay plain text
  automatically;
- `always` emits colors unconditionally (and overrides `NO_COLOR`);
- `never` never emits colors.

*Orchestrator logs.* Engine status lines (e.g. `[specrelay] creating task …`,
`[executor] task … checking working-tree guard`, `Transitioned: … -> …`) get a
dimmed `[tag]` prefix and a body accent keyed on the state keyword — green as a
task progresses toward completion, yellow for rework/warnings, red for
refusals/failures. Errors on stderr are red.

*Semantic live events.* When color is on, the rendered lines are laid out closer
to the Claude Code UI: a distinct, aligned, colored tool label followed by the
plain argument — `Bash` (yellow), `Read`/`Grep`/`Glob` (blue), `Write`/`Edit`
(magenta); a long `Bash` command wraps onto an indented, role-prefixed
continuation line; `started` and `result:` lines carry a `●` marker (cyan;
green on success, red on error); `says:` is green. With color **off** the output
is byte-for-byte the historical single-line plain form, so greps and parsing are
unaffected.

Colors are **terminal-only** and are **never written into evidence** and never
pollute machine-parsed channels: the raw events files (`19`/`20`), the extracted
final-text files (`12`/`15`), the stderr files (`13`/`16`), the persisted
`state.json`, and the reviewer `DECISION:` output all stay plain text regardless
of color mode. Color policy is centralized (the shell side in
`lib/specrelay/output.sh`, the Python side in `lib/specrelay/py/color.py`); no
raw escape codes are sprinkled through the engine.

`specrelay doctor` reports, as an informational line, whether the semantic layer
is available for the configured Claude provider(s).

> A heartbeat/idle-tick fallback (periodic "still working…" output when a
> provider is genuinely silent) is a possible **future** addition, but is not
> implemented here: the goal of spec 0006 is restoring the real semantic events,
> not synthesizing activity.

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
preserves a deliberately small, proven invocation surface with one
multi-tier flag negotiation (the `--agent` check below) and, when the installed
CLI advertises it, **semantic live event streaming** via
`--verbose --output-format stream-json` (spec 0006 — see
[Semantic Claude live event rendering](#semantic-claude-live-event-rendering-spec-0006)).
When the structured mode is unavailable it falls back honestly to the generic
raw streaming from spec 0003.

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
because a `--print` run cannot answer an interactive permission prompt. In the
generic (fallback) path, stdout and stderr are streamed live (prefixed
`[executor:claude]`) and captured raw to `12-executor-stdout.txt` /
`13-executor-stderr.txt` via `specrelay::provider::run_streamed`, and the CLI's
real exit code is returned (see
[Live provider output streaming](#live-provider-output-streaming-spec-0003)).

When semantic events are available the invocation instead becomes:

```
claude --print --verbose --output-format stream-json --dangerously-skip-permissions "<prompt>"
```

and the raw JSONL event stream is persisted to `19-executor-events.jsonl` while
the extracted final assistant text is written to `12-executor-stdout.txt` —
see [Semantic Claude live event rendering](#semantic-claude-live-event-rendering-spec-0006).

**Reviewer usage.** Always a **fresh** `claude` process. If the **consumer
project** defines a reviewer sub-agent (`.claude/agents/ai-reviewer.md` is
present) **and** `claude --help` advertises `--agent`, it runs with
`--agent ai-reviewer --print --dangerously-skip-permissions`; otherwise it runs
with `--print --dangerously-skip-permissions`. This flag choice is made by
*inspecting* `claude --help`, never by guessing.

> **Standalone SpecRelay does not ship `.claude/agents/ai-reviewer.md`.** That
> file belongs to the *consumer project*, not to the SpecRelay engine. SpecRelay
> ships it only as a **template** at `templates/claude/agents/ai-reviewer.md`.
> `specrelay init` copies that template into a project's
> `.claude/agents/ai-reviewer.md` when the reviewer provider is `claude` or
> `claude-subagent` (never overwriting an existing file); otherwise copy it
> manually. When the file is absent the Claude reviewer still works — it simply
> falls back to a plain `claude --print` reviewer using the same prompt, and
> `specrelay doctor` reports the sub-agent as not configured. See
> [Installation](installation.md) for the consumer-project setup. When semantic events are
available, the same `--verbose --output-format stream-json` flags are added
(e.g.
`claude --agent ai-reviewer --print --verbose --output-format stream-json --dangerously-skip-permissions "<prompt>"`),
raw events are persisted to `20-reviewer-events.jsonl`, and the extracted final
text is written to `15-reviewer-stdout.txt`. In both modes the live copy goes to
fd 2, so this adapter's own stdout stays reserved for the decision.

**Reviewer decision extraction.** After a successful (exit 0) reviewer run, the
adapter reads `15-reviewer-stdout.txt` and looks for an explicit marker,
anchored at end of line. This works identically in both modes because
`15-reviewer-stdout.txt` always holds human-readable text (the raw provider
stream in generic mode, the extracted final assistant text in semantic mode) —
**never** raw JSON, so the machine-readable decision channel is never polluted
by the live event rendering:

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
dispatches to the same `claude` reviewer implementation described above; it is
kept as **legacy shorthand**, not the preferred new form. Internally it
normalizes to the explicit three-key form **`provider: claude`, `agent:
ai-reviewer`, `model: provider-default`** (spec 0009); that normalized metadata
is what `doctor` reports and what the runtime evidence records. It is fully
backward compatible — existing configs using `provider: claude-subagent` keep
working unchanged — but new configs should prefer the explicit form. It is
truthfully just the `claude` reviewer: it uses `--agent ai-reviewer` **only**
when the project ships `.claude/agents/ai-reviewer.md` and the CLI advertises
`--agent`, and otherwise falls back to a plain `claude --print` reviewer. There
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

When the **reviewer** provider is `claude` or `claude-subagent`, `doctor` also
reports whether the `ai-reviewer` sub-agent is configured: an informational line
when `.claude/agents/ai-reviewer.md` is present, or a non-failing **warning**
when it is absent (the reviewer falls back to a plain `claude` reviewer). This
makes `claude-subagent` honest — it never silently pretends a sub-agent that the
project has not provided.

`doctor` also reports the **effective, normalized role configuration** (spec
0009) as two informational lines — for example:

```
Executor role: provider=claude model=provider-default agent=none
Reviewer role: provider=claude model=claude-sonnet-4 agent=ai-reviewer
```

These reflect the resolved provider/model/agent after env overrides, config, and
legacy `claude-subagent` normalization. If an explicit model is configured for a
Claude role but the installed CLI does not advertise a `--model` flag, `doctor`
reports that clearly (the run would fail rather than silently ignore the model).

When either role uses a Claude provider, `doctor` also prints an informational
line reporting whether **semantic live events** are available (python3 +
renderer present, or disabled via `SPECRELAY_SEMANTIC_EVENTS=0`). This is never
a failing check — the generic streaming fallback always works.

Failing mandatory checks make `doctor` exit non-zero.

## Adapter capability summary (section 30)

| Adapter | Required executable | Detection method | Invocation contract | Output handling | Structured-event capability | Failure semantics |
|---|---|---|---|---|---|---|
| `fake` | none | always available | scripted per round via optional plan files (`SPECRELAY_FAKE_EXECUTOR_PLAN` / `SPECRELAY_FAKE_REVIEWER_PLAN`); no real process | writes required numbered task files + `12`/`13` (exec) or `09`/`10`/`11` + `15`/`16` (review); reviewer prints `ACCEPT`/`REQUEST_CHANGES` per plan `decision` | none (fixed text) | plan `exit=N` returns that code; reviewer non-zero = no decision, state unchanged |
| `claude` | `claude` CLI (`${SPECRELAY_CLAUDE_BIN:-claude}`) | `command -v "$bin"` on `PATH`; `doctor` reports the same | executor: `claude --print [--verbose --output-format stream-json] --dangerously-skip-permissions`; reviewer: fresh process, `--agent ai-reviewer` when advertised + repo agent present, same optional stream-json flags | generic mode: raw streams captured to `12`/`13` (exec) or `15`/`16` (review); semantic mode: raw events to `19`/`20`, extracted final text to `12`/`15`; required task files written; decision from `DECISION: ACCEPT`/`DECISION: REQUEST_CHANGES` marker in the extracted reviewer text | semantic live events via `--output-format stream-json` when the CLI advertises it (spec 0006), rendered by `py/render_agent_events.py`; honest fallback to generic streaming otherwise | missing binary or CLI non-zero → return non-zero; reviewer with no `DECISION:` marker → non-zero, no decision inferred |
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
