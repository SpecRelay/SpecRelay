# Release-impact metadata and release commands

Spec 0022 establishes an enforceable release-impact discipline for every
SpecRelay spec written **after** it, and adds `bin/specrelay release
plan|prepare|verify|tag` to plan and prepare (never publish) a release from
that metadata. It also formalizes the currently-unreleased feature set as
`0.5.0` — see the `CHANGELOG.md` entry for what that release actually
contains.

## Release-impact metadata (mandatory for specs after 0022)

Every specification numbered after 0022 must contain a top-level YAML block:

```yaml
release:
  impact: none|patch|minor|major
  rationale: <non-empty explanation>
```

- `none` — no released artifact change.
- `patch` — backward-compatible defect correction.
- `minor` — backward-compatible public capability or command addition.
- `major` — incompatible public CLI, configuration, schema, installation, or
  behavior change.

Missing, malformed, or empty `release:` metadata fails release preparation
with an actionable message (`bin/specrelay release plan`/`prepare` names the
spec and the problem). **Historical specs at or before 0022 are not required
to have this block and are never rewritten automatically** — they remain
readable exactly as they are.

## Pre-1.0 version-bump policy

While `VERSION` is below `1.0.0`:

- `patch` increments the patch component only;
- `minor` **and** `major` both increment the minor component and reset patch
  (a `major`-labeled change pre-1.0 does not jump to a new major version on
  its own — an explicit, human-approved `1.0.0` release is a separate,
  deliberate decision no automation here makes);
- when multiple pending specs declare different impacts, the **highest**
  ranked impact (`major` > `minor` > `patch`) determines the bump.

## Commands

All four operate on **this SpecRelay checkout's own** `VERSION`,
`CHANGELOG.md`, and Git tags — never a consumer project's, and only in
source-local execution (an installed SpecRelay has no repository to release
and refuses these commands cleanly).

### `bin/specrelay release plan`

Read-only. Scans `docs/specs/*/spec.md` for specs numbered after 0022 with a
non-`none` `release:` block, reports each one's impact/rationale, the current
`VERSION`, and the proposed version under the pre-1.0 policy above. A
malformed `release:` block is reported as an error, not silently skipped. No
pending specs → "Pending impact: none", proposed version unchanged.

### `bin/specrelay release prepare`

Computes the same proposed version as `plan`, writes the new `VERSION`,
inserts a changelog entry (spec ids + impact + rationale for every spec that
contributed to the bump) at the top of `CHANGELOG.md`, and shows the diff.
**Never commits, tags, or pushes** — the working tree is left with the change
uncommitted for human review.

### `bin/specrelay release verify`

Verifies, independently of `prepare`:

- `VERSION` is syntactically valid semver;
- it is monotonically greater than (or equal to, if already tagged) the last
  `vX.Y.Z` Git tag;
- `CHANGELOG.md` contains an entry mentioning the new version;
- source-local `specrelay version` actually reports it.

Any failure is reported per-check and the command returns non-zero.

### `bin/specrelay release tag`

Requires a **clean, already-committed** working tree (the human commits
`VERSION`/`CHANGELOG.md` themselves after reviewing `prepare`'s diff — this
command never commits on your behalf). Creates the annotated `vX.Y.Z` tag at
`HEAD`, refuses if that tag already exists, and **never pushes** — pushing
`main` and pushing tags remain explicit human operations:

```sh
bin/specrelay release plan
bin/specrelay release prepare
bin/specrelay release verify
git add VERSION CHANGELOG.md
git commit -m "Release X.Y.Z"
bin/specrelay release tag
git push
git push --tags
```

## The 0.5.0 baseline

`VERSION` moved directly from `0.4.0` to `0.5.0` in the same change that
introduced this release-impact discipline (spec 0022 itself predates the new
YAML metadata format and was not required to carry it — see `docs/specs/0022-.../spec.md`,
"Release impact"). No intermediate `0.4.x`/`0.5.x` version was ever
published. See `CHANGELOG.md`'s `## 0.5.0` entry for the honest, human-written
summary of everything that shipped since `0.4.0`.
