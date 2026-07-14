# Contributing to SpecRelay

Thanks for your interest in SpecRelay. This guide covers how to develop, test,
and extend the tool. SpecRelay is a POSIX-shell CLI with two small helper
runtimes; it deliberately avoids heavy dependencies.

## Development setup

Requirements:

- `bash` (developed against both modern bash and the macOS system bash 3.2)
- `git`
- `ruby` — used to parse `.specrelay/config.yml` (via the standard `yaml`
  library / `YAML.safe_load`); no gems beyond Ruby's standard library
- `python3` — used to read/write task `state.json` (via
  `lib/specrelay/py/state_lib.py`)
- standard POSIX tools (`sed`, `awk`, `grep`, `find`, `mktemp`, `date`,
  `stat`, `readlink`)

No system directories are touched and no `sudo` is required. To try the CLI
from the source tree:

```sh
bin/specrelay version
bin/specrelay help
```

To install it into a throwaway prefix while developing:

```sh
./install/install.sh --prefix /tmp/specrelay-dev
# or symlink the executable back to the source tree:
./install/install.sh --prefix /tmp/specrelay-dev --dev-link
```

## Running the tests

The standalone suite runs entirely on isolated temporary Git fixtures — no host
application, no network, no real AI provider:

```sh
scripts/test
```

It uses the deterministic `fake` provider to exercise the full workflow
(accepted and request-changes/rework lifecycles). This is the suite that must
pass in an extracted, standalone repository.

### Parallel test runner (spec 0016)

`scripts/test` runs independent test files **concurrently** in a bounded number
of workers, captures each file's output in isolation, then prints the complete
logs in a **deterministic** order (test-name order, or the explicit input order
for targeted runs) so parallel completion order never changes what you see. It
records per-file timing and can report the slowest files.

```sh
scripts/test                                  # default (parallel)
scripts/test --jobs 8                          # explicit worker count
scripts/test --jobs auto                       # min(logical CPUs, 8)
scripts/test --serial                          # one worker; no overlap
scripts/test --timings                         # + timing summary + slowest list
scripts/test --slowest 5                       # show the 5 slowest files
scripts/test --slow-threshold 30               # mark files >= 30s as SLOW (informational)
scripts/test test/config_test.sh test/cli_test.sh   # run only the given files
```

- **Default worker count** is `min(logical CPU count, 8)`. Precedence:
  `--serial` → `--jobs` → `SPECRELAY_TEST_JOBS` → the auto default. Invalid job
  counts (`0`, `-1`, `abc`, absurdly large values) are rejected with a clear
  error, and a maximum bound guards against process explosions. The selected
  worker count is printed in the summary.
- **Targeted execution** runs only the files you name (order preserved).
  Unknown files, or files outside the `test/` root, are rejected — a typo never
  silently expands to a different file. Great for running just the affected
  tests during development instead of the whole suite repeatedly.
- **Timing evidence.** With `--timings`, a machine-readable timing profile is
  written to `.specrelay-cache/tests/latest.json` (created under the existing
  cache namespace; **git-ignored** reusable local profiling data — never a new
  top-level runtime directory). The file is written atomically, so an
  interrupted run never replaces a previous valid result. For task evidence,
  set an explicit destination — the active task is never inferred from the
  newest task directory:

  ```sh
  SPECRELAY_TEST_TIMINGS_OUT=.specrelay-runs/tasks/<task-id>/07-test-timings.json \
    scripts/test --jobs auto --timings
  ```

- **Serial-only tests.** A few tests may be unsafe to run concurrently (a fixed
  shared path/port/file, or global mutable state). Declare them, one bare
  `*_test.sh` basename per line, in [`test/serial-tests.txt`](test/serial-tests.txt);
  they run one at a time in the serial group (still timed) while every
  parallel-safe test runs concurrently. Classify a test as serial only for a
  **real** resource conflict — never merely because it is slow, and never to
  paper over a parallel flake (fix the isolation instead; a
  parallelization-induced flaky failure is a defect). The suite adds no retry
  mechanism.
- **Interrupts.** On `SIGINT`/`SIGTERM` the runner stops launching new tests,
  terminates active child processes (and their descendants — no orphans),
  cleans up its per-worker temp capture files (in the OS temp dir), reports
  which tests were cancelled or not run, exits non-zero, and never overwrites a
  previous valid `latest.json`.
- **Recommended full verification** after a change (runs the suite once, then
  the smoke-only checks — no duplicate suite run):

  ```sh
  scripts/test --jobs auto --timings
  scripts/smoke --skip-tests
  ```

  Reviewers can run just the affected tests plus the timing summary, e.g.
  `scripts/test test/<affected>_test.sh --timings`, and consult
  `.specrelay-cache/tests/latest.json` to confirm timing/overlap.

Host-integration tests (which need a host repository's legacy `.ai/` workflow,
rollback engine, or spec history) are kept separate and are run via
`test/run_all.sh` in the incubation host only. They are explicitly excluded
from `scripts/test` and stay visible in its final summary as skipped.

Please add or update tests for any behavior change, and keep new tests
host-independent (temporary Git fixtures + the `fake` provider) unless they are
genuinely host-integration tests.

## Architecture boundaries

The most important rule: **SpecRelay core must not depend on any host
repository's layout, docs, commands, or task-naming conventions.** The host
repository is one *consumer* of SpecRelay, not part of its implementation.

- Keep the tool's own location (`SPECRELAY_HOME`) and the consumer project's
  location (`PROJECT_ROOT`) strictly separate. Derive `SPECRELAY_HOME` from the
  executable's own path; never from the consumer project's Git root.
- No machine-specific absolute paths, and no host-specific strings (product
  names, `bundle exec rspec`, host doc paths, host task-run roots) in reusable
  core code. Put project-specific values in `.specrelay/config.yml` instead.
- Generic defaults are `specs/` (spec root) and `.specrelay-runs/tasks`
  (runtime evidence). These are defaults, not hardcoded requirements.
- Prefer portable shell: mkdir-based locking (not `flock`), `date -u
  +"%Y-%m-%dT%H:%M:%SZ"`, a `stat -f … || stat -c …` fallback for BSD/GNU, and
  a manual symlink-follow loop instead of `readlink -f`. Quote all paths.

## Contributing a provider adapter

Providers implement the executor and reviewer roles. See
[docs/providers.md](docs/providers.md) for the full contract. In short, a new
adapter must define: availability detection, executor invocation, reviewer
invocation, how stdout/stderr are used, exit-code semantics, and how the
accept/`request_changes` decision is extracted. Model your adapter on
`lib/specrelay/providers/fake.sh` (deterministic, for tests) and
`lib/specrelay/providers/claude.sh` (a real AI provider). Never store
credentials in config or logs.

## Contributing a context adapter

Context adapters run a capability preflight before a role does substantive
work. See [docs/context-adapters.md](docs/context-adapters.md). A new adapter
must define availability, the required-vs-optional policy, executor/reviewer
preflight, context retrieval, and failure behavior. `none` (no-op) and
`contextplus` are the reference implementations.

## Evidence expectations

Every workflow round produces durable evidence (executor log, tests output,
executor summary, Git diff/status snapshots), and prior rounds are archived
under `iterations/round-N/`. When changing the workflow, preserve this durable,
auditable handoff — do not make evidence ephemeral or overwrite prior rounds.

## Commit and review discipline

- Keep changes host-independent and covered by `scripts/test`.
- Do not weaken the human final gate or let the executor self-approve.
- Task state (`state.json`) is written only through audited transitions, never
  by hand.
