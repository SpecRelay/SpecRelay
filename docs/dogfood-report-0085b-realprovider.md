# SpecRelay Real-Provider Dogfood Report (SDD 0085B)

Status: durable evidence capture for SDD 0085B, Section 9 (§9.4, §9.5, §9.6, §9.7).

## What this report is (and is not)

This report records **real-provider** SpecRelay dogfood runs — executor provider
`claude`, reviewer provider `claude-subagent` (see `.specrelay/config.yml`
`roles.executor.provider` / `roles.reviewer.provider`) — driven under the safe
**M1** orchestration model (foreground, synchronous, one scenario at a time, by
the outer runner/operator, never by a non-interactive `claude --print` executor
spawning background nested tasks). It references only **real** task ids, real
final states, real independent reviewer decisions, and real on-disk evidence
paths.

It is deliberately a **separate file** from the older
`tools/specrelay/docs/dogfood-report.md`. That older report is the SDD 0085
**fake-provider** dogfood report; it is honestly labelled as fake-provider and is
preserved unchanged as SDD 0085 migration evidence (spec 0085B §6). A
fake/deterministic-provider run must never be presented as satisfying a
real-provider acceptance criterion (§4.5, §9.6); this file is the real-provider
evidence, and it does not overwrite or restate the fake-provider one.

`.ai-runs/` is gitignored, so the task directories cited below are working-tree
evidence, not committed history (spec §6.5). Nothing here was committed; human
final review/commit of each dogfood artifact remains required (§5.4, §9.8).

---

## Scenario A (§9.4) — accepted first round

**Delivered evidence: task `9101a-scenario-a-troubleshooting-doc`, adopted as the
Scenario-A run per spec §6.** (A fresh `9201a` spec was authored at
`docs/sdd/9201a-scenario-a-troubleshooting-doc/spec.md`, but no fresh `9201a`
task was run; §6 explicitly permits reusing the successful `9101a` run as
Scenario-A evidence, which is done here rather than misrepresenting a re-run.)

| Field | Value (real, from `state.json`) |
|---|---|
| task_id | `9101a-scenario-a-troubleshooting-doc` |
| engine | `specrelay` |
| base_commit | `7b4fc15cbcbb7dc19906993b66a211c4c767fff8` |
| spec_source | `tools/specrelay/test/fixtures/dogfood-0085-realprovider/9101-scenario-a-troubleshooting-doc/spec.md` |
| created / approved | `2026-07-11T10:01:11Z` / `10:01:12Z` (`approved_by: human`) |
| claimed_by | `specrelay-runner` (`10:01:43Z`) |
| iteration | `1` (accepted first round) |
| reviewer_provider | `claude-subagent` |
| review_result | `accepted` (`reviewed_at 10:07:19Z`, `reviewed_by reviewer-agent`) |
| final state | `READY_FOR_HUMAN_REVIEW` |

- **Deliverable artifact:** `tools/specrelay/docs/troubleshooting.md` (one new
  operator-facing doc; three real operational issues each with Symptom +
  Resolution, grounded in `lock.sh`, `contextplus.sh`, `git_guard.sh`). It was
  produced inside the task run and was **not committed**; because `.ai-runs/` is
  gitignored and the run was never committed, the file is not on the current
  working tree. Its content and line-by-line source verification are preserved in
  the reviewer notes below and in `06-git-diff.patch`.
- **Reviewer decision (independent, real `claude-subagent`): ACCEPT.** The
  reviewer verified the working tree (`git status --short`), confirmed the
  fixture dir was pre-existing (mtimes), and checked the doc line-by-line against
  `lock.sh` / `contextplus.sh` / `git_guard.sh`. No product code touched; no
  commit.
- **Evidence paths (all real):**
  - `.ai-runs/tasks/9101a-scenario-a-troubleshooting-doc/state.json`
  - `.../09-consultant-review.md` and `.../15-reviewer-stdout.txt` (ACCEPT)
  - `.../03-executor-log.md`, `.../07-tests.txt`, `.../08-executor-summary.md`
  - `.../06-git-diff.patch`, `.../10-business-summary.md`
  - `.../iterations/`

**§9.4 satisfied:** real executor + real reviewer, accepted first round, reached
`READY_FOR_HUMAN_REVIEW`, durable evidence present.

---

## Scenario B (§9.5) — request-changes → rework → accept

**Delivered evidence: task `9202b-scenario-b-operator-recovery-doc`** (fresh,
non-colliding id per §5.3; SpecRelay-created, `engine: specrelay`).

| Field | Value (real, from `state.json`) |
|---|---|
| task_id | `9202b-scenario-b-operator-recovery-doc` |
| engine | `specrelay` |
| base_commit | `7b4fc15cbcbb7dc19906993b66a211c4c767fff8` |
| spec_source | `docs/sdd/9202b-scenario-b-operator-recovery-doc/spec.md` |
| created / approved | `2026-07-11T11:37:11Z` (`approved_by: human`) |
| reviewer_provider | `claude-subagent` |
| final iteration | `2` |
| final state | `READY_FOR_HUMAN_REVIEW` |

**Round 1 — reviewer genuinely requested changes (merit-based, not scripted):**
- `changes_requested_by: reviewer-agent` at `2026-07-11T11:45:14Z`.
- `changes_requested_reason`: *"Runbook references a non-existent
  troubleshooting.md as an existing companion doc; resolve the dangling
  reference."*
- The reviewer's own notes
  (`.../iterations/round-1/09-consultant-review.md`) show it verified the
  runbook against the real CLI (`cli.sh`, `transitions.sh`, `lock.sh`),
  confirmed scope was clean, then flagged exactly one real accuracy defect: the
  header cross-reference presented `troubleshooting.md` as an existing companion
  doc when it does not exist in `tools/specrelay/docs/`. This is an independent,
  merit-based finding — not a forced/scripted fake-provider plan.

**Requeue → Round 2 — real rework accepted:**
- `requeued_at 11:59:20Z` (`requeued_by: specrelay-orchestrator`), `iteration`
  incremented `1 → 2`; round-1 artifacts archived to
  `.../iterations/round-1/` and the pre-requeue prompt preserved as
  `02-executor-prompt.before-requeue-20260711T115920Z.md` (round-1 evidence not
  overwritten).
- Executor reworked, submitted `12:02:25Z`.
- **Reviewer decision (independent, real `claude-subagent`, fresh context):
  ACCEPT** at `12:05:02Z` (`review_result: accepted`). The round-2 notes
  (`.../iterations/round-2/09-consultant-review.md`) confirm the fix
  (`grep -c "troubleshooting.md" operator-recovery.md → 0`), re-verify the
  runbook against `cli.sh`/`lock.sh`/`transitions.sh` (with line references),
  and re-run `recover_test.sh` (28 tests, 0 failed). Nothing else was disturbed.
- **Deliverable artifact:** `tools/specrelay/docs/operator-recovery.md` (an
  operator runbook for interrupted-task recovery). It was checkpoint-committed by
  the human in `50ea0eb2` ("Checkpoint SDD 9202b operator recovery dogfood
  evidence") and the working-tree copy is identical to `HEAD`; the SpecRelay task
  itself reached `READY_FOR_HUMAN_REVIEW` and still awaits human final review.
- **Evidence paths (all real):**
  - `.ai-runs/tasks/9202b-scenario-b-operator-recovery-doc/state.json`
  - `.../iterations/round-1/09-consultant-review.md` (REQUEST_CHANGES)
  - `.../iterations/round-2/09-consultant-review.md` (ACCEPT)
  - `.../09-consultant-review.md`, `.../15-reviewer-stdout.txt`
  - `.../03-executor-log.md`, `.../07-tests.txt`, `.../08-executor-summary.md`
  - `.../06-git-diff.patch`, `.../02-executor-prompt.before-requeue-*.md`

**§9.5 satisfied:** real executor + real reviewer; the reviewer genuinely
requested changes once (its own independent judgment), a real rework round was
accepted, and the task reached `READY_FOR_HUMAN_REVIEW` after a real
request-changes → rework → accept cycle.

---

## Residue recovery (§9.7) — no task left orphaned in EXECUTOR_RUNNING

All resolutions used SpecRelay-native, audited commands or an explicit,
documented operator action. No `state.json` was hand-edited; nothing was silently
`rm`'d (§6.2, §10.4).

| Task | Engine | Prior state | Action | Final state |
|---|---|---|---|---|
| `9101-scenario-a-troubleshooting-doc` | `specrelay` | `EXECUTOR_RUNNING` (orphaned, stale lock) | `specrelay task recover` (audited) | `READY_FOR_EXECUTOR` |
| `0085-add-specrelay-compatibility-shims-and-dogfood-real-workflows` | *(none — legacy-born)* | `EXECUTOR_RUNNING` | explicit operator `specrelay task block` | `BLOCKED` |
| `zzz-test-0038-sdd-89021-1` | `specrelay` | `EXECUTOR_RUNNING` (stale test fixture, dead owner) | `specrelay task block` (audited) | `BLOCKED` |

- **`9101`** was recovered `EXECUTOR_RUNNING → READY_FOR_EXECUTOR` at
  `2026-07-11T11:36:21Z` by `specrelay-recover`, with the audited metadata
  `recovered_at` / `recovered_by` / `recovered_from_state` /
  `recovery_reason` (*"orphaned by interrupted 0085 dogfood; recovered per SDD
  0085B §9.7"*). Existing evidence files preserved untouched (§3.4, §3.5).
- **`0085`** is legacy-born (no `engine` field), so SpecRelay's `_require_owned`
  guard refuses it and the legacy engine is frozen. It was resolved by an
  explicit, documented operator action — `specrelay task block` (blocked at
  `2026-07-11T12:18:52Z` by `local-runner`) with the reason recorded in
  `state.json` (superseded by 0085B; historical evidence, not continued). This is
  the "explicit, documented operator action" §9.7/§6.2 requires, not a silent
  edit/delete.
- **`zzz-test-0038-sdd-89021-1`** is a stale test-harness fixture (spec §6
  stale-lock residue) left in `EXECUTOR_RUNNING` by an interrupted test run on
  2026-07-10 with a **dead** same-host lock owner (pid 89067, verified via
  `kill -0`). Although the spec lists it under stale *locks* (auto-reclaimed) and
  this prompt named only `0085`/`9101`, by the plain reading of §9.7 it was a
  task orphaned in `EXECUTOR_RUNNING`; it was resolved to `BLOCKED` via the
  audited `specrelay task block` (`2026-07-11T12:30:42Z`) for completeness and
  documented here transparently. It is not real workflow/dogfood work.

**Final orphan scan:** the only task in `EXECUTOR_RUNNING` is
`0085B-finalize-specrelay-as-the-only-active-workflow-engine` — the currently
*active* task, which the SpecRelay orchestrator transitions after the executor
process exits. It is not orphaned.

**§9.7 satisfied:** no interrupted task is left orphaned in `EXECUTOR_RUNNING`;
each was recovered or explicitly BLOCKED with a reason.

---

## Real-provider confirmation (§9.6)

- Both scenarios used the real configured providers: executor `claude`, reviewer
  `claude-subagent` (`reviewer_provider: claude-subagent` in each `state.json`).
- The reviewer decisions are genuine independent judgments: fresh-context reviews
  that verify claims against source with concrete line references, re-run tests
  themselves, and — in Scenario B round 1 — raise a real merit-based defect that
  forced a rework. This is materially different from the SDD 0085
  fake-provider report's `SPECRELAY_FAKE_REVIEWER_PLAN`-scripted decision.
- No fake/deterministic-provider run is presented here as real-provider evidence.
</content>
</invoke>
