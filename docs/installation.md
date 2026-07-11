# SpecRelay Installation

This is the install/update reference required by spec 0086 (sections 9-13,
44-47). It documents the copy-based, no-sudo, user-level installer and the
local-source updater exactly as they behave today.

SpecRelay currently ships and installs **from a source tree**. There is no
package-manager, release-archive, or network install path yet; see
[Future distribution](#future-distribution) below.

## Requirements

SpecRelay is a Bash CLI built from portable shell and standard POSIX tools:

- **Bash** — the executable and its library are `#!/usr/bin/env bash`.
- **git** — required at runtime (baseline snapshots, diff/status evidence,
  guarded working-tree checks) and checked by `specrelay doctor`.
- **Standard POSIX utilities** — `cp`, `mkdir`, `rm`, `ln`, `chmod`, `tr`,
  `sort`, `head`, `sed`, `awk`, `grep`, `find`, `mktemp`, `date`, `stat`,
  `readlink`, used by the installer and the CLI.
- **ruby** — required by the core workflow to parse `.specrelay/config.yml`
  (via Ruby's standard `yaml` library / `YAML.safe_load`; no extra gems). Any
  command that reads project config (`run`, `resume`, `init`-configured
  projects, `doctor`) needs it.
- **python3** — required by the core workflow to read and write task
  `state.json` (via `lib/specrelay/py/state_lib.py`). Any command that touches
  task state needs it.

`ruby` and `python3` are **core** runtime dependencies for driving workflows,
not optional extras — installing the files (`install.sh`) and `specrelay
version` / `help` do not need them, but running a task does. A provider may add
its own requirement: the `claude` provider needs the Claude CLI on `PATH`,
while the `fake` provider needs nothing beyond the above. `specrelay doctor`
reports the availability of the pieces a given project actually configures.

No sudo, no root, and no system directories are involved at any point.

## Copy-based user installation

Run the installer from the SpecRelay source tree. By default it installs into
your user prefix `$HOME/.local`:

```bash
./install/install.sh
```

To choose an explicit prefix:

```bash
./install/install.sh --prefix "$HOME/.local"
```

Any prefix you own works. The installer refuses an empty prefix and refuses
the filesystem root (`/`); it never writes outside the prefix you give it.

### Resulting layout

The installer produces exactly this layout under `<prefix>`:

```
<prefix>/bin/specrelay                 # the executable
<prefix>/share/specrelay/lib           # runtime library (lib/specrelay/…)
<prefix>/share/specrelay/templates     # project/init templates
<prefix>/share/specrelay/VERSION       # installed version marker
<prefix>/share/specrelay/docs          # bundled docs (if present in source)
<prefix>/share/specrelay/README.md     # bundled README (if present in source)
```

The install is **relocatable**: no absolute paths are baked into the copied
executable. At runtime `specrelay` resolves its own real location (following
symlinks) and finds its resources relative to itself — the installed layout
(`<prefix>/bin` alongside `<prefix>/share/specrelay/lib`) or the source-tree
layout (`<home>/bin` alongside `<home>/lib`). You can therefore move a whole
prefix and it keeps working, and you can point at a specific home explicitly
with the `SPECRELAY_HOME` environment variable if you ever need to override
discovery.

### PATH guidance

After a successful install the installer confirms the version by running the
freshly installed executable. It then checks whether `<prefix>/bin` is on your
`PATH`:

- if it is, it prints that `<prefix>/bin` is already on your PATH;
- if it is not, it prints a note with the exact line to add, e.g.:

  ```bash
  export PATH="$HOME/.local/bin:$PATH"
  ```

Add that line to your shell profile so the `specrelay` command is available in
new shells.

### Optional development symlink mode

`--dev-link` is an **optional** mode for development only — it is not the
production install method. Instead of copying, it symlinks
`<prefix>/bin/specrelay` back to the executable in this source tree, so edits
to the source are picked up immediately:

```bash
./install/install.sh --dev-link
```

For a normal installation, omit `--dev-link`; copying is the default.

### Idempotency

Re-running the installer is safe. In copy mode it replaces only the
tool-owned `<prefix>/share/specrelay` directory, so a re-install never leaves
stale files behind. If the **same version** is already installed, the
installer reports that it is already installed and that you can pass `--force`
to reinstall:

```bash
./install/install.sh --force
```

As a safety measure, the installer refuses to overwrite a
`<prefix>/share/specrelay` that exists but is not a SpecRelay install.

### Installer flags

```
Usage: install.sh [--prefix DIR] [--dev-link] [--force] [-h|--help]

  --prefix DIR   Install under DIR (default: $HOME/.local).
  --dev-link     Symlink the executable to this source tree (development).
  --force        Reinstall even if the same version is already installed.
  -h, --help     Show this help.
```

## Tool root vs. project root

Installing the **tool** is a separate concern from initializing a **project**:

- **Installing/updating** places the SpecRelay tool under `<prefix>` (its
  `bin`, `lib`, `templates`, `VERSION`). It never reads or writes a consumer
  project's configuration.
- **Initializing a project** is a project-side operation run *inside* a
  consumer repository:

  ```bash
  specrelay init [--path <dir>] [--force]
  ```

  This creates `.specrelay/config.yml` (from the bundled template) in that
  project, where you set your executor/reviewer providers and roots.

The installer and updater **never touch** any consumer project's
`.specrelay/config.yml` or `.specrelay/` directory. Upgrading the tool leaves
every project's configuration exactly as it was.

## Updating an installed copy

During incubation the only supported update source is a **local SpecRelay
source tree**, given with `--from`. There is no network/release/package-manager
update path yet, so `--from` is required:

```bash
./install/update.sh --from /path/to/specrelay
```

The updater:

1. Detects the installed version (`<prefix>/share/specrelay/VERSION`) and the
   source version (`<from>/VERSION`) and prints both.
2. Refuses to run if there is no existing install at the prefix — `update.sh`
   only **updates** an existing install; use `install.sh` for a first install.
3. Refuses an accidental **downgrade** (installing an older version than the
   one installed) unless you pass `--allow-downgrade`.
4. If the versions match, refreshes the files from source.
5. Delegates the actual file replacement to the source's
   `install.sh --prefix <prefix> --force`, which writes **only tool-owned
   files** under `<prefix>`. Consumer project configs are left untouched.

To choose a non-default prefix, or to permit a downgrade:

```bash
./install/update.sh --from /path/to/specrelay --prefix "$HOME/.local"
./install/update.sh --from /path/to/specrelay --allow-downgrade
```

### Updater flags

```
Usage: update.sh --from DIR [--prefix DIR] [--allow-downgrade] [-h|--help]

  --from DIR          A local SpecRelay source tree to update FROM (required).
  --prefix DIR        The install prefix to update (default: $HOME/.local).
  --allow-downgrade   Permit installing an OLDER version than is installed.
  -h, --help          Show this help.
```

## Version ownership

The single source of truth for the version is the **`VERSION` file**. The
source tree carries it (currently `0.3.0`); the installer copies it to
`<prefix>/share/specrelay/VERSION`, and both the installer and updater read
those two files to decide "already installed", "reinstall", or "downgrade".
`specrelay version` prints the installed value.

## Using the global CLI

Once `<prefix>/bin` is on your `PATH`, invoke the tool by its plain name from
anywhere:

```bash
specrelay run <spec.md>
specrelay status
specrelay doctor
```

Use `tools/specrelay/bin/specrelay ...` (the in-repo path) only when working
directly in the source tree; the installed `specrelay` on your `PATH` is the
supported entry point for day-to-day use. See `commands.md` for the full
command reference.

## Future distribution

Additional distribution channels — a Homebrew formula/tap, a downloadable
release archive, or other package managers (npm, gem, etc.) — are **possible
future options only**. None of them exist today, and this document does not
provide install commands for them. Until they ship, use the copy-based
`install.sh` / `update.sh` flow described above.
