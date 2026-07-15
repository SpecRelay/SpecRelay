# Jam recording capability (spec 0023)

Jam is a screen-recording tool. A specification or its supporting evidence
may link to a Jam recording as proof of a defect or expected behavior. This
document covers how SpecRelay treats a Jam link as first-class external
evidence.

## Optional globally, required per task

```text
Jam globally optional
+
Jam reference discovered in a task
=
Jam required for that task
```

- A SpecRelay installation and `specrelay doctor` remain usable with **no**
  Jam configuration at all.
- The moment a task's specification bundle contains a recognised Jam
  reference (a `https://…jam.dev/…` URL in `spec.md`, `tech-spec.md` /
  `tech_spec.md`, or any other directly-inspectable local evidence file), Jam
  becomes **required for that task**: the task must not begin Executor
  implementation until the recording has been retrieved, normalized,
  redacted, and snapshotted — or task creation fails with an actionable
  reason.
- A project may set `jam.required: true` to make Jam globally required (so
  `specrelay doctor` fails overall readiness whenever Jam itself is not
  ready, even with no task referencing it yet). The default is `false`.

## Configuration

```yaml
jam:
  required: false   # global policy; see "Optional globally, required per task" above
  retrieval_command: /path/to/jam-retrieve-adapter   # the real adapter; see below
```

Registration/readiness is a project-local `.mcp.json` entry (the same
mechanism `contextplus` uses — see `docs/context-adapters.md`), inspected via
`claude mcp list` plus the on-disk `.mcp.json`. **Retrieval itself** goes
through `jam.retrieval_command`: any executable SpecRelay invokes as
`<cmd> <canonical-id> <url> <out-dir>`, expected to write
`<evidence-class>.raw` files (`metadata.raw`, `transcript.raw`,
`user-events.raw`, `console-logs.raw`, `console-errors.raw`,
`network-requests.raw`, `network-errors.raw`, `environment.raw`) into
`<out-dir>` for whatever it can retrieve, then exit `0`. A typical adapter is
a small wrapper around a bounded `claude --print --strict-mcp-config` call
naming only the Jam MCP server's read tools (the same pattern
`context/contextplus.sh` uses for repository context — see
`docs/context-adapters.md`), or a direct Jam API client. SpecRelay core never
depends on unstable provider-specific Jam MCP tool names directly; it depends
on this stable internal adapter contract in `lib/specrelay/jam.sh`. With no
`jam.retrieval_command` configured, a task referencing Jam fails retrieval
clearly rather than fabricating success.

Test-only environment hooks (never used by a real installation):

- `SPECRELAY_JAM_CLAUDE_BIN` — override the Claude-compatible binary used for
  readiness checks.
- `SPECRELAY_JAM_SERVER_NAME` — override the registered MCP server name
  (default `jam`).
- `SPECRELAY_JAM_FAKE_RETRIEVE` — path to a fixture script that stands in for
  real retrieval. Automated tests must never touch a real Jam recording (see
  `test/jam_test.sh`).

## Doctor readiness states

`specrelay doctor` reports Jam **separately** from repository context
capabilities, distinguishing at least: `not-configured`, `configured`,
`registered`, `connected`, `authenticated`, `tools-available`, `ready`. A
configured-but-broken integration is reported honestly with actionable
detail — never silently downgraded to "not configured".

## What gets retrieved and where it lives

For each canonical Jam reference, SpecRelay retrieves, normalizes, redacts,
and snapshots whatever evidence classes the recording actually has, before
Executor invocation, beneath:

```text
<task-runtime>/01-input-bundle/external/jam/<canonical-id>/
  reference.json           # original URL, canonical id, retrieval status/timestamp
  metadata.json
  transcript.md
  user-events.json
  console-logs.json
  console-errors.json
  network-requests.json
  network-errors.json
  environment.json
  retrieval-evidence.json  # which evidence classes were available vs. missing
  redaction-report.json    # category + count per artifact; never the secret itself
```

Missing evidence classes are recorded honestly in `retrieval-evidence.json`
rather than silently omitted. Duplicate references to the same recording
(found in multiple local files) resolve to **one** canonical snapshot, with
every referencing file recorded as provenance in `01-input-manifest.json`.

Executor, Reviewer, and `resume` all consume this same immutable snapshot.
None of them re-fetches the recording — a URL alone is never treated as
evidence of inspection; only the snapshot contents may be cited.

## Security: redaction before durable storage

Jam evidence can contain credentials, authorization headers, tokens, cookies,
session identifiers, and other sensitive request/response data. Before
anything is written durably, the adapter redacts at minimum: authorization
headers, access/refresh tokens, cookies, session identifiers, and recognized
API keys/secrets — replacing each match with `[REDACTED:<category>]` and
recording only the artifact/category/count in `redaction-report.json`, never
the removed value. If evidence cannot be safely redacted under the active
policy, the task is blocked rather than stored unsafely.

**Never** point a real, sensitive Jam recording at an automated test run —
tests use `SPECRELAY_JAM_FAKE_RETRIEVE` fixtures exclusively.

## Future work

The resolved specification's "External Evidence" and "Defect Reproduction"
sections cite Jam-derived findings with provenance to the specific snapshot
artifact, but deep cross-evidence-class timeline correlation (e.g. "at 12.4s
the user clicked Submit; at 12.7s the network call failed") is left to the
Executor/Reviewer reading the raw snapshot directly — this module's automated
analysis pass is structural/bibliographic, not semantic. See spec 0023,
section 18.6, and the future complete artifact-layout migration noted in
`docs/migration.md`.
