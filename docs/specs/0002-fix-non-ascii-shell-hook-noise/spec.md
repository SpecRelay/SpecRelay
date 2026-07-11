# 0002 — Fix non-ASCII shell / hook / test noise

- **Status:** Draft (spec only — not yet implemented)
- **Spec number:** 0002 (second standalone SpecRelay spec)
- **Spec path:** `docs/specs/0002-fix-non-ascii-shell-hook-noise/spec.md`

## Goal

Investigate, classify, and safely fix the recurring shell/Git noise seen during
commit and test flows:

```
fatal: ambiguous argument '–abbrev-ref': unknown revision or path not in the working tree.
grep: illegal byte sequence
sed: 1: "“1s/^/:
": invalid command code �
```

Commits still succeed, but the output is confusing and makes SpecRelay look
unreliable. This task identifies the real source, classifies every relevant
non-ASCII shell-risk hit, and removes the noise **without** changing product
behavior or weakening tests.

This spec is scoped narrowly to the non-ASCII shell/hook/test noise. It does
**not** touch docs publication cleanup, ContextPlus setup, state/schema renames,
or live provider streaming (see Non-goals).

## Context

SpecRelay is a standalone repository:

- **Remote:** `git@github.com:SpecRelay/SpecRelay.git`
- **VERSION:** `0.4.0`
- Spec convention `docs/specs/<number>-<slug>/spec.md` was established by spec
  0001, which is the spec root and also scrubbed stale standalone docs after
  GitHub publication.

### Confirmed root cause (verified while authoring this spec, `2026-07-11`)

The investigation below was already performed at spec-authoring time and is
recorded here so the implementer can re-verify rather than rediscover. **The
implementer must re-run the searches and confirm these findings still hold**
before acting.

**The noise does not originate in any tracked SpecRelay file.** It comes from a
developer-global Git hook, injected via a **global** `core.hooksPath`:

- `git config --get core.hooksPath` (and `--global`) →
  `/Users/hrmohseni/.git-hooks`.
- This repo's own `.git/hooks/` contains **no** active (non-sample) hooks.
- The offending file is `/Users/hrmohseni/.git-hooks/prepare-commit-msg`, which
  contains non-ASCII shell punctuation:

  | Symptom | Hook line (as found) | Cause |
  | --- | --- | --- |
  | `fatal: ambiguous argument '–abbrev-ref'` | `BRANCH=$(git rev-parse –abbrev-ref HEAD)` | en dash (U+2013) used where `--` is required |
  | `grep: illegal byte sequence` | `grep -oE ‘[A-Z]+-[0-9]+’` | smart single quotes (U+2018/U+2019) become non-UTF-8 pattern bytes under a UTF-8 locale on BSD grep |
  | `sed: … invalid command code` | `sed -i.bak “1s/^/$TICKET: /”` | smart double quotes (U+201C/U+201D) around the sed script |

  Other lines (`MSG_FILE=”$1”`, `[ -z “$TICKET” ]`, `grep -q “^$TICKET”`) use the
  same smart quotes.

Because `core.hooksPath` is global, this hook fires on **every** commit in
**every** repository the developer works in — including the temporary Git repos
SpecRelay's test suite creates and commits into (e.g.
`git commit -q -m …` in `test/test_helper.sh`, `test/cli_workflow_test.sh`,
`test/evidence_test.sh`, and others). That is why the same noise appears during
`scripts/test`.

**Verified clean (not the source):**

- No tracked file uses an en/em dash as an option prefix
  (`(–|—)[A-Za-z]` search over all tracked files: zero hits).
- No tracked file places smart quotes adjacent to `git`/`grep`/`sed`/`awk`
  commands (zero hits).
- The em/en dashes that *do* appear in tracked files are in **prose comments**
  (e.g. `# specrelay — CLI entry point`) — natural prose, not shell punctuation.
- `test/run_all.sh:39` and `:70` use the correct ASCII form
  `git rev-parse --abbrev-ref HEAD`.
- No test fixture contains non-UTF-8 bytes (`iconv -f UTF-8 -t UTF-8` scan over
  `git ls-files test/fixtures` reported none), so the `grep: illegal byte
  sequence` is **not** caused by fixture content in this repo.

### Classification of the root cause

- **Primary source:** *environment / local-global untracked Git hook bug*
  (`/Users/hrmohseni/.git-hooks/prepare-commit-msg`). It is outside this
  repository and affects all of the developer's repos.
- **Contributing in-repo weakness:** SpecRelay's test harness (and any
  evidence-capture commit path) runs developer-global hooks instead of being
  hermetic, so a hostile global hook leaks its noise into `scripts/test`. This
  is a legitimate in-repo robustness gap this task may fix.
- **Not** a tracked source shell bug, **not** an intentional fixture, **not** a
  historical documentation example.

## Scope

### 1. Repository facts verification

- Verify this is the standalone **SpecRelay** repo (by remote + contents).
- Verify remote `origin` is `git@github.com:SpecRelay/SpecRelay.git`.
- Verify `VERSION` is `0.4.0`, or record the new value if it changed.
- Verify the working tree is clean before implementation starts.
- Verify the `docs/specs/` convention from spec 0001 exists.

### 2. Investigation (re-verify the confirmed findings above)

- Search tracked files for Unicode dash/quote characters unsafe in shell
  commands, focusing on the dangerous patterns (dash-as-option-prefix, smart
  quotes adjacent to commands), not harmless prose dashes.
- Search executable scripts, tests, fixtures, templates, docs examples, and
  `install/` + `update` logic.
- Inspect the **active** Git hooks: both `.git/hooks/` **and** any directory set
  by `core.hooksPath` (local and global) — the observed noise appears during
  `git commit`, and in this environment the active hook lives under a global
  `core.hooksPath`.
- Determine whether any **tracked** file generates or installs the offending
  hook. (Finding at authoring time: none does — the hook is purely developer
  environment.)
- If a source is an intentional test fixture containing bad shell examples, do
  **not** silently rewrite it unless a test expectation requires it.
- Classify each relevant hit as exactly one of:
  - tracked source bug,
  - local/untracked Git hook bug (incl. global `core.hooksPath`),
  - intentional test fixture,
  - historical documentation example,
  - environment / locale issue.

### 3. Fix policy

- **Fix tracked source bugs** in the repo. (At authoring time none were found;
  if the re-verification finds any, ASCII-ize them.)
- Convert unsafe shell command punctuation to ASCII wherever it is a bug:
  - en dash / em dash used as an option prefix → ASCII hyphen-minus (`--`),
  - smart quotes → ASCII single/double quotes.
- **Make the test harness hermetic** so developer-global hooks cannot leak noise
  into `scripts/test`: commits made by the test suite (and any SpecRelay
  evidence-capture commit) should not execute arbitrary developer hooks — e.g.
  run them with hooks disabled (`git -c core.hooksPath= … commit` or
  `commit --no-verify`) or an equivalent isolation. This removes the test-flow
  noise deterministically regardless of the developer's environment, and is a
  correctness improvement (tests should not depend on developer-global config),
  not a behavior change to the product.
- For the **local/global untracked hook** itself
  (`/Users/hrmohseni/.git-hooks/prepare-commit-msg`):
  - It is outside this repository and affects all the developer's repos, so
    SpecRelay must **not** silently rewrite it. Repairing it is
    environment/local cleanup that requires explicit human approval (see Human
    decisions).
  - Instead, add a **tracked** diagnostic so future users detect this class of
    problem: a `bin/specrelay doctor` check that inspects the active Git hook
    path (`core.hooksPath` / `.git/hooks`) for a `prepare-commit-msg` (or other
    commit hook) containing non-ASCII shell punctuation, and reports an
    actionable warning pointing at the offending file and the ASCII fix.
  - Do **not** edit `.git/hooks` (or the global hooks dir) directly as the
    *only* solution unless the task is explicitly labelled local cleanup and no
    tracked source exists; here the tracked deliverable is the doctor check plus
    hermetic test commits.
- Make `grep` usage robust *only where it scans arbitrary bytes*. (In tracked
  code, `grep` is used with `-Fq`/`-oE` over controlled strings, so no change is
  required unless the re-verification finds a byte-oriented scan; if one exists,
  force a safe locale — `LC_ALL=C` — for the byte-oriented scan, restrict it to
  known text files, or explicitly skip binary files.)
- Do **not** hide real failures by redirecting everything to `/dev/null`.
- Do **not** weaken tests just to silence noise.

### 4. License / publication

Out of scope. Do not touch `LICENSE.TODO` or publication state.

## Non-goals / Policy

This task must **not**:

- Implement live provider terminal streaming.
- Fix the duplicate `READY_FOR_HUMAN_REVIEW` transition behavior.
- Implement ContextPlus setup.
- Rename state/schema fields.
- Choose or change the license.
- Change anything in the Sprint-reports repository.
- Tag or publish a release.
- Rewrite historical docs merely to strip all Unicode from prose (em/en dashes
  and quotes in natural-language docs and comments are allowed).
- Silently rewrite the developer's global/local Git hook without explicit human
  approval.

Additionally, this spec itself performs **no implementation** — it only authors
this `spec.md`.

## Acceptance criteria

Implementation is complete when:

1. The observed `git commit` noise no longer appears when making a normal commit
   in this repository (once the root-cause hook is repaired per the documented
   human step, or isolated where SpecRelay controls the commit).
2. `scripts/test` exits `0` **without** the non-ASCII dash / `grep: illegal byte
   sequence` / `sed: invalid command code` noise — deterministically, regardless
   of the developer's global Git hooks (achieved via hermetic test commits).
3. `bin/specrelay doctor` still passes, or reports only intentional, documented
   warnings — including a new, actionable warning when an active commit hook
   contains non-ASCII shell punctuation.
4. `bin/specrelay version` reports the expected version (`0.4.0` unless changed).
5. A search/classification table records every relevant non-ASCII shell-risk
   hit, each classified as: natural prose allowed / historical evidence allowed
   / fixture intentional / still-a-bug-to-fix.
6. No product behavior is changed except removing shell/hook/test noise and
   improving diagnostics.

## Suggested verification commands

Run and record outputs for:

```sh
git status --short
scripts/test
bin/specrelay doctor
bin/specrelay version

# Active hook path (local + global)
git config --get core.hooksPath
git config --global --get core.hooksPath

# Risky characters in shell-sensitive files (dangerous patterns, not prose)
LC_ALL=C git grep -nP '(\xe2\x80\x93|\xe2\x80\x94)[A-Za-z]'      # dash used as option prefix
LC_ALL=C git grep -nP '(sed|grep|git|awk).{0,40}(\xe2\x80\x9c|\xe2\x80\x9d|\xe2\x80\x98|\xe2\x80\x99)'  # smart quotes near commands

# Non-UTF-8 bytes in fixtures (grep illegal-byte-sequence source)
for f in $(git ls-files test/fixtures); do iconv -f UTF-8 -t UTF-8 "$f" >/dev/null 2>&1 || echo "NON-UTF8: $f"; done
```

Also: exercise a **safe** commit path to confirm the noise is gone — e.g. a
harmless commit in a throwaway/temporary repo, or an equivalent direct
invocation of the active `prepare-commit-msg` hook — rather than committing into
this repository's history if a real commit is not appropriate.

## Assumptions

- The active commit hook is the developer-global
  `/Users/hrmohseni/.git-hooks/prepare-commit-msg` (verified `2026-07-11`); the
  repository's own `.git/hooks/` has no active custom hooks.
- No tracked SpecRelay source file is a source of the noise (verified); the only
  in-repo work is hermetic test commits and a new doctor diagnostic.
- No test fixture contains non-UTF-8 bytes (verified); `grep: illegal byte
  sequence` originates from the global hook's smart-quoted pattern, not repo
  content.
- `VERSION` is `0.4.0` (verified).
- Output restricted to this spec file means `docs/specs/README.md`'s index is
  **not** updated here; adding the 0002 row there is a trivial follow-up.

## Human decisions required

- **Repairing the global hook.** `/Users/hrmohseni/.git-hooks/prepare-commit-msg`
  is the developer's personal, global file affecting *all* their repositories.
  SpecRelay should not rewrite it automatically. A human must decide whether to
  fix it (replace the en dash with `--` and the smart quotes with ASCII quotes)
  or remove/relocate it. SpecRelay's deliverable is detection + documentation,
  not silent mutation.
- **Test-commit isolation mechanism.** Whether to isolate test/evidence commits
  via `core.hooksPath=`, `--no-verify`, or a per-fixture local hook path is an
  implementation choice to confirm — it must not change what the product commits,
  only that it does not run arbitrary developer hooks.
- **Scope of the doctor check.** Whether the new doctor diagnostic warns on *any*
  non-ASCII in active hooks or only on the specific dangerous patterns
  (dash-as-option, smart-quotes-near-commands) is a judgment call to avoid false
  positives on legitimate prose in hook comments.
