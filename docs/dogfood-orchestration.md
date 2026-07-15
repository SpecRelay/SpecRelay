# SpecRelay Dogfood Orchestration Model (SDD 0085B)

> **Historical document.** This document describes a historical dogfood
> orchestration exercise (SDD 0085B) that defined safe orchestration models
> for the former in-host SpecRelay architecture (`tools/specrelay/` incubated
> inside a host repository, `.ai/scripts/` compatibility shims, `.ai-runs/`
> task runtime). That architecture is no longer a supported current product
> surface. See README.md and docs/architecture.md for the current standalone
> architecture (`bin/specrelay` / installed `specrelay`,
> `.specrelay/config.yml`, `.specrelay-runs/`).

This document defines the **safe** way to drive real-provider dogfood scenarios
through SpecRelay, and the **prohibited** pattern that broke SDD 0085. It is
mandatory reading before running any real-provider dogfood task.

## The prohibited pattern (never do this)

An executor agent running under **non-interactive `claude --print`** must
**not** spawn nested, long-running, real-provider dogfood tasks *in the
background* and "wait for a notification."

That execution context cannot be re-invoked by a background completion event, so
the `claude --print` process simply exits — leaving its own contract files empty
and **orphaning the child task in `EXECUTOR_RUNNING`**. This is the exact root
cause of the orphaned `9101-scenario-a-troubleshooting-doc` during SDD 0085.

Concretely, the following are forbidden inside an executor agent:

- `specrelay run <spec> &` (fire-and-forget background launch),
- `nohup specrelay run <spec> &`, `disown`, or any detached child,
- any "launch a nested task, then wait to be notified" flow.

## The safe models

A dogfood scenario must be driven by one of these models. **SDD 0085B adopts
(M1) as primary and (M3) as the documentation posture.**

- **(M1) Foreground orchestration by the outer runner/operator** — *adopted,
  primary.* The human/operator (not the executor agent) runs
  `tools/specrelay/bin/specrelay run <spec>` **synchronously in the foreground**,
  blocking until the task reaches a terminal state, **one scenario at a time**.
  This is the model already proven to work: `9101a-scenario-a-troubleshooting-doc`
  reached `READY_FOR_HUMAN_REVIEW` this way.
- **(M2) SpecRelay-native synchronous, state-aware subtask orchestration** — if
  SpecRelay itself ever launches subtasks, it must do so **synchronously** and
  track each subtask's ownership (`engine`), `state.json`, and lock. No
  fire-and-forget background launch. (Not used by 0085B.)
- **(M3) Dogfood tasks are separate human/orchestrator-driven tasks** — *adopted,
  documentation posture.* Each dogfood scenario is its own SpecRelay-native task
  run **outside** the executor agent of the spec that defines it. The executor
  of the *defining* spec (e.g. this SDD 0085B task) never runs the scenarios
  itself.

### Guardrails (SDD 0085B, section 4.2–4.6)

- **No untracked background nested tasks.** Every launched real-provider task
  must have a tracked task id, a `state.json` (with `engine: "specrelay"`), and
  a lock. (Test: `dogfood_orchestration_test.sh`.)
- **No orphaned `EXECUTOR_RUNNING`.** If a dogfood run is interrupted, the
  supported remedy is `specrelay task recover <task-ref> --reason "…"` (SDD
  0085B, section 3) — never a silent `rm` or manual `state.json` edit.
- **Evidence must be real.** Dogfood evidence references real task IDs, final
  states, reviewer decisions, and evidence paths — not narrative claims.
- **Fake/deterministic providers are for unit tests only.** A fake-provider run
  must **never** be presented as satisfying a real-provider dogfood acceptance
  criterion. (This is the specific failure the SDD 0085 reviewer caught.)
- **Run sequentially.** Because dogfood executors mutate the host working tree,
  scenarios run one at a time (or each in an isolated working area) to avoid
  working-tree races.

## The fresh SpecRelay-native dogfood scenarios (SDD 0085B, section 5)

Both scenarios are **SpecRelay-created from the start** (so `state.json` has
`engine: "specrelay"`), neither legacy-born, neither requiring legacy tooling.
They use **fresh task IDs** that do not collide with the historical interrupted
tasks (`9101`, `9102`) whose dirs/locks may still exist.

Each scenario produces a **genuinely useful, harmless, reviewable** repository
artifact (a real SpecRelay operator doc), driven per model (M1).

| Scenario | Task id (fresh) | Spec | Artifact produced | Acceptance shape |
|---|---|---|---|---|
| **A** | `9201a-scenario-a-troubleshooting-doc` | `docs/sdd/9201a-scenario-a-troubleshooting-doc/spec.md` | `tools/specrelay/docs/troubleshooting.md` | real executor + real reviewer, **accepted first round** → `READY_FOR_HUMAN_REVIEW` |
| **B** | `9202b-scenario-b-operator-recovery-doc` | `docs/sdd/9202b-scenario-b-operator-recovery-doc/spec.md` | `tools/specrelay/docs/operator-recovery.md` | real executor + real reviewer; reviewer **genuinely requests changes once**, then a **real rework round is accepted** → `READY_FOR_HUMAN_REVIEW` |

The reviewer's decision in each scenario is its own **independent judgment**,
never scripted. Dogfood tasks reach their **own** `READY_FOR_HUMAN_REVIEW`; the
orchestrator must **not** self-accept them or transition them to human review by
fiat. Human final review of each dogfood artifact is still required before any
commit.

### How to run them (operator, model M1)

Run each **synchronously, in the foreground, one at a time**:

```
tools/specrelay/bin/specrelay run docs/sdd/9201a-scenario-a-troubleshooting-doc/spec.md
# review the artifact + reviewer decision, then:
tools/specrelay/bin/specrelay run docs/sdd/9202b-scenario-b-operator-recovery-doc/spec.md
```

If either run is interrupted and left in `EXECUTOR_RUNNING`:

```
tools/specrelay/bin/specrelay task recover <task-ref> --reason "interrupted dogfood run"
```

### Execution status and honesty note (SDD 0085B, sections 4.4–4.5, 12)

The **defining** task for these scenarios is SDD 0085B, whose executor runs
under non-interactive `claude --print`. Per the prohibited-pattern rule above,
that executor **must not** run these real-provider scenarios itself (doing so is
exactly the background-nested-dogfood failure this spec forbids). Therefore:

- The scenario **specs and this orchestration model are the deliverable of the
  0085B executor**; the **real-provider execution is an operator-driven step
  (M1)**, run outside the executor agent.
- Prior successful evidence already exists for the Scenario A *shape*:
  `9101a-scenario-a-troubleshooting-doc` reached `READY_FOR_HUMAN_REVIEW` in one
  round with a real executor and a real, independent reviewer (see
  `.ai-runs/tasks/9101a-scenario-a-troubleshooting-doc/`). It may be cited as
  Scenario-A evidence or superseded by a fresh `9201a` run, at the operator's
  discretion — it must not be misrepresented.
- No fake-provider run is, or may be, presented as real-provider evidence.

When the operator completes each real-provider run, record the durable evidence
(real task id, final state, reviewer decision, evidence paths) in
`docs/dogfood-report.md`.
