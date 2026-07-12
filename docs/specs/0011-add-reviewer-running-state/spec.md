# Reviewer Running State

- Spec: 0011
- Status: Draft

---

# Summary

Introduce a dedicated `REVIEWER_RUNNING` task state for automated reviewers.

Currently an automated reviewer starts executing while the task still appears in
`READY_FOR_REVIEW`. This makes it impossible to distinguish between:

- waiting for a reviewer
- currently being reviewed

This specification introduces an explicit running state for automated reviewers
while preserving the existing behavior for manual reviewers.

---

# Problem

Current automated flow:

```
READY_FOR_EXECUTOR
→ EXECUTOR_RUNNING
→ READY_FOR_REVIEW
(reviewer starts)
→ READY_FOR_HUMAN_REVIEW
```

During review execution the task still reports:

```
READY_FOR_REVIEW
```

which is misleading because the review has already started.

---

# Goals

- Make reviewer execution visible.
- Distinguish waiting from running.
- Preserve current manual-review workflow.
- Keep resume semantics unchanged.

---

# Non Goals

This specification does not:

- introduce multiple reviewer stages
- support parallel reviewers
- redesign the review pipeline
- change review decisions

---

# New State

```
REVIEWER_RUNNING
```

Meaning:

An automated reviewer currently owns the task and review execution is in progress.

---

# Updated State Machine

Automated reviewer:

```
READY_FOR_EXECUTOR
        │
        ▼
EXECUTOR_RUNNING
        │
        ▼
READY_FOR_REVIEW
        │
        ▼
REVIEWER_RUNNING
        │
        ├──────────────► READY_FOR_HUMAN_REVIEW
        │
        └──────────────► CHANGES_REQUESTED
```

Manual reviewer:

```
READY_FOR_EXECUTOR
        │
        ▼
EXECUTOR_RUNNING
        │
        ▼
READY_FOR_REVIEW
```

No change.

---

# Transition Rules

Allowed:

```
READY_FOR_REVIEW
    → REVIEWER_RUNNING

REVIEWER_RUNNING
    → READY_FOR_HUMAN_REVIEW

REVIEWER_RUNNING
    → CHANGES_REQUESTED
```

Forbidden:

```
READY_FOR_REVIEW
    → READY_FOR_HUMAN_REVIEW

READY_FOR_REVIEW
    → CHANGES_REQUESTED

REVIEWER_RUNNING
    → READY_FOR_EXECUTOR

REVIEWER_RUNNING
    → EXECUTOR_RUNNING
```

---

# Resume Behavior

If resume encounters:

```
READY_FOR_REVIEW
```

and reviewer type is:

```
manual
```

stop exactly as today.

If reviewer type is:

```
automatic
```

then:

1. update state to

```
REVIEWER_RUNNING
```

2. execute reviewer

3. write review result

4. transition to

```
READY_FOR_HUMAN_REVIEW
```

or

```
CHANGES_REQUESTED
```

---

# Failure Handling

If reviewer crashes after entering
`REVIEWER_RUNNING`

the task remains in

```
REVIEWER_RUNNING
```

A later resume should continue from that state.

No rollback occurs.

---

# CLI

Status output should display:

```
State:
    REVIEWER_RUNNING
```

instead of

```
READY_FOR_REVIEW
```

while an automated review is active.

---

# Backward Compatibility

Existing task files without
`REVIEWER_RUNNING`

remain valid.

Only new executions may enter this state.

No migration is required.

---

# Acceptance Criteria

- automated reviewers enter `REVIEWER_RUNNING`
- manual reviewers remain at `READY_FOR_REVIEW`
- reviewer completion exits `REVIEWER_RUNNING`
- rejected reviews transition to `CHANGES_REQUESTED`
- accepted reviews transition to `READY_FOR_HUMAN_REVIEW`
- interrupted reviews remain in `REVIEWER_RUNNING`
- resume continues correctly from `REVIEWER_RUNNING`
- all existing tests remain green

---

# Verification

Run:

```
scripts/test
```

```
scripts/smoke
```

```
bin/specrelay doctor
```

```
bin/specrelay version
```

Verify automated review shows:

```
READY_FOR_REVIEW
→ REVIEWER_RUNNING
→ READY_FOR_HUMAN_REVIEW
```

Verify manual review remains:

```
READY_FOR_REVIEW
```