#!/usr/bin/env bash
# config_local.sh — local developer configuration overlay (spec 0027).
#
# .specrelay/config.local.yml is an OPTIONAL, Git-ignored, sparse-override
# file layered on top of .specrelay/config.yml. This module is the single
# place that:
#   * discovers the local file (with a symlink-outside-project-root refusal);
#   * reads BOTH files exactly once per call and computes their SHA-256
#     digests from those SAME bytes (spec section 23, "Atomic and consistent
#     reads");
#   * deep-merges them (mappings recurse, lists replace wholesale, an
#     explicit YAML `null` in the local file removes the inherited key,
#     and a mapping/scalar type conflict at the same path fails with a
#     path-specific error — spec section 8);
#   * retains per-leaf PROVENANCE (which layer supplied the effective value,
#     and what it overrode) rather than reconstructing it heuristically after
#     the fact (spec section 18).
#
# Every other config.sh accessor that must honor the local overlay reads its
# data through specrelay::config::effective_data_yaml below instead of
# reading .specrelay/config.yml directly — this is the ONE merge
# implementation; there is no separate "reduced" local schema (spec section
# 9). YAML parsing uses Ruby's Psych (YAML.safe_load, never
# YAML.load/unsafe_load) for the same reason config.sh does.

# specrelay::config::local_path <project-root>
# Prints the expected local overlay path (whether or not it exists).
specrelay::config::local_path() {
  local root="$1"
  printf '%s/.specrelay/config.local.yml\n' "$root"
}

# specrelay::config::local_exists <project-root>
# True (exit 0) if a local overlay file (or symlink) is present at all. This
# is a plain presence check ONLY — it does not validate YAML, shape, or the
# symlink-boundary rule (see effective_envelope for that); doctor and CLI
# reporting use this to distinguish "not present" from "present" before
# asking whether the present file is actually valid.
specrelay::config::local_exists() {
  local root="$1" path
  path="$(specrelay::config::local_path "$root")"
  [ -f "$path" ] || [ -L "$path" ]
}

# specrelay::config::_cache_file <project-root>
# A per-invocation cache path for the merge envelope. Bash's $$ names the
# TOP-LEVEL invoking process even from deep inside a nested command
# substitution subshell (unlike $BASHPID, which changes per subshell) — this
# is exactly the property spec section 23 ("Atomic and consistent reads")
# requires: one `specrelay` command invocation reads each configuration file
# ONCE and reuses that same content for every accessor call for the rest of
# that invocation, no matter how many nested subshells call
# specrelay::config::get / role_context / verification_policy / etc. Without
# this cache, every single accessor call re-shells out to two fresh Ruby
# processes to recompute the whole merge from scratch — for a `run`/`resume`
# invocation that calls these accessors dozens of times, that turns a
# sub-second command into a multi-minute one. The project root is folded into
# the filename (via cksum) so two different roots invoked under a reused PID
# never collide; bin/specrelay removes this file on exit.
specrelay::config::_cache_file() {
  local root="$1" key
  key="$(printf '%s' "$root" | cksum | awk '{print $1}')"
  printf '%s/specrelay-config-cache.%s.%s\n' "${TMPDIR:-/tmp}" "$$" "$key"
}

# specrelay::config::_source_signature <project-root>
# A cheap (stat-only, no Ruby) mtime+size fingerprint of the shared and local
# files, used to invalidate the cache above WITHOUT needing a real "one OS
# process per command" boundary. A genuine `bin/specrelay` invocation is
# always a fresh process anyway, so this only matters for long-lived callers
# that source config.sh directly and rewrite a fixture's config file
# in-place across several calls within the SAME process (this repository's
# own test suite does exactly that) — without this check, such a caller
# would silently keep reading the FIRST version of the file for the rest of
# the process's life once the cache is warm.
specrelay::config::_source_signature() {
  local root="$1" shared_file="$1/.specrelay/config.yml" local_file="$1/.specrelay/config.local.yml" sig=""
  if [ -f "$shared_file" ]; then
    sig="s:$(stat -f '%m.%z' "$shared_file" 2>/dev/null || stat -c '%Y.%s' "$shared_file" 2>/dev/null)"
  else
    sig="s:absent"
  fi
  if [ -f "$local_file" ] || [ -L "$local_file" ]; then
    sig="$sig|l:$(stat -f '%m.%z' "$local_file" 2>/dev/null || stat -c '%Y.%s' "$local_file" 2>/dev/null)"
  else
    sig="$sig|l:absent"
  fi
  printf '%s\n' "$sig"
}

# specrelay::config::_effective_envelope_json <project-root>
# Cached entry point: prints the same envelope as the uncached
# implementation below, computing it at most ONCE per (invocation, current
# file signature) pair (see _cache_file / _source_signature above).
specrelay::config::_effective_envelope_json() {
  local root="$1" cache_file sig_file tmp current_sig cached_sig
  cache_file="$(specrelay::config::_cache_file "$root")"
  sig_file="${cache_file}.sig"
  current_sig="$(specrelay::config::_source_signature "$root")"
  if [ -s "$cache_file" ] && [ -f "$sig_file" ]; then
    cached_sig="$(cat "$sig_file" 2>/dev/null)"
    if [ "$cached_sig" = "$current_sig" ]; then
      cat "$cache_file"
      return 0
    fi
  fi
  tmp="$(mktemp "${cache_file}.XXXXXX" 2>/dev/null || printf '%s.%s\n' "$cache_file" "$RANDOM")"
  specrelay::config::_effective_envelope_json_uncached "$root" > "$tmp" 2>/dev/null
  # Atomic rename into place: concurrent callers (e.g. bounded-parallel
  # verification checks) may race here, but every racer computed the SAME
  # merge from the SAME files, so a lost race just means one redundant
  # computation, never corrupt or inconsistent content.
  mv -f "$tmp" "$cache_file" 2>/dev/null
  printf '%s\n' "$current_sig" > "$sig_file" 2>/dev/null
  cat "$cache_file" 2>/dev/null || cat "$tmp" 2>/dev/null
}

# specrelay::config::_effective_envelope_json_uncached <project-root>
# THE single merge implementation. Prints one JSON object to stdout and
# ALWAYS exits 0 (success/failure is carried in the "ok" field, not the exit
# code, so callers that want sources/provenance even on failure never lose
# them to a truncated capture). Envelope shape:
#   {
#     "ok": true|false,
#     "error": null|"<path-specific detail>",
#     "phase": null|"pre-merge"|"merge",
#     "data": {...merged mapping...}|null,
#     "data_yaml": "<merged mapping re-serialized as YAML>"|null,
#     "provenance": [ {"path","value","source_kind","source_path","overrode","removed"?} ... ],
#     "sources": [ {"kind":"shared"|"local","path","present","sha256"} ... ],
#     "shared_present": bool,
#     "local_present": bool
#   }
# "provenance" covers every LEAF reachable in either file: a leaf overridden
# by the local file has source_kind "local" (with the shared value it
# replaced, if any, under "overrode"); a leaf that came only from the shared
# file has source_kind "shared". Environment-variable and CLI-flag layers are
# NOT part of this envelope (this module only merges the two YAML files) —
# callers that need the full defaults/shared/local/environment/CLI picture
# (config explain) layer that on top themselves.
specrelay::config::_effective_envelope_json_uncached() {
  local root="$1"
  ruby -e '
    require "yaml"
    require "json"
    require "digest"

    root = ARGV[0]
    begin
      real_root = File.realpath(root)
    rescue StandardError
      real_root = File.expand_path(root)
    end

    shared_path = File.join(root, ".specrelay", "config.yml")
    local_path  = File.join(root, ".specrelay", "config.local.yml")

    def emit(hash)
      puts hash.to_json
    end

    def type_name(v)
      case v
      when Hash then "mapping"
      when Array then "list"
      when String then "string"
      when TrueClass, FalseClass then "boolean"
      when Integer, Float then "number"
      when NilClass then "null"
      else v.class.name
      end
    end

    sources = []

    # ---- shared: single read, digest from the SAME bytes used to parse ----
    shared_present = File.file?(shared_path)
    shared_data = {}
    if shared_present
      bytes = File.read(shared_path)
      sources << {"kind" => "shared", "path" => ".specrelay/config.yml", "present" => true, "sha256" => Digest::SHA256.hexdigest(bytes)}
      begin
        parsed = YAML.safe_load(bytes, permitted_classes: [], aliases: false)
      rescue Psych::SyntaxError, Psych::DisallowedClass => e
        emit({"ok" => false, "error" => "shared configuration (.specrelay/config.yml) is malformed YAML: #{e.message}", "phase" => "pre-merge", "data" => nil, "data_yaml" => nil, "provenance" => [], "sources" => sources, "shared_present" => shared_present, "local_present" => false})
        exit 0
      end
      parsed = {} if parsed.nil?
      unless parsed.is_a?(Hash)
        emit({"ok" => false, "error" => "shared configuration (.specrelay/config.yml) root must be a mapping (got #{type_name(parsed)})", "phase" => "pre-merge", "data" => nil, "data_yaml" => nil, "provenance" => [], "sources" => sources, "shared_present" => shared_present, "local_present" => false})
        exit 0
      end
      shared_data = parsed
    else
      sources << {"kind" => "shared", "path" => ".specrelay/config.yml", "present" => false, "sha256" => nil}
    end

    # ---- local: symlink-outside-root refusal, then single read ----
    if File.symlink?(local_path)
      begin
        real_target = File.realpath(local_path)
      rescue StandardError => e
        emit({"ok" => false, "error" => "local configuration (.specrelay/config.local.yml) is a symlink with an unresolvable target: #{e.message}", "phase" => "pre-merge", "data" => nil, "data_yaml" => nil, "provenance" => [], "sources" => sources, "shared_present" => shared_present, "local_present" => false})
        exit 0
      end
      unless real_target == real_root || real_target.start_with?(real_root + File::SEPARATOR)
        emit({"ok" => false, "error" => "local configuration (.specrelay/config.local.yml) is a symlink resolving outside the project root (target: #{real_target}); refusing to load it", "phase" => "pre-merge", "data" => nil, "data_yaml" => nil, "provenance" => [], "sources" => sources, "shared_present" => shared_present, "local_present" => false})
        exit 0
      end
    end

    local_present = false
    local_data = {}
    if File.file?(local_path)
      local_present = true
      bytes = File.read(local_path)
      sources << {"kind" => "local", "path" => ".specrelay/config.local.yml", "present" => true, "sha256" => Digest::SHA256.hexdigest(bytes)}
      begin
        parsed = YAML.safe_load(bytes, permitted_classes: [], aliases: false)
      rescue Psych::SyntaxError, Psych::DisallowedClass => e
        emit({"ok" => false, "error" => "local configuration (.specrelay/config.local.yml) is malformed YAML: #{e.message}", "phase" => "pre-merge", "data" => nil, "data_yaml" => nil, "provenance" => [], "sources" => sources, "shared_present" => shared_present, "local_present" => local_present})
        exit 0
      end
      parsed = {} if parsed.nil?
      unless parsed.is_a?(Hash)
        emit({"ok" => false, "error" => "local configuration (.specrelay/config.local.yml) root must be a mapping (got #{type_name(parsed)})", "phase" => "pre-merge", "data" => nil, "data_yaml" => nil, "provenance" => [], "sources" => sources, "shared_present" => shared_present, "local_present" => local_present})
        exit 0
      end
      local_data = parsed
    else
      sources << {"kind" => "local", "path" => ".specrelay/config.local.yml", "present" => false, "sha256" => nil}
    end

    # ---- deep merge (spec section 8): mappings recurse, lists/scalars
    # replace wholesale, explicit null removes the inherited key, and a
    # mapping/scalar type conflict at the same path fails with the path. ----
    class TypeConflict < StandardError; end

    provenance = []

    merge = lambda do |shared_val, has_local, local_val, path|
      path_str = path.join(".")

      unless has_local
        next [shared_val, true]
      end

      if local_val.nil?
        overrode = shared_val.nil? ? [] : [{"source_kind" => "shared", "value" => shared_val}]
        provenance << {"path" => path_str, "value" => nil, "source_kind" => "local", "source_path" => ".specrelay/config.local.yml", "removed" => true, "overrode" => overrode}
        next [nil, false]
      end

      if local_val.is_a?(Hash)
        if !shared_val.nil? && !shared_val.is_a?(Hash)
          raise TypeConflict, "#{path_str} must be #{type_name(shared_val)} (matching the shared configuration), got a mapping in local configuration"
        end
        shared_hash = shared_val.is_a?(Hash) ? shared_val : {}
        merged = {}
        keys = (shared_hash.keys + local_val.keys).uniq
        keys.each do |k|
          sv = shared_hash.key?(k) ? shared_hash[k] : nil
          has_l = local_val.key?(k)
          lv = has_l ? local_val[k] : nil
          val, present = merge.call(sv, has_l, lv, path + [k])
          merged[k] = val if present
        end
        next [merged, true]
      end

      if shared_val.is_a?(Hash)
        raise TypeConflict, "#{path_str} must be a mapping, got #{type_name(local_val)}"
      end

      overrode = shared_val.nil? ? [] : [{"source_kind" => "shared", "value" => shared_val}]
      provenance << {"path" => path_str, "value" => local_val, "source_kind" => "local", "source_path" => ".specrelay/config.local.yml", "overrode" => overrode}
      [local_val, true]
    end

    # record_shared_provenance: after the merge above (which only records
    # LOCAL-sourced leaves), walk the ORIGINAL shared tree and add a
    # provenance entry for every leaf not already recorded — never
    # reconstructed heuristically, just the shared values merge() did not
    # touch because local had no key at all on that path (spec section 18:
    # "must not reconstruct provenance heuristically after merge" — this is
    # still the SAME merge pass''s bookkeeping, just deferred until the
    # local-override set is known).
    record_shared_provenance = lambda do |value, path, visited|
      path_str = path.join(".")
      if value.is_a?(Hash)
        value.each { |k, v| record_shared_provenance.call(v, path + [k], visited) }
      else
        next if visited.include?(path_str)
        provenance << {"path" => path_str, "value" => value, "source_kind" => "shared", "source_path" => ".specrelay/config.yml", "overrode" => []}
      end
    end

    merged = {}
    begin
      keys = (shared_data.keys + local_data.keys).uniq
      keys.each do |k|
        sv = shared_data.key?(k) ? shared_data[k] : nil
        has_l = local_data.key?(k)
        lv = has_l ? local_data[k] : nil
        val, present = merge.call(sv, has_l, lv, [k])
        merged[k] = val if present
      end
    rescue TypeConflict => e
      emit({"ok" => false, "error" => e.message, "phase" => "merge", "data" => nil, "data_yaml" => nil, "provenance" => [], "sources" => sources, "shared_present" => shared_present, "local_present" => local_present})
      exit 0
    end

    visited = provenance.map { |p| p["path"] }
    record_shared_provenance.call(shared_data, [], visited)

    emit({
      "ok" => true,
      "error" => nil,
      "phase" => nil,
      "data" => merged,
      "data_yaml" => merged.to_yaml,
      "provenance" => provenance,
      "sources" => sources,
      "shared_present" => shared_present,
      "local_present" => local_present,
    })
  ' "$root"
}

# specrelay::config::effective_envelope <project-root>
# Public alias for the merge envelope above (used by doctor, CLI config
# commands, and task effective-configuration capture).
specrelay::config::effective_envelope() {
  specrelay::config::_effective_envelope_json "$1"
}

# specrelay::config::effective_ok <project-root>
# True (exit 0) when the shared+local merge is valid; false otherwise. Prints
# nothing.
specrelay::config::effective_ok() {
  local root="$1"
  command -v ruby >/dev/null 2>&1 || return 0
  specrelay::config::_effective_envelope_json "$root" | ruby -rjson -e '
    d = JSON.parse(STDIN.read)
    exit(d["ok"] ? 0 : 1)
  '
}

# specrelay::config::effective_error <project-root>
# Prints the merge error detail (empty when the merge is valid).
specrelay::config::effective_error() {
  local root="$1"
  command -v ruby >/dev/null 2>&1 || return 0
  specrelay::config::_effective_envelope_json "$root" | ruby -rjson -e '
    d = JSON.parse(STDIN.read)
    print(d["ok"] ? "" : d["error"].to_s)
  '
}

# specrelay::config::validate_effective <project-root>
# The REQUIRED gate before a task may enter EXECUTOR_RUNNING / REVIEWER_RUNNING
# or invoke the Coordinator (spec section 13, section 24 "Error and fallback
# policy" — no permissive fallback from an invalid local overlay). Prints
# nothing on success (exit 0); on failure prints an actionable, source-
# specific error (exit 1). Shared-file validation is unchanged
# (specrelay::config::validate); this additionally covers local YAML syntax,
# root type, merge type compatibility, and the symlink boundary rule.
specrelay::config::validate_effective() {
  local root="$1" err
  specrelay::config::validate "$root" || return 1
  if err="$(specrelay::config::effective_error "$root")" && [ -z "$err" ]; then
    return 0
  fi
  err="$(specrelay::config::effective_error "$root")"
  specrelay::out::err "Invalid local configuration:"
  {
    echo "  source: .specrelay/config.local.yml"
    echo "  error: $err"
  } >&2
  return 1
}

# specrelay::config::effective_data_yaml <project-root>
# Prints the MERGED (shared + local) configuration re-serialized as YAML on
# success (exit 0) — a drop-in replacement for `File.read(shared-config-path)`
# inside every config.sh accessor below that must honor the local overlay.
# On an invalid local overlay (malformed YAML, wrong root type, a merge type
# conflict, or a symlink escaping the project root), prints the SAME
# human-readable error DETAIL config.sh's other accessors already print on
# their own structural errors (exit 1) — callers propagate this exactly like
# any other "bad()" detail (spec section 24: no silent fallback to
# shared-only configuration).
specrelay::config::effective_data_yaml() {
  local root="$1" cache_file sig_file tmp status body current_sig cached_sig
  if ! command -v ruby >/dev/null 2>&1; then
    printf '{}\n'
    return 0
  fi

  # Cached (see _cache_file / _source_signature above): this is the hottest
  # path in config.sh — every accessor (get/role_context/
  # role_model_selection/verification_policy/phase_budgets/
  # execution_efficiency_policy/coordinator_policy) calls this once per
  # invocation of ITSELF, and those accessors are each called many times over
  # a single `run`/`resume`. Caching here avoids a second Ruby fork per call
  # on top of the (already-cached) envelope computation. Gated on the SAME
  # mtime+size signature as the envelope cache, so a caller that rewrites a
  # fixture's config file in-place within one long-lived process (this
  # repository's own test suite) never reads stale data.
  cache_file="$(specrelay::config::_cache_file "$root").data_yaml"
  sig_file="${cache_file}.sig"
  current_sig="$(specrelay::config::_source_signature "$root")"
  if [ -s "$cache_file" ] && [ -f "$sig_file" ]; then
    cached_sig="$(cat "$sig_file" 2>/dev/null)"
    if [ "$cached_sig" = "$current_sig" ]; then
      status="$(head -n 1 "$cache_file")"
      body="$(tail -n +2 "$cache_file")"
      if [ "$status" = "OK" ]; then
        printf '%s' "$body"
        return 0
      fi
      printf '%s\n' "$body"
      return 1
    fi
  fi

  tmp="$(mktemp "${cache_file}.XXXXXX" 2>/dev/null || printf '%s.%s\n' "$cache_file" "$RANDOM")"
  specrelay::config::_effective_envelope_json "$root" | ruby -rjson -ryaml -e '
    d = JSON.parse(STDIN.read)
    if d["ok"]
      puts "OK"
      print d["data_yaml"]
    else
      puts "ERR"
      puts d["error"]
    end
  ' > "$tmp" 2>/dev/null
  mv -f "$tmp" "$cache_file" 2>/dev/null
  printf '%s\n' "$current_sig" > "$sig_file" 2>/dev/null

  status="$(head -n 1 "$cache_file" 2>/dev/null)"
  body="$(tail -n +2 "$cache_file" 2>/dev/null)"
  if [ "$status" = "OK" ]; then
    printf '%s' "$body"
    return 0
  fi
  printf '%s\n' "$body"
  return 1
}

# --- secret-shaped key detection (shared with CLI/doctor/task-capture) ------
#
# Reuses the same marker-substring approach as verification_policy_lib.py's
# _secret_shaped / command_timing_lib.py's redact_command (spec section 10:
# "reuse an existing centralized redaction mechanism ... rather than creating
# inconsistent per-command redaction") plus this spec's own examples (cookie,
# credential). Matching is done against the LAST dotted path segment,
# case-insensitively, by substring — the same "name marker" approach already
# used elsewhere in this codebase.
SPECRELAY_CONFIG_SECRET_MARKERS_RB='%w[TOKEN API_KEY APIKEY SECRET PASSWORD PASSWD COOKIE AUTHORIZATION CREDENTIAL PRIVATE_KEY ACCESS_KEY CLIENT_SECRET]'

# --- `specrelay config show` (spec section 16.2) ----------------------------
#
# specrelay::config::cmd_show <project-root> [--effective] [--sources] [--json]
# Entirely read-only: validates and reports; never creates a task, never
# writes a configuration file.
specrelay::config::cmd_show() {
  local root="$1"; shift
  local want_effective=0 want_sources=0 want_json=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --effective) want_effective=1; shift ;;
      --sources) want_sources=1; shift ;;
      --json) want_json=1; shift ;;
      *) specrelay::out::err "usage: specrelay config show [--effective] [--sources] [--json]"; return 2 ;;
    esac
  done

  local envelope
  envelope="$(specrelay::config::effective_envelope "$root")"

  ENVELOPE="$envelope" WANT_EFFECTIVE="$want_effective" WANT_SOURCES="$want_sources" WANT_JSON="$want_json" \
    MARKERS="$SPECRELAY_CONFIG_SECRET_MARKERS_RB" \
    ruby -rjson -ryaml -e '
    d = JSON.parse(ENV["ENVELOPE"])
    markers = eval(ENV["MARKERS"])

    def secret_shaped?(path, markers)
      last = path.to_s.split(".").last.to_s.upcase
      markers.any? { |m| last.include?(m) }
    end

    def redact_tree(value, path, markers)
      if value.is_a?(Hash)
        value.each_with_object({}) { |(k, v), acc| acc[k] = redact_tree(v, path.empty? ? k.to_s : "#{path}.#{k}", markers) }
      else
        secret_shaped?(path, markers) ? "[REDACTED]" : value
      end
    end

    shared_src = (d["sources"] || []).find { |s| s["kind"] == "shared" } || {}
    local_src  = (d["sources"] || []).find { |s| s["kind"] == "local" } || {}
    local_status =
      if !local_src["present"]
        "not present"
      elsif d["ok"]
        "loaded"
      else
        "invalid"
      end

    effective = d["ok"] ? redact_tree(d["data"], "", markers) : nil

    if ENV["WANT_JSON"] == "1"
      out = {
        "shared_configuration" => {"path" => ".specrelay/config.yml", "present" => shared_src["present"]},
        "local_overlay" => {"path" => ".specrelay/config.local.yml", "status" => local_status},
        "precedence" => ["defaults", "shared", "local", "environment", "cli"],
        "merge_valid" => d["ok"],
      }
      out["sources"] = d["sources"] if ENV["WANT_SOURCES"] == "1"
      if ENV["WANT_EFFECTIVE"] == "1"
        out["effective"] = effective
        out["merge_error"] = d["error"] unless d["ok"]
      end
      puts JSON.pretty_generate(out)
      exit(d["ok"] ? 0 : 1)
    end

    puts "Shared configuration: .specrelay/config.yml (#{shared_src["present"] ? "present" : "missing"})"
    puts "Local overlay: .specrelay/config.local.yml (#{local_status})"
    puts "Effective precedence: defaults < shared < local < environment < CLI"
    unless d["ok"]
      puts "Merge: INVALID — #{d["error"]}"
    end

    if ENV["WANT_SOURCES"] == "1"
      puts
      puts "Sources:"
      (d["sources"] || []).each do |s|
        digest = s["sha256"] ? s["sha256"][0, 12] : "(none)"
        puts "  #{s["kind"]}: #{s["path"]} present=#{s["present"]} sha256=#{digest}"
      end
    end

    if ENV["WANT_EFFECTIVE"] == "1"
      puts
      if d["ok"]
        puts "Effective configuration (secrets redacted):"
        puts effective.to_yaml
      else
        puts "Effective configuration: unavailable (invalid local overlay)"
      end
    end

    exit(d["ok"] ? 0 : 1)
  '
}

# --- `specrelay config explain <path>` (spec section 16.3) ------------------
#
# specrelay::config::cmd_explain <project-root> <dotted.path>
# Read-only. Reports the final (redacted-if-secret) value, the source layer
# that supplied it (defaults|shared|local|environment|cli), and any
# lower-priority value it replaced (redacted-if-secret). The environment/CLI
# layers above the merge engine are recognized only for the small,
# documented set of role env overrides (SPECRELAY_EXECUTOR_MODEL,
# SPECRELAY_EXECUTOR_AGENT, SPECRELAY_REVIEWER_MODEL,
# SPECRELAY_REVIEWER_AGENT — see workflow.sh's _role_env) — this module does
# not invent a generic env-var-per-path mapping (spec section 19: "must not
# add generic arbitrary environment-variable mapping for every YAML path").
specrelay::config::cmd_explain() {
  local root="$1" path="$2"
  [ -n "$path" ] || { specrelay::out::err "usage: specrelay config explain <dotted.path>"; return 2; }

  local envelope env_var env_val=""
  envelope="$(specrelay::config::effective_envelope "$root")"

  case "$path" in
    roles.executor.model) env_var="SPECRELAY_EXECUTOR_MODEL" ;;
    roles.executor.agent) env_var="SPECRELAY_EXECUTOR_AGENT" ;;
    roles.reviewer.model) env_var="SPECRELAY_REVIEWER_MODEL" ;;
    roles.reviewer.agent) env_var="SPECRELAY_REVIEWER_AGENT" ;;
    *) env_var="" ;;
  esac
  [ -n "$env_var" ] && env_val="${!env_var:-}"

  ENVELOPE="$envelope" PATH_ARG="$path" ENV_VAR="$env_var" ENV_VAL="$env_val" \
    MARKERS="$SPECRELAY_CONFIG_SECRET_MARKERS_RB" \
    ruby -rjson -e '
    d = JSON.parse(ENV["ENVELOPE"])
    markers = eval(ENV["MARKERS"])
    path = ENV["PATH_ARG"]

    def secret_shaped?(path, markers)
      last = path.to_s.split(".").last.to_s.upcase
      markers.any? { |m| last.include?(m) }
    end

    def display(value, path, markers)
      return "[REDACTED]" if secret_shaped?(path, markers)
      return "null" if value.nil?
      value.is_a?(String) ? value : value.inspect
    end

    unless d["ok"]
      puts "Invalid configuration: #{d["error"]}"
      exit 1
    end

    if !ENV["ENV_VAR"].to_s.empty? && !ENV["ENV_VAL"].to_s.empty?
      shown = secret_shaped?(path, markers) ? "[REDACTED]" : ENV["ENV_VAL"]
      puts "#{path} = #{shown}"
      puts "source: $#{ENV["ENV_VAR"]} (environment override)"
      entry = (d["provenance"] || []).find { |p| p["path"] == path }
      if entry
        puts "replaced: #{display(entry["value"], path, markers)} from #{entry["source_kind"] == "local" ? ".specrelay/config.local.yml" : ".specrelay/config.yml"}"
      end
      exit 0
    end

    entry = (d["provenance"] || []).find { |p| p["path"] == path }
    unless entry
      puts "#{path}: not set in shared or local configuration; built-in default applies (if any)"
      puts "source: default"
      exit 0
    end

    source_path = entry["source_kind"] == "local" ? ".specrelay/config.local.yml" : ".specrelay/config.yml"
    if entry["removed"]
      puts "#{path} = (removed by explicit null in local configuration; built-in default applies, if any)"
      puts "source: #{source_path}"
    else
      puts "#{path} = #{display(entry["value"], path, markers)}"
      puts "source: #{source_path}"
    end
    (entry["overrode"] || []).each do |o|
      o_source = o["source_kind"] == "local" ? ".specrelay/config.local.yml" : ".specrelay/config.yml"
      puts "replaced: #{display(o["value"], path, markers)} from #{o_source}"
    end
  '
}
