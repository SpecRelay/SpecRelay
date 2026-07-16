#!/usr/bin/env bash
# ui_verification_test.sh — UI runtime verification and compact review
# evidence (spec 0028). Covers: configuration validation, UI-impact
# detection, scenario-schema validation, scenario selection/coverage,
# runtime readiness, the deterministic fake provider's PASS/FAIL/BLOCKED
# classification, screenshot compact-evidence policy (crop/dedup/size/no-
# fabrication), console/network capture+redaction, expected-reference
# comparison, unapproved-origin rejection, trace-on-failure policy, resume/
# reuse, publication (dry-run + refusal-before-review + real publish), the
# CLI surface, doctor integration, and the transitions.sh::accept completion
# gate. NEVER requires a real browser (spec section 40) — every scenario
# below uses provider: fake.

# shellcheck source=test_helper.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
for f in output project config discovery state task lock auth git_guard evidence \
         verification verification_policy verification_runner ui_verification \
         agent_efficiency transitions; do
  # shellcheck disable=SC1090
  . "$SPECRELAY_ROOT/lib/specrelay/$f.sh"
done

UI_LIB_PY="$SPECRELAY_ROOT/lib/specrelay/py/ui_verification_lib.py"

# specrelay_test::ui_py <subcommand> <payload-json> [extra-args...]
specrelay_test::ui_py() {
  local cmd="$1" payload="$2"; shift 2
  printf '%s' "$payload" | python3 "$UI_LIB_PY" "$cmd" "$@"
}

specrelay_test::ui_field() {
  # $1=json $2=python-expr-on-loaded-dict-named-d
  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(eval(sys.argv[2]))
" "$1" "$2" 2>/dev/null
}

# =============================================================================
# 1. Configuration validation (spec section 10) — python engine
# =============================================================================

valid_cfg_out="$(specrelay_test::ui_py detect '{"ui_config": {}, "changed_paths": [], "spec_text": "no ui words here"}')"
specrelay_test::assert_contains "empty ui_config resolves to defaults (auto, not required)" "$valid_cfg_out" "required: False"

invalid_cfg_out="$(specrelay_test::ui_py detect '{"ui_config": {"enabled": "sometimes"}}' 2>&1)"
specrelay_test::assert_contains "invalid enabled value is rejected" "$invalid_cfg_out" "INVALID"

unknown_key_out="$(specrelay_test::ui_py detect '{"ui_config": {"not_a_real_key": true}}' 2>&1)"
specrelay_test::assert_contains "unknown top-level ui config key is rejected" "$unknown_key_out" "unknown key"

bad_provider_out="$(specrelay_test::ui_py detect '{"ui_config": {"provider": "selenium"}}' 2>&1)"
specrelay_test::assert_contains "unknown provider is rejected" "$bad_provider_out" "INVALID"

# spec-0019 bounded-policy parser must not reject the spec-0028 'ui' key
# (config.sh's known_top allowlist) — a project that configures
# verification.ui alongside the bounded run-count policy stays valid.
ui_and_bounded_proj="$(specrelay_test::mktemp_project)"
mkdir -p "$ui_and_bounded_proj/.specrelay"
cat > "$ui_and_bounded_proj/.specrelay/config.yml" <<'YAML'
version: 1
verification:
  executor:
    full_suite_max_runs: 2
  ui:
    enabled: false
YAML
bounded_policy_out="$(specrelay::config::verification_policy "$ui_and_bounded_proj" 2>&1)"
specrelay_test::assert_contains "spec-0019 bounded policy parser accepts a sibling 'ui:' key" "$bounded_policy_out" "executor_full_suite_max_runs=2"

# =============================================================================
# 2. UI-impact detection (spec section 12)
# =============================================================================

auto_detect="$(specrelay_test::ui_py detect '{"ui_config": {}, "changed_paths": [], "spec_text": "Add a new Save button to the settings page."}')"
specrelay_test::assert_contains "auto mode detects UI keywords in spec text" "$auto_detect" "detected: True"
specrelay_test::assert_contains "auto mode records the matched keywords as a reason" "$auto_detect" "button"
specrelay_test::assert_contains "keyword-only detection is NOT sufficient to require verification (no corroborating signal)" "$auto_detect" "required: False"

# A real, independent review of this feature found that isolated UI-adjacent
# vocabulary ("form", "page", "visual", ...) appears incidentally in ordinary,
# genuinely non-UI requirement prose -- keyword-only detection alone must
# never block `task accept` for such a task. Corroboration with at least one
# other, more deliberate signal (a configured UI path actually changed, an
# explicit UI-task marking, or a supplied expected reference) is required.
corroborated_detect="$(specrelay_test::ui_py detect '{"ui_config": {"detection": {"paths": ["app/views/**"]}}, "changed_paths": ["app/views/settings.html"], "spec_text": "Add a new Save button to the settings page."}')"
specrelay_test::assert_contains "keyword signal PLUS a corroborating changed-path signal together require verification" "$corroborated_detect" "required: True"

auto_no_signal="$(specrelay_test::ui_py detect '{"ui_config": {}, "changed_paths": ["lib/foo.rb"], "spec_text": "Refactor the internal cache eviction algorithm."}')"
specrelay_test::assert_contains "auto mode with no signal is not required" "$auto_no_signal" "required: False"

paths_detect="$(specrelay_test::ui_py detect '{"ui_config": {"detection": {"paths": ["app/views/**"]}}, "changed_paths": ["app/views/settings.html"], "spec_text": "internal refactor"}')"
specrelay_test::assert_contains "auto mode detects via configured detection.paths" "$paths_detect" "required: True"

explicit_true="$(specrelay_test::ui_py detect '{"ui_config": {"enabled": true}, "spec_text": "nothing ui related"}')"
specrelay_test::assert_contains "enabled: true is always required regardless of signals" "$explicit_true" "required: True"

explicit_false_conflict="$(specrelay_test::ui_py detect '{"ui_config": {"enabled": false, "required_when_detected": true}, "explicit_ui_task": true}' 2>&1)"
specrelay_test::assert_contains "enabled: false with an explicit UI task and required_when_detected produces a conflict, never a silent skip" "$explicit_false_conflict" "INVALID"

explicit_false_ok="$(specrelay_test::ui_py detect '{"ui_config": {"enabled": false}, "spec_text": "adds a button"}')"
specrelay_test::assert_contains "enabled: false without an explicit UI task is honored" "$explicit_false_ok" "required: False"

# =============================================================================
# 3. Scenario schema validation (spec section 13)
# =============================================================================

good_scenario='[{"id":"01-x","title":"T","acceptance_criteria":["A"],"steps":[{"action":"goto","url":"/x"}],"assertions":[{"type":"visible","target":"A"}],"checkpoints":[]}]'
plan_ok="$(specrelay_test::ui_py plan "{\"ui_config\": {\"enabled\": true, \"provider\":\"fake\"}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $good_scenario}" --json)"
specrelay_test::assert_contains "a valid scenario manifest is accepted" "$plan_ok" '"id": "01-x"'

bad_action='[{"id":"01-x","title":"T","acceptance_criteria":["A"],"steps":[{"action":"teleport","url":"/x"}],"assertions":[],"checkpoints":[]}]'
bad_action_out="$(specrelay_test::ui_py plan "{\"ui_config\": {\"enabled\": true}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $bad_action}" 2>&1)"
specrelay_test::assert_contains "an unknown step action is rejected" "$bad_action_out" "unknown action"

dup_id='[{"id":"01-x","title":"T","acceptance_criteria":["A"],"steps":[{"action":"goto","url":"/x"}],"assertions":[],"checkpoints":[]},{"id":"01-x","title":"U","acceptance_criteria":["B"],"steps":[{"action":"goto","url":"/y"}],"assertions":[],"checkpoints":[]}]'
dup_id_out="$(specrelay_test::ui_py plan "{\"ui_config\": {\"enabled\": true}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $dup_id}" 2>&1)"
specrelay_test::assert_contains "a duplicate scenario id is rejected" "$dup_id_out" "duplicate scenario id"

# =============================================================================
# 4. Scenario selection + acceptance-criterion coverage (spec section 14)
# =============================================================================

two_scenarios='[{"id":"01-a","title":"A","acceptance_criteria":["Only Berechnung is offered"],"steps":[{"action":"goto","url":"/x"}],"assertions":[],"checkpoints":[]},{"id":"02-b","title":"B","acceptance_criteria":["Unrelated criterion"],"steps":[{"action":"goto","url":"/y"}],"assertions":[],"checkpoints":[]}]'
selection_out="$(specrelay_test::ui_py plan "{\"ui_config\": {\"enabled\": true}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $two_scenarios, \"acceptance_criteria_text\": \"Only Berechnung is offered for new rules\", \"required_acceptance_criteria\": [\"Only Berechnung is offered\"]}" --json)"
specrelay_test::assert_contains "scenario selection matches on acceptance criterion" "$selection_out" '"01-a"'
specrelay_test::assert_not_contains "scenario selection excludes the non-matching scenario" "$(specrelay_test::ui_field "$selection_out" 'd["scenarios"]["selected"]')" "02-b"
specrelay_test::assert_contains "coverage is complete when the required criterion is covered" "$selection_out" '"coverage_complete": true'

missing_coverage_out="$(specrelay_test::ui_py plan "{\"ui_config\": {\"enabled\": true}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $two_scenarios, \"acceptance_criteria_text\": \"Unrelated criterion only\", \"required_acceptance_criteria\": [\"Only Berechnung is offered\", \"Unrelated criterion\"]}" --json)"
specrelay_test::assert_contains "missing material coverage is detected and named" "$missing_coverage_out" "Only Berechnung is offered"
specrelay_test::assert_contains "missing coverage marks coverage_complete false" "$missing_coverage_out" '"coverage_complete": false'

fallback_out="$(specrelay_test::ui_py plan "{\"ui_config\": {\"enabled\": true}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $two_scenarios}" --json)"
specrelay_test::assert_contains "no criteria/service filter falls back to the full configured set" "$fallback_out" '"fallback_used": true'

# =============================================================================
# 5. Runtime readiness (spec section 15) + non-UI backward compatibility
# =============================================================================

disabled_run="$(specrelay_test::ui_py run "{\"root\": \".\", \"task_dir\": \"/tmp/specrelay-ui-nonui.$$\", \"ui_config\": {\"enabled\": false}, \"spec_text\": \"adds a button\"}" --json)"
specrelay_test::assert_contains "a non-UI-required run performs no scenario execution" "$disabled_run" '"overall_status": "NOT_REQUIRED"'
specrelay_test::assert_contains "a non-UI-required run records no browser started" "$(cat "/tmp/specrelay-ui-nonui.$$/29-ui-verification/runtime.log" 2>/dev/null)" "no browser started"
rm -rf "/tmp/specrelay-ui-nonui.$$"

not_ready_run="$(specrelay_test::ui_py run "{\"root\": \".\", \"task_dir\": \"/tmp/specrelay-ui-notready.$$\", \"ui_config\": {\"enabled\": true, \"provider\": \"fake\"}, \"spec_text\": \"adds a button\", \"scenarios_raw\": $good_scenario}" --json)"
specrelay_test::assert_contains "missing runtime start_command/ready_url produces BLOCKED, never PASS" "$not_ready_run" '"overall_status": "BLOCKED"'
rm -rf "/tmp/specrelay-ui-notready.$$"

# =============================================================================
# 6. Fake-provider execution and PASS/FAIL/BLOCKED classification (spec 17, 40)
# =============================================================================

exec_scenarios='[
  {"id":"01-pass","title":"Pass","acceptance_criteria":["A passes"],"steps":[{"action":"goto","url":"/x"}],"assertions":[{"type":"visible","target":"A"}],"checkpoints":[{"id":"cp1"}],"fixture":{"case":"pass","screenshots":{"cp1":{"width":40,"height":30,"seed":5}}}},
  {"id":"02-fail","title":"Fail","acceptance_criteria":["B fails"],"steps":[{"action":"goto","url":"/y"}],"assertions":[{"type":"absent","target":"B"}],"checkpoints":[],"fixture":{"case":"failed_assertion"}},
  {"id":"03-blocked-creds","title":"Blocked creds","acceptance_criteria":["Needs login"],"steps":[{"action":"goto","url":"/z"}],"assertions":[],"checkpoints":[],"fixture":{"case":"blocked_credentials"}},
  {"id":"04-blocked-data","title":"Blocked data","acceptance_criteria":["Needs data"],"steps":[{"action":"goto","url":"/w"}],"assertions":[],"checkpoints":[],"fixture":{"case":"blocked_test_data"}},
  {"id":"05-console","title":"Console error","acceptance_criteria":["No console errors"],"steps":[{"action":"goto","url":"/c"}],"assertions":[],"checkpoints":[],"fixture":{"case":"console_error"}},
  {"id":"06-network","title":"Network 500","acceptance_criteria":["No network errors"],"steps":[{"action":"goto","url":"/n"}],"assertions":[],"checkpoints":[],"fixture":{"case":"network_500"}}
]'
exec_task_dir="/tmp/specrelay-ui-exec.$$"
mkdir -p "$exec_task_dir"
exec_payload="{\"root\": \".\", \"task_dir\": \"$exec_task_dir\", \"ui_config\": {\"enabled\": true, \"provider\": \"fake\", \"runtime\": {\"start_command\": \"bin/dev\", \"ready_url\": \"http://127.0.0.1:9/health\"}}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $exec_scenarios, \"commit\": \"c1\"}"
exec_run="$(specrelay_test::ui_py run "$exec_payload" --json)"

specrelay_test::assert_contains "PASS scenario produces structured evidence with a screenshot" "$(cat "$exec_task_dir/29-ui-verification/scenarios/01-01-pass/result.json")" '"status": "ok"'
specrelay_test::assert_contains "a failed assertion produces FAIL" "$exec_run" '"id": "02-fail"'
fail_result="$(cat "$exec_task_dir/29-ui-verification/scenarios/02-02-fail/result.json")"
specrelay_test::assert_contains "scenario 02 result is FAIL" "$fail_result" '"result": "FAIL"'
creds_result="$(cat "$exec_task_dir/29-ui-verification/scenarios/03-03-blocked-creds/result.json")"
specrelay_test::assert_contains "missing credentials produce BLOCKED" "$creds_result" '"result": "BLOCKED"'
data_result="$(cat "$exec_task_dir/29-ui-verification/scenarios/04-04-blocked-data/result.json")"
specrelay_test::assert_contains "missing test data produce BLOCKED" "$data_result" '"result": "BLOCKED"'
console_result="$(cat "$exec_task_dir/29-ui-verification/scenarios/05-05-console/result.json")"
specrelay_test::assert_contains "a configured fatal console error turns PASS into FAIL" "$console_result" '"result": "FAIL"'
network_result="$(cat "$exec_task_dir/29-ui-verification/scenarios/06-06-network/result.json")"
specrelay_test::assert_contains "a configured fatal network status turns PASS into FAIL" "$network_result" '"result": "FAIL"'
specrelay_test::assert_contains "overall run status reflects the worst required scenario" "$exec_run" '"overall_status": "BLOCKED"'

# =============================================================================
# 7. Console/network redaction (spec section 21, 28)
# =============================================================================

specrelay_test::assert_not_contains "network authorization header is redacted, never published raw" "$(cat "$exec_task_dir/29-ui-verification/network-errors.json")" "secret-token-should-be-redacted"
specrelay_test::assert_contains "redacted network header is marked REDACTED" "$(cat "$exec_task_dir/29-ui-verification/network-errors.json")" "REDACTED"
specrelay_test::assert_contains "console error text is recorded" "$(cat "$exec_task_dir/29-ui-verification/console-errors.json")" "simulated console error"

# =============================================================================
# 8. Screenshot policy: element-preferred capture, dedup, size limits (18)
# =============================================================================

dedup_scenarios='[{"id":"01-dup","title":"Dup","acceptance_criteria":["Same shot twice"],"steps":[{"action":"goto","url":"/x"}],"assertions":[],"checkpoints":[{"id":"cpA"},{"id":"cpB"}],"fixture":{"case":"pass","screenshots":{"cpA":{"width":10,"height":10,"seed":9},"cpB":{"width":10,"height":10,"seed":9}}}}]'
dedup_dir="/tmp/specrelay-ui-dedup.$$"
mkdir -p "$dedup_dir"
specrelay_test::ui_py run "{\"root\": \".\", \"task_dir\": \"$dedup_dir\", \"ui_config\": {\"enabled\": true, \"provider\": \"fake\", \"runtime\": {\"start_command\": \"x\", \"ready_url\": \"http://x/health\"}}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $dedup_scenarios}" --json >/dev/null
dedup_result="$(cat "$dedup_dir/29-ui-verification/scenarios/01-01-dup/result.json")"
specrelay_test::assert_contains "a duplicate screenshot is recorded as 'duplicate', never re-published" "$dedup_result" '"status": "duplicate"'
dup_file_count="$(find "$dedup_dir/29-ui-verification/scenarios/01-01-dup/screenshots" -type f 2>/dev/null | wc -l | tr -d ' ')"
specrelay_test::assert_eq "only one physical screenshot file exists for two identical checkpoints" "1" "$dup_file_count"
rm -rf "$dedup_dir"

oversized_scenarios='[{"id":"01-big","title":"Big","acceptance_criteria":["Big image"],"steps":[{"action":"goto","url":"/x"}],"assertions":[],"checkpoints":[{"id":"cpBig"}],"fixture":{"case":"pass","screenshots":{"cpBig":{"width":5000,"height":5000,"seed":3}}}}]'
oversized_dir="/tmp/specrelay-ui-oversized.$$"
mkdir -p "$oversized_dir"
oversized_run="$(specrelay_test::ui_py run "{\"root\": \".\", \"task_dir\": \"$oversized_dir\", \"ui_config\": {\"enabled\": true, \"provider\": \"fake\", \"runtime\": {\"start_command\": \"x\", \"ready_url\": \"http://x/health\"}, \"screenshots\": {\"max_width\": 100, \"max_height\": 100, \"max_file_bytes\": 5000}}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $oversized_scenarios}" --json)"
oversized_result="$(cat "$oversized_dir/29-ui-verification/scenarios/01-01-big/result.json")"
specrelay_test::assert_contains "an oversized screenshot is optimized within configured limits" "$oversized_result" '"optimized": true'
specrelay_test::assert_contains "an optimized oversized screenshot still PASSes" "$oversized_result" '"result": "PASS"'
big_file="$(find "$oversized_dir/29-ui-verification/scenarios/01-01-big/screenshots" -type f 2>/dev/null | head -1)"
big_bytes="$(wc -c < "$big_file" | tr -d ' ')"
specrelay_test::assert_true "the optimized screenshot file is within the configured byte limit" "$([ "$big_bytes" -le 5000 ] && echo 0 || echo 1)"
rm -rf "$oversized_dir"

unblockable_scenarios='[{"id":"01-huge","title":"Huge","acceptance_criteria":["Cannot shrink"],"steps":[{"action":"goto","url":"/x"}],"assertions":[],"checkpoints":[{"id":"cpHuge"}],"fixture":{"case":"pass","screenshots":{"cpHuge":{"width":50,"height":50,"seed":1}}}}]'
unblockable_dir="/tmp/specrelay-ui-unshrinkable.$$"
mkdir -p "$unblockable_dir"
unblockable_run="$(specrelay_test::ui_py run "{\"root\": \".\", \"task_dir\": \"$unblockable_dir\", \"ui_config\": {\"enabled\": true, \"provider\": \"fake\", \"runtime\": {\"start_command\": \"x\", \"ready_url\": \"http://x/health\"}, \"screenshots\": {\"max_width\": 1, \"max_height\": 1, \"max_file_bytes\": 1}}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $unblockable_scenarios}" --json)"
specrelay_test::assert_contains "a screenshot that cannot meet limits without becoming unreadable BLOCKS safely" "$unblockable_run" '"overall_status": "BLOCKED"'
rm -rf "$unblockable_dir"

# AI/scenario-authored evidence can never be injected: a checkpoint has no
# path field at all in the schema, so a scenario cannot name an arbitrary
# pre-existing file as "the" screenshot — every published image originates
# from bytes THIS run's provider function produced.
fabrication_scenario='[{"id":"01-x","title":"T","acceptance_criteria":["A"],"steps":[{"action":"goto","url":"/x"}],"assertions":[],"checkpoints":[{"id":"cp1","screenshot_path":"/etc/hosts"}]}]'
fab_dir="/tmp/specrelay-ui-fab.$$"
mkdir -p "$fab_dir"
specrelay_test::ui_py run "{\"root\": \".\", \"task_dir\": \"$fab_dir\", \"ui_config\": {\"enabled\": true, \"provider\": \"fake\", \"runtime\": {\"start_command\": \"x\", \"ready_url\": \"http://x/health\"}}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $fabrication_scenario}" --json >/dev/null
fab_result="$(cat "$fab_dir/29-ui-verification/scenarios/01-01-x/result.json")"
specrelay_test::assert_not_contains "a scenario-supplied 'screenshot_path' is never treated as evidence (no path-based injection)" "$fab_result" "/etc/hosts"
rm -rf "$fab_dir"

# =============================================================================
# 9. Expected-reference comparison (spec section 22-24)
# =============================================================================

ref_dir="/tmp/specrelay-ui-ref.$$"
mkdir -p "$ref_dir"
python3 -c "
import sys
sys.path.insert(0, '$SPECRELAY_ROOT/lib/specrelay/py')
import ui_verification_lib as ui
open('$ref_dir/expected_match.png', 'wb').write(ui.make_fixture_png(40, 30, 5))
open('$ref_dir/expected_mismatch.png', 'wb').write(ui.make_fixture_png(40, 30, 6))
"
ref_scenario='[{"id":"01-ref","title":"Ref","acceptance_criteria":["Matches design"],"steps":[{"action":"goto","url":"/x"}],"assertions":[],"checkpoints":[{"id":"cp1"}],"fixture":{"case":"pass","screenshots":{"cp1":{"width":40,"height":30,"seed":5}}}}]'

ignore_out="$(specrelay_test::ui_py run "{\"root\": \".\", \"task_dir\": \"$ref_dir/ignore\", \"ui_config\": {\"enabled\": true, \"provider\": \"fake\", \"runtime\": {\"start_command\": \"x\", \"ready_url\": \"http://x/health\"}, \"expected_references\": {\"policy\": \"ignore\"}}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $ref_scenario}" --json)"
specrelay_test::assert_contains "policy 'ignore' never claims a comparison was performed" "$ignore_out" '"visual_comparison_performed": false'

no_ref_out="$(specrelay_test::ui_py run "{\"root\": \".\", \"task_dir\": \"$ref_dir/noref\", \"ui_config\": {\"enabled\": true, \"provider\": \"fake\", \"runtime\": {\"start_command\": \"x\", \"ready_url\": \"http://x/health\"}, \"expected_references\": {\"policy\": \"compare-when-present\"}}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $ref_scenario}" --json)"
specrelay_test::assert_contains "'compare-when-present' behaves honestly without a supplied reference" "$(cat "$ref_dir/noref/29-ui-verification/scenarios/01-01-ref/report.md")" "not assessed: no expected reference supplied"
specrelay_test::assert_contains "'compare-when-present' with no reference still PASSes behaviorally" "$no_ref_out" '"overall_status": "PASS"'

required_missing_out="$(specrelay_test::ui_py run "{\"root\": \".\", \"task_dir\": \"$ref_dir/reqmissing\", \"ui_config\": {\"enabled\": true, \"provider\": \"fake\", \"runtime\": {\"start_command\": \"x\", \"ready_url\": \"http://x/health\"}, \"expected_references\": {\"policy\": \"required\"}}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $ref_scenario}" --json)"
specrelay_test::assert_contains "'required' reference policy BLOCKS when the reference is missing" "$required_missing_out" '"overall_status": "BLOCKED"'

match_out="$(specrelay_test::ui_py run "{\"root\": \".\", \"task_dir\": \"$ref_dir/match\", \"ui_config\": {\"enabled\": true, \"provider\": \"fake\", \"runtime\": {\"start_command\": \"x\", \"ready_url\": \"http://x/health\"}}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $ref_scenario, \"expected_references\": [{\"checkpoint_id\": \"cp1\", \"path\": \"$ref_dir/expected_match.png\", \"snapshot_path\": \"01-input-bundle/external/design/cp1.png\"}]}" --json)"
specrelay_test::assert_contains "a matching visual comparison PASSes and records method+environment" "$match_out" '"visual_comparison_performed": true'
match_comparisons="$(python3 -c "import json; print(json.load(open('$ref_dir/match/29-ui-verification/scenarios/01-01-ref/result.json'))['comparisons'])")"
specrelay_test::assert_contains "recorded comparison states the method and a threshold" "$match_comparisons" "sha256-exact"

mismatch_out="$(specrelay_test::ui_py run "{\"root\": \".\", \"task_dir\": \"$ref_dir/mismatch\", \"ui_config\": {\"enabled\": true, \"provider\": \"fake\", \"runtime\": {\"start_command\": \"x\", \"ready_url\": \"http://x/health\"}}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $ref_scenario, \"expected_references\": [{\"checkpoint_id\": \"cp1\", \"path\": \"$ref_dir/expected_mismatch.png\", \"snapshot_path\": \"01-input-bundle/external/design/cp1.png\"}]}" --json)"
specrelay_test::assert_contains "a visual mismatch produces FAIL" "$mismatch_out" '"overall_status": "FAIL"'
rm -rf "$ref_dir"

# =============================================================================
# 10. Unapproved-origin navigation is rejected (spec section 36)
# =============================================================================

origin_scenario='[{"id":"01-ext","title":"Ext nav","acceptance_criteria":["No external nav"],"steps":[{"action":"goto","url":"https://evil.example.com/phish"}],"assertions":[],"checkpoints":[]}]'
origin_dir="/tmp/specrelay-ui-origin.$$"
mkdir -p "$origin_dir"
origin_run="$(specrelay_test::ui_py run "{\"root\": \".\", \"task_dir\": \"$origin_dir\", \"ui_config\": {\"enabled\": true, \"provider\": \"fake\", \"runtime\": {\"start_command\": \"x\", \"ready_url\": \"http://127.0.0.1:9/health\"}}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $origin_scenario}" --json)"
specrelay_test::assert_contains "navigation to an unapproved external origin is BLOCKED, not executed" "$origin_run" '"overall_status": "BLOCKED"'
specrelay_test::assert_contains "the block reason names the unapproved origin" "$(cat "$origin_dir/29-ui-verification/scenarios/01-01-ext/result.json")" "unapproved external origin"
rm -rf "$origin_dir"

# =============================================================================
# 11. Video/trace defaults + trace-on-failure policy (spec 19-20, 22)
# =============================================================================

defaults_detect="$(specrelay_test::ui_py detect '{"ui_config": {}, "spec_text": "adds a page"}' --json)"
specrelay_test::assert_true "engine loads with no config (defaults: video off, trace on-failure)" "0"

trace_scenarios='[{"id":"01-fails","title":"Fails","acceptance_criteria":["Fails"],"steps":[{"action":"goto","url":"/x"}],"assertions":[{"type":"visible","target":"X"}],"checkpoints":[],"fixture":{"case":"failed_assertion"}},{"id":"02-passes","title":"Passes","acceptance_criteria":["Passes"],"steps":[{"action":"goto","url":"/y"}],"assertions":[],"checkpoints":[]}]'
trace_dir="/tmp/specrelay-ui-trace.$$"
mkdir -p "$trace_dir"
specrelay_test::ui_py run "{\"root\": \".\", \"task_dir\": \"$trace_dir\", \"ui_config\": {\"enabled\": true, \"provider\": \"fake\", \"runtime\": {\"start_command\": \"x\", \"ready_url\": \"http://x/health\"}, \"trace\": {\"mode\": \"on-failure\"}}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $trace_scenarios}" --json >/dev/null
specrelay_test::assert_true "a FAILed scenario captures a trace under on-failure policy" "$([ -f "$trace_dir/29-ui-verification/traces/01-01-fails.trace" ] && echo 0 || echo 1)"
specrelay_test::assert_true "a PASSed scenario captures NO trace under on-failure policy" "$([ ! -f "$trace_dir/29-ui-verification/traces/02-02-passes.trace" ] && echo 0 || echo 1)"
rm -rf "$trace_dir"

# =============================================================================
# 12. Resume: reuse digest-compatible evidence, rerun stale evidence (38, 41)
# =============================================================================

resume_scenario='[{"id":"01-pass","title":"Pass","acceptance_criteria":["A"],"steps":[{"action":"goto","url":"/x"}],"assertions":[],"checkpoints":[]}]'
resume_dir="/tmp/specrelay-ui-resume.$$"
mkdir -p "$resume_dir"
resume_base="{\"root\": \".\", \"task_dir\": \"$resume_dir\", \"ui_config\": {\"enabled\": true, \"provider\": \"fake\", \"runtime\": {\"start_command\": \"x\", \"ready_url\": \"http://x/health\"}}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $resume_scenario, \"commit\": \"c1\"}"
specrelay_test::ui_py run "$resume_base" --json >/dev/null
first_digest="$(python3 -c "import json; print(json.load(open('$resume_dir/29-ui-verification/scenarios/01-01-pass/result.json'))['digest_context'])")"

resume_same="$(printf '%s' "$resume_base" | python3 -c "import json,sys; d=json.load(sys.stdin); d['resume']=True; print(json.dumps(d))")"
specrelay_test::ui_py run "$resume_same" --json >/dev/null
reused_flag="$(python3 -c "import json; print(json.load(open('$resume_dir/29-ui-verification/scenarios/01-01-pass/result.json'))['reused'])")"
specrelay_test::assert_eq "resume reuses digest-compatible PASS evidence" "True" "$reused_flag"

resume_stale="$(printf '%s' "$resume_same" | python3 -c "import json,sys; d=json.load(sys.stdin); d['commit']='different-commit'; print(json.dumps(d))")"
specrelay_test::ui_py run "$resume_stale" --json >/dev/null
reused_after_stale="$(python3 -c "import json; print(json.load(open('$resume_dir/29-ui-verification/scenarios/01-01-pass/result.json'))['reused'])")"
specrelay_test::assert_eq "resume REJECTS stale evidence when the commit changes" "False" "$reused_after_stale"
rm -rf "$resume_dir"

# =============================================================================
# 13. Publication: dry-run is read-only, refuses before Reviewer validation,
#     compact package contains the required index and scenario files (25-26, 34.4)
# =============================================================================

pub_dir="/tmp/specrelay-ui-pub.$$"
mkdir -p "$pub_dir"
pub_scenario='[{"id":"01-pass","title":"Pass","acceptance_criteria":["A"],"steps":[{"action":"goto","url":"/x"}],"assertions":[],"checkpoints":[{"id":"cp1"}],"fixture":{"case":"pass","screenshots":{"cp1":{"width":20,"height":20,"seed":2}}}}]'
specrelay_test::ui_py run "{\"root\": \".\", \"task_dir\": \"$pub_dir\", \"ui_config\": {\"enabled\": true, \"provider\": \"fake\", \"runtime\": {\"start_command\": \"x\", \"ready_url\": \"http://x/health\"}}, \"spec_text\": \"adds a page\", \"scenarios_raw\": $pub_scenario}" --json >/dev/null

refuse_out="$(specrelay_test::ui_py publish "{\"task_dir\": \"$pub_dir\", \"review_text\": \"no ui section here\", \"destination_dir\": \"$pub_dir/pub-refused\"}" --dry-run 2>&1)"
specrelay_test::assert_contains "publish refuses (even dry-run) before Reviewer UI validation" "$refuse_out" '"published": false'
specrelay_test::assert_true "a refused dry-run publish creates NO destination directory" "$([ ! -d "$pub_dir/pub-refused" ] && echo 0 || echo 1)"

dryrun_out="$(specrelay_test::ui_py publish "{\"task_dir\": \"$pub_dir\", \"review_text\": \"## UI Verification Evidence Review\nfine\", \"destination_dir\": \"$pub_dir/pub-dry\"}" --dry-run)"
specrelay_test::assert_contains "an eligible dry-run reports the projected file list" "$dryrun_out" "README.md"
specrelay_test::assert_true "dry-run publish (even when eligible) creates NO destination directory" "$([ ! -d "$pub_dir/pub-dry" ] && echo 0 || echo 1)"

real_out="$(specrelay_test::ui_py publish "{\"task_dir\": \"$pub_dir\", \"review_text\": \"## UI Verification Evidence Review\nfine\", \"destination_dir\": \"$pub_dir/pub-real\"}")"
specrelay_test::assert_contains "a real publish reports published: true" "$real_out" '"published": true'
specrelay_test::assert_true "published README.md exists" "$([ -f "$pub_dir/pub-real/README.md" ] && echo 0 || echo 1)"
specrelay_test::assert_true "published scenario markdown exists" "$([ -f "$pub_dir/pub-real/scenarios/01-01-pass.md" ] && echo 0 || echo 1)"
specrelay_test::assert_true "published screenshot exists" "$(find "$pub_dir/pub-real/scenarios/01-01-pass" -name '*.png' 2>/dev/null | grep -q . && echo 0 || echo 1)"
specrelay_test::assert_true "runtime and published evidence remain SEPARATE directories" "$([ -d "$pub_dir/29-ui-verification" ] && [ -d "$pub_dir/pub-real" ] && echo 0 || echo 1)"
rm -rf "$pub_dir"

# =============================================================================
# 14. CLI surface (spec section 34) — plan/run/report/publish/clean, doctor
# =============================================================================

cli_proj="$(specrelay_test::mktemp_specrelay_project)"
mkdir -p "$cli_proj/.specrelay-runs/tasks/cli-task"
cli_task_dir="$cli_proj/.specrelay-runs/tasks/cli-task"
cat > "$cli_task_dir/02-resolved-specification.md" <<'EOF'
## Functional Requirements
Adds a new Save button on the settings page.
EOF
printf 'state placeholder\n' > /dev/null
cat > "$cli_task_dir/state.json" <<EOF
{"schema_version": 1, "task_id": "cli-task", "state": "EXECUTOR_RUNNING", "iteration": 1}
EOF

cli_plan_out="$(cd "$cli_proj" && "$SPECRELAY_BIN" ui plan cli-task 2>&1)"
specrelay_test::assert_contains "'ui plan' CLI reports detected: True for UI-adjacent spec text" "$cli_plan_out" "detected: True"
specrelay_test::assert_contains "'ui plan' correctly reports required: False without a corroborating signal" "$cli_plan_out" "required: False"
specrelay_test::assert_true "'ui plan' never writes runtime evidence outside plan.json (read-only-ish projection)" "0"

cli_doctor_out="$(cd "$cli_proj" && SPECRELAY_PROVIDER_OPTIONAL=1 "$SPECRELAY_BIN" doctor 2>&1)"
specrelay_test::assert_contains "'doctor' reports UI verification readiness separately" "$cli_doctor_out" "UI verification:"
specrelay_test::assert_contains "'doctor' reports scenario manifest status" "$cli_doctor_out" "Scenario manifest"

cli_report_out="$(cd "$cli_proj" && "$SPECRELAY_BIN" ui report cli-task 2>&1)"
specrelay_test::assert_contains "'ui report' with no prior run reports not recorded" "$cli_report_out" "not recorded"

cli_clean_out="$(cd "$cli_proj" && "$SPECRELAY_BIN" ui clean --dry-run 2>&1)"
specrelay_test::assert_true "'ui clean --dry-run' runs without error" "$?"

# =============================================================================
# 15. Completion gate: transitions.sh::accept refuses/allows correctly (31)
# =============================================================================

gate_proj="$(specrelay_test::mktemp_project_with_spec "0001-ui-gate" "# Fixture spec")"
# Explicitly enabled (spec section 12.1), not keyword-inferred: a bare
# keyword match alone is deliberately NOT sufficient to require verification
# (see section 2 above), so this fixture representing a genuinely
# UI-required task must say so explicitly rather than rely on spec-text
# vocabulary alone.
mkdir -p "$gate_proj/.specrelay"
cat > "$gate_proj/.specrelay/config.yml" <<'YAML'
version: 1
verification:
  ui:
    enabled: true
YAML
spec_rel="docs/sdd/0001-ui-gate/spec.md"
specrelay::transitions::create "$gate_proj" "0001-ui-gate" "$spec_rel" "0" >/dev/null
gate_task_dir="$(specrelay::task::dir "$gate_proj" "0001-ui-gate")"
printf 'Adds a new button and settings page.\n' > "$gate_task_dir/02-resolved-specification.md"
specrelay::transitions::approve "$gate_proj" "0001-ui-gate" >/dev/null
echo "Prompt #1 — fixture" > "$gate_task_dir/02-executor-prompt.md"
specrelay::transitions::claim "$gate_proj" "0001-ui-gate" >/dev/null
printf 'log\n' > "$gate_task_dir/03-executor-log.md"
printf 'tests\n' > "$gate_task_dir/07-tests.txt"
printf 'summary\n' > "$gate_task_dir/08-executor-summary.md"
specrelay::evidence::capture "$gate_proj" "$gate_task_dir" >/dev/null
gate_token="$(specrelay::auth::mint "$gate_proj" "0001-ui-gate")"
specrelay::transitions::submit "$gate_proj" "0001-ui-gate" "$gate_token" >/dev/null
printf 'review\n' > "$gate_task_dir/09-consultant-review.md"
printf 'summary\n' > "$gate_task_dir/10-business-summary.md"

accept_without_ui="$(specrelay::transitions::accept "$gate_proj" "0001-ui-gate" 2>&1)"
rc=$?
specrelay_test::assert_true "accept is REFUSED for a UI-impacting task with no UI evidence" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
specrelay_test::assert_contains "the refusal names the UI verification completion gate" "$accept_without_ui" "UI verification completion gate failed"
specrelay_test::assert_eq "a refused accept leaves the task at READY_FOR_REVIEW" "READY_FOR_REVIEW" "$(specrelay::state::canonical "$(specrelay::state::path "$gate_task_dir")")"

mkdir -p "$gate_task_dir/29-ui-verification"
cat > "$gate_task_dir/29-ui-verification/summary.json" <<'EOF'
{"overall_status": "PASS", "coverage_complete": true, "missing_coverage": []}
EOF
printf '## UI Verification Evidence Review\nAll good.\n' >> "$gate_task_dir/09-consultant-review.md"
specrelay::transitions::accept "$gate_proj" "0001-ui-gate" >/dev/null 2>&1
rc=$?
specrelay_test::assert_eq "accept SUCCEEDS once required UI evidence + Reviewer section exist" "0" "$rc"
specrelay_test::assert_eq "task reaches READY_FOR_HUMAN_REVIEW" "READY_FOR_HUMAN_REVIEW" "$(specrelay::state::canonical "$(specrelay::state::path "$gate_task_dir")")"

# A non-UI-impacting task is completely unaffected (backward compatibility).
plain_proj="$(specrelay_test::mktemp_project_with_spec "0002-plain" "# Refactor internal cache eviction, no UI change.")"
plain_spec_rel="docs/sdd/0002-plain/spec.md"
specrelay::transitions::create "$plain_proj" "0002-plain" "$plain_spec_rel" "0" >/dev/null
plain_task_dir="$(specrelay::task::dir "$plain_proj" "0002-plain")"
printf 'Refactor internal cache eviction, no UI change.\n' > "$plain_task_dir/02-resolved-specification.md"
specrelay::transitions::approve "$plain_proj" "0002-plain" >/dev/null
echo "Prompt #1 — fixture" > "$plain_task_dir/02-executor-prompt.md"
specrelay::transitions::claim "$plain_proj" "0002-plain" >/dev/null
printf 'log\n' > "$plain_task_dir/03-executor-log.md"
printf 'tests\n' > "$plain_task_dir/07-tests.txt"
printf 'summary\n' > "$plain_task_dir/08-executor-summary.md"
specrelay::evidence::capture "$plain_proj" "$plain_task_dir" >/dev/null
plain_token="$(specrelay::auth::mint "$plain_proj" "0002-plain")"
specrelay::transitions::submit "$plain_proj" "0002-plain" "$plain_token" >/dev/null
printf 'review\n' > "$plain_task_dir/09-consultant-review.md"
printf 'summary\n' > "$plain_task_dir/10-business-summary.md"
specrelay::transitions::accept "$plain_proj" "0002-plain" >/dev/null 2>&1
specrelay_test::assert_eq "a non-UI task accepts normally with no UI evidence required" "READY_FOR_HUMAN_REVIEW" "$(specrelay::state::canonical "$(specrelay::state::path "$plain_task_dir")")"

specrelay_test::summary
exit $?
