# Execution modes, installation metadata, and safe updates

This document is the canonical reference for spec 0022's execution-mode
contract, installed-only update commands, daily update discovery, and
rollback safety. It replaces the "there is no `specrelay self-update`" claim
in [upgrading.md](upgrading.md) with the real, safe update workflow described
below — `specrelay self-update`-shaped behavior is now `specrelay update`.

## Execution modes

SpecRelay distinguishes two ways it can be running:

- **source-local** — the executable belongs to a SpecRelay repository
  checkout (`bin/specrelay` / `./bin/specrelay`). Always runs the current
  working tree.
- **installed** — the executable is an installed launcher whose runtime
  resources and installation metadata live under an installation prefix
  outside any source repository (typically the `specrelay` on your `PATH`).

Detection is **structural, not command-spelling based**: `bin/specrelay`
resolves its own real location by following symlinks before anything else
runs, so a repository checkout that has been symlinked elsewhere on `PATH`
still resolves back to the repository root — and a repository root always has
`bin/specrelay` directly under it, which an installed prefix's resource
directory (`<prefix>/share/specrelay`) never does (the installed launcher
lives at `<prefix>/bin/specrelay`, a *sibling* of the resource directory, not
inside it). That single structural fact is what `specrelay environment`
reports as `Execution mode`.

Source-local execution:

- always uses the current repository checkout;
- **never** performs automatic update discovery;
- **never** displays an update prompt;
- **never** reads or writes update-check/dismissal state
  (`update-state.json`);
- **never** makes a network request for update discovery;
- is never influenced by an installed version, even a newer one;
- `bin/specrelay update` refuses cleanly (no mutation) and explains that
  installed-update operations do not apply.

```
specrelay environment [--json]
```

```text
SpecRelay environment
  Execution mode: source-local
  Executable:     /path/to/specrelay/bin/specrelay
  Resources:      /path/to/specrelay
  Update checks:  disabled
```

```text
SpecRelay environment
  Execution mode: installed
  Executable:     /Users/user/.local/bin/specrelay
  Resources:      /Users/user/.local/share/specrelay
  Update checks:  enabled
  Check interval: 24h
```

## Installation metadata

An installed SpecRelay carries `install-metadata.json` (schema v1) directly
under its resource directory (`<prefix>/share/specrelay/install-metadata.json`
— under the install prefix, **never** in a consumer repository):

```json
{
  "schema_version": 1,
  "installation_type": "source-install",
  "installed_version": "0.5.0",
  "installed_commit": "abcdef123456",
  "installed_at": "2026-07-14T18:00:00Z",
  "executable_path": "/Users/user/.local/bin/specrelay",
  "resource_path": "/Users/user/.local/share/specrelay",
  "update_source": {
    "type": "official-git",
    "repository": "git@github.com:SpecRelay/SpecRelay.git",
    "ref": "main"
  }
}
```

Writes are atomic (temp file + rename). It never contains credentials or
access tokens. `install/install.sh` writes it on every fresh install and
reinstall.

```
specrelay install-info [--json]
```

```text
╭─ SpecRelay Installation ─────────────────────────────╮
│ Mode              installed                         │
│ Executable        ~/.local/bin/specrelay            │
│ Version           0.5.0                              │
│ Commit            abcdef12                           │
│ Resources         ~/.local/share/specrelay           │
│ Update source     official-git ... (main)            │
│ Last update       2026-07-14 18:00 UTC                │
╰──────────────────────────────────────────────────────╯
```

Read-only, no mutation, no network. A source-local invocation reports that
mode and explains installed-update metadata does not apply.

### Migrating an existing installation

An installation that predates spec 0022 has no `install-metadata.json`.
`install-info` reports this as a clear, actionable diagnostic rather than a
crash or a silent guess. The migration path is a one-time reinstall from an
official source (`./install/install.sh` from an up-to-date checkout, or
`specrelay update --from <path>`), which writes fresh metadata.

## Explicit update commands

All of the following are **installed mode only**.

### Check

```
specrelay update --check
```

Bypasses the 24h cache, performs read-only discovery, prints the installed
and available versions, and returns success whether or not a newer version
exists. Never modifies the installed payload.

### Update

```
specrelay update [--yes]
```

Discovers the newest released version from the configured official source
(Git tags), requires confirmation in an interactive terminal unless `--yes`
is given, then:

1. stages the new payload beside the current installation
   (`<share>.staging-<pid>`);
2. verifies it in place — resource files present, and a real copy of the
   launcher actually runs against the staged tree and reports the expected
   version;
3. **atomically activates** it with a rename-based swap
   (`<share>` → `<share>.old-<pid>`, staging → `<share>`);
4. **re-verifies** the now-live installation the same way;
5. writes fresh installation metadata only after that succeeds;
6. prints the installed version and commit as proof.

The prior installation is removed only after activation is verified; any
failure **before** activation leaves the current installation completely
untouched, and a failure **after** activation (step 4) rolls back
automatically, restoring the prior installation, reporting failure, and
returning non-zero.

### Explicit source

```
specrelay update --from /path/to/specrelay
```

Uses an explicit local SpecRelay source checkout instead of the configured
official source. The path must structurally look like a SpecRelay source
(`VERSION`, `bin/specrelay`, `lib/specrelay/`); a **dirty** source checkout
(uncommitted changes) is refused rather than reset or overwritten. The
installed payload is still staged and activated atomically, exactly as above.

### Dry run

```
specrelay update --dry-run
```

Shows the current installation, selected source, proposed version, the
installation areas that would change, the verification steps that would run,
and whether activation would occur — without mutating installation state.

### Non-interactive update

```
specrelay update --yes
```

Explicit consent for scripts. Automatic daily discovery (below) **never**
infers `--yes` on its own.

### Notification controls

```
specrelay update --ignore 0.6.0
specrelay update --reset-notifications
```

`--ignore <version>` records that exact version as dismissed (a later version
is still offered); `--reset-notifications` clears the cached check time and
any ignored version.

## Daily update discovery

Automatic discovery applies **only** to installed mode and **only** before
operational commands (`run`, `resume`) — it runs before task creation, task
approval, task claim, or any lifecycle transition, and at most once per 24
hours (a new automatic check does not run if a successful check happened less
than 24h ago). State (`last_checked_at`, `last_available_version`,
`ignored_version`, `last_check_status`) lives at
`<prefix>/share/specrelay/update-state.json` — user-level installation state,
never a project repository — written atomically.

Prompting requires **all** of: installed mode, an interactive stdin *and*
terminal, a newer valid semantic version, that exact version not already
ignored, and automatic checks enabled (`SPECRELAY_UPDATE_CHECK` unset or not
`0`):

```text
╭─ SpecRelay Update Available ───────────────╮
│ Installed   0.5.0                         │
│ Available   0.6.0                         │
╰────────────────────────────────────────────╯

Update before running this task? [y/N]
```

Accepting performs the safe update above, then **re-executes the original
command with exactly the original arguments** exactly once (an internal
loop-prevention marker stops a re-executed process from checking again).
Rejecting records that exact version as ignored and continues the original
command immediately; a later version is still offered.

### Non-interactive / CI behavior

- never prompts;
- never waits for input;
- never auto-installs;
- never blocks the requested command because discovery failed or a newer
  version exists;
- an available update produces **one** concise advisory on stderr
  (`specrelay: an update is available: ... `);
- repeated advisories respect the 24h check cache.

### Discovery failure

Network, source, or metadata failures during automatic discovery are recorded
honestly (`last_check_status: "failure"`) and **never** block `run`/`resume`.

### Disabling automatic discovery

```sh
SPECRELAY_UPDATE_CHECK=0 specrelay run <spec>
```

## Update source and version discovery

The official update mechanism compares semantic versions from Git tags at the
repository recorded in installation metadata (`update_source.repository`),
via read-only `git ls-remote --tags` — it never runs `git pull`, resets a
checkout, or treats an unversioned/moving branch tip as a released version.
`--from` is the explicit-operator-source alternative; a documented fallback
beyond these two would require a new release mechanism to exist first, and
none is claimed here.

## Safety requirements

- **Atomic installation** — the current installation remains usable until the
  replacement is fully staged and verified.
- **Rollback** — a post-activation verification failure restores the prior
  installation and metadata, reports failure, and returns non-zero without
  continuing the original command.
- **Locking** — concurrent update attempts are serialized (`mkdir`-based,
  same stale-lock-reclaim strategy as task locking).
- **No consumer mutation** — update/release commands never modify consumer
  source code, `.specrelay/config.yml`, task runtime data, or consumer Git
  state.
- **No secrets** — installation metadata and update state never contain
  credentials or tokens.
