# SpecRelay Current Plan

*Read time: under a minute. For the reasoning behind any of this, see
[architecture-roadmap.md](architecture-roadmap.md).*

## Current objective

**Configurable test levels and multi-service verification** (Phase 3).
Replace the single `full_test_command` string with a real policy: `changed`
/ `full` / `flexible` levels, across multiple services and checks (unit,
lint, type-check, integration, contract, smoke), run in parallel where
independent, evidence kept deterministic per service/command. This is the
next architecture milestone — **not** releasing spec 0025 (see below).

## Next objective

**UI runtime and visual verification** (Phase 4). Real app startup,
Playwright flows, screenshot capture vs. supplied expected references,
traces/video/console/network evidence, independent Reviewer verification.
Explicit `BLOCKED` — never a silent skip — when the app, flow, credentials,
or an expected reference is unavailable. One more check kind inside Phase
3's policy.

## Later objectives

In dependency order (roadmap §5):

1. **Bounded artifact repair** — a real, engine-executed `REPAIR_ARTIFACTS`. *(Phase 5)*
2. **Full artifact-layout migration** (`00-task/ … 06-telemetry/`) — last, once its real contents are known. *(Phase 6)*
3. **Reduced-touchpoint autonomous routing** — once verification/UI checks are mature. *(Phase 7)*
4. **Per-task isolated workspaces**, then **parallel task execution**. *(Phases 8–9)*
5. **Cross-task dependency/conflict coordination**. *(Phase 10)*
6. **Durable cross-task knowledge/memory** — exploratory, no design yet. *(Phase 11)*
7. **Package-manager release + additional providers** (planned); **license** blocked on a human decision (`LICENSE.TODO`). *(Phase 12)*

## Recently completed architecture milestones

- **Spec 0025 — AI Coordinator role**: implemented, reviewed, committed,
  pushed. Recommends a next action but can never perform one directly; every
  decision is validated against an engine-computed allowlist first.
  *Releasing it (`CHANGELOG`/`VERSION` bump) is a separate, later operational
  decision — not an architecture milestone.*
- **Spec 0024 — Legacy engine retirement**: SpecRelay is now the sole
  supported engine; no dual-architecture fallback to maintain.
- **Spec 0023 — Specification-bundle analysis & Jam evidence**: task input
  can be a whole directory, snapshotted immutably and resolved into one brief
  before either AI role runs.
