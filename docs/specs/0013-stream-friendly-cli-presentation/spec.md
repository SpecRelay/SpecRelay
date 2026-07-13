# Stream-Friendly CLI Presentation

- Spec: 0013
- Status: Draft

---

# Summary

Redesign SpecRelay's CLI presentation while preserving its current streaming
execution model.

The objective is **not** to build a dashboard or terminal UI.

Instead, improve readability using structured sections, transition cards,
consistent spacing and Unicode box drawing while keeping the output a normal
append-only terminal stream.

Every emitted line must remain visible, scrollable, copyable and redirectable.

---

# Motivation

Current output is technically correct but visually flat.

Large executions become difficult to scan because transitions, role boundaries,
provider execution and final summaries all have nearly identical visual weight.

Users should immediately recognize:

- where a phase starts
- when a transition happens
- which role is currently executing
- when a provider finishes
- the final task result

without losing the simplicity of a normal terminal log.

---

# Core Principle

SpecRelay is a **streaming CLI**, not a dashboard.

This specification explicitly rejects:

- live dashboards
- split panes
- alternate terminal screens
- cursor movement
- screen redraw
- hidden logs
- replacing previous output
- collapsing old output

Every line written during execution must remain permanently visible in terminal
scrollback.

---

# Output Contract

The following must remain true:

- output is append-only
- nothing is erased
- nothing is overwritten
- nothing disappears
- the complete execution can be copied afterwards
- piping and redirecting preserve identical information

The following must work exactly as today:

```bash
bin/specrelay run ...
```

```bash
bin/specrelay run ... | tee run.log
```

```bash
bin/specrelay run ... > run.log 2>&1
```

---

# Visual Hierarchy

Instead of a flat stream, output should have four visual levels.

## Level 1

Major execution sections.

Example:

```text
╭─ SpecRelay Task ─────────────────────────────╮
│ Task ...                                     │
╰──────────────────────────────────────────────╯
```

---

## Level 2

Transitions.

Example:

```text
╭─ Transition ─────────────────────────────────╮
│ READY_FOR_REVIEW ─────▶ REVIEWER_RUNNING     │
╰──────────────────────────────────────────────╯
```

Transitions should immediately stand out while remaining compact.

---

## Level 3

Role execution headers.

Example:

```text
╭─ Executor · Round 1 ─────────────────────────╮
│ Provider  claude                            │
│ Model     claude-opus-4-8                   │
│ Agent     none                              │
╰──────────────────────────────────────────────╯
```

and

```text
╭─ Reviewer · Round 1 ─────────────────────────╮
│ Provider  claude-subagent                   │
│ Model     claude-opus-4-8                   │
│ Agent     ai-reviewer                       │
╰──────────────────────────────────────────────╯
```

---

## Level 4

Normal provider logs.

Provider output continues exactly as today.

Example:

```text
[executor:claude] Read ...
[executor:claude] Bash ...
[executor:claude] Edit ...
```

No summarisation replaces provider output.

---

# Transition Presentation

Current:

```text
Transitioned:
READY_FOR_EXECUTOR -> EXECUTOR_RUNNING
```

Desired:

```text
╭─ Transition ─────────────────────────────────╮
│ READY_FOR_EXECUTOR ─────▶ EXECUTOR_RUNNING   │
╰──────────────────────────────────────────────╯
```

Requirements:

- source state visible
- destination state visible
- copy/paste friendly
- no animation
- width adapts automatically
- readable on 80-column terminals

---

# Result Cards

Executor completion:

```text
╭─ Executor Result ────────────────────────────╮
│ SUCCESS                                      │
│ Duration ...                                 │
╰──────────────────────────────────────────────╯
```

Reviewer completion:

```text
╭─ Reviewer Result ────────────────────────────╮
│ ACCEPT                                       │
╰──────────────────────────────────────────────╯
```

Final task completion:

```text
╭─ SpecRelay Result ───────────────────────────╮
│ READY_FOR_HUMAN_REVIEW                       │
╰──────────────────────────────────────────────╯
```

---

# Color Usage

Color should improve readability only.

Information must never depend on color.

Suggested semantics:

- green = completed
- blue = running
- magenta = review
- yellow = warning/manual
- red = failure

When colors are disabled the hierarchy must remain obvious.

---

# Stream Integrity

The implementation must never emit:

- cursor-up sequences
- clear-screen sequences
- alternate-screen mode
- terminal redraw
- progress bars that overwrite themselves
- spinners
- hidden sections

Every emitted line must remain available afterwards.

---

# Backward Compatibility

Existing log parsers should continue to work.

State names, provider names and important messages must remain present as plain
text.

Only presentation changes.

No execution semantics change.

---

# Acceptance Criteria

- execution remains append-only
- full scrollback preserved
- complete output remains copyable
- transition cards implemented
- executor/reviewer cards implemented
- final summary card implemented
- provider logs remain unchanged
- no dashboard behaviour
- no cursor movement
- no screen redraw
- redirected output preserved
- existing tests remain green

---

# Verification

Run:

```bash
scripts/test
```

```bash
scripts/smoke
```

```bash
bin/specrelay doctor
```

```bash
bin/specrelay version
```

Verify manually:

- terminal scrollback contains the complete execution
- selecting all terminal output copies every line
- redirecting to a file produces a complete execution log
- no information disappears during execution