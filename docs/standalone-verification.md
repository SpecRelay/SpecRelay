# Standalone Verification Matrix

This document records how each SpecRelay capability was verified across the
environments that matter for standalone extraction (SDD 0086, section 65). It
is evidence-based: a cell is `PASS` only where the capability was actually
exercised, not merely implemented.

> **Historical record.** This matrix captures the standalone-extraction
> verification performed for SDD 0086 at SpecRelay **v0.3.0**, run from the
> origin host's incubated `tools/specrelay/` tree. It is preserved as a
> point-in-time evidence record; the version numbers and host paths below
> reflect *that* run and are **not** a live status of the current standalone
> `0.4.0` repository.

## Environments

| Column | Meaning |
|---|---|
| **Incubated host** | Run from the origin repo at `tools/specrelay/` (source tree, `SPECRELAY_HOME` = the source). |
| **Extracted tree** | The source copied/`git subtree split` into a temporary repo where SpecRelay is the **repository root**. |
| **Installed prefix** | Installed via `install/install.sh --prefix <tmp>`; the CLI runs from `<prefix>/bin/specrelay` resolving `<prefix>/share/specrelay` (with `SPECRELAY_HOME` unset). |
| **Fresh consumer** | A brand-new empty Git repo, `specrelay init`, fake providers, driven by the installed CLI. |

All temporary environments were created under `mktemp` outside the host working
tree, with the host's global git hooks neutralized for clean fixtures. The
fresh-consumer environment used a path **with spaces** to also cover safe path
handling (section 22, Project D).

## Matrix

| Capability | Incubated host | Extracted tree | Installed prefix | Fresh consumer | Evidence |
|---|---|---|---|---|---|
| `version` | PASS | PASS | PASS | PASS | `specrelay version` → `specrelay 0.3.0` in all four |
| `help` | PASS | PASS | PASS | PASS | `specrelay help` prints the command list |
| `init` | n/a (host already initialized) | n/a | n/a | PASS | created `.specrelay/config.yml` (name substituted), `specs/`, `.gitignore` entry `.specrelay-runs/` |
| Project-root discovery | PASS | PASS | PASS | PASS | discovered root from a nested dir (`specs/0001-.../`) and from a spaces-in-path project |
| `doctor` | PASS* | — | PASS | PASS | generic consumer doctor is all-green and does **not** demand Rails/RSpec/ContextPlus; installed doctor reports home = `<prefix>/share/specrelay` |
| Fake **accepted** workflow | PASS | via suite | — | PASS | reached `READY_FOR_HUMAN_REVIEW`, iteration 1 |
| Fake **request-changes/rework** workflow | PASS | via suite | — | PASS | round 1 `CHANGES_REQUESTED` → round 2 accept; final iteration 2; `iterations/round-1` + `round-2` archived |
| `status` | PASS | — | — | PASS | table shows task/state/iteration |
| `show <task>` | PASS | — | — | PASS | prints state, iteration, spec, providers, timestamps |
| `list` | PASS | — | — | PASS | lists tasks with state + iteration |
| `resume <task>` | PASS | — | — | PASS | at `READY_FOR_HUMAN_REVIEW` correctly refuses to advance (human gate), state unchanged |
| Standalone test suite (`scripts/test`) | PASS | PASS | — | — | 14 files, 0 failed; host-integration tests excluded |
| Installer | — | source | PASS | — | copy install into `<prefix>`; idempotent second run; PATH guidance printed |
| Updater | — | source | PASS | — | `update.sh --from` upgraded 0.0.1 → 0.3.0; refused 9.9.9 → 0.3.0 downgrade (exit 1) |

`*` On the incubation host, `doctor` reports one expected non-pass **only while
a `specrelay run` is in progress**: a live engine lock is correctly detected as
a "conflicting active engine lock". On an idle host all checks pass.

## Test suites

| Suite | Command | Result |
|---|---|---|
| Standalone (host-independent) | `scripts/test` | 14 files, 0 failed |
| Host full suite | `test/run_all.sh` | 22 files, 0 failed; host HEAD/branch/working-tree unchanged |

## Portability notes (macOS / Linux)

- Locking uses atomic `mkdir` (no `flock` dependency), so it works on macOS.
- Timestamps use `date -u +"%Y-%m-%dT%H:%M:%SZ"` (POSIX-portable).
- File mtime uses a `stat -f %m … || stat -c %Y …` fallback (BSD/GNU).
- Tool-root discovery uses a manual symlink-follow loop, not `readlink -f`.
- Verified on macOS (BSD userland, system bash 3.2). Linux is supported by the
  same portable constructs; Windows native is not claimed (WSL would behave as
  Linux).

## Known limitations

- The **real-provider** standalone smoke (a genuine Claude executor/reviewer
  run from an isolated consumer repo) is recorded separately; where the Claude
  CLI is unavailable in the harness, the deterministic `fake`-provider proof
  above stands in and the blocker is stated honestly rather than faked.
- The `git subtree split` extraction rehearsal reflects **committed** history;
  working-tree fixes made in this task are proven standalone-clean via a
  working-tree-snapshot extraction and become part of the split once committed.
