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
specrelay::config::get() {
  local root="$1" field="$2" default="${3:-}" path
  path="$(specrelay::config::path "$root")"

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
  local root="$1" role="$2" path
  path="$(specrelay::config::path "$root")"

  if [ ! -f "$path" ] || ! command -v ruby >/dev/null 2>&1; then
    printf 'adapter=none\nrequired=false\n'
    return 0
  fi

  ruby -e '
    require "yaml"
    path, role = ARGV[0], ARGV[1]

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
      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
    rescue StandardError
      # Malformed YAML is reported by specrelay::config::validate, not here.
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
    known_top_keys = known_role_keys + ["executor", "reviewer"]
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

    ["executor", "reviewer"].each do |r|
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
  ' "$path" "$role"
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
  local root="$1" role="$2" path
  path="$(specrelay::config::path "$root")"

  if [ ! -f "$path" ] || ! command -v ruby >/dev/null 2>&1; then
    printf '{}\n'
    return 0
  fi

  ruby -e '
    require "yaml"
    require "json"
    path, role = ARGV[0], ARGV[1]

    begin
      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
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
  ' "$path" "$role"
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
  local root="$1" role="$2" path
  path="$(specrelay::config::path "$root")"

  if [ ! -f "$path" ] || ! command -v ruby >/dev/null 2>&1; then
    printf 'provider-default\n'
    return 0
  fi

  ruby -e '
    require "yaml"
    path, role = ARGV[0], ARGV[1]

    def ok(selection)
      puts selection
      exit 0
    end

    def bad(detail)
      puts detail
      exit 1
    end

    begin
      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
    rescue StandardError
      # Malformed YAML is reported by specrelay::config::validate, not here.
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
  ' "$path" "$role"
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
