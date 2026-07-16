#!/usr/bin/env bash
# config_local_test.sh — local developer configuration overlay (spec 0027,
# section 32, tests 32.1-32.26). Uses only temporary fixture directories and
# the deterministic 'fake' provider — never the real repository's own
# .specrelay/config.yml, and never a real AI provider.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# shellcheck source=../lib/specrelay/output.sh
. "$SPECRELAY_ROOT/lib/specrelay/output.sh"
# shellcheck source=../lib/specrelay/config.sh
. "$SPECRELAY_ROOT/lib/specrelay/config.sh"

# =============================================================================
# 32.1 — No local file: existing configuration behavior is unchanged.
# =============================================================================
proj1="$(specrelay_test::mktemp_project)"
mkdir -p "$proj1/.specrelay"
cat > "$proj1/.specrelay/config.yml" <<'YAML'
version: 1
roles:
  executor:
    provider: claude
    model: provider-default
    agent: none
YAML
specrelay_test::assert_eq "32.1: no local file — merge is ok" "0" "$(specrelay::config::effective_ok "$proj1"; echo $?)"
out1="$(specrelay::config::effective_data_yaml "$proj1")"
specrelay_test::assert_contains "32.1: effective data equals shared-only data" "$out1" "provider: claude"
specrelay_test::assert_eq "32.1: role_model_selection unaffected by absent local file" \
  "provider-default" "$(specrelay::config::role_model_selection "$proj1" executor)"

# =============================================================================
# 32.2 — Sparse deep override: a nested scalar overrides only that value.
# =============================================================================
proj2="$(specrelay_test::mktemp_project)"
mkdir -p "$proj2/.specrelay"
cat > "$proj2/.specrelay/config.yml" <<'YAML'
version: 1
roles:
  executor:
    provider: claude
    model: provider-default
    agent: none
YAML
cat > "$proj2/.specrelay/config.local.yml" <<'YAML'
roles:
  executor:
    model: claude-sonnet-5
YAML
out2="$(specrelay::config::effective_data_yaml "$proj2")"
specrelay_test::assert_contains "32.2: overridden leaf takes the local value" "$out2" "model: claude-sonnet-5"
specrelay_test::assert_contains "32.2: sibling provider is preserved from shared" "$out2" "provider: claude"
specrelay_test::assert_contains "32.2: sibling agent is preserved from shared" "$out2" "agent: none"

# =============================================================================
# 32.3 — List replacement: a local list replaces, never concatenates.
# =============================================================================
proj3="$(specrelay_test::mktemp_project)"
mkdir -p "$proj3/.specrelay"
cat > "$proj3/.specrelay/config.yml" <<'YAML'
version: 1
some_list:
  - a
  - b
  - c
YAML
cat > "$proj3/.specrelay/config.local.yml" <<'YAML'
some_list:
  - z
YAML
out3="$(specrelay::config::effective_data_yaml "$proj3")"
specrelay_test::assert_contains "32.3: replaced list contains the local entry" "$out3" "- z"
specrelay_test::assert_not_contains "32.3: replaced list does NOT contain shared entries (no concatenation)" "$out3" "- a"

# =============================================================================
# 32.4 — Null removal: explicit null removes the inherited raw value, and
# built-in defaults apply afterward (verified via role_context: an absent
# adapter key resolves to the "none" default).
# =============================================================================
proj4="$(specrelay_test::mktemp_project)"
mkdir -p "$proj4/.specrelay"
cat > "$proj4/.specrelay/config.yml" <<'YAML'
version: 1
context:
  adapter: fake
  required: true
YAML
cat > "$proj4/.specrelay/config.local.yml" <<'YAML'
context:
  adapter: null
YAML
out4="$(specrelay::config::effective_data_yaml "$proj4")"
specrelay_test::assert_not_contains "32.4: null-removed key is absent from the merged raw config" "$out4" "adapter:"
specrelay_test::assert_contains "32.4: null-removed key's sibling survives" "$out4" "required: true"
ctx4="$(specrelay::config::role_context "$proj4" executor)"
specrelay_test::assert_contains "32.4: after removal, the built-in adapter default (none) applies" "$ctx4" "adapter=none"

# =============================================================================
# 32.5 — Type conflict: mapping/scalar conflicts fail with source and path.
# =============================================================================
proj5="$(specrelay_test::mktemp_project)"
mkdir -p "$proj5/.specrelay"
cat > "$proj5/.specrelay/config.yml" <<'YAML'
version: 1
roles:
  executor:
    provider: claude
YAML
cat > "$proj5/.specrelay/config.local.yml" <<'YAML'
roles:
  executor: "oops"
YAML
err5="$(specrelay::config::effective_data_yaml "$proj5")"
rc5=$?
specrelay_test::assert_eq "32.5: type conflict fails (exit 1)" "1" "$rc5"
specrelay_test::assert_contains "32.5: error names the path" "$err5" "roles.executor"
specrelay_test::assert_contains "32.5: error names the conflicting shape" "$err5" "must be a mapping, got string"

# The reverse direction (scalar shared value, mapping local value) also fails.
proj5b="$(specrelay_test::mktemp_project)"
mkdir -p "$proj5b/.specrelay"
cat > "$proj5b/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: scalar-name
YAML
cat > "$proj5b/.specrelay/config.local.yml" <<'YAML'
project:
  name:
    nested: value
YAML
err5b="$(specrelay::config::effective_data_yaml "$proj5b")"
rc5b=$?
specrelay_test::assert_eq "32.5: reverse type conflict (scalar -> mapping) also fails" "1" "$rc5b"
specrelay_test::assert_contains "32.5: reverse-conflict error names the path" "$err5b" "project.name"

# =============================================================================
# 32.6 — Invalid local YAML fails before task role invocation.
# =============================================================================
proj6="$(specrelay_test::mktemp_project)"
mkdir -p "$proj6/.specrelay" "$proj6/docs/sdd/0027-bad-local"
cat > "$proj6/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: Fixture
specs:
  root: docs/sdd
tasks:
  runs_root: .specrelay-runs/tasks
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
YAML
printf 'not: [valid: yaml: broken\n' > "$proj6/.specrelay/config.local.yml"
echo "# spec" > "$proj6/docs/sdd/0027-bad-local/spec.md"
(cd "$proj6" && git add -A && git commit -q -m init)
out6="$(cd "$proj6" && "$SPECRELAY_BIN" run docs/sdd/0027-bad-local/spec.md 2>&1)"
rc6=$?
specrelay_test::assert_true "32.6: run with invalid local YAML exits non-zero" "$([ "$rc6" -ne 0 ]; echo $?)"
specrelay_test::assert_contains "32.6: run reports invalid local configuration" "$out6" "config.local.yml"
specrelay_test::assert_not_contains "32.6: the fake executor never recorded an invocation" \
  "$(cat "$proj6/.specrelay-runs/tasks/0027-bad-local/12-executor-stdout.txt" 2>/dev/null)" "fake-executor"

# =============================================================================
# 32.7 — Unknown key: unknown local keys fail under the same schema rules as
# shared configuration (context section's known-key check).
# =============================================================================
proj7="$(specrelay_test::mktemp_project)"
mkdir -p "$proj7/.specrelay"
cat > "$proj7/.specrelay/config.yml" <<'YAML'
version: 1
context:
  adapter: none
  required: false
YAML
cat > "$proj7/.specrelay/config.local.yml" <<'YAML'
context:
  bogus_key: true
YAML
err7="$(specrelay::config::role_context "$proj7" executor)"
rc7=$?
specrelay_test::assert_eq "32.7: unknown local key under context: fails (exit 1)" "1" "$rc7"
specrelay_test::assert_contains "32.7: unknown-key error names it" "$err7" "bogus_key"

# =============================================================================
# 32.8 — Precedence: defaults < shared < local < environment < CLI (env/local
# tested through workflow.sh's role_model_selection, which applies the
# role-specific env override ABOVE config.sh's merged shared+local result).
# =============================================================================
# shellcheck source=../lib/specrelay/state.sh
. "$SPECRELAY_ROOT/lib/specrelay/state.sh"
# shellcheck source=../lib/specrelay/task.sh
. "$SPECRELAY_ROOT/lib/specrelay/task.sh"
proj8="$(specrelay_test::mktemp_project)"
mkdir -p "$proj8/.specrelay"
cat > "$proj8/.specrelay/config.yml" <<'YAML'
version: 1
roles:
  executor:
    model: shared-model
YAML
# defaults < shared: no local, no env.
sel8a="$(specrelay::config::role_model_selection "$proj8" executor)"
specrelay_test::assert_eq "32.8: shared value used when no local/env override" "id:shared-model" "$sel8a"

cat > "$proj8/.specrelay/config.local.yml" <<'YAML'
roles:
  executor:
    model: local-model
YAML
sel8b="$(specrelay::config::role_model_selection "$proj8" executor)"
specrelay_test::assert_eq "32.8: local overrides shared" "id:local-model" "$sel8b"

# shellcheck source=../lib/specrelay/providers/capability.sh
. "$SPECRELAY_ROOT/lib/specrelay/providers/capability.sh"
# shellcheck source=../lib/specrelay/workflow.sh
. "$SPECRELAY_ROOT/lib/specrelay/workflow.sh"
sel8c="$(SPECRELAY_EXECUTOR_MODEL=env-model specrelay::workflow::role_model_selection "$proj8" executor 2>/dev/null || true)"
specrelay_test::assert_eq "32.8: environment overrides local" "id:env-model" "$sel8c"

# =============================================================================
# 32.9 — Git ignore initialization: `init` adds the entry exactly once,
# without disturbing unrelated entries.
# =============================================================================
proj9="$(specrelay_test::mktemp_project)"
printf 'my-unrelated-entry/\n' > "$proj9/.gitignore"
(cd "$proj9" && "$SPECRELAY_BIN" init >/dev/null 2>&1)
gi9="$(cat "$proj9/.gitignore")"
specrelay_test::assert_contains "32.9: init adds the local-overlay ignore entry" "$gi9" ".specrelay/config.local.yml"
specrelay_test::assert_contains "32.9: init preserves the unrelated pre-existing entry" "$gi9" "my-unrelated-entry/"
count9="$(grep -c '^\.specrelay/config\.local\.yml$' "$proj9/.gitignore")"
specrelay_test::assert_eq "32.9: the entry appears exactly once" "1" "$count9"
(cd "$proj9" && "$SPECRELAY_BIN" init >/dev/null 2>&1)
count9b="$(grep -c '^\.specrelay/config\.local\.yml$' "$proj9/.gitignore")"
specrelay_test::assert_eq "32.9: re-running init does not duplicate the entry" "1" "$count9b"
specrelay_test::assert_true "32.9: init copies the committed example overlay" \
  "$([ -f "$proj9/.specrelay/config.local.example.yml" ]; echo $?)"

# =============================================================================
# 32.10 — Git ignore warning: doctor reports a present-but-unignored local
# file (no secret-like field) as a WARNING, not a failure.
# =============================================================================
proj10="$(specrelay_test::mktemp_project)"
mkdir -p "$proj10/.specrelay" "$proj10/specs"
cat > "$proj10/.specrelay/config.yml" <<'YAML'
version: 1
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
YAML
cat > "$proj10/.specrelay/config.local.yml" <<'YAML'
roles:
  executor:
    model: claude-sonnet-5
YAML
(cd "$proj10" && git add -A && git commit -q -m init)
out10="$(cd "$proj10" && SPECRELAY_PROVIDER_OPTIONAL=1 "$SPECRELAY_BIN" doctor 2>&1)"
rc10=$?
specrelay_test::assert_eq "32.10: doctor still exits 0 (advisory warning only)" "0" "$rc10"
specrelay_test::assert_contains "32.10: doctor warns the local overlay is not ignored" "$out10" "Local overlay Git ignore: not ignored"

# =============================================================================
# 32.11 — Secret exposure failure: doctor fails when a trackable local file
# contains a secret-like key.
# =============================================================================
proj11="$(specrelay_test::mktemp_project)"
mkdir -p "$proj11/.specrelay" "$proj11/specs"
cp "$proj10/.specrelay/config.yml" "$proj11/.specrelay/config.yml"
cat > "$proj11/.specrelay/config.local.yml" <<'YAML'
integrations:
  example:
    token: super-secret-value
YAML
(cd "$proj11" && git add -A && git commit -q -m init)
out11="$(cd "$proj11" && SPECRELAY_PROVIDER_OPTIONAL=1 "$SPECRELAY_BIN" doctor 2>&1)"
rc11=$?
specrelay_test::assert_true "32.11: doctor fails (exit non-zero)" "$([ "$rc11" -ne 0 ]; echo $?)"
specrelay_test::assert_contains "32.11: doctor reports the secret exposure risk" "$out11" "Secret exposure risk: unsafe"
specrelay_test::assert_not_contains "32.11: doctor never prints the raw secret value" "$out11" "super-secret-value"

# =============================================================================
# 32.12 — Redaction: config show / config explain / doctor / JSON never
# print secret values.
# =============================================================================
proj12="$proj11"
show12="$(cd "$proj12" && "$SPECRELAY_BIN" config show --effective --json)"
specrelay_test::assert_not_contains "32.12: config show --json never prints the secret" "$show12" "super-secret-value"
specrelay_test::assert_contains "32.12: config show --json redacts the secret" "$show12" "REDACTED"
explain12="$(cd "$proj12" && "$SPECRELAY_BIN" config explain integrations.example.token)"
specrelay_test::assert_not_contains "32.12: config explain never prints the secret" "$explain12" "super-secret-value"
specrelay_test::assert_contains "32.12: config explain redacts the secret" "$explain12" "REDACTED"

# =============================================================================
# 32.13 — Symlink outside the project root is rejected.
# =============================================================================
proj13="$(specrelay_test::mktemp_project)"
mkdir -p "$proj13/.specrelay"
cat > "$proj13/.specrelay/config.yml" <<'YAML'
version: 1
YAML
outside13="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-outside.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$outside13")
echo "roles: {}" > "$outside13/evil.yml"
ln -s "$outside13/evil.yml" "$proj13/.specrelay/config.local.yml"
err13="$(specrelay::config::effective_data_yaml "$proj13")"
rc13=$?
specrelay_test::assert_eq "32.13: symlink escaping the project root is rejected (exit 1)" "1" "$rc13"
specrelay_test::assert_contains "32.13: rejection error mentions the symlink" "$err13" "symlink"

# =============================================================================
# 32.14 — Config show: source status and redacted effective configuration.
# =============================================================================
show14="$(cd "$proj2" && "$SPECRELAY_BIN" config show --sources)"
specrelay_test::assert_contains "32.14: config show reports the shared source" "$show14" "shared:"
specrelay_test::assert_contains "32.14: config show reports the local source" "$show14" "local:"
specrelay_test::assert_contains "32.14: config show reports precedence" "$show14" "defaults < shared < local < environment < CLI"

# =============================================================================
# 32.15 — Config explain: final source and overridden source for a normal
# scalar.
# =============================================================================
explain15="$(cd "$proj2" && "$SPECRELAY_BIN" config explain roles.executor.model)"
specrelay_test::assert_contains "32.15: explain reports the final value" "$explain15" "claude-sonnet-5"
specrelay_test::assert_contains "32.15: explain reports the local source" "$explain15" ".specrelay/config.local.yml"
specrelay_test::assert_contains "32.15: explain reports the replaced shared value" "$explain15" "provider-default"

# =============================================================================
# 32.16 — Config explain secret: reports provenance but redacts the value.
# =============================================================================
explain16="$(cd "$proj12" && "$SPECRELAY_BIN" config explain integrations.example.token)"
specrelay_test::assert_contains "32.16: explain still reports the source for a secret path" "$explain16" ".specrelay/config.local.yml"
specrelay_test::assert_not_contains "32.16: explain redacts the secret value" "$explain16" "super-secret-value"

# =============================================================================
# 32.17-32.20 — Task effective capture, resume-unchanged, resume-changed
# local config, and a historical task without configuration metadata. Shares
# one real (fake-provider) task fixture: reviewer is 'manual' so `resume`
# calls below are fast (no re-invocation of a provider).
# =============================================================================
proj17="$(specrelay_test::mktemp_project)"
mkdir -p "$proj17/.specrelay" "$proj17/docs/sdd/0027-capture"
cat > "$proj17/.specrelay/config.yml" <<'YAML'
version: 1
project:
  name: Fixture
specs:
  root: docs/sdd
tasks:
  runs_root: .specrelay-runs/tasks
roles:
  executor:
    provider: fake
    model: executor-model-A
  reviewer:
    provider: manual
context:
  adapter: none
  required: false
validation:
  full_test_command: "echo ok"
policy:
  human_final_review_required: true
YAML
echo "# spec" > "$proj17/docs/sdd/0027-capture/spec.md"
(cd "$proj17" && git add -A && git commit -q -m init)
(cd "$proj17" && "$SPECRELAY_BIN" run docs/sdd/0027-capture/spec.md >/dev/null 2>&1)

state17="$proj17/.specrelay-runs/tasks/0027-capture/state.json"
cfg_eff17="$(python3 -c "import json; d=json.load(open('$state17')); print(json.dumps(d.get('configuration_effective')))")"
specrelay_test::assert_contains "32.17: task captures configuration_effective" "$cfg_eff17" "schema_version"
specrelay_test::assert_contains "32.17: capture records the shared source path" "$cfg_eff17" ".specrelay/config.yml"
specrelay_test::assert_contains "32.17: capture records the precedence order" "$cfg_eff17" "environment"
sha17="$(python3 -c "import json; d=json.load(open('$state17')); print([s['sha256'] for s in d['configuration_effective']['sources'] if s['kind']=='shared'][0])")"
specrelay_test::assert_true "32.17: captured shared digest is a real sha256 (64 hex chars)" \
  "$(printf '%s' "$sha17" | grep -Eq '^[0-9a-f]{64}$'; echo $?)"

# 32.18 — resume with unchanged sources: no drift note.
resume18="$(cd "$proj17" && "$SPECRELAY_BIN" resume 0027-capture 2>&1)"
specrelay_test::assert_not_contains "32.18: resume with unchanged config prints no drift note" \
  "$resume18" "continuing with the CAPTURED configuration"

# 32.19 — resume after the local config changed: no silent adoption.
cat > "$proj17/.specrelay/config.local.yml" <<'YAML'
roles:
  executor:
    model: executor-model-B
YAML
resume19="$(cd "$proj17" && "$SPECRELAY_BIN" resume 0027-capture 2>&1)"
specrelay_test::assert_contains "32.19: resume after a local config change prints the drift note" \
  "$resume19" "continuing with the CAPTURED configuration"
captured_model19="$(python3 -c "import json; d=json.load(open('$state17')); print(d['roles_effective']['executor']['model'])")"
specrelay_test::assert_eq "32.19: durable state still records the ORIGINAL captured executor model" \
  "executor-model-A" "$captured_model19"
show19="$(cd "$proj17" && "$SPECRELAY_BIN" task show 0027-capture 2>&1)"
specrelay_test::assert_contains "32.19: task show reports the captured model, not the new local one" \
  "$show19" "executor-model-A"
specrelay_test::assert_not_contains "32.19: task show does NOT report the new local model" \
  "$show19" "executor-model-B"
rm -f "$proj17/.specrelay/config.local.yml"

# 32.20 — a historical task without configuration_effective reports honestly.
python3 -c "
import json
with open('$state17') as f:
    d = json.load(f)
d.pop('configuration_effective', None)
with open('$state17', 'w') as f:
    json.dump(d, f)
"
resume20="$(cd "$proj17" && "$SPECRELAY_BIN" resume 0027-capture 2>&1)"
specrelay_test::assert_contains "32.20: a task without capture reports 'not recorded' honestly" \
  "$resume20" "configuration provenance: not recorded"
specrelay_test::assert_not_contains "32.20: no fabricated digest comparison is printed" \
  "$resume20" "continuing with the CAPTURED configuration"

# =============================================================================
# 32.21 — Multi-service integration: local verification overrides are
# applied AND a sparse override preserves sibling fields (e.g. `required`).
# =============================================================================
proj21="$(specrelay_test::mktemp_project)"
mkdir -p "$proj21/.specrelay"
cat > "$proj21/.specrelay/config.yml" <<'YAML'
version: 1
verification:
  services:
    products:
      root: .
      checks:
        unit:
          kind: command
          command: "echo shared-command"
          required: true
          timeout_seconds: 300
YAML
cat > "$proj21/.specrelay/config.local.yml" <<'YAML'
verification:
  services:
    products:
      checks:
        unit:
          command: "echo local-command"
          timeout_seconds: 900
YAML
raw21="$(specrelay::config::verification_engine_raw "$proj21")"
specrelay_test::assert_contains "32.21: local verification command override is applied" "$raw21" "local-command"
specrelay_test::assert_contains "32.21: local timeout override is applied" "$raw21" "900"
specrelay_test::assert_contains "32.21: sparse override preserves the required flag from shared" "$raw21" "\"required\":true"

# =============================================================================
# 32.22 — Required verification protection: a sparse local override cannot
# accidentally drop a required check's `required` flag, and an explicit
# override of it is visible (validated), never silent.
# =============================================================================
raw22_sparse="$raw21"
specrelay_test::assert_contains "32.22: sparse local override does not silently drop required=true" \
  "$raw22_sparse" "\"required\":true"

proj22b="$(specrelay_test::mktemp_project)"
mkdir -p "$proj22b/.specrelay"
cp "$proj21/.specrelay/config.yml" "$proj22b/.specrelay/config.yml"
cat > "$proj22b/.specrelay/config.local.yml" <<'YAML'
verification:
  services:
    products:
      checks:
        unit:
          required: false
YAML
raw22b="$(specrelay::config::verification_engine_raw "$proj22b")"
specrelay_test::assert_contains "32.22: an EXPLICIT local required:false override is visible in the merged config (validated, not silently applied)" \
  "$raw22b" "\"required\":false"

# =============================================================================
# 32.23 — Coordinator isolation: the coordinator input snapshot never
# includes raw local configuration content, and the existing centralized
# redaction mechanism (reused, not reimplemented) still redacts secret-shaped
# keys inside any snapshot fed through it.
# =============================================================================
specrelay_test::assert_true "32.23: coordinator.sh's snapshot builder does not read config.local.yml directly" \
  "$(grep -q 'config.local.yml' "$SPECRELAY_ROOT/lib/specrelay/coordinator.sh" && echo 1 || echo 0)"
redact23="$(printf '%s' '{"integrations":{"token":"super-secret-value"}}' | python3 "$SPECRELAY_ROOT/lib/specrelay/py/coordinator_lib.py" redact-snapshot)"
specrelay_test::assert_not_contains "32.23: coordinator's reused redaction mechanism strips a secret value" \
  "$redact23" "super-secret-value"

# =============================================================================
# 32.24 — Source-local/installed parity: configuration discovery/precedence
# depends ONLY on the project root, never on SPECRELAY_HOME — so both
# execution modes resolve identically.
# =============================================================================
fake_home24="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-fakehome.XXXXXX")"
SPECRELAY_TEST_TMP_DIRS+=("$fake_home24")
out24a="$(specrelay::config::effective_data_yaml "$proj2")"
out24b="$(SPECRELAY_HOME="$fake_home24" specrelay::config::effective_data_yaml "$proj2")"
specrelay_test::assert_eq "32.24: merge result is identical regardless of SPECRELAY_HOME (install boundary)" \
  "$out24a" "$out24b"

# =============================================================================
# 32.25 — Atomic read: the digest and the parsed content come from the same
# bytes actually on disk.
# =============================================================================
envelope25="$(specrelay::config::effective_envelope "$proj2")"
sha_reported25="$(printf '%s' "$envelope25" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for s in d["sources"]:
    if s["kind"] == "shared":
        print(s["sha256"])
')"
sha_actual25="$(shasum -a 256 "$proj2/.specrelay/config.yml" | awk '{print $1}')"
specrelay_test::assert_eq "32.25: reported shared digest matches the actual on-disk bytes" \
  "$sha_actual25" "$sha_reported25"

# =============================================================================
# 32.26 — No command expansion during inspection: a value containing shell
# syntax is printed as data, never executed.
# =============================================================================
proj26="$(specrelay_test::mktemp_project)"
mkdir -p "$proj26/.specrelay"
marker26="$(mktemp -u "${TMPDIR:-/tmp}/specrelay-marker26.XXXXXX")"
cat > "$proj26/.specrelay/config.yml" <<YAML
version: 1
project:
  name: safe-name
YAML
cat > "$proj26/.specrelay/config.local.yml" <<YAML
project:
  name: '\$(touch $marker26)'
YAML
show26="$(cd "$proj26" && "$SPECRELAY_BIN" config show --effective)"
explain26="$(cd "$proj26" && "$SPECRELAY_BIN" config explain project.name)"
specrelay_test::assert_true "32.26: marker file was NOT created (no command execution)" \
  "$([ ! -e "$marker26" ]; echo $?)"
specrelay_test::assert_contains "32.26: config show prints the shell syntax as literal data" "$show26" '$(touch'
specrelay_test::assert_contains "32.26: config explain prints the shell syntax as literal data" "$explain26" '$(touch'

specrelay_test::summary
exit $?
