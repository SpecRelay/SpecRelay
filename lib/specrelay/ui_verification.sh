#!/usr/bin/env bash
# ui_verification.sh — UI runtime verification and compact review evidence
# (spec 0028, "UI Runtime Verification and Compact Review Evidence"). Thin
# bash wrapper around py/ui_verification_lib.py (the deterministic engine),
# mirroring verification_policy.sh's relationship to
# py/verification_policy_lib.py: YAML parsing (both the `verification.ui`
# config section and the scenario manifest) happens in Ruby via
# YAML.safe_load; everything past that — schema validation, detection,
# selection, execution, screenshot policy, redaction, comparison, artifact
# writing, publication, and the completion-gate check — lives in the Python
# module.
#
# Every "ui" subcommand except `doctor`/`clean` is TASK-SCOPED: evidence is
# written under <task-dir>/29-ui-verification/ (runtime) and, on publish,
# under <spec-directory>/verification/ui/ (compact, checked-in evidence).

SPECRELAY_UI_VERIFICATION_LIB_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/ui_verification_lib.py"
SPECRELAY_UI_PLAYWRIGHT_RUNNER_JS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/js/ui_playwright_runner.js"

specrelay::ui_verification::_available() {
  command -v python3 >/dev/null 2>&1 && [ -f "$SPECRELAY_UI_VERIFICATION_LIB_PY" ]
}

# specrelay::ui_verification::raw_config_json <project-root>
# Prints the raw (unvalidated) `verification.ui` mapping as JSON (or `null`),
# already reflecting the spec-0027 local-override merge (reuses config.sh's
# existing verification_engine_raw passthrough — same rationale as
# verification_policy_lib.py: this is a disjoint key set under the SAME
# top-level `verification:` mapping).
specrelay::ui_verification::raw_config_json() {
  local root="$1" raw
  raw="$(specrelay::config::verification_engine_raw "$root" 2>/dev/null)" || { printf 'null\n'; return 0; }
  printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print("null")
    raise SystemExit
v = d.get("verification") if isinstance(d, dict) else None
ui = v.get("ui") if isinstance(v, dict) else None
print(json.dumps(ui))
' 2>/dev/null || printf 'null\n'
}

# specrelay::ui_verification::scenarios_raw_json <project-root> <manifest-relpath>
# Prints the scenario manifest as a JSON array (or "[]" when the file is
# absent, or when ruby is unavailable — the python validator then reports
# "no scenarios configured" rather than this function silently failing).
specrelay::ui_verification::scenarios_raw_json() {
  local root="$1" manifest="$2" path
  path="$root/$manifest"
  if [ ! -f "$path" ] || ! command -v ruby >/dev/null 2>&1; then
    printf '[]\n'
    return 0
  fi
  ruby -e '
    require "yaml"
    require "json"
    begin
      data = YAML.safe_load(File.read(ARGV[0]), permitted_classes: [], aliases: false)
    rescue Psych::SyntaxError, Psych::DisallowedClass => e
      STDERR.puts "malformed scenario manifest (#{e.class}): #{e.message}"
      puts "null"
      exit 1
    end
    data = [] if data.nil?
    puts data.to_json
  ' "$path" 2>/dev/null || printf 'null\n'
}

# specrelay::ui_verification::_extract_section <file> <heading-text>
# A small, deliberately literal Markdown section extractor: everything
# between a line exactly "## <heading-text>" and the next "## " heading (or
# EOF). Mirrors resolved_spec.sh's section-extraction convention closely
# enough for this module's own detection/selection signals without pulling
# in a Markdown parser.
specrelay::ui_verification::_extract_section() {
  local file="$1" heading="$2"
  [ -f "$file" ] || return 0
  awk -v h="## ${heading}" '
    $0 == h { found=1; next }
    found && /^## / { exit }
    found { print }
  ' "$file" 2>/dev/null
}

# specrelay::ui_verification::_has_expected_references <task-dir>
# True when the immutable input bundle contains at least one image file
# (spec section 9.5, "Expected reference" — a screenshot, design export, or
# prototype image supplied through the bundle).
specrelay::ui_verification::_has_expected_references() {
  local task_dir="$1" bundle
  bundle="$task_dir/01-input-bundle"
  [ -d "$bundle" ] || return 1
  find "$bundle" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.svg' \) -print -quit 2>/dev/null | grep -q .
}

# specrelay::ui_verification::_changed_paths_json <project-root> <task-dir>
# Prefers the durably captured 05-changed-files.txt (this task's own diff
# evidence); falls back to the live working-tree status when that file does
# not exist yet (e.g. a `ui plan` invoked before any executor round ran).
specrelay::ui_verification::_changed_paths_json() {
  local root="$1" task_dir="$2" src
  if [ -s "$task_dir/05-changed-files.txt" ]; then
    src="$task_dir/05-changed-files.txt"
  else
    src="$(mktemp "${TMPDIR:-/tmp}/specrelay-ui-changed.XXXXXX")"
    (cd "$root" && git status --short 2>/dev/null | awk '{print $NF}') > "$src"
  fi
  python3 -c '
import json, sys
paths = [l.strip() for l in open(sys.argv[1]) if l.strip()]
print(json.dumps(paths))
' "$src"
}

# specrelay::ui_verification::_base_payload <project-root> <task-id>
# Prints the shared JSON payload fields (root, task_dir, task_id, raw
# config/scenario/spec inputs) every task-scoped subcommand needs. Extra
# top-level keys can be merged in by the caller.
specrelay::ui_verification::_base_payload() {
  local root="$1" task_id="$2" task_dir spec_file ui_config scenarios manifest_rel changed has_refs commit spec_text
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  spec_file="$task_dir/02-resolved-specification.md"
  if [ -f "$spec_file" ]; then
    # UI-keyword detection (spec 0028, section 12.3) must scan genuine
    # requirement content only -- NEVER this same file's own auto-generated
    # evidence-classification/bookkeeping prose (e.g. its "UI and Visual
    # Evidence" / "Input Coverage" sections). Spec 0023's resolved-
    # specification generator unconditionally emits "No screenshots or
    # other visual evidence were discovered in this bundle." for every task
    # with no image inputs (the overwhelming majority), which otherwise
    # matches the UI_KEYWORDS list and makes detection self-trigger on
    # almost every task ever created, regardless of subject matter.
    spec_text="$(
      { specrelay::ui_verification::_extract_section "$spec_file" "Objective"
        specrelay::ui_verification::_extract_section "$spec_file" "Functional Requirements"
        specrelay::ui_verification::_extract_section "$spec_file" "Technical Requirements"
        specrelay::ui_verification::_extract_section "$spec_file" "Acceptance Criteria"
        specrelay::ui_verification::_extract_section "$spec_file" "Constraints and Boundaries"
      } 2>/dev/null
    )"
    # Fallback for a resolved-specification.md with none of the known
    # headings (e.g. a legacy/malformed file, or one not produced by
    # resolved_spec.sh's generator): scan the whole file rather than
    # silently detecting nothing. Real generator output always has these
    # headings, so this path never re-introduces the self-trigger bug above.
    if [ -z "$(printf '%s' "$spec_text" | tr -d '[:space:]')" ]; then
      spec_text="$(cat "$spec_file" 2>/dev/null)"
    fi
  else
    spec_file="$task_dir/00-user-request.md"
    spec_text="$(cat "$spec_file" 2>/dev/null)"
  fi
  ui_config="$(specrelay::ui_verification::raw_config_json "$root")"
  manifest_rel="$(printf '%s' "$ui_config" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d or {}).get("scenarios",{}).get("manifest",".specrelay/ui-scenarios.yml"))' 2>/dev/null || printf '.specrelay/ui-scenarios.yml\n')"
  scenarios="$(specrelay::ui_verification::scenarios_raw_json "$root" "$manifest_rel")"
  changed="$(specrelay::ui_verification::_changed_paths_json "$root" "$task_dir")"
  has_refs=false
  specrelay::ui_verification::_has_expected_references "$task_dir" && has_refs=true
  commit="$(cd "$root" && git rev-parse HEAD 2>/dev/null || echo unknown)"

  AC_TEXT="$(specrelay::ui_verification::_extract_section "$spec_file" "Acceptance Criteria")" \
  SPEC_TEXT="$spec_text" \
  python3 -c '
import json, os, sys
ui_config = json.loads(sys.argv[1])
scenarios = json.loads(sys.argv[2])
changed = json.loads(sys.argv[3])
print(json.dumps({
    "root": sys.argv[4],
    "task_dir": sys.argv[5],
    "task_id": sys.argv[6],
    "ui_config": ui_config,
    "scenarios_raw": scenarios if isinstance(scenarios, list) else [],
    "changed_paths": changed,
    "spec_text": os.environ.get("SPEC_TEXT", ""),
    "acceptance_criteria_text": os.environ.get("AC_TEXT", ""),
    "explicit_ui_task": False,
    "has_expected_references": sys.argv[7] == "true",
    "commit": sys.argv[8],
}))
' "$ui_config" "$scenarios" "$changed" "$root" "$task_dir" "$task_id" "$has_refs" "$commit"
}

# specrelay::ui_verification::required <project-root> <task-id>
# Prints "true" or "false": whether UI verification is required for this
# task RIGHT NOW (detection only — no scenario manifest needed). Used by
# workflow.sh's executor/reviewer prompt construction. Fails safe to "false"
# with a warning on stderr so a python3/ruby outage never blocks prompt
# construction (detection is re-verified for real by the completion gate).
specrelay::ui_verification::required() {
  local root="$1" task_id="$2" payload
  specrelay::ui_verification::_available || { printf 'false\n'; return 0; }
  payload="$(specrelay::ui_verification::_base_payload "$root" "$task_id")"
  printf '%s' "$payload" | python3 "$SPECRELAY_UI_VERIFICATION_LIB_PY" detect --json 2>/dev/null \
    | python3 -c 'import json,sys
try:
    print("true" if json.load(sys.stdin).get("required") else "false")
except Exception:
    print("false")' 2>/dev/null || printf 'false\n'
}

# specrelay::ui_verification::plan <project-root> <task-id> [--json]
specrelay::ui_verification::plan() {
  local root="$1" task_id="$2"; shift 2
  specrelay::ui_verification::_available || { printf 'UI verification: python3 unavailable\n'; return 0; }
  local payload
  payload="$(specrelay::ui_verification::_base_payload "$root" "$task_id")"
  local task_dir; task_dir="$(specrelay::task::dir "$root" "$task_id")"
  printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["task_dir"] = sys.argv[1]
print(json.dumps(d))
' "$task_dir" | python3 "$SPECRELAY_UI_VERIFICATION_LIB_PY" plan "$@"
}

# specrelay::ui_verification::run <project-root> <task-id> [--json] [--resume]
specrelay::ui_verification::run() {
  local root="$1" task_id="$2"; shift 2
  specrelay::ui_verification::_available || { printf 'UI verification: python3 unavailable\n'; return 1; }
  local resume=0 as_json=0
  local -a rest=()
  for a in "$@"; do
    case "$a" in
      --resume) resume=1 ;;
      --json) as_json=1; rest+=("$a") ;;
      *) rest+=("$a") ;;
    esac
  done
  local task_dir; task_dir="$(specrelay::task::dir "$root" "$task_id")"
  local payload
  payload="$(specrelay::ui_verification::_base_payload "$root" "$task_id")"
  printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["task_dir"] = sys.argv[1]
d["resume"] = sys.argv[2] == "1"
print(json.dumps(d))
' "$task_dir" "$resume" | python3 "$SPECRELAY_UI_VERIFICATION_LIB_PY" run ${rest[@]+"${rest[@]}"}
}

# specrelay::ui_verification::report <project-root> <task-id> [--json]
specrelay::ui_verification::report() {
  local root="$1" task_id="$2"; shift 2
  specrelay::ui_verification::_available || { printf 'UI verification: not recorded\n'; return 0; }
  local task_dir; task_dir="$(specrelay::task::dir "$root" "$task_id")"
  python3 "$SPECRELAY_UI_VERIFICATION_LIB_PY" report "$task_dir" "$@"
}

# specrelay::ui_verification::gate_check <project-root> <task-id>
# Prints `{"ok": bool, "reason": "..."}`. Never mutates anything; the ONLY
# consumer that acts on this is transitions.sh::accept (spec section 31).
# Detection is always RECOMPUTED from the base payload (never trusts the mere
# absence of a prior 'ui plan'/'ui run' as proof verification was not
# required — spec section 12.2/31).
specrelay::ui_verification::gate_check() {
  local root="$1" task_id="$2" task_dir review_path review_text payload
  specrelay::ui_verification::_available || { printf '{"ok": true, "reason": "UI verification engine unavailable (python3 missing); treated as not applicable"}\n'; return 0; }
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  review_path="$task_dir/09-consultant-review.md"
  review_text=""
  [ -f "$review_path" ] && review_text="$(cat "$review_path")"
  payload="$(specrelay::ui_verification::_base_payload "$root" "$task_id")"
  REVIEW_TEXT="$review_text" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
d["task_dir"] = sys.argv[1]
d["review_text"] = os.environ.get("REVIEW_TEXT", "")
print(json.dumps(d))
' "$task_dir" <<< "$payload" | python3 "$SPECRELAY_UI_VERIFICATION_LIB_PY" gate
}

# specrelay::ui_verification::publish <project-root> <task-id> <spec-directory> [--dry-run]
specrelay::ui_verification::publish() {
  local root="$1" task_id="$2" spec_dir="$3"; shift 3
  specrelay::ui_verification::_available || { specrelay::out::err "UI verification engine unavailable (python3 missing)"; return 1; }
  local task_dir review_path review_text dest_dir pub_path payload
  task_dir="$(specrelay::task::dir "$root" "$task_id")"
  review_path="$task_dir/09-consultant-review.md"
  review_text=""
  [ -f "$review_path" ] && review_text="$(cat "$review_path")"
  pub_path="$(specrelay::ui_verification::raw_config_json "$root" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d or {}).get("publication",{}).get("path","verification/ui"))' 2>/dev/null || printf 'verification/ui\n')"
  dest_dir="$root/$spec_dir/$pub_path"
  payload="$(specrelay::ui_verification::_base_payload "$root" "$task_id")"
  REVIEW_TEXT="$review_text" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
d["task_dir"] = sys.argv[1]
d["review_text"] = os.environ.get("REVIEW_TEXT", "")
d["destination_dir"] = sys.argv[2]
print(json.dumps(d))
' "$task_dir" "$dest_dir" <<< "$payload" | python3 "$SPECRELAY_UI_VERIFICATION_LIB_PY" publish "$@"
}

# specrelay::ui_verification::doctor_summary <project-root>
# Read-only JSON summary for `specrelay doctor` (spec section 35).
specrelay::ui_verification::doctor_summary() {
  local root="$1" ui_config
  specrelay::ui_verification::_available || { printf '{"config_valid": true, "enabled": "auto", "unavailable": true}\n'; return 0; }
  ui_config="$(specrelay::ui_verification::raw_config_json "$root")"
  python3 -c '
import json, sys
print(json.dumps({"raw_ui_config": json.loads(sys.argv[1]), "root": sys.argv[2]}))
' "$ui_config" "$root" | python3 "$SPECRELAY_UI_VERIFICATION_LIB_PY" doctor
}

# specrelay::ui_verification::clean <project-root> [--dry-run]
# Removes stale <task-dir>/29-ui-verification runtime directories for tasks
# that are no longer in-flight (spec section 39) — NEVER touches published
# evidence under <spec-directory>/verification/ui/.
specrelay::ui_verification::clean() {
  local root="$1"; shift
  specrelay::ui_verification::_available || return 0
  local tasks_root candidates active
  tasks_root="$(specrelay::task::runs_root "$root" 2>/dev/null || printf '%s/.specrelay-runs/tasks\n' "$root")"
  candidates="$(find "$tasks_root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)"
  active=""
  if [ -d "$tasks_root" ]; then
    while IFS= read -r d; do
      [ -z "$d" ] && continue
      local state_file state
      state_file="$(specrelay::state::path "$d" 2>/dev/null)"
      state="$(specrelay::state::canonical "$state_file" 2>/dev/null || echo '')"
      case "$state" in
        READY_FOR_HUMAN_REVIEW|BLOCKED|"") : ;;
        *) active="$active
$d" ;;
      esac
    done <<< "$candidates"
  fi
  python3 -c '
import json, sys
cands = [l for l in sys.argv[1].splitlines() if l.strip()]
act = [l for l in sys.argv[2].splitlines() if l.strip()]
print(json.dumps({"root": sys.argv[3], "candidate_task_dirs": cands, "active_task_dirs": act}))
' "$candidates" "$active" "$root" | python3 "$SPECRELAY_UI_VERIFICATION_LIB_PY" clean "$@"
}
