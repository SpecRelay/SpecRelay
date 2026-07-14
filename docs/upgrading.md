# Upgrading and uninstalling SpecRelay

This is the upgrade/uninstall reference required by spec 0008 (sections 4-5).
It documents only what SpecRelay actually supports today, and states clearly
what it does **not** support. For a first install, see
[installation.md](installation.md); for the future packaging plan, see
[homebrew.md](homebrew.md).

> **`specrelay update` (spec 0022)** is the safe, installed-mode self-update
> command: `specrelay update [--yes]`, `--check`, `--from <path>`,
> `--dry-run`. It atomically stages, verifies, and activates a newer release,
> rolling back automatically if verification fails, and never runs for a
> source-local checkout (`bin/specrelay`/`./bin/specrelay`) — those always run
> the current working tree and never perform automatic update discovery. Full
> details: [updates.md](updates.md). The manual source-clone/reinstall path
> below remains supported and is what `specrelay update --from` uses under
> the hood for an explicit local source.

## How upgrading works

SpecRelay installs by **copying** a source tree into a user prefix (default
`$HOME/.local`): the executable to `<prefix>/bin/specrelay` and its resources
to `<prefix>/share/specrelay/`. Upgrading therefore means: get a newer source
tree, then run the installer over the existing install. The installer replaces
only the tool-owned files under `<prefix>` and never touches any consumer
project's `.specrelay/` configuration.

There are two source-tree flavors, matching the two install paths in
[installation.md](installation.md): a `main` (source clone) checkout, and a
version-tag checkout. Pick the one that matches how you installed.

## Upgrade path A — source clone (tracking `main`)

If you installed from a clone that tracks `main`, upgrade by fast-forwarding
that clone and reinstalling from it:

```sh
cd <your local SpecRelay clone>
git fetch origin
git checkout main
git pull --ff-only origin main
./install/install.sh            # reinstall over the existing install (idempotent)
specrelay version               # confirm the new version
specrelay doctor                # confirm readiness
```

Notes:

- `git pull --ff-only` refuses to create a merge commit; if it reports the
  branch has diverged, resolve that in your clone before reinstalling.
- Re-running `./install/install.sh` over an existing install is safe and
  idempotent: it replaces only `<prefix>/share/specrelay` (so no stale files
  survive) and rewrites `<prefix>/bin/specrelay`. If the **same** version is
  already installed it says so; pass `--force` to reinstall the same version.
- If you installed into a non-default prefix, pass the same
  `--prefix <dir>` to `install.sh` here.

Equivalent alternative (from a *separate* SpecRelay source tree, without
reinstalling in place) — the local-source updater:

```sh
./install/update.sh --from <path to updated SpecRelay source> --prefix "$HOME/.local"
```

`update.sh` detects the installed and source versions, refuses an accidental
downgrade unless you pass `--allow-downgrade`, and delegates the file
replacement to the source's `install.sh --force`. It updates only tool-owned
files and never touches consumer project configs. See
[installation.md](installation.md#updating-an-installed-copy).

## Upgrade path B — version tag

If you installed from a specific version tag (see
[installation.md](installation.md#install-from-a-release-tag)) and want to move
to a newer tag, check out the new tag and reinstall:

```sh
cd <your local SpecRelay clone>
git fetch origin --tags
git checkout vX.Y.Z             # the newer tag you want
./install/install.sh
specrelay version               # should report X.Y.Z
specrelay doctor
```

> **Honesty note:** no version tag has been published for SpecRelay yet (the
> repository currently has no tags, and publication is blocked until a license
> is chosen — see [publication.md](publication.md) and
> [versioning.md](versioning.md#releases-and-git-tags)). The command above is
> the documented path for **once tags exist**; substitute the real tag name
> when there is one. Until then, use path A (source clone).

## Version-compatibility during upgrades

SpecRelay records the engine version and state-schema version that created each
task, and refuses an **unsafe** resume across incompatible versions rather than
corrupting state. Minor/patch upgrades within the same major version are
backward-compatible; a major-version change is not. See
[versioning.md](versioning.md) for the exact rules and the deliberate,
per-invocation override used for human-driven recovery.

## Upgrading the AI Reviewer sub-agent template

`templates/claude/agents/ai-reviewer.md` (the bundled Claude reviewer
sub-agent template — see [providers.md](providers.md)) can change between
SpecRelay versions, e.g. spec 0019's risk-based Reviewer Policy v2 rewrite.
Upgrading the **tool** (paths A/B above) always refreshes the bundled template
itself, but it does **not** silently touch a project's own installed copy at
`.claude/agents/ai-reviewer.md` — `specrelay init` (and its internal
`--force`-free re-run) never overwrites a file that already exists there,
customized or not. To pick up a newer bundled template in a project that
already has one installed:

```sh
# See what's different first (never blindly overwrite a customization):
diff <specrelay-home>/templates/claude/agents/ai-reviewer.md .claude/agents/ai-reviewer.md

# Then, deliberately, either:
cp <specrelay-home>/templates/claude/agents/ai-reviewer.md .claude/agents/ai-reviewer.md
# or re-apply your own customizations on top of the new template by hand.
```

`specrelay doctor` distinguishes **template available** (this SpecRelay
installation ships the template), **project reviewer installed** (present and
byte-identical to the bundled template), **project reviewer missing**, and
**project reviewer installed and CUSTOMIZED** (present but differs from the
bundled template) — so an upgrade never silently claims a project is using
the newest template when it is actually running an older or hand-edited copy.

## Uninstalling

Uninstalling removes the SpecRelay **tool** from your prefix. It does not, and
should not, remove SpecRelay configuration from your projects.

### Locate the installed executable

```sh
command -v specrelay            # which specrelay is on your PATH
specrelay doctor                # prints "SpecRelay home (<prefix>/share/specrelay)"
```

The executable lives at `<prefix>/bin/specrelay` and its resources at
`<prefix>/share/specrelay/` (default prefix `$HOME/.local`).

### Automated uninstall

Use the bundled uninstaller. It removes only the two tool-owned locations above
and refuses to delete anything else:

```sh
./install/uninstall.sh                       # uninstall from ~/.local
./install/uninstall.sh --prefix "$HOME/.local"
```

It:

- removes `<prefix>/bin/specrelay` (a copy **or** a `--dev-link` symlink;
  removing a symlink never touches the source tree it points at);
- removes `<prefix>/share/specrelay/`, but only if it actually looks like a
  SpecRelay install (it refuses to delete an unrelated directory);
- is idempotent — running it again when nothing is installed simply reports
  that there was nothing to remove;
- never uses sudo, never writes outside `<prefix>`, and never touches any
  consumer project's `.specrelay/`.

### Manual uninstall (equivalent)

If you prefer to remove the files by hand:

```sh
rm -f  "$HOME/.local/bin/specrelay"
rm -rf "$HOME/.local/share/specrelay"
```

(substitute your prefix if you installed elsewhere).

### Reinstall cleanly

Reinstalling is just installing again from a source tree:

```sh
./install/install.sh
specrelay version
```

Because copy-mode installs replace `<prefix>/share/specrelay` wholesale, a
reinstall never leaves stale files behind — you do not have to uninstall first
to get a clean install.

### What is NOT removed

Uninstalling the tool intentionally leaves **consumer projects** untouched.
The following are project-owned and are never removed by `uninstall.sh` or by
the manual commands above:

- a project's `.specrelay/config.yml` and `.specrelay/` directory;
- a project's task runtime evidence (default `.specrelay-runs/`);
- a project's specs (default `specs/`) and any docs.

Remove those per-project by hand only if you intend to stop using SpecRelay in
that specific repository.

## Safe self-update (spec 0022)

`specrelay update` (installed mode only) is the supported self-update path —
see [updates.md](updates.md) for the full command reference, the daily
automatic-discovery contract before `run`/`resume`, version-specific
dismissal, CI/non-interactive safety, and the atomic stage/verify/activate/
rollback design. A source-local checkout (`bin/specrelay`) never performs
automatic update discovery and refuses `update` cleanly, by design (section
1 of spec 0022) — upgrading a source clone still goes through `git pull` and
re-running the installer, as documented above.
