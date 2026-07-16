# SpecRelay Current Plan

*Read time: under a minute. For the reasoning behind any of this, see
[architecture-roadmap.md](architecture-roadmap.md).*

## Current objective

Not yet selected — see "Later objectives" below for the dependency-ordered
candidates.

## Next objective

**Bounded artifact repair** — a real, engine-executed `REPAIR_ARTIFACTS`.
*(Phase 5)*

## Later objectives

In dependency order (roadmap §5):

1. **Full artifact-layout migration** (`00-task/ … 06-telemetry/`) — last, once its real contents are known. *(Phase 6)*
2. **Reduced-touchpoint autonomous routing** — once verification/UI checks are mature. *(Phase 7)*
3. **Per-task isolated workspaces**, then **parallel task execution**. *(Phases 8–9)*
4. **Cross-task dependency/conflict coordination**. *(Phase 10)*
5. **Durable cross-task knowledge/memory** — exploratory, no design yet. *(Phase 11)*
6. **Package-manager release + additional providers** (planned); **license** blocked on a human decision (`LICENSE.TODO`). *(Phase 12)*

## Recently completed architecture milestones

- **Spec 0028 — UI runtime verification and compact review evidence**:
  first-class UI-impact detection, deterministic Playwright (or fake,
  no-browser-required) scenario execution, compact checkpoint-screenshot
  evidence (crop/dedup/size policy, no retained source image), redacted
  browser-console/network capture, optional expected-reference comparison,
  and a `transitions.sh::accept` completion gate requiring a Reviewer
  `## UI Verification Evidence Review` section before `READY_FOR_HUMAN_REVIEW`.
  `kind: ui` (reserved in spec 0026's schema) is now a real check kind.
  *Releasing it (`CHANGELOG`/`VERSION` bump) is a separate, later operational
  decision — not an architecture milestone.*
- **Spec 0027 — Local developer configuration overlay**: an optional,
  Git-ignored `.specrelay/config.local.yml` layers sparse, personal
  overrides on top of the shared `.specrelay/config.yml` (deterministic
  deep merge; lists replace wholesale; explicit `null` removes an
  inherited key), inspectable via `specrelay config show`/`config explain`
  and reported by `doctor`/`project inspect`. Sequenced immediately before
  spec 0028 (UI runtime verification) above because it needed
  developer-local browser paths, credentials, service startup commands,
  test data, and timeouts to be overridable per developer.
- **Spec 0026 — Configurable verification policy and multi-service
  execution**: the single `full_test_command` string is now one option
  alongside a real multi-service, multi-check policy — `changed`/`full`/
  `flexible` levels, dependencies, bounded parallel execution, per-check
  evidence. Legacy configuration keeps working unmodified; a project
  configuring both at once gets an ambiguity error, not a guess.
  *Releasing it is a separate, later operational decision.*
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
