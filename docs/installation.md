# SpecRelay Installation

This is the install/update reference required by spec 0086 (sections 9-13,
44-47). It documents the copy-based, no-sudo, user-level installer and the
local-source updater exactly as they behave today.

SpecRelay currently ships and installs **from a source tree**. There is no
package-manager, release-archive, or network install path yet; see
[Future distribution](#future-distribution) below.

**Related docs:** upgrading and uninstalling are covered in
[upgrading.md](upgrading.md); the (not-yet-published) Homebrew plan is in
[homebrew.md](homebrew.md). This page covers first-install and the two
supported source install paths (a `main` clone and a version tag).

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

### Claude reviewer sub-agent (`ai-reviewer`)

The `claude` / `claude-subagent` **reviewer** can run as a named Claude
sub-agent (`--agent ai-reviewer`), but that requires an agent definition at
`.claude/agents/ai-reviewer.md` **in your project**. SpecRelay does **not** ship
that file into your repository — it belongs to the consumer project. SpecRelay
provides it as a template at `templates/claude/agents/ai-reviewer.md` and sets
it up for you as follows:

- **`specrelay init`** copies the template to `.claude/agents/ai-reviewer.md`
  automatically when the reviewer provider is `claude` or `claude-subagent`. It
  never overwrites an existing agent file.
- **Manual copy** (e.g. you switched an already-initialized project to a Claude
  reviewer): copy it yourself —

  ```sh
  mkdir -p .claude/agents
  cp "$SPECRELAY_HOME/templates/claude/agents/ai-reviewer.md" .claude/agents/ai-reviewer.md
  ```

If the file is absent the reviewer still works: it falls back to a plain
`claude --print` reviewer, and `specrelay doctor` prints a warning so the state
is never silently misrepresented.

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

## Install paths: `main` clone vs. release tag

There are two supported ways to obtain the source tree the installer copies
from. Both use the same `install/install.sh`; they differ only in **which
revision** you check out first.

### Install from a fresh clone (tracking `main`)

The canonical fresh-user path. Clone the repository, then install from it:

```sh
git clone git@github.com:SpecRelay/SpecRelay.git
cd SpecRelay
./install/install.sh
specrelay version     # requires <prefix>/bin on PATH; otherwise run <prefix>/bin/specrelay version
specrelay doctor
```

This tracks `main` (the latest reviewed development state). To upgrade later,
fast-forward the clone and reinstall — see
[upgrading.md](upgrading.md#upgrade-path-a--source-clone-tracking-main).

> If `<prefix>/bin` is not yet on your `PATH`, the plain `specrelay` name will
> not resolve in this shell. Either add `<prefix>/bin` to `PATH` first (the
> installer prints the exact line), or invoke the installed executable by its
> full path, e.g. `"$HOME/.local/bin/specrelay" version`.

### Install from a release tag

For users who want a pinned version instead of tracking `main`, do a shallow
clone of a specific tag and install from it:

```sh
git clone --branch vX.Y.Z --depth 1 git@github.com:SpecRelay/SpecRelay.git SpecRelay
cd SpecRelay
./install/install.sh
specrelay version     # should report X.Y.Z
```

> **Honesty note:** no version tag has been published yet — the repository
> currently has **no tags**, and publication is blocked until a license is
> chosen (see [publication.md](publication.md) and
> [versioning.md](versioning.md#releases-and-git-tags)). The command above is
> the documented path for **once a tag exists**; substitute the real tag name
> when there is one. Until then, use the `main`-clone path above.

### Release tarball / archive install

A downloadable **release tarball/archive** install (fetching a `.tar.gz` for a
tag and installing from the unpacked tree) is **not supported yet**: no release
archive is published, and SpecRelay does not download anything over the network
during install. When a real release archive exists, unpacking it yields the
same source layout as a checkout, so `./install/install.sh` from the unpacked
directory would work identically — but that flow is unverified today and is a
recorded follow-up (see [homebrew.md](homebrew.md) and the release plan in
[publication.md](publication.md)). Do not assume an archive URL until one is
published.

## Verifying which executable you are running

After installing, confirm you are running the copy you just installed:

```sh
command -v specrelay          # the specrelay resolved on your PATH
specrelay version             # the version it reports
specrelay doctor              # prints "SpecRelay home (<prefix>/share/specrelay)"
```

`command -v specrelay` prints the exact path; if it is not
`<prefix>/bin/specrelay`, an older or different install is shadowing it on your
`PATH`. The `doctor` output's "SpecRelay home" line names the resources
directory the running executable actually resolved, which is the definitive
answer to "which install is this?".

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

## Bootstrapping a consumer project (fake provider, no Claude)

You can enable SpecRelay in a project and run a full workflow **without Claude
installed**, using the deterministic `fake` provider. This is the fastest way
to confirm your install works end to end.

**Is there a `specrelay init`?** Yes — `specrelay init` is the supported way to
bootstrap a project; you do **not** have to hand-write configuration. It
creates `.specrelay/config.yml` from the built-in template, creates the spec
root, and adds a `.gitignore` entry for the runtime evidence directory.

The template's default executor is `claude` (see the note above about `init`'s
current fixed template), so for a no-Claude run you switch the providers to
`fake` after `init`:

```sh
cd my-project
git init                     # SpecRelay discovers the project root via git
specrelay init               # creates .specrelay/config.yml, spec root, .gitignore

# Switch executor AND reviewer to the deterministic fake provider so no Claude
# CLI is required. Edit .specrelay/config.yml so the roles block reads:
#
#   roles:
#     executor:
#       provider: fake
#     reviewer:
#       provider: fake

specrelay doctor             # should pass: fake providers are always available
```

The **minimal** `.specrelay/config.yml` for a fake-provider project is:

```yaml
version: 1
project:
  name: my-project
specs:
  root: specs
tasks:
  runs_root: .specrelay-runs/tasks
  max_iterations: 3
roles:
  executor:
    provider: fake
  reviewer:
    provider: fake
context:
  adapter: none
  required: false
validation:
  full_test_command: "echo ok"
policy:
  human_final_review_required: true
```

Specs live under the configured `specs.root` (default `specs/`), one directory
per task: `specs/0001-example/spec.md`. Run a first deterministic task:

```sh
mkdir -p specs/0001-example
printf '# Example spec\n' > specs/0001-example/spec.md
specrelay run specs/0001-example/spec.md
```

With the `fake` executor and `fake` reviewer this reaches
`READY_FOR_HUMAN_REVIEW` deterministically, producing real evidence files under
`.specrelay-runs/tasks/0001-example/`, and never calls any AI.

**Switching to the Claude provider.** When you are ready to use a real AI, set
the executor (and optionally reviewer) back to `claude` /`claude-subagent` in
`.specrelay/config.yml`, and install the Claude CLI so it is on your `PATH`.
`specrelay doctor` then verifies the Claude CLI is present; without it, doctor
fails (by default) so a missing provider is never hidden — see
[providers.md](providers.md).

**What `doctor` verifies in a consumer project:** that you are in a git
repository, `.specrelay/config.yml` is present and well-formed, the spec root
exists, the task runtime root is writable (or creatable), and the configured
executor/reviewer providers are available (`fake` always is; `claude` requires
the Claude CLI on `PATH`). It is read-only and changes nothing.

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

## Uninstalling

Remove an installed SpecRelay with the bundled uninstaller. It removes only the
tool-owned `<prefix>/bin/specrelay` and `<prefix>/share/specrelay/`, refuses to
delete an unrelated directory, is idempotent, and **never** touches any consumer
project's `.specrelay/` configuration, task runs, or specs:

```sh
./install/uninstall.sh                       # uninstall from ~/.local
./install/uninstall.sh --prefix "$HOME/.local"
```

The equivalent manual removal is `rm -f "$HOME/.local/bin/specrelay"` and
`rm -rf "$HOME/.local/share/specrelay"`. Full uninstall/reinstall details,
including what is intentionally left in consumer projects, are in
[upgrading.md](upgrading.md#uninstalling).

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

The Homebrew path is planned in phases (a project tap first, Homebrew core only
much later) and is described — with a clearly-marked **sample** formula — in
[homebrew.md](homebrew.md). No tap exists yet and `brew install specrelay` does
not work; that document plans the future, it does not enable it.
