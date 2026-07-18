# SpecRelay — Architecture North Star

**Architecture version:** 1 · **Status:** proposed (see
[`architecture-version.yml`](architecture-version.yml))

> This is a **normative** document: it states the intended architecture, not a
> report of current code. Where intent and code differ, that is *architectural
> drift* to be resolved explicitly (see
> [ADR-0001](decisions/ADR-0001-architecture-authority-and-versioning.md)) — the
> document does not silently defer to the code, and the code is not silently
> bound by the document. This file is kept deliberately compact and stable; it
> avoids volatile implementation detail, which lives in the operational docs
> and in ADR context.

## Purpose

SpecRelay exists to make AI-driven software change **trustworthy enough to run
with decreasing human supervision, without ever trading away auditability or
the human's final word.**

Every principle and decision in this architecture layer descends from that one
sentence. When a hard choice arises — a principle appears to block a useful
feature, or two principles seem to conflict — it is resolved by asking which
option better preserves *trust that survives inspection*. That is the invariant
SpecRelay trades other things to protect.

## What SpecRelay is

SpecRelay is a **deterministic engine** that drives a written specification
through a supervised `executor → reviewer → human` workflow and produces
durable, inspectable evidence at every step. It is, at once:

- a **task state machine** — a task is files on disk moving through named
  states via named transitions; there is no hidden or session-only state;
- an **orchestrator of AI roles** — it invokes an executor, an independent
  reviewer, and (optionally) an advisory coordinator; it is the thing *around*
  the AI agents, never one of them;
- an **evidence recorder** — every step leaves plain, version-controllable
  artifacts, so a task's history can be audited long after it ran;
- a **safety boundary** — it refuses unsafe actions (self-approval without
  authorization, an incompatible resume, a claim over an unaccountable working
  tree) by code, not by convention;
- a **dependency-light CLI** — one entry point, its own bundled engine, and a
  thin project-configuration seam; it vendors nothing into the projects it
  serves and is fully testable with a deterministic non-AI provider.

Its center of gravity is fixed: **the deterministic engine is the product; the
AI providers are guests.** A version of SpecRelay in which the AI is the
authority and the engine merely assists would be a different product.

## What SpecRelay must never become

These are boundaries that define the product, not gaps awaiting a feature.
Crossing one is an amendment to this north star, argued as such — never a
routine next step.

1. It must not make the **final acceptance decision**. A successful run halts
   at the human-review handoff and goes no further on its own.
2. It must not let an AI role become the **authority over task state**. AI roles
   interpret and recommend; the deterministic engine validates and acts, and is
   the sole author of state.
3. It must not accept a **claim in place of evidence**, nor silently skip,
   fabricate, or downgrade. An unavailable prerequisite is an explicit blocked
   outcome with a recorded reason; "not recorded" is honest, a made-up value is
   not.
4. It must not **publish on its own** — commit, push, merge, deploy, or release
   to the outside world. It prepares evidence and stops; outward publication is
   a human-controlled act.
5. It must not **hardcode one AI vendor, one context tool, or one consumer's
   policy** into its core, nor **vendor itself** into the projects it serves.
6. It must not **destructively rewrite a task's recorded history**. Evolution of
   stored evidence, if ever needed, is explicit, versioned, and
   provenance-preserving — never a silent in-place rewrite.

## The central bet

Underneath everything: *every increase in what AI is allowed to decide must be
matched by an equal or greater increase in what the deterministic engine
verifies before acting on that decision.* Autonomy grows one narrowly-scoped,
reversible, independently-tested capability at a time, on a substrate that never
has to be re-trusted from scratch.

This is why the architecture scales **out** (more tasks, more providers, richer
evidence) far more readily than it scales the AI's **authority**, and why the
human gate is the last thing any future direction is allowed to touch.

## How to navigate this layer

- **[`principles.md`](principles.md)** — the durable rules, each with an honest
  status (enforced / established / target / proposed).
- **[`decisions/`](decisions/README.md)** — the consequential decisions and
  trade-offs, as ADRs.
- **[`architecture-version.yml`](architecture-version.yml)** — the version
  contract and the future-spec `architecture_version` requirement.

For *as-built* current behavior, see the operational docs
(`docs/architecture.md`, `docs/task-lifecycle.md`, `docs/providers.md`,
`docs/verification-and-timeline.md`, `docs/versioning.md`, and others). This
layer is intent; those describe the implementation as it stands.
