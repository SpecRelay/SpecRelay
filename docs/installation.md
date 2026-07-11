# SpecRelay Installation

This is the install/update reference required by spec 0086 (sections 9-13,
44-47). It documents the copy-based, no-sudo, user-level installer and the
local-source updater exactly as they behave today.

SpecRelay currently ships and installs **from a source tree**. There is no
package-manager, release-archive, or network install path yet; see
[Future distribution](#future-distribution) below.

## Requirements

SpecRelay is a Bash CLI built from portable shell and standard POSIX tools:

- **Bash** — the executable and its library are `#!/usr/bin/env bash`. Written
  to run on the macOS system Bash (**3.2**) as well as modern Bash 4/5, so no
  Bash-4+-only features are required.
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

### Supported platforms

- **macOS** and **Linux** are supported and exercised (portable constructs
  only: atomic `mkdir` locks, POSIX `date`, a `stat -f … || stat -c …`
  fallback, a manual symlink-follow loop instead of `readlink -f`).
- **Windows** native is not claimed; WSL behaves as Linux.

See `docs/standalone-verification.md` for the portability notes and the
environments in which the CLI was exercised.

### Claude CLI (optional provider)

The Claude CLI is **optional**. It is required **only** when a project's
configuration selects a Claude-backed role (`roles.executor.provider: claude`,
or `roles.reviewer.provider: claude` / `claude-subagent`). Projects using the
`fake` executor/reviewer or a `manual` reviewer need no Claude CLI at all.
Continuous integration for this repository intentionally does not install
Claude; see `SPECRELAY_PROVIDER_OPTIONAL` below.

### Environment variables

These optional variables tune where SpecRelay looks for its parts and how it
runs; none is required for normal use.

| Variable | Effect |
|---|---|
| `SPECRELAY_HOME` | Absolute path to the installed SpecRelay itself (its `lib/`, `templates/`, `VERSION`). Normally derived from the executable's own location; set it to force a specific engine copy. |
| `SPECRELAY_PYTHON` | Python interpreter used for task `state.json` (default `python3`). |
| `SPECRELAY_CLAUDE_BIN` | Executable name/path for the Claude CLI (default `claude`), used by the `claude` / `claude-subagent` providers. |
| `SPECRELAY_SEMANTIC_EVENTS` | Set to `0` to disable Claude semantic live events and fall back to generic stdout/stderr streaming (default on). |
| `SPECRELAY_PROVIDER_OPTIONAL` | Set to `1` so `specrelay doctor` reports an absent **configured** provider CLI (e.g. Claude) as an advisory warning instead of a hard failure. Core dependency checks stay mandatory. Used by CI (`.github/workflows/ci.yml`) so verification does not require a real Claude; default off, so normal local diagnostics still fail loudly when a configured provider is missing. |

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

## Responsibilities: `install` vs. `init` vs. `doctor` vs. `run`

Each command has a **bounded** responsibility; no step silently reaches outside
its own scope:

- **`install`** (`install/install.sh` / `install/update.sh`) installs the
  SpecRelay CLI and its resources under a prefix you own. It **never** modifies
  an arbitrary project's `.specrelay/config.yml`, and it **never** touches your
  Claude MCP configuration. Installing or updating the tool is purely a
  tool-side operation.
- **`init`** (`specrelay init`) is a **project-side** operation only. It
  creates/updates the project-local `.specrelay/config.yml`, the spec root, and
  a `.gitignore` entry for the runtime evidence directory. It refuses to
  overwrite an existing config unless you pass `--force`.
- **`doctor`** (`specrelay doctor`) **reports** readiness — installation,
  project config, providers, and the configured context adapter — read-only. It
  does **not** silently fix anything or mutate configuration.
- **`run`** (`specrelay run`) **fails clearly**, with an actionable message, if
  a required provider or a required context adapter is missing, rather than
  proceeding, hanging, or failing obscurely before it can claim a task. (A
  required-but-unregistered `contextplus` adapter is exactly the failure mode
  that motivated documenting this boundary — see
  [context-adapters.md](context-adapters.md).)

## Preparing a repository: use `init`, not a hand-written config

The supported way to prepare a repository to run SpecRelay is `specrelay init`
(or `bin/specrelay init` from a standalone source checkout). **Hand-writing
`.specrelay/config.yml` is a temporary bootstrap escape hatch, not the normal
product path** — a hand-written config that requires a context adapter which is
not actually available is what caused an early dogfood run to fail before it
could claim a task.

Current `init` behavior and its known gap:

- `init` writes a **fixed bundled template** (`templates/project/config.yml`):
  spec root `specs`, executor `claude`, reviewer `manual`, and
  `context.adapter: none` / `context.required: false`. It substitutes the
  project name but does **not** yet accept per-project values for the spec
  root, providers, or context adapter.
- Values `init` sets **automatically** today: `version`, `project.name` (the
  project directory's basename), `specs.root: specs`, `tasks.runs_root`,
  `tasks.max_iterations`, `roles.executor.provider: claude`,
  `roles.reviewer.provider: manual`, `context.adapter: none`,
  `context.required: false`, and a placeholder `validation.full_test_command`.
- Values you must still **adjust by hand** after `init` (until configurability
  lands) include a non-default spec root (e.g. `docs/specs`), an automated
  reviewer (e.g. `claude-subagent`), your real `validation.full_test_command`,
  and any context-adapter policy.
- Making `init` fully configurable (spec root, providers, context adapter via
  flags, prompts, or template selection) is a **recorded follow-up** — see
  `docs/specs/0001-establish-docs-specs-convention-and-scrub-standalone-docs/spec.md`.

Adjust the generated config only by editing the keys documented in
[configuration.md](configuration.md); do not treat a hand-edited config as the
intended long-term interface.

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
source tree carries it (currently `0.4.0`); the installer copies it to
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

Use `bin/specrelay ...` (the in-repo path from a standalone source checkout)
only when working directly in the source tree; the installed `specrelay` on
your `PATH` is the supported entry point for day-to-day use. See `commands.md`
for the full command reference.

## Future distribution

Additional distribution channels — a Homebrew formula/tap, a downloadable
release archive, or other package managers (npm, gem, etc.) — are **possible
future options only**. None of them exist today, and this document does not
provide install commands for them. Until they ship, use the copy-based
`install.sh` / `update.sh` flow described above.
