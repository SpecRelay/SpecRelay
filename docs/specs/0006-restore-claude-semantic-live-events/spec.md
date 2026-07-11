# 0006 — Restore Claude semantic live events
- **Status:** Draft
- **Spec number:** 0006
- **Spec path:** `docs/specs/0006-restore-claude-semantic-live-events/spec.md`

## Goal

Restore the original workflow's **semantic Claude live terminal behavior** in
standalone SpecRelay. Real Claude executor/reviewer runs must show meaningful,
human-readable per-step activity live while the provider works, while still
preserving durable evidence and correct exit-code / decision handling.

## Problem

Spec 0003 added generic stdout/stderr streaming through
`specrelay::provider::run_streamed`. That works for the fake provider and any
provider that emits line output. But a real Claude run uses:

```
claude --print --dangerously-skip-permissions "<prompt>"
```

and that mode emits almost nothing while it works, so the generic layer shows a
silent terminal for minutes and the numbered stdout evidence stays empty during
the run. This is a regression from the original workflow, where Claude live
output was provided by **semantic live agent events** using Claude Code's
`--output-format stream-json` mode: meaningful live events were rendered while
durable evidence was preserved.

## Scope

1. For Claude **executor** runs, use semantic event streaming when available:
   `claude --print --verbose --output-format stream-json --dangerously-skip-permissions "<prompt>"`.
2. For Claude **reviewer** runs, use the same semantic mode, preserving the
   reviewer subagent behavior when available
   (`claude --agent ai-reviewer --print --verbose --output-format stream-json --dangerously-skip-permissions "<prompt>"`),
   falling back to a plain reviewer invocation when `--agent` is unsupported.
3. Render the semantic events live to the operator terminal in a human-readable
   way (plain text, no color required), scoped by role/provider.
4. Preserve durable evidence:
   - the raw JSONL event stream is saved to a task events file
     (`19-executor-events.jsonl` / `20-reviewer-events.jsonl`);
   - rendered live output is terminal-only (fd 2);
   - the final assistant text is extracted into the existing numbered stdout
     evidence files (`12-executor-stdout.txt` / `15-reviewer-stdout.txt`);
   - stderr is still captured (`13`/`16`).
5. The reviewer machine-readable decision channel must not be polluted by live
   event rendering; decision extraction must remain correct.
6. Fallback is **pre-launch only**: when semantic mode is disabled, unavailable
   (python3/renderer missing), or the CLI does not advertise the stream-json
   flags (detected from `claude --help` before launch), use the generic
   spec-0003 streaming path rather than breaking the run. Once a semantic Claude
   process has launched, its exit code is authoritative — SpecRelay does **not**
   automatically retry a failed semantic run as a generic run, because that
   could duplicate provider side effects or rerun a partially completed agent
   task. A renderer failure may warn but never masks or overrides the provider
   exit code.
7. Do not fake semantic events. If Claude does not emit stream-json, fall back
   honestly (pre-launch, per item 6).
8. Do not remove generic `run_streamed`; keep it for the fake provider and the
   fallback paths.
9. Heartbeat is only a possible future fallback; the main goal is restoring the
   real semantic events. Heartbeat is not implemented in this task.
10. Do not change the origin host repository.

## Design

- **Renderer:** `lib/specrelay/py/render_agent_events.py` — a standalone,
  provider-neutral renderer (next to `state_lib.py`) that reads a JSONL event
  stream and writes concise human-readable lines, extracts the final assistant
  text (`--final-stdout`), and persists the raw stream (`--raw-events`). It
  never renders private reasoning and references no host paths.
- **Transport:** `specrelay::provider::run_agent_events` in
  `providers/provider.sh` — parallel to `run_streamed`. It pipes the provider's
  stdout through the renderer (rendered lines → fd 2), captures stderr live to a
  file, and returns the provider's real exit code via `PIPESTATUS[0]`.
- **Adapter:** `providers/claude.sh` detects stream-json capability from
  `claude --help` (never guessed) and, when enabled and available, runs semantic
  mode; otherwise it uses the generic spec-0003 path. Core `workflow.sh` is
  unchanged.
- **Controls:** `SPECRELAY_SEMANTIC_EVENTS=0` forces the generic path;
  `SPECRELAY_PYTHON` selects the interpreter; `SPECRELAY_CLAUDE_BIN` selects the
  binary. `specrelay doctor` reports availability informationally.

## Acceptance criteria

1. Claude executor/reviewer runs use semantic stream-json when the CLI
   advertises it; live human-readable activity appears on the terminal.
2. Raw events are persisted to `19`/`20`; the final assistant text is extracted
   to `12`/`15`; stderr is captured to `13`/`16`.
3. The reviewer `DECISION:` marker is parsed correctly from the extracted text,
   and the decision channel is never polluted by rendered lines.
4. Provider exit codes are preserved, including failures; a renderer failure
   never masks a provider failure or fails a valid run.
5. Fallback to generic streaming works when semantic mode is
   disabled/unavailable, and semantic events are never faked.
6. `scripts/test` exits 0; `bin/specrelay doctor` passes (documented info lines
   only); `bin/specrelay version` reports the expected version.
7. Deterministic tests cover: (a) rendering stream-json fixtures into live
   lines; (b) final-text extraction into the stdout evidence file; (c) reviewer
   decision parsing from extracted text; (d) fallback generic streaming.
8. Docs explain both layers (generic spec-0003 streaming; semantic spec-0006
   rendering).

## Non-goals

- Implementing a heartbeat/idle-tick layer (future work only).
- Adding a Codex provider adapter (the renderer keeps a Codex adapter for
  neutrality, but Codex is not a shipped SpecRelay provider).
- Changing the origin host repository, the license, or any release/publication.
- Redesigning the provider abstraction or removing evidence files.

## Human decisions

- Semantic events are **on by default** when available, with an explicit opt-out
  (`SPECRELAY_SEMANTIC_EVENTS=0`), mirroring the spec-0003 "live by default"
  decision.
- Output is **plain text** (no color), consistent with spec 0003.
- Real Claude runs are verified manually / at fixture level; automated tests use
  deterministic fixtures and a fake `claude` binary, never a real provider.
