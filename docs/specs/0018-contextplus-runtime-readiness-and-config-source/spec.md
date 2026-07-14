# Context+ Runtime Readiness and Configuration Source
- Spec: 0018
- Status: Draft
---
# Summary
Make Context+ capability reporting accurate, explicit, and operationally useful.
SpecRelay currently reports the Context+ adapter as:
```text
Availability:
  available

when the Claude CLI executable is installed.

This is misleading because Claude CLI installation alone does not prove that:

* the Context+ MCP server is registered
* the MCP server is connected
* project-local MCP configuration exists
* global Claude MCP registration exists
* the server is usable with --strict-mcp-config
* semantic_code_search can actually be invoked
* the configured context source is compatible with the retrieval path

This specification introduces distinct runtime readiness states and explicit
configuration-source detection.

The Context+ adapter must distinguish:

installed
registered
connected
config source
retrieval ready

and must not collapse them into one ambiguous available status.

⸻

Problem

The current Context+ capability adapter contains two different assumptions.

Its local availability check effectively validates only:

command -v claude

This results in:

Availability:
  available

even when:

.mcp.json does not exist
Context+ is not registered
Context+ is not connected

The runtime preflight later performs:

claude mcp list

to inspect MCP registration and connection.

However, the retrieval invocation also uses:

--strict-mcp-config
--mcp-config <generated-config>

and attempts to construct that config from:

<project-root>/.mcp.json

This can create a contradiction:

Context+ is registered globally in Claude
but project .mcp.json does not exist

The adapter may therefore report availability before runtime while still being
unable to construct a valid strict MCP configuration for the actual retrieval.

⸻

Goals

* Separate executable installation from MCP readiness.
* Detect Context+ registration accurately.
* Detect connection health accurately.
* Detect the effective MCP configuration source.
* Distinguish project-local and global registration.
* Avoid misleading available reporting.
* Make contexts contextplus operationally useful.
* Make doctor report Context+ readiness honestly.
* Preserve non-billable inspection for contexts and doctor.
* Keep actual retrieval validation in explicit runtime preflight.
* Support project-local .mcp.json safely.
* Support global Claude MCP registration where technically reliable.
* Refuse unsupported or ambiguous config-source combinations.
* Preserve context.adapter: none behavior.
* Avoid leaking MCP credentials or configuration secrets.
* Keep executor and reviewer provider-independent at the generic context layer.

⸻

Non-Goals

This specification does not:

* build a new Context+ MCP server
* install Context+
* register Context+ automatically without explicit user approval
* modify global Claude MCP configuration
* perform billable retrieval from doctor
* perform billable retrieval from contexts
* expose MCP credentials
* copy complete MCP configuration into task evidence
* claim index freshness
* claim durable prepared context
* change Context+ capability level beyond preflight
* add a Context+ implementation for Codex
* change the generic context capability contract unnecessarily

⸻

Core Terminology

The Context+ adapter must use distinct readiness concepts.

Installed

The configured Claude-compatible CLI executable exists.

Example:

Installed: yes

This proves only that the executable can be launched.

It does not prove MCP registration or readiness.

⸻

Registered

The configured MCP server name appears in Claude MCP configuration or
claude mcp list.

Example:

Registered: yes

Registration source must be reported.

⸻

Connected

The MCP server is reported as connected by a reliable local/non-billable MCP
inspection command.

Example:

Connected: yes

A registered but disconnected server is not ready.

⸻

Configuration Source

The source used or available for the MCP server configuration.

Allowed conceptual values:

project
global
project-and-global
none
unknown

Human-readable examples:

project .mcp.json
global Claude MCP registration
project .mcp.json and global Claude MCP registration
not found

⸻

Retrieval Ready

The adapter has enough validated configuration to attempt the bounded retrieval
preflight.

Example:

Retrieval ready: yes

This does not mean retrieval has already succeeded.

It means the adapter can safely attempt it.

⸻

Preflight Verified

A real bounded Context+ retrieval was performed successfully.

This may only be established during the runtime preflight, not by contexts or
doctor.

Example:

Preflight verified: yes

⸻

Readiness Status Model

The adapter must expose a clear summary status.

Suggested statuses:

unavailable
installed
registered
disconnected
config-incomplete
ready
verified

Exact internal naming may follow repository conventions.

Required meaning:

unavailable

Claude-compatible executable not found.

installed

Executable exists, but Context+ registration is not found.

registered

Context+ registration exists, but connection or usable config is not yet proven.

disconnected

Context+ registration exists, but MCP reports it disconnected.

config-incomplete

Registration exists, but SpecRelay cannot produce a valid configuration for the
strict retrieval invocation.

ready

Registration, connection, and usable config source are available.

A bounded retrieval may be attempted.

verified

A bounded retrieval succeeded during runtime preflight.

⸻

Availability Contract

The generic context capability currently expects an availability result.

For Context+, availability must no longer mean only:

Claude executable exists

It must mean:

the adapter is ready enough for its promised capability

Because Context+ promises a real bounded retrieval preflight, availability must
require at least:

* executable installed
* server registered
* server connected
* usable configuration source
* supported provider combination

If these are not all true, availability must return non-zero and a precise
reason.

The adapter may expose additional inspection functions for detailed status.

⸻

Non-Billable Inspection

The following commands must remain non-billable:

bin/specrelay contexts
bin/specrelay contexts contextplus
bin/specrelay doctor

They may run commands such as:

claude mcp list

only if those commands are reliably non-billable and non-mutating.

They must not perform:

semantic_code_search
AI model invocation
bounded retrieval
provider prompt execution

⸻

Configuration Source Detection

The adapter must inspect possible Context+ configuration sources.

Project-Local Source

Project-local MCP configuration:

<project-root>/.mcp.json

Requirements:

* file exists
* valid JSON
* contains mcpServers
* contains the configured Context+ server name
* server entry is structurally usable
* errors are actionable
* credentials are never printed

Example:

Configuration source:
  project .mcp.json

⸻

Global Claude Source

Global registration may be discovered through Claude CLI.

Possible command:

claude mcp list

If Claude provides a reliable non-secret machine-readable inspection command,
the adapter may use it.

The adapter must not parse human-formatted output in a fragile way without tests
covering realistic variants.

If the CLI only exposes registration names and connection status but not the
server configuration required by --strict-mcp-config, global registration may
be detectable but not usable for strict retrieval.

In that case report:

Registered: yes
Connected: yes
Configuration source: global Claude registration
Retrieval ready: no
Reason: strict MCP configuration cannot be reconstructed safely

Do not fabricate a usable config.

⸻

Project and Global Source Precedence

The adapter must define deterministic precedence.

Recommended policy:

valid project .mcp.json entry
→ global registration only when safely usable
→ unavailable/config-incomplete

Project-local configuration should be preferred for reproducibility.

If both project and global registrations exist:

* report both
* identify the source selected for retrieval
* detect incompatible server definitions where possible
* do not silently switch between them

Example:

Detected sources:
  project .mcp.json
  global Claude MCP registration
Selected source:
  project .mcp.json

⸻

Strict MCP Configuration

The current retrieval uses:

--strict-mcp-config

This means the adapter must provide a valid explicit MCP config.

The implementation must make an explicit decision:

Option A — Project-Local Required

Only a valid project .mcp.json entry can satisfy retrieval readiness.

Global registration may be displayed but cannot make the adapter ready.

Example:

Registered globally: yes
Project config: missing
Retrieval ready: no

Option B — Safe Global Export Supported

Global registration can be exported or resolved through a reliable Claude CLI
mechanism without exposing secrets.

Then the adapter may construct strict config from the supported export.

The implementation must not choose Option B unless the mechanism is real,
documented, and covered by tests.

Fallback recommendation:

Prefer Option A unless global export is provably safe and supported.

⸻

Contexts Command Output

Update:

bin/specrelay contexts contextplus

Example when Claude is installed but Context+ is not registered:

Context adapter: contextplus
Description:
  Context Plus MCP preflight with one bounded semantic retrieval.
Runtime readiness:
  Installed:       yes
  Registered:      no
  Connected:       no
  Config source:   none
  Retrieval ready: no
Status:
  installed
Reason:
  Context+ MCP server 'contextplus' is not registered.
Inspect Claude MCP registration with:
  claude mcp list

⸻

Example when globally registered but no usable project config exists:

Runtime readiness:
  Installed:       yes
  Registered:      yes
  Connected:       yes
  Project config:  missing
  Global config:   detected
  Selected source: none
  Retrieval ready: no
Status:
  config-incomplete
Reason:
  Global registration is visible, but SpecRelay cannot construct a safe strict
  MCP config from it. Add a project-local .mcp.json entry.

⸻

Example when project configuration is valid:

Runtime readiness:
  Installed:       yes
  Registered:      yes
  Connected:       yes
  Project config:  valid
  Global config:   detected
  Selected source: project .mcp.json
  Retrieval ready: yes
Status:
  ready

⸻

Context List Output

Update:

bin/specrelay contexts

Current output such as:

contextplus   built-in  available

must be replaced with a more accurate compact status.

Examples:

contextplus   built-in  installed-not-registered
contextplus   built-in  disconnected
contextplus   built-in  config-incomplete
contextplus   built-in  ready

Do not use ambiguous available unless the adapter is genuinely ready.

⸻

Doctor Integration

bin/specrelay doctor must report detailed Context+ readiness when the adapter
is configured for executor or reviewer.

Example:

✓ Executor context adapter: contextplus
✓ Executor context executable: claude found
✗ Executor context MCP registration: contextplus not registered
✗ Executor context readiness: unavailable

Required policy behavior remains:

required=true

Context+ not ready causes doctor failure.

required=false

Context+ not ready causes an advisory warning.

Doctor must not run the bounded retrieval.

Doctor must not mutate MCP config.

⸻

Unconfigured Adapter Inspection

When the project context adapter is:

context:
  adapter: none

doctor is not required to deeply inspect Context+.

However:

bin/specrelay contexts contextplus

must still provide accurate detailed readiness.

The general:

bin/specrelay contexts

must not label Context+ ready merely because Claude is installed.

⸻

Runtime Preflight

The runtime preflight must re-check readiness before bounded retrieval.

This protects against changes between inspection and execution:

server disconnected
config removed
registration changed
binary removed

Ordering:

validate config
inspect readiness
select config source
build strict MCP config
run bounded retrieval
verify semantic_code_search evidence
return success

⸻

Bounded Retrieval

The current bounded retrieval contract remains:

* one Context+ semantic_code_search tool call
* no unrelated tool calls
* explicit allowed tool
* budget cap
* machine-readable stream output
* evidence that the Context+ tool was invoked
* failure on non-zero provider exit
* failure when expected tool evidence is absent

The implementation must not weaken these protections.

⸻

Temporary MCP Config

When creating a narrowed temporary MCP config:

* use a secure temporary directory
* include only the selected server
* set restrictive file permissions where practical
* remove temporary files on success
* remove temporary files on failure
* remove temporary files on interrupt where possible
* never write the config into task evidence
* never print its secret values

⸻

Security and Redaction

The adapter must never print or persist:

* API keys
* access tokens
* command arguments containing secrets
* environment credentials
* complete .mcp.json contents
* full global MCP configuration
* authentication headers

Error messages may identify:

server name
config source
missing field names
connection status

but not secret values.

⸻

Provider Compatibility

The generic context layer remains provider-independent.

The Context+ adapter may currently support only Claude-family automated
providers because the bounded retrieval implementation uses Claude CLI.

Supported provider behavior must be explicit.

Examples:

claude: supported
claude-subagent: supported
manual: not applicable
fake: test-only behavior
codex: unsupported

Unsupported automated providers must fail before entering running state when
Context+ is required.

Do not silently route Codex through Claude merely to retrieve context unless a
separate specification explicitly authorizes that architecture.

⸻

Configuration Validation

Support explicit Context+ configuration where useful.

Conceptual example:

context:
  adapter: contextplus
  required: true
  options:
    server_name: contextplus
    config_source: project

Role-specific variant:

context:
  executor:
    adapter: contextplus
    required: true
    options:
      server_name: contextplus
      config_source: project

The exact syntax must follow existing config conventions.

Possible config-source values:

auto
project
global

Requirements:

* auto follows deterministic source precedence
* project requires a valid project .mcp.json
* global is accepted only if safely supported
* unknown values are rejected
* empty server names are rejected
* options are role-specific where configured

Do not add options that are not implemented.

⸻

Recommended Initial Scope

To avoid unsafe global config reconstruction, the minimum acceptable
implementation is:

project-local retrieval readiness

Meaning:

* claude mcp list may confirm registration/connection
* a valid project .mcp.json entry is required for strict retrieval
* global-only registration is reported but classified as config-incomplete
* no fake global export is attempted

This is preferable to reporting false readiness.

⸻

Readiness Inspection API

Extend the adapter capability contract with a structured readiness inspection.

Conceptually:

status
installed
registered
connected
project_config
global_registration
selected_source
retrieval_ready
reason

The exact interface may use:

* key=value lines
* JSON
* repository-consistent shell functions

Generic contexts and doctor code should consume structured adapter output
rather than reimplement Context+ checks.

⸻

Fake/Test Hooks

Provide deterministic test hooks or fixture binaries for:

* Claude executable missing
* MCP list failure
* Context+ not registered
* registered but disconnected
* registered and connected
* project .mcp.json missing
* malformed project .mcp.json
* server absent from project .mcp.json
* valid project .mcp.json
* global-only registration
* both global and project sources
* bounded retrieval success
* bounded retrieval failure
* expected tool call missing
* secret redaction

Tests must not require real Context+ or a live network.

⸻

Required Tests

Installation

* missing Claude executable reports installed=false
* existing Claude executable reports installed=true
* installation alone does not report ready
* installation alone does not report available

Registration

* missing server registration reports registered=false
* registered server reports registered=true
* configured server name is respected
* similarly named server does not produce false match
* MCP list command failure is reported separately
* empty MCP list output is handled

Connection

* connected server reports connected=true
* disconnected server reports connected=false
* unknown connection status is not treated as connected
* human-readable MCP output parsing is covered by realistic fixtures

Project Configuration

* missing .mcp.json is detected
* malformed JSON is detected
* missing mcpServers is detected
* configured server missing from mcpServers is detected
* valid server entry is detected
* project config secrets are not printed
* selected server is copied into temporary strict config only

Source Selection

* project-only source selects project
* global-only registration is reported
* global-only registration does not become retrieval-ready unless safely
    supported
* both sources are reported
* project source has deterministic precedence
* explicitly requested unsupported global source fails clearly
* auto behavior is deterministic

Status

* installed-only status is not ready
* registered-but-disconnected status is not ready
* connected-but-no-project-config status is config-incomplete
* valid project config plus connected registration is ready
* status reasons are actionable

Contexts Command

* list output uses precise readiness status
* detail output shows installed/registered/connected/source/ready
* no billable retrieval occurs
* no MCP mutation occurs
* output contains no secrets
* output remains append-only and copyable

Doctor

* optional Context+ unready produces warning
* required Context+ unready produces failure
* ready Context+ passes non-billable inspection
* doctor does not invoke semantic retrieval
* doctor displays selected configuration source

Runtime Preflight

* preflight re-checks readiness
* missing registration blocks before role running state
* disconnected server blocks before role running state
* config-incomplete blocks before role running state
* optional failure degrades honestly
* required failure blocks provider execution
* valid readiness runs exactly one bounded retrieval
* successful retrieval requires expected tool evidence
* retrieval failure remains a hard failure when required

Temporary Config

* generated config contains only selected server
* temp config is removed after success
* temp config is removed after failure
* file content is never added to task evidence
* secret values never appear in logs

Compatibility

* context.adapter: none remains unchanged
* fake context adapter remains unchanged
* Context+ capability level remains preflight
* existing context adapter tests remain green
* workflow remains free from scattered Context+ branches
* existing tests remain green

⸻

Acceptance Criteria

This specification is accepted only when:

* Context+ installation and readiness are distinct
* available is no longer based only on command -v claude
* registration is checked accurately
* connection is checked accurately
* project MCP config is validated
* effective config source is reported
* global-only registration is not falsely treated as strict-config-ready
* contexts contextplus is honest and actionable
* doctor is honest and non-billable
* runtime preflight re-checks readiness
* bounded retrieval safety remains intact
* secrets are not exposed
* no unsupported provider path is silently accepted
* all existing tests pass
* no new top-level runtime directory is introduced

⸻

Reviewer Rejection Conditions

The reviewer must reject if:

* Claude installation is still equivalent to Context+ readiness
* global registration is claimed usable without a real export/config mechanism
* .mcp.json absence is ignored while using --strict-mcp-config
* registration matching can confuse similarly named servers
* disconnected servers are treated as ready
* doctor performs a billable retrieval
* contexts performs a billable retrieval
* secrets appear in output or evidence
* temporary MCP config persists after execution
* unsupported providers silently use Claude
* readiness is reported through ambiguous prose only
* tests rely on a real Context+ server

⸻

Verification

Inspect current local status:

bin/specrelay contexts contextplus

Inspect Claude MCP registration:

claude mcp list

Run:

scripts/test --changed --jobs auto --timings --explain

Run focused tests:

scripts/test test/context_adapters_test.sh

Run full verification:

scripts/test --jobs auto --timings

Run smoke without duplicate tests:

scripts/smoke --skip-tests

Run:

SPECRELAY_PROVIDER_OPTIONAL=1 bin/specrelay doctor
bin/specrelay version

Verify Context+ status under fixture scenarios:

binary missing
not registered
disconnected
global-only registration
project config missing
project config malformed
project config valid
ready
retrieval success
retrieval failure

Verify no secret values appear in:

terminal output
07-tests.txt
task state
context evidence

⸻

Executor Deliverables

Write:

03-executor-log.md
07-tests.txt
08-executor-summary.md

The executor summary must explicitly report:

* readiness state model
* installed versus registered versus connected
* project/global config-source behavior
* strict MCP config decision
* contexts output changes
* doctor behavior
* runtime preflight behavior
* provider compatibility
* security/redaction protections
* test fixture architecture
* verification results

⸻

Reviewer Focus

The reviewer must independently verify:

1. Claude installation alone is not reported as Context+ ready
2. global registration and project config are distinguished
3. global-only configuration is not falsely used with strict MCP mode
4. disconnected servers are rejected
5. contexts and doctor remain non-billable
6. runtime preflight still performs exactly one bounded retrieval
7. temporary MCP config is cleaned up
8. secrets never appear in logs or evidence
9. required failures happen before running-state transitions
   