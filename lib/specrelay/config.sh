#!/usr/bin/env bash
# config.sh — minimal, safe loader for .specrelay/config.yml.
#
# Parser choice and rationale (Phase G of SDD 0083): this repository's native
# runtime is Ruby (Gemfile, .ruby-version), and Ruby's standard library already
# ships Psych (YAML) — requiring "yaml" adds no new gem, no new language
# runtime, and no large dependency stack. `YAML.safe_load` is used explicitly
# (never `YAML.load`/`YAML.unsafe_load`), which restricts parsing to plain
# scalars, arrays, and hashes and never instantiates arbitrary Ruby objects —
# satisfying "does not use unsafe YAML object deserialization" directly rather
# than reimplementing a YAML subset parser by hand.
#
# Every accessor below shells out to a small, self-contained `ruby -e` snippet
# per call. The config path and dotted field path are passed as argv (never
# interpolated into the Ruby source), so untrusted values cannot inject code.
#
# config_local.sh (spec 0027, "Local Developer Configuration Overlay") is
# sourced here because every accessor below that must honor an optional
# .specrelay/config.local.yml overlay reads its data through
# specrelay::config::effective_data_yaml instead of File.read()-ing
# .specrelay/config.yml directly. Sourcing it from here (rather than only
# from bin/specrelay) means every existing test/script that already sources
# only config.sh keeps working without also having to be updated.
SPECRELAY_CONFIG_LOCAL_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config_local.sh"
# shellcheck source=config_local.sh
[ -f "$SPECRELAY_CONFIG_LOCAL_SH" ] && . "$SPECRELAY_CONFIG_LOCAL_SH"

# specrelay::config::path <project-root>
# Prints the expected config file path (whether or not it exists).
specrelay::config::path() {
  local root="$1"
  printf '%s/.specrelay/config.yml\n' "$root"
}

# specrelay::config::exists <project-root>
# True (exit 0) if the config file exists and is a regular file.
specrelay::config::exists() {
  local root="$1"
  [ -f "$(specrelay::config::path "$root")" ]
}

# specrelay::config::validate <project-root>
# Prints nothing on success (exit 0). On a missing or malformed config, prints
# a clear error to stderr and returns non-zero. "Malformed" covers both
# YAML syntax errors and a top level that is not a mapping (object).
specrelay::config::validate() {
  local root="$1" path
  path="$(specrelay::config::path "$root")"

  if [ ! -f "$path" ]; then
    specrelay::out::err "config not found: $path"
    return 1
  fi

  if ! command -v ruby >/dev/null 2>&1; then
    specrelay::out::err "ruby is required to read .specrelay/config.yml but was not found on PATH"
    return 1
  fi

  ruby -e '
    require "yaml"
    path = ARGV[0]
    begin
      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
    rescue Psych::SyntaxError, Psych::DisallowedClass => e
      warn "specrelay: malformed config (#{e.class}): #{e.message}"
      exit 1
    end
    unless data.is_a?(Hash)
      warn "specrelay: malformed config: top level must be a mapping (got #{data.class})"
      exit 1
    end
  ' "$path"
}

# specrelay::config::get <project-root> <dotted.field.path> [default]
# Prints the value at the dotted path (e.g. "specs.root") as a plain string.
# Prints the optional default (or nothing) if the path is missing. Assumes
# the config has already been validated by the caller.
#
# Reads through the MERGED shared+local configuration (spec 0027) when an
# optional .specrelay/config.local.yml overlay is present and valid, so every
# existing caller of this accessor automatically honors a developer's local
# override without a separate reduced schema (spec section 9). This function
# itself never fails on an invalid local overlay (falling back to the
# shared-only value, mirroring its historical never-fails contract for a
# malformed shared file) — callers that must REFUSE to proceed on an invalid
# local overlay call specrelay::config::validate_effective first, exactly as
# they already call specrelay::config::validate before relying on this
# accessor for a malformed shared file.
specrelay::config::get() {
  local root="$1" field="$2" default="${3:-}" path yaml_text
  path="$(specrelay::config::path "$root")"

  if command -v specrelay::config::effective_data_yaml >/dev/null 2>&1 \
    && yaml_text="$(specrelay::config::effective_data_yaml "$root" 2>/dev/null)"; then
    ruby -e '
      require "yaml"
      field, default = ARGV[0], ARGV[1]
      data = YAML.safe_load(STDIN.read, permitted_classes: [], aliases: false) rescue {}
      data = {} unless data.is_a?(Hash)
      value = field.split(".").reduce(data) do |acc, key|
        acc.is_a?(Hash) ? acc[key] : nil
      end
      puts value.nil? ? default.to_s : value.to_s
    ' "$field" "$default" <<< "$yaml_text"
    return 0
  fi

  if [ ! -f "$path" ]; then
    printf '%s\n' "$default"
    return 0
  fi

  ruby -e '
    require "yaml"
    path, field, default = ARGV[0], ARGV[1], ARGV[2]
    data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
    data = {} unless data.is_a?(Hash)
    value = field.split(".").reduce(data) do |acc, key|
      acc.is_a?(Hash) ? acc[key] : nil
    end
    puts value.nil? ? default.to_s : value.to_s
  ' "$path" "$field" "$default"
}

# --- role context configuration parsing (spec 0015) --------------------------
#
# The context section supports a global form plus role-specific overrides:
#
#   context:
#     adapter: none          # global adapter
#     required: false        # global required policy
#     executor:              # optional role-specific override
#       adapter: fake
#       required: true
#     reviewer:
#       adapter: none
#       required: false
#
# Resolution order, PER FIELD (spec 0015, "Configuration Contract"):
#   role-specific value -> global value -> built-in default
#   (adapter: none, required: false)
# so the executor and reviewer may use entirely different adapters and
# policies. All structural validation happens here, in one parser, so every
# consumer (workflow validation, doctor, contexts) shares it.

# specrelay::config::role_context <project-root> <role>
# Prints two lines on success (exit 0):
#   adapter=<name>
#   required=<true|false>
# On a structurally invalid context configuration prints a human-readable
# error DETAIL (exit 1). Missing config / context section resolves to the
# defaults. Rejected here (spec 0015, "Configuration Validation"): a context
# section that is not a mapping, unknown context keys, a non-string or empty
# adapter name, a non-boolean required value, and a malformed role-specific
# subsection. Adapter EXISTENCE is validated by the caller against the
# adapter registry, not here.
specrelay::config::role_context() {
  local root="$1" role="$2" yaml_text

  if ! command -v ruby >/dev/null 2>&1; then
    printf 'adapter=none\nrequired=false\n'
    return 0
  fi
  if ! yaml_text="$(specrelay::config::effective_data_yaml "$root")"; then
    printf '%s\n' "$yaml_text"
    return 1
  fi

  ruby -e '
    require "yaml"
    role = ARGV[0]

    def ok(adapter, required)
      puts "adapter=#{adapter}"
      puts "required=#{required}"
      exit 0
    end

    def bad(detail)
      puts detail
      exit 1
    end

    begin
      data = YAML.safe_load(STDIN.read, permitted_classes: [], aliases: false)
    rescue StandardError
      # Malformed YAML is reported by specrelay::config::validate_effective, not here.
      ok("none", "false")
    end
    ok("none", "false") unless data.is_a?(Hash)
    ok("none", "false") unless data.key?("context")
    ctx = data["context"]
    ok("none", "false") if ctx.nil?
    unless ctx.is_a?(Hash)
      bad "context configuration is not a mapping (got #{ctx.class})"
    end

    known_role_keys = ["adapter", "required", "options"]
    known_top_keys = known_role_keys + ["executor", "reviewer", "coordinator"]
    unknown = ctx.keys - known_top_keys
    unless unknown.empty?
      bad "context configuration has unknown key(s) #{unknown.map(&:inspect).join(", ")}; recognized keys: adapter, required, options, executor, reviewer"
    end

    # check_block <hash> <label> -> validates adapter/required/options shapes in
    # one (global or role-specific) context mapping. "options" is an opaque,
    # adapter-specific mapping (e.g. contextplus server_name/config_source,
    # spec 0018) — only its SHAPE (a mapping) is checked here; adapter-specific
    # key/value validation happens in the adapter own validate_config hook.
    check_block = lambda do |block, label|
      if block.key?("adapter") && !block["adapter"].nil?
        a = block["adapter"]
        unless a.is_a?(String)
          bad "#{label} context adapter must be a string (got #{a.class}: #{a.inspect})"
        end
        if a.strip.empty?
          bad "#{label} context adapter is empty; set a known adapter name (e.g. none) or omit the key"
        end
      end
      if block.key?("required") && !block["required"].nil?
        r = block["required"]
        unless r == true || r == false
          bad "#{label} context required must be a boolean true or false (got #{r.class}: #{r.inspect})"
        end
      end
      if block.key?("options") && !block["options"].nil?
        o = block["options"]
        unless o.is_a?(Hash)
          bad "#{label} context options must be a mapping (got #{o.class}: #{o.inspect})"
        end
      end
    end

    check_block.call(ctx, "global")

    ["executor", "reviewer", "coordinator"].each do |r|
      next unless ctx.key?(r)
      sub = ctx[r]
      next if sub.nil?
      unless sub.is_a?(Hash)
        bad "role-specific context configuration for #{r} is not a mapping (got #{sub.class}: #{sub.inspect})"
      end
      sub_unknown = sub.keys - known_role_keys
      unless sub_unknown.empty?
        bad "role-specific context configuration for #{r} has unknown key(s) #{sub_unknown.map(&:inspect).join(", ")}; recognized keys: adapter, required"
      end
      check_block.call(sub, r)
    end

    role_cfg = ctx[role].is_a?(Hash) ? ctx[role] : {}
    adapter = nil
    adapter = role_cfg["adapter"] if role_cfg.key?("adapter") && !role_cfg["adapter"].nil?
    adapter = ctx["adapter"] if adapter.nil? && ctx.key?("adapter") && !ctx["adapter"].nil?
    adapter = "none" if adapter.nil?

    required = nil
    required = role_cfg["required"] if role_cfg.key?("required") && !role_cfg["required"].nil?
    required = ctx["required"] if required.nil? && ctx.key?("required") && !ctx["required"].nil?
    required = false if required.nil?

    ok(adapter, required ? "true" : "false")
  ' "$role" <<< "$yaml_text"
}

# specrelay::config::role_context_options <project-root> <role>
# Prints the resolved, adapter-agnostic "options" mapping for a role's context
# configuration as compact JSON (spec 0018, "Configuration Validation") — an
# empty mapping ("{}") when no options are configured. Resolution is a WHOLE-
# BLOCK override (not per-key): a role-specific "options" mapping, when
# present, replaces the global one entirely, rather than merging field by
# field, so an adapter's option set is never a confusing splice of two
# sources. Only reachable after specrelay::config::role_context has already
# validated the context section's SHAPE (options is a mapping if present); this
# accessor degrades to "{}" on any unexpected shape rather than erroring again.
specrelay::config::role_context_options() {
  local root="$1" role="$2" yaml_text

  if ! command -v ruby >/dev/null 2>&1; then
    printf '{}\n'
    return 0
  fi
  if ! yaml_text="$(specrelay::config::effective_data_yaml "$root")"; then
    printf '{}\n'
    return 0
  fi

  ruby -e '
    require "yaml"
    require "json"
    role = ARGV[0]

    begin
      data = YAML.safe_load(STDIN.read, permitted_classes: [], aliases: false)
    rescue StandardError
      puts "{}"
      exit 0
    end
    unless data.is_a?(Hash) && data["context"].is_a?(Hash)
      puts "{}"
      exit 0
    end
    ctx = data["context"]
    role_cfg = ctx[role].is_a?(Hash) ? ctx[role] : {}

    opts = nil
    opts = role_cfg["options"] if role_cfg.key?("options") && !role_cfg["options"].nil?
    opts = ctx["options"] if opts.nil? && ctx.key?("options") && !ctx["options"].nil?
    opts = {} unless opts.is_a?(Hash)

    puts opts.to_json
  ' "$role" <<< "$yaml_text"
}

# --- role model SELECTION parsing (spec 0014) --------------------------------
#
# Spec 0014 introduces three explicit model-selection forms for
# roles.<role>.model, all parsed here into ONE canonical selection string so
# every consumer (validation, resolution, capture, doctor, models command)
# shares a single parser:
#
#   provider-default          <- absent key, nil, or the literal string
#                                "provider-default" (pass no model argument)
#   alias:<name>              <- structured form  model: { alias: <name> }
#   id:<provider-model-id>    <- structured form  model: { id: <value> }, OR
#                                (backward compatibility) any other non-empty
#                                legacy string, which continues to mean a raw
#                                provider model id
#
# The canonical string is unambiguous because the kind prefix is ADDED here at
# serialization time: a legacy raw string that itself happens to start with
# "alias:" or "id:" still serializes as id:<that whole string>, and parsing
# strips only the FIRST kind prefix — so raw ids survive byte-for-byte.

# specrelay::config::role_model_selection <project-root> <role>
# Prints the canonical selection string (exit 0), or prints a human-readable
# error DETAIL (exit 1) when the configured model is structurally invalid.
# Missing config / role / model key resolves to provider-default. Callers that
# need the standard error framing use specrelay::config::validate_role_model.
specrelay::config::role_model_selection() {
  local root="$1" role="$2" yaml_text

  if ! command -v ruby >/dev/null 2>&1; then
    printf 'provider-default\n'
    return 0
  fi
  if ! yaml_text="$(specrelay::config::effective_data_yaml "$root")"; then
    printf '%s\n' "$yaml_text"
    return 1
  fi

  ruby -e '
    require "yaml"
    role = ARGV[0]

    def ok(selection)
      puts selection
      exit 0
    end

    def bad(detail)
      puts detail
      exit 1
    end

    begin
      data = YAML.safe_load(STDIN.read, permitted_classes: [], aliases: false)
    rescue StandardError
      # Malformed YAML is reported by specrelay::config::validate_effective, not here.
      ok "provider-default"
    end
    ok "provider-default" unless data.is_a?(Hash)
    roles = data["roles"]
    ok "provider-default" unless roles.is_a?(Hash)
    ok "provider-default" unless roles.key?(role)
    role_cfg = roles[role]
    ok "provider-default" if role_cfg.nil?
    unless role_cfg.is_a?(Hash)
      bad "role configuration for #{role} is not a mapping (got #{role_cfg.class})"
    end
    ok "provider-default" unless role_cfg.key?("model")
    model = role_cfg["model"]
    ok "provider-default" if model.nil?

    # Legacy string forms (backward compatibility, spec 0014): the literal
    # provider-default sentinel, or any other non-empty string meaning a raw
    # provider model id (exactly equivalent to model: { id: <string> }).
    if model.is_a?(String)
      if model.empty?
        bad "model for role #{role} is empty; omit the key to use provider-default, or set an explicit model id"
      end
      if model.strip.empty?
        bad "model for role #{role} is whitespace-only (#{model.inspect}); omit the key to use provider-default, or set an explicit model id"
      end
      ok "provider-default" if model == "provider-default"
      ok "id:#{model}"
    end

    # Structured forms (spec 0014): a mapping with EXACTLY ONE of alias / id.
    if model.is_a?(Hash)
      keys = model.keys
      unknown = keys - ["alias", "id"]
      unless unknown.empty?
        bad "model for role #{role} has unknown key(s) #{unknown.map(&:inspect).join(", ")}; a structured model must set exactly one of alias: <name> or id: <provider-model-id>"
      end
      if keys.empty?
        bad "model for role #{role} is an empty mapping; a model selection must resolve to exactly one of provider-default, alias: <name>, or id: <provider-model-id>"
      end
      if keys.length > 1
        bad "model for role #{role} sets both alias and id; a model selection must resolve to exactly one of provider-default, alias: <name>, or id: <provider-model-id>"
      end
      kind = keys.first
      value = model[kind]
      unless value.is_a?(String)
        bad "model #{kind} for role #{role} must be a string (got #{value.class}: #{value.inspect})"
      end
      if value.strip.empty?
        bad "model #{kind} for role #{role} is empty; set a non-empty #{kind}, or use model: provider-default"
      end
      ok "#{kind}:#{value}"
    end

    # Any other type (list, number, boolean, ...) is invalid.
    bad "model for role #{role} must be a string (got #{model.class}: #{model.inspect}) or a structured alias/id mapping"
  ' "$role" <<< "$yaml_text"
}

# specrelay::config::validate_role_model <project-root> <role>
# Validates the SHAPE of roles.<role>.model in .specrelay/config.yml BEFORE any
# provider execution (spec 0012 string forms; spec 0014 structured forms). A
# model identifier is an opaque provider-specific string — this check never
# consults a remote allowlist — but the configuration MUST be structurally
# valid so a malformed value fails clearly up front instead of forwarding
# garbage (or a non-model value) to a provider CLI.
#
# Rejected (non-zero, with a clear error naming the role, the invalid value,
# the config source, and the expected forms):
#   * a non-string, non-mapping model value (list, number, boolean, ...);
#   * an empty or whitespace-only explicit model value;
#   * a structurally invalid role configuration (roles.<role> is not a mapping);
#   * a structured mapping that is empty, sets both alias and id, has unknown
#     keys, or has a nil/empty/non-string alias or id value.
# Accepted: an absent/nil model (provider-default), the provider-default
# sentinel string, a legacy non-empty raw-id string, and the structured
# single-key alias/id forms. Provider-AWARE validation (alias membership,
# discovery) is layered on top in workflow.sh, not here.
# --- bounded verification policy configuration (spec 0019) -------------------
#
# The `verification:` section configures how many times each verification
# operation (focused/targeted/full-suite/smoke/doctor/version) an Executor or
# Reviewer may run BY DEFAULT before a recorded reason is required for an
# additional run (see verification.sh, "Bounded Verification Policy"). Missing
# configuration resolves entirely to the built-in defaults below, so every
# existing project (with no `verification:` section at all) keeps working
# unchanged (spec: "missing configuration remains backward compatible").

# specrelay::config::_verification_defaults
# One `key=value` per line — the built-in defaults (spec 0019, "Verification
# Policy Configuration"). The single source of truth for every consumer
# (parser below, doctor, verification.sh).
specrelay::config::_verification_defaults() {
  cat <<'DEFAULTS'
executor_full_suite_max_runs=1
executor_smoke_max_runs=1
executor_doctor_max_runs=1
executor_version_max_runs=1
reviewer_default_mode=targeted
reviewer_focused_max_runs=3
reviewer_targeted_max_runs=1
reviewer_full_suite_max_runs=0
reviewer_smoke_max_runs=0
reviewer_doctor_max_runs=1
reviewer_version_max_runs=1
DEFAULTS
}

# specrelay::config::verification_policy <project-root>
# Prints the EFFECTIVE, flat `key=value` verification policy (one line per
# field, defaults merged with any configured overrides) on success (exit 0).
# On a structurally invalid `verification:` section, prints a human-readable
# error DETAIL on stdout and returns 1 (mirrors role_context's ok/bad
# convention). Rejected: a non-mapping section/subsection, unknown keys,
# negative limits, non-integer limits, and an unknown reviewer default_mode.
specrelay::config::verification_policy() {
  local root="$1" yaml_text

  if ! command -v ruby >/dev/null 2>&1; then
    specrelay::config::_verification_defaults
    return 0
  fi
  if ! yaml_text="$(specrelay::config::effective_data_yaml "$root")"; then
    printf '%s\n' "$yaml_text"
    return 1
  fi

  CONFIG_YAML="$yaml_text" ruby -e '
    require "yaml"

    defaults = {}
    STDIN.each_line do |line|
      k, v = line.strip.split("=", 2)
      defaults[k] = v if k && v
    end

    def bad(detail)
      puts detail
      exit 1
    end

    begin
      data = YAML.safe_load(ENV["CONFIG_YAML"], permitted_classes: [], aliases: false)
    rescue StandardError
      data = nil
    end
    data = {} unless data.is_a?(Hash)
    verification = data["verification"]

    if verification.nil?
      defaults.each { |k, v| puts "#{k}=#{v}" }
      exit 0
    end
    unless verification.is_a?(Hash)
      bad "verification configuration is not a mapping (got #{verification.class})"
    end

    # "version", "defaults", "placement", "services", "risk_rules" belong to
    # the spec-0026 verification-POLICY-ENGINE schema (multi-service/check
    # selection) — a disjoint key set from this bounded-run-count policy
    # (spec 0019). Both live under the same top-level `verification:` mapping
    # so a project can configure them together; this parser recognizes those
    # keys ONLY to avoid rejecting them as unknown — their actual validation
    # happens in specrelay::config::verification_engine_raw / py/
    # verification_policy_lib.py, never here.
    known_top = ["executor", "reviewer", "version", "defaults", "placement", "services", "risk_rules"]
    unknown_top = verification.keys - known_top
    unless unknown_top.empty?
      bad "verification configuration has unknown key(s) #{unknown_top.map(&:inspect).join(", ")}; recognized keys: executor, reviewer, version, defaults, placement, services, risk_rules"
    end

    int_keys = {
      "executor" => ["full_suite_max_runs", "smoke_max_runs", "doctor_max_runs", "version_max_runs"],
      "reviewer" => ["focused_max_runs", "targeted_max_runs", "full_suite_max_runs", "smoke_max_runs", "doctor_max_runs", "version_max_runs"],
    }
    reviewer_string_keys = ["default_mode"]
    known_modes = ["focused", "targeted", "full"]

    result = defaults.dup

    ["executor", "reviewer"].each do |role|
      block = verification[role]
      next if block.nil?
      unless block.is_a?(Hash)
        bad "verification.#{role} is not a mapping (got #{block.class})"
      end
      allowed = int_keys[role] + (role == "reviewer" ? reviewer_string_keys : [])
      unknown = block.keys - allowed
      unless unknown.empty?
        bad "verification.#{role} has unknown key(s) #{unknown.map(&:inspect).join(", ")}; recognized keys: #{allowed.join(", ")}"
      end
      int_keys[role].each do |k|
        next unless block.key?(k)
        v = block[k]
        unless v.is_a?(Integer)
          bad "verification.#{role}.#{k} must be a non-negative integer (got #{v.inspect})"
        end
        if v < 0
          bad "verification.#{role}.#{k} must be a non-negative integer (got #{v})"
        end
        result["#{role}_#{k}"] = v.to_s
      end
      if role == "reviewer" && block.key?("default_mode")
        v = block["default_mode"]
        unless v.is_a?(String) && known_modes.include?(v)
          bad "verification.reviewer.default_mode must be one of #{known_modes.join(", ")} (got #{v.inspect})"
        end
        result["reviewer_default_mode"] = v
      end
    end

    result.each { |k, v| puts "#{k}=#{v}" }
  ' <<< "$(specrelay::config::_verification_defaults)"
}

# --- verification-policy ENGINE configuration (spec 0026) --------------------
#
# Unlike every other section above, deep structural validation of this
# section (nested services/checks arrays, dependency-graph/cycle checks, safe
# cwd/root checks, duplicate-identity detection, unknown-kind checks, ...) is
# deliberately done in Python (py/verification_policy_lib.py), not here. This
# function's ONLY job is the part that genuinely needs Ruby: safely parsing
# YAML (YAML.safe_load, never YAML.load/unsafe_load — same rationale as the
# rest of this file) and re-emitting it as plain JSON so a single Python
# module can own the rest of the schema (nested arrays of mappings do not fit
# this file's flat `key=value` accessor convention, and hand-rolling
# graph/cycle validation in a `ruby -e` heredoc would just duplicate logic
# that is already exercised, in one place, by verification_policy_lib.py).
#
# Prints one JSON object on success (exit 0):
#   {"legacy_full_test_command": <string|null>, "verification": <mapping|null>}
# "verification" is the RAW (unvalidated) `verification:` mapping from the
# config file, or null if the section is absent. On a YAML syntax error,
# prints a human-readable error DETAIL on stdout and returns 1 (mirrors the
# rest of this file's ok/bad convention — a malformed config file is reported
# the same way everywhere).
specrelay::config::verification_engine_raw() {
  local root="$1" yaml_text

  if ! command -v ruby >/dev/null 2>&1; then
    printf '{"legacy_full_test_command": null, "verification": null}\n'
    return 0
  fi
  if ! yaml_text="$(specrelay::config::effective_data_yaml "$root")"; then
    printf '%s\n' "$yaml_text"
    return 1
  fi

  ruby -e '
    require "yaml"
    require "json"

    begin
      data = YAML.safe_load(STDIN.read, permitted_classes: [], aliases: false)
    rescue Psych::SyntaxError, Psych::DisallowedClass => e
      puts "malformed config (#{e.class}): #{e.message}"
      exit 1
    end
    data = {} unless data.is_a?(Hash)

    legacy = nil
    validation = data["validation"]
    if validation.is_a?(Hash)
      cmd = validation["full_test_command"]
      legacy = cmd if cmd.is_a?(String) && !cmd.strip.empty?
    end

    verification = data["verification"]
    verification = nil unless verification.is_a?(Hash) || verification.is_a?(Array) || verification.nil?

    puts({"legacy_full_test_command" => legacy, "verification" => verification}.to_json)
  ' <<< "$yaml_text"
}

# --- phase budget configuration (spec 0019) ----------------------------------
#
# The `performance.phase_budgets` section configures SOFT (advisory) per-phase
# duration budgets (spec 0019, "Phase Budgets"). Exceeding a budget only ever
# produces a warning in the final execution-timeline report — it NEVER alters
# task state. Missing configuration resolves entirely to the built-in defaults.

specrelay::config::_phase_budget_defaults() {
  cat <<'DEFAULTS'
executor_context_preflight_seconds=30
executor_evidence_capture_seconds=120
reviewer_context_preflight_seconds=30
reviewer_provider_seconds=900
reviewer_marker_recovery_seconds=60
finalization_seconds=30
DEFAULTS
}

# specrelay::config::phase_budgets <project-root>
# Prints the effective `key=value` phase-budget seconds (one per line) on
# success (exit 0). On a structurally invalid `performance:` section, prints a
# human-readable error DETAIL on stdout and returns 1. Rejected: a non-mapping
# section, unknown keys, negative values, and non-integer values.
specrelay::config::phase_budgets() {
  local root="$1" yaml_text

  if ! command -v ruby >/dev/null 2>&1; then
    specrelay::config::_phase_budget_defaults
    return 0
  fi
  if ! yaml_text="$(specrelay::config::effective_data_yaml "$root")"; then
    printf '%s\n' "$yaml_text"
    return 1
  fi

  CONFIG_YAML="$yaml_text" ruby -e '
    require "yaml"

    defaults = {}
    STDIN.each_line do |line|
      k, v = line.strip.split("=", 2)
      defaults[k] = v if k && v
    end

    def bad(detail)
      puts detail
      exit 1
    end

    begin
      data = YAML.safe_load(ENV["CONFIG_YAML"], permitted_classes: [], aliases: false)
    rescue StandardError
      data = nil
    end
    data = {} unless data.is_a?(Hash)
    perf = data["performance"]

    if perf.nil?
      defaults.each { |k, v| puts "#{k}=#{v}" }
      exit 0
    end
    unless perf.is_a?(Hash)
      bad "performance configuration is not a mapping (got #{perf.class})"
    end
    unless perf.keys == ["phase_budgets"] || perf.key?("phase_budgets")
      bad "performance configuration has unknown key(s) #{(perf.keys - ["phase_budgets"]).map(&:inspect).join(", ")}; recognized keys: phase_budgets"
    end
    unknown_top = perf.keys - ["phase_budgets"]
    unless unknown_top.empty?
      bad "performance configuration has unknown key(s) #{unknown_top.map(&:inspect).join(", ")}; recognized keys: phase_budgets"
    end

    budgets = perf["phase_budgets"]
    result = defaults.dup
    unless budgets.nil?
      unless budgets.is_a?(Hash)
        bad "performance.phase_budgets is not a mapping (got #{budgets.class})"
      end
      unknown = budgets.keys - defaults.keys
      unless unknown.empty?
        bad "performance.phase_budgets has unknown key(s) #{unknown.map(&:inspect).join(", ")}; recognized keys: #{defaults.keys.join(", ")}"
      end
      budgets.each do |k, v|
        unless v.is_a?(Integer)
          bad "performance.phase_budgets.#{k} must be a non-negative integer number of seconds (got #{v.inspect})"
        end
        if v < 0
          bad "performance.phase_budgets.#{k} must be a non-negative integer number of seconds (got #{v})"
        end
        result[k] = v.to_s
      end
    end

    result.each { |k, v| puts "#{k}=#{v}" }
  ' <<< "$(specrelay::config::_phase_budget_defaults)"
}

# --- execution efficiency and completion gate policy (spec 0021) -----------
#
# The `execution_efficiency:` section configures the completion-gate policy
# enforced on Executor/Reviewer provider completion (spec 0021, "Executor
# Completion Contract" / "Required Executor Artifacts" / "Unresolved Waiting
# Detection"). Missing configuration resolves entirely to the built-in
# defaults below, so every existing project keeps working unchanged.

specrelay::config::_execution_efficiency_defaults() {
  cat <<'DEFAULTS'
enabled=true
executor_exploration_warning_calls=30
executor_repeated_verification_limit=1
executor_unresolved_wait_is_failure=true
executor_require_artifacts_before_success=true
reviewer_exploration_warning_calls=20
reviewer_repeated_verification_limit=1
reviewer_unresolved_wait_is_failure=true
reviewer_require_artifacts_before_success=true
DEFAULTS
}

# specrelay::config::execution_efficiency_policy <project-root>
# Prints the EFFECTIVE, flat `key=value` execution-efficiency policy (one line
# per field, defaults merged with any configured overrides) on success (exit
# 0). On a structurally invalid `execution_efficiency:` section, prints a
# human-readable error DETAIL on stdout and returns 1 (mirrors
# verification_policy's ok/bad convention). Rejected: a non-mapping
# section/subsection, unknown keys, a non-boolean `enabled`/policy flag, and a
# negative or non-integer `exploration_warning_calls`/
# `repeated_verification_limit`.
specrelay::config::execution_efficiency_policy() {
  local root="$1" yaml_text

  if ! command -v ruby >/dev/null 2>&1; then
    specrelay::config::_execution_efficiency_defaults
    return 0
  fi
  if ! yaml_text="$(specrelay::config::effective_data_yaml "$root")"; then
    printf '%s\n' "$yaml_text"
    return 1
  fi

  CONFIG_YAML="$yaml_text" ruby -e '
    require "yaml"

    defaults = {}
    STDIN.each_line do |line|
      k, v = line.strip.split("=", 2)
      defaults[k] = v if k && v
    end

    def bad(detail)
      puts detail
      exit 1
    end

    begin
      data = YAML.safe_load(ENV["CONFIG_YAML"], permitted_classes: [], aliases: false)
    rescue StandardError
      data = nil
    end
    data = {} unless data.is_a?(Hash)
    ee = data["execution_efficiency"]

    if ee.nil?
      defaults.each { |k, v| puts "#{k}=#{v}" }
      exit 0
    end
    unless ee.is_a?(Hash)
      bad "execution_efficiency configuration is not a mapping (got #{ee.class})"
    end

    known_top = ["enabled", "executor", "reviewer"]
    unknown_top = ee.keys - known_top
    unless unknown_top.empty?
      bad "execution_efficiency configuration has unknown key(s) #{unknown_top.map(&:inspect).join(", ")}; recognized keys: #{known_top.join(", ")}"
    end

    result = defaults.dup

    if ee.key?("enabled")
      v = ee["enabled"]
      unless v == true || v == false
        bad "execution_efficiency.enabled must be a boolean true or false (got #{v.inspect})"
      end
      result["enabled"] = v ? "true" : "false"
    end

    int_keys = ["exploration_warning_calls", "repeated_verification_limit"]
    bool_keys = ["unresolved_wait_is_failure", "require_artifacts_before_success"]
    allowed = int_keys + bool_keys

    ["executor", "reviewer"].each do |role|
      block = ee[role]
      next if block.nil?
      unless block.is_a?(Hash)
        bad "execution_efficiency.#{role} is not a mapping (got #{block.class})"
      end
      unknown = block.keys - allowed
      unless unknown.empty?
        bad "execution_efficiency.#{role} has unknown key(s) #{unknown.map(&:inspect).join(", ")}; recognized keys: #{allowed.join(", ")}"
      end
      int_keys.each do |k|
        next unless block.key?(k)
        v = block[k]
        unless v.is_a?(Integer)
          bad "execution_efficiency.#{role}.#{k} must be a non-negative integer (got #{v.inspect})"
        end
        if v < 0
          bad "execution_efficiency.#{role}.#{k} must be a non-negative integer (got #{v})"
        end
        result["#{role}_#{k}"] = v.to_s
      end
      bool_keys.each do |k|
        next unless block.key?(k)
        v = block[k]
        unless v == true || v == false
          bad "execution_efficiency.#{role}.#{k} must be a boolean true or false (got #{v.inspect})"
        end
        result["#{role}_#{k}"] = v ? "true" : "false"
      end
    end

    result.each { |k, v| puts "#{k}=#{v}" }
  ' <<< "$(specrelay::config::_execution_efficiency_defaults)"
}

# --- coordinator role policy (spec 0025) ------------------------------------
#
# The `roles.coordinator:` section configures the AI Coordinator role (spec
# 0025, "Coordinator configuration"): provider/model/agent reuse the SAME
# generic accessors as executor/reviewer (config::role_model_selection,
# config::role_context already key on an arbitrary role string), but the
# coordinator ALSO needs its own enabled/required/max-attempts/timeout/
# confidence-threshold policy, which executor/reviewer do not have (they are
# always invoked; the coordinator is optional and advisory). Missing
# configuration resolves entirely to the built-in defaults — "coordinator
# disabled" is the default behavior (spec section 32, "Backward
# compatibility"), so every existing project keeps working unchanged.

specrelay::config::_coordinator_defaults() {
  cat <<'DEFAULTS'
enabled=false
required=false
max_decision_attempts=2
timeout_seconds=300
confidence_threshold=none
DEFAULTS
}

# specrelay::config::coordinator_policy <project-root>
# Prints the EFFECTIVE, flat `key=value` coordinator policy (one line per
# field) on success (exit 0). On a structurally invalid `roles.coordinator:`
# section, prints a human-readable error DETAIL on stdout and returns 1
# (mirrors verification_policy's ok/bad convention). Rejected: a non-mapping
# section, unknown keys, non-boolean enabled/required, a negative or
# non-integer max_decision_attempts/timeout_seconds, and an unrecognized
# confidence_threshold.
specrelay::config::coordinator_policy() {
  local root="$1" yaml_text

  if ! command -v ruby >/dev/null 2>&1; then
    specrelay::config::_coordinator_defaults
    return 0
  fi
  if ! yaml_text="$(specrelay::config::effective_data_yaml "$root")"; then
    printf '%s\n' "$yaml_text"
    return 1
  fi

  CONFIG_YAML="$yaml_text" ruby -e '
    require "yaml"

    defaults = {}
    STDIN.each_line do |line|
      k, v = line.strip.split("=", 2)
      defaults[k] = v if k && v
    end

    def bad(detail)
      puts detail
      exit 1
    end

    begin
      data = YAML.safe_load(ENV["CONFIG_YAML"], permitted_classes: [], aliases: false)
    rescue StandardError
      data = nil
    end
    data = {} unless data.is_a?(Hash)
    roles = data["roles"]
    roles = {} unless roles.is_a?(Hash)
    coord = roles["coordinator"]

    if coord.nil?
      defaults.each { |k, v| puts "#{k}=#{v}" }
      exit 0
    end
    unless coord.is_a?(Hash)
      bad "roles.coordinator is not a mapping (got #{coord.class})"
    end

    known_top = ["provider", "model", "agent", "enabled", "required", "max_decision_attempts", "timeout_seconds", "confidence_threshold"]
    unknown_top = coord.keys - known_top
    unless unknown_top.empty?
      bad "roles.coordinator has unknown key(s) #{unknown_top.map(&:inspect).join(", ")}; recognized keys: #{known_top.join(", ")}"
    end

    result = defaults.dup

    ["enabled", "required"].each do |k|
      next unless coord.key?(k)
      v = coord[k]
      unless v == true || v == false
        bad "roles.coordinator.#{k} must be a boolean true or false (got #{v.inspect})"
      end
      result[k] = v ? "true" : "false"
    end

    ["max_decision_attempts", "timeout_seconds"].each do |k|
      next unless coord.key?(k)
      v = coord[k]
      unless v.is_a?(Integer)
        bad "roles.coordinator.#{k} must be a non-negative integer (got #{v.inspect})"
      end
      if v < 0
        bad "roles.coordinator.#{k} must be a non-negative integer (got #{v})"
      end
      result[k] = v.to_s
    end

    if coord.key?("confidence_threshold")
      v = coord["confidence_threshold"]
      known = ["low", "medium", "high", "none"]
      unless v.is_a?(String) && known.include?(v)
        bad "roles.coordinator.confidence_threshold must be one of #{known.join(", ")} (got #{v.inspect})"
      end
      result["confidence_threshold"] = v
    end

    result.each { |k, v| puts "#{k}=#{v}" }
  ' <<< "$(specrelay::config::_coordinator_defaults)"
}

specrelay::config::validate_role_model() {
  local root="$1" role="$2" path msg rc
  path="$(specrelay::config::path "$root")"

  # No config file, or no Ruby to read it: nothing to validate here (a missing
  # config is reported by the caller's own readiness checks, not this one).
  [ -f "$path" ] || return 0
  command -v ruby >/dev/null 2>&1 || return 0

  msg="$(specrelay::config::role_model_selection "$root" "$role")"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    specrelay::out::err "invalid model configuration in $path: $msg"
    {
      echo "Expected model configuration forms:"
      echo "  Provider default:"
      echo "    model: provider-default"
      echo "  Semantic alias (provider-specific):"
      echo "    model:"
      echo "      alias: <alias>"
      echo "  Exact provider model ID:"
      echo "    model:"
      echo "      id: <provider-model-id>"
      echo "Inspect model options with: specrelay models <provider>"
    } >&2
    return 1
  fi
  return 0
}
