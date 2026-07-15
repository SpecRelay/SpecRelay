# SpecRelay Extraction (Standalone Repository)

> **Historical document.** This document describes the historical procedures for
> extracting the former in-host SpecRelay architecture (`tools/specrelay/`
> incubated inside a host repository, `.ai/scripts/` compatibility shims,
> `.ai-runs/` task runtime) into a standalone repository. That architecture is
> no longer a supported current product surface. See README.md and
> docs/architecture.md for the current standalone architecture
> (`bin/specrelay` / installed `specrelay`, `.specrelay/config.yml`,
> `.specrelay-runs/`).

## E1. Goal

SpecRelay is being incubated **inside** a host repository at `tools/specrelay/`.
The purpose of extraction is to turn that subtree into a **standalone repository
where `tools/specrelay/` is the root** — so that `bin/`, `lib/`, `docs/`,
`install/`, `scripts/`, `templates/`, `test/`, `README.md`, and `VERSION` sit at
the top level — while **preserving the useful Git history** of that subtree.

Extraction in this task is **local and history-preserving only.** It produces a
new repository *on disk*. Publishing that repository — pushing to any remote,
creating a hosting-provider repository, tagging a public release, or distributing
a package — is **explicitly out of scope for now** (spec sections 41, 80). None of
the commands below push anywhere, and none should be extended to.

This document describes rehearsable, reversible procedures. It does not delete or
alter the host copy; see E5.

## E2. What "standalone-ready" already means here

The in-repository tree is already arranged so that `tools/specrelay/` can *become*
a root without edits:

- `bin/specrelay` resolves its own resources relative to its real location
  (source layout `<home>/bin` + `<home>/lib`, or installed layout
  `<prefix>/bin` + `<prefix>/share/specrelay/lib`), so nothing breaks when the
  directory is promoted to a repository root.
- `scripts/test` runs the **standalone** suite: every test that operates purely on
  isolated temporary git fixtures and needs neither the host application nor a
  pre-existing `.ai/` workflow. Host-integration tests are excluded by name and
  run separately from the host via `test/run_all.sh`.
- `install/install.sh` and `install/update.sh` copy only tool-owned files and
  never touch a consumer project's `.specrelay/` config.

Extraction is therefore a **history/packaging** operation, not a code-restructuring
one. The two strategies below differ only in how they carve the subtree's history.

## E3. Strategy A — Git subtree split

`git subtree` is built into Git and needs no extra install. It produces a new
branch whose history contains only the commits that touched `tools/specrelay/`,
rewritten so that subtree is at the root.

```text
# From the host repository root. Read-only w.r.t. your working branch: this
# only creates a new local branch; it pushes nothing.
git subtree split --prefix=tools/specrelay -b specrelay-extraction

# Materialize the split branch as a fresh local repository. A local clone of a
# single branch keeps this self-contained and off any remote.
git clone --no-hardlinks --branch specrelay-extraction --single-branch \
  . /tmp/specrelay-standalone

cd /tmp/specrelay-standalone
# In this new repo, VERSION, bin/, lib/, docs/, install/, scripts/, templates/,
# test/, and README.md are now at the repository root.
```

Notes:

- `git subtree split` is convenient and dependency-free, but on a large host
  history it can be slow, and it follows the subtree as it existed under the
  prefix (renames into/out of the prefix are not always carried perfectly). For
  the cleanest, most complete history rewrite, prefer Strategy B.
- The `-b specrelay-extraction` branch is a local artifact; delete it once you
  have cloned from it if you do not want it lingering in the host repo.

## E4. Strategy B — Filtered history extraction (preferred)

A history *filter* rewrites a clone so that only `tools/specrelay/`'s history
remains, with that directory promoted to the root. Always run a filter against a
**throwaway clone**, never against your working repository — the rewrite is
destructive to the clone it runs in.

```text
# Always operate on a disposable copy so the host repo is never rewritten.
git clone --no-hardlinks . /tmp/specrelay-extract
cd /tmp/specrelay-extract
```

### B1 — `git filter-repo` (preferred, if available)

`git filter-repo` is the modern, recommended history-rewriting tool. It is a
**separate install** (it is not bundled with Git) — install it first, e.g. via
your package manager or `pip`.

```text
git filter-repo --subdirectory-filter tools/specrelay
# The clone's history now contains only tools/specrelay/'s commits, with that
# directory's contents at the repository root.
```

### B2 — `git filter-branch` (built-in fallback)

If `git filter-repo` cannot be installed, `git filter-branch` ships with Git but
is **slower and officially deprecated** (Git itself warns against it). Use it only
as a fallback:

```text
git filter-branch --subdirectory-filter tools/specrelay -- --all
```

Either way, the result is the same shape: a local repository whose root *is* the
former `tools/specrelay/` subtree, carrying its history.

## E5. The host copy stays the single source of truth

Until a later task explicitly retires it, the in-repository copy at
`tools/specrelay/` remains the **single source of truth**:

- Extraction outputs (the split branch, the clones under `/tmp/…`) are
  **temporary rehearsal artifacts** — treat them as disposable.
- Do **not** delete the host copy at `tools/specrelay/`.
- Do **not** delete or disable the host's compatibility shims
  (`.ai/scripts/*` → SpecRelay) or the frozen legacy engine in this task.
- Do **not** point the host at an extracted copy; the host continues to run
  SpecRelay from `tools/specrelay/`.

Promoting an extracted repository to *the* source of truth, and removing the host
copy/shims, is deliberately a **separate future task** (see
`docs/architecture.md`, "Migration stages"). This task only proves extraction is
possible and clean.

## E6. Post-extraction verification (the rehearsal)

The point of extraction is not just to move files — it is to **prove no hidden
host-repo dependencies remain**. Run the following inside an extracted repository
(the output of Strategy A or B). Every step must pass with the extracted tree
*alone*, with no access to the host application, `.ai/`, or host spec history.

```text
cd /tmp/specrelay-standalone   # or /tmp/specrelay-extract

# 1. The executable runs and reports its version and help from the new root.
bin/specrelay version
bin/specrelay help

# 2. The STANDALONE test suite passes with the extracted tree only.
#    (Host-integration tests are excluded by scripts/test by design.)
scripts/test

# 3. A no-sudo, copy-based install into a throwaway prefix succeeds, and the
#    installed executable runs.
install/install.sh --prefix /tmp/specrelay-prefix
export PATH="/tmp/specrelay-prefix/bin:$PATH"
specrelay version

# 4. Initialize a FRESH consumer repo and drive a fake, end-to-end workflow —
#    proving init + a full lifecycle work outside the host.
mkdir -p /tmp/consumer && cd /tmp/consumer && git init
specrelay init
#   -> writes .specrelay/config.yml from the built-in template, creates the
#      spec root, and adds a safe .gitignore entry for the runtime directory.
# Point the config at the deterministic 'fake' provider so the rehearsal needs
# no real AI provider (edit roles.executor.provider: fake in .specrelay/config.yml),
# add a trivial spec under the configured spec root, then:
specrelay run <spec-path>
specrelay status
```

If all four steps pass in a tree that has *only* the extracted files, extraction
is clean: SpecRelay carries no hidden dependency on the incubation host.

## E7. What this document deliberately does not do

- It does **not** push to, create, or configure any remote or hosting provider —
  publishing is out of scope for now (E1).
- It does **not** delete the host copy at `tools/specrelay/` or the host's
  compatibility shims / frozen legacy engine (E5).
- It does **not** change the host's active engine, its `.specrelay/` config, or
  any existing task run directory.

See `docs/migration.md` for how a consuming project (including the incubation
host itself) relates to SpecRelay once it is standalone-ready.
