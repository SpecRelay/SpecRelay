#!/usr/bin/env ruby
# frozen_string_literal: true
#
# architecture_validate.rb — the CANONICAL architecture-version contract
# validator (spec 0031, sections 11-14). This is the single source of truth
# used by `specrelay architecture validate`, the release-command preflight,
# and the focused test suite; there is deliberately ONE parser with ONE set of
# rules (spec 12.1), never two slightly-divergent ones.
#
# Parser choice mirrors lib/specrelay/config.sh and select_tests.rb: this
# repository's native runtime is Ruby, whose stdlib ships Psych (YAML).
# `YAML.safe_load` restricts parsing to plain scalars/arrays/hashes and never
# instantiates arbitrary objects — no new third-party dependency is added, and
# `YAML.load`/`unsafe_load`/regex-only YAML parsing are never used (spec 12.1).
#
# It validates, against a SpecRelay SOURCE checkout (never a consumer
# project's .specrelay/config.yml):
#   - the architecture-version.yml schema (version/status/timestamp/enforcement/
#     boundary/required_field);
#   - the document + ADR set (existence, no-escape, no-duplicate, per-ADR
#     architecture version, required ADR headings, index/set agreement);
#   - accepted-vs-proposed status coherence; and
#   - the future-spec `architecture_version` metadata contract for every spec
#     numbered strictly greater than the recorded adoption boundary.
#
# It is READ-ONLY and DETERMINISTIC: it never writes, never touches the network,
# and depends on nothing outside the passed --root. On any failure it prints one
# actionable diagnostic per problem and exits non-zero; on success it prints a
# concise summary and exits zero. `--json` emits a stable object with at least
# ok/architecture_version/status/adoption_boundary/checked_specs/errors.
#
# Usage:
#   architecture_validate.rb --root R [--json]

require "yaml"
require "json"
require "date"
require "time"

PROG = "specrelay architecture validate"
VERSION_FILE_REL = "architecture/architecture-version.yml"
REQUIRED_DOC_KEYS = %w[north_star principles decisions_index].freeze
REQUIRED_FIELD = "architecture_version"
VALID_STATUSES = %w[proposed accepted superseded].freeze
# The lifecycle status word as it appears in an ADR `## Status` line, a
# north-star/principles `**Status:**` surface, and the decisions-index status
# column — keyed by the version file's lowercase status.
STATUS_TITLECASE = { "proposed" => "Proposed", "accepted" => "Accepted", "superseded" => "Superseded" }.freeze
# Only these enforcement values are supported, per status (finding 5). Anything
# else — including a plausible-looking typo — is rejected, never accepted.
SUPPORTED_ENFORCEMENT = { "accepted" => %w[machine-validated], "proposed" => %w[documentation-only] }.freeze
# Every ADR must carry these headings (architecture/decisions/README.md
# "Conventions"). "Title" is the leading `# ADR-NNNN …` line; the rest are
# level-2 headings.
REQUIRED_ADR_HEADINGS = [
  "Status", "Architecture version", "Context", "Decision",
  "Alternatives considered", "Consequences",
  "Compatibility / migration impact", "Supersedes / superseded by",
  "Verification or evidence", "Open questions"
].freeze
# A FULL ISO-8601 date-time with an explicit timezone (Z or ±HH[:]MM). The
# `T` date/time separator, the seconds field, and the timezone are all required
# (finding 4): a date-only value, a value missing the time, or a value with no
# timezone is rejected.
ISO8601_TZ = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})\z/

# A single accumulated validation problem, rendered as
#   "<where>: <message>"
class Report
  attr_reader :errors

  def initialize
    @errors = []
  end

  def error(where, message)
    @errors << "#{where}: #{message}"
  end

  def ok?
    @errors.empty?
  end
end

def parse_args(argv)
  root = nil
  json = false
  compute_boundary = false
  i = 0
  while i < argv.length
    case argv[i]
    when "--root"
      root = argv[i + 1]
      i += 2
    when "--json"
      json = true
      i += 1
    when "--compute-boundary"
      # The deterministic ratification-time computation (spec 9): print the
      # maximum four-digit spec prefix present, so ratification never hard-codes
      # the boundary. Read-only, exits 0.
      compute_boundary = true
      i += 1
    else
      warn "#{PROG}: unknown argument: #{argv[i]}"
      exit 2
    end
  end
  if root.nil? || root.empty?
    warn "#{PROG}: --root <specrelay-source-checkout> is required"
    exit 2
  end
  [root, json, compute_boundary]
end

# Canonically resolve a repository-root-relative path, rejecting absolute
# paths, `..` escapes, and symlink targets outside the root (spec 12.2). Returns
# [absolute_real_path, nil] on success or [nil, reason] on rejection/missing.
def resolve_in_root(root_real, rel)
  unless rel.is_a?(String) && !rel.empty?
    return [nil, "path is missing or not a string"]
  end
  if rel.start_with?("/")
    return [nil, "absolute paths are not allowed (#{rel})"]
  end
  if rel.split(%r{[/\\]}).include?("..")
    return [nil, "path escapes the repository with '..' (#{rel})"]
  end
  joined = File.join(root_real, rel)
  begin
    real = File.realpath(joined)
  rescue Errno::ENOENT
    return [nil, "path does not exist (#{rel})"]
  end
  prefix = root_real.end_with?(File::SEPARATOR) ? root_real : root_real + File::SEPARATOR
  unless real == root_real || real.start_with?(prefix)
    return [nil, "path resolves outside the repository root (#{rel})"]
  end
  [real, nil]
end

# Enumerate docs/specs/NNNN-*/spec.md directories as a sorted array of
# [number, name] pairs (INCLUDING any two directories that share a number, so a
# collision is detected rather than silently overwritten — finding 2). Only a
# four-digit numeric prefix immediately followed by '-' qualifies (spec 9.2);
# non-numbered directories are ignored.
def enumerate_specs(root_real)
  specs_dir = File.join(root_real, "docs", "specs")
  out = []
  return out unless File.directory?(specs_dir)
  Dir.children(specs_dir).sort.each do |name|
    full = File.join(specs_dir, name)
    next unless File.directory?(full)
    m = name.match(/\A(\d{4})-/)
    next unless m
    next unless File.file?(File.join(full, "spec.md"))
    out << [m[1].to_i, name]
  end
  out.sort_by { |number, name| [number, name] }
end

# Extract the body of the single `## [N.] Architecture metadata` section from a
# spec's markdown, plus how many such sections exist. Returns [count, body].
def architecture_metadata_sections(text)
  lines = text.lines
  sections = []
  current = nil
  lines.each do |line|
    if line =~ /\A##\s+(?:\d+\.?\s+)?Architecture metadata\s*\z/
      current = []
      sections << current
    elsif line =~ /\A##\s+/ # any other level-2 heading closes the section
      current = nil
    elsif current
      current << line
    end
  end
  [sections.length, sections.first&.join || ""]
end

# The first ```yaml / ```yml fenced block inside a section body, or nil.
def first_yaml_fence(body)
  in_block = false
  buf = []
  body.lines.each do |line|
    if !in_block && line =~ /\A```ya?ml\s*\z/
      in_block = true
      next
    elsif in_block && line =~ /\A```\s*\z/
      return buf.join
    elsif in_block
      buf << line
    end
  end
  nil
end

# Validate one post-boundary spec's Architecture metadata contract (spec 11).
def validate_spec_metadata(report, spec_rel, spec_md, version)
  text = File.read(spec_md)
  count, body = architecture_metadata_sections(text)
  if count.zero?
    report.error(spec_rel, "missing Architecture metadata section; expected #{REQUIRED_FIELD}: #{version}")
    return
  end
  if count > 1
    report.error(spec_rel, "duplicate Architecture metadata sections (#{count}); expected exactly one")
    return
  end
  fence = first_yaml_fence(body)
  if fence.nil?
    report.error(spec_rel, "Architecture metadata section has no fenced YAML block; expected #{REQUIRED_FIELD}: #{version}")
    return
  end
  # A duplicate `architecture_version` key is a contract violation even though
  # Psych (safe_load) silently keeps the last one. Detect the bare key AND the
  # quoted-key variants (`"architecture_version":` / `'architecture_version':`)
  # so `architecture_version: 1` + `"architecture_version": 2` cannot slip
  # through (finding 3).
  if fence.scan(/^\s*(?:"#{REQUIRED_FIELD}"|'#{REQUIRED_FIELD}'|#{REQUIRED_FIELD})\s*:/).length > 1
    report.error(spec_rel, "duplicate #{REQUIRED_FIELD} field in the Architecture metadata block")
    return
  end
  begin
    data = YAML.safe_load(fence, permitted_classes: [], aliases: false)
  rescue Psych::SyntaxError, Psych::DisallowedClass => e
    report.error(spec_rel, "malformed Architecture metadata YAML block (#{e.message.lines.first.to_s.strip})")
    return
  end
  unless data.is_a?(Hash)
    report.error(spec_rel, "Architecture metadata YAML block must be a mapping containing #{REQUIRED_FIELD}: #{version}")
    return
  end
  unless data.key?(REQUIRED_FIELD)
    report.error(spec_rel, "Architecture metadata block is missing the #{REQUIRED_FIELD} field; expected #{REQUIRED_FIELD}: #{version}")
    return
  end
  val = data[REQUIRED_FIELD]
  # Reject a quoted string, float, list, boolean, etc.: it must be a bare
  # integer. (true/false are not Integers; "1" parses to String; 1.0 to Float.)
  unless val.is_a?(Integer) && !val.is_a?(TrueClass) && !val.is_a?(FalseClass)
    report.error(spec_rel, "#{REQUIRED_FIELD} must be a bare integer, not #{val.inspect}")
    return
  end
  unless val == version
    report.error(spec_rel, "#{REQUIRED_FIELD} #{val} does not match accepted version #{version}")
    return
  end
end

def run(root, report)
  root_real = File.realpath(root) rescue nil
  if root_real.nil? || !File.directory?(root_real)
    report.error(root, "not a directory")
    return { version: nil, status: nil, boundary: nil, checked: 0 }
  end

  vf_rel = VERSION_FILE_REL
  vf_abs = File.join(root_real, vf_rel)
  unless File.file?(vf_abs)
    report.error(vf_rel, "architecture version file not found")
    return { version: nil, status: nil, boundary: nil, checked: 0 }
  end

  begin
    # `Time`/`Date` are permitted only so an unquoted ISO-8601 `ratified_at`
    # (which Psych auto-types as a Time) does not make the whole file
    # unparseable. This is still `safe_load` with an explicit allow-list — never
    # `YAML.load`/`unsafe_load` — so no arbitrary object is ever instantiated.
    doc = YAML.safe_load(File.read(vf_abs), permitted_classes: [Time, Date], aliases: false)
  rescue Psych::SyntaxError, Psych::DisallowedClass => e
    report.error(vf_rel, "malformed YAML (#{e.message.lines.first.to_s.strip})")
    return { version: nil, status: nil, boundary: nil, checked: 0 }
  end

  unless doc.is_a?(Hash)
    report.error(vf_rel, "root must be a mapping")
    return { version: nil, status: nil, boundary: nil, checked: 0 }
  end

  # --- version -------------------------------------------------------------
  version = doc["version"]
  unless version.is_a?(Integer) && !version.is_a?(TrueClass) && !version.is_a?(FalseClass) && version.positive?
    report.error(vf_rel, "version must be a positive integer (got #{version.inspect})")
    version = nil
  end

  # --- status --------------------------------------------------------------
  status = doc["status"]
  unless VALID_STATUSES.include?(status)
    report.error(vf_rel, "status must be one of #{VALID_STATUSES.join('/')} (got #{status.inspect})")
    status = nil
  end

  # --- spec_contract sub-tree ---------------------------------------------
  sc = doc["spec_contract"]
  sc = {} unless sc.is_a?(Hash)
  required_field = sc["required_field"]
  if required_field != REQUIRED_FIELD
    report.error(vf_rel, "spec_contract.required_field must be '#{REQUIRED_FIELD}' (got #{required_field.inspect})")
  end
  enforcement = sc["enforcement"]
  ab = sc["adoption_boundary"]
  ab = {} unless ab.is_a?(Hash)
  boundary = ab["exempt_specs_up_to_and_including"]
  ratified_at = doc["ratified_at"]

  # --- status-dependent coherence -----------------------------------------
  boundary_active = nil
  if status == "accepted"
    # ratified_at MUST be a quoted full-ISO-8601 string with an explicit
    # timezone (finding 4). A YAML-typed Time/Date is rejected on purpose: it
    # cannot prove the source carried an explicit timezone (a Date has no time
    # at all, and an unquoted tz-less value is silently coerced), so the
    # contract requires the unambiguous quoted string form.
    if ratified_at.is_a?(String) && ratified_at.match?(ISO8601_TZ)
      # ok
    elsif ratified_at.is_a?(Time) || ratified_at.is_a?(Date)
      report.error(vf_rel, "ratified_at must be a QUOTED full ISO-8601 string with an explicit timezone (e.g. \"2026-07-19T08:50:41Z\"), not a bare YAML timestamp")
    else
      report.error(vf_rel, "accepted architecture requires a full ISO-8601 ratified_at timestamp with an explicit timezone (got #{ratified_at.inspect})")
    end
    if boundary.is_a?(Integer) && !boundary.is_a?(TrueClass) && !boundary.is_a?(FalseClass) && boundary >= 0
      boundary_active = boundary
    else
      report.error(vf_rel, "accepted architecture requires an integer adoption_boundary >= 0 (got #{boundary.inspect})")
    end
    unless SUPPORTED_ENFORCEMENT["accepted"].include?(enforcement)
      report.error(vf_rel, "accepted architecture enforcement must be one of #{SUPPORTED_ENFORCEMENT['accepted'].join('/')} (got #{enforcement.inspect})")
    end
  elsif status == "proposed"
    # A proposed configuration is valid but UNENFORCED (spec 12.3): its
    # boundary and timestamp are null and enforcement is documentation-only.
    unless ratified_at.nil?
      report.error(vf_rel, "proposed architecture must have ratified_at: null (got #{ratified_at.inspect})")
    end
    unless boundary.nil?
      report.error(vf_rel, "proposed architecture must have a null adoption_boundary until ratification (got #{boundary.inspect})")
    end
    unless SUPPORTED_ENFORCEMENT["proposed"].include?(enforcement)
      report.error(vf_rel, "proposed architecture enforcement must be one of #{SUPPORTED_ENFORCEMENT['proposed'].join('/')} until ratification (got #{enforcement.inspect})")
    end
  end

  # --- documents -----------------------------------------------------------
  documents = doc["documents"]
  documents = {} unless documents.is_a?(Hash)
  REQUIRED_DOC_KEYS.each do |k|
    unless documents.key?(k)
      report.error(vf_rel, "documents.#{k} is required but missing")
    end
  end
  documents.each do |k, rel|
    abs, reason = resolve_in_root(root_real, rel)
    if reason
      report.error(vf_rel, "documents.#{k}: #{reason}")
      next
    end
    # north-star.md and principles.md must declare a status coherent with the
    # version file (finding 1).
    validate_doc_status(report, rel, abs, status) if %w[north_star principles].include?(k)
  end

  # --- decisions -----------------------------------------------------------
  decisions = doc["decisions"]
  decisions = [] unless decisions.is_a?(Array)
  seen = {}
  decision_reals = []
  decisions.each do |rel|
    if seen[rel]
      report.error(vf_rel, "duplicate decision path (#{rel})")
      next
    end
    seen[rel] = true
    abs, reason = resolve_in_root(root_real, rel)
    if reason
      report.error(vf_rel, "decisions: #{reason}")
      next
    end
    decision_reals << [rel, abs]
    validate_adr(report, rel, abs, version, status)
  end

  # --- decisions index agrees with the version set -------------------------
  idx_rel = documents["decisions_index"]
  if idx_rel.is_a?(String)
    idx_abs, reason = resolve_in_root(root_real, idx_rel)
    if reason.nil?
      idx_text = File.read(idx_abs)
      indexed = idx_text.scan(/\(([^)]*ADR-\d{4}[^)]*\.md)[^)]*\)/).flatten.map do |p|
        File.join("architecture/decisions", File.basename(p))
      end.uniq.sort
      set = decisions.select { |d| d.is_a?(String) }.sort
      if indexed != set
        report.error(idx_rel, "decisions index does not match the architecture-version.yml decision set (index=#{indexed.inspect}, set=#{set.inspect})")
      end
      # Per-ADR status coherence in the index table (finding 1): a row that
      # links a version-set ADR and states a lifecycle-vocabulary status must
      # state the version file's status. Implementation-maturity words
      # (ENFORCED/ESTABLISHED/TARGET, or an upper-case PROPOSED with trailing
      # detail) are never bare status cells, so they are not confused with it.
      if status
        expected = STATUS_TITLECASE[status]
        idx_text.each_line do |line|
          next unless line =~ /ADR-\d{4}[^)]*\.md/
          cells = line.split("|").map(&:strip)
          found = cells.select { |c| %w[Proposed Accepted Superseded].include?(c) }
          next if found.empty?
          unless found.all? { |c| c == expected }
            report.error(idx_rel, "index status #{found.inspect} for '#{line.strip}' is incoherent with the #{status} architecture version (expected '#{expected}')")
          end
        end
      end
    end
  end

  # --- spec directories: reject duplicate numbers (finding 2) ---------------
  specs = enumerate_specs(root_real)
  by_number = {}
  specs.each { |number, name| (by_number[number] ||= []) << name }
  by_number.each do |number, names|
    next unless names.length > 1
    report.error("docs/specs", "duplicate spec directories share number #{format('%04d', number)}: #{names.sort.join(', ')} (each spec number must be unique)")
  end

  # --- post-boundary spec metadata contract --------------------------------
  checked = 0
  # The computed maximum prefix is informational; the STORED boundary is what
  # governs which specs must declare architecture_version (so a newly-added
  # 0032 is enforced without rewriting the version file).
  if status == "accepted" && !boundary_active.nil? && version
    specs.each do |number, name|
      next unless number > boundary_active
      checked += 1
      spec_md = File.join(root_real, "docs", "specs", name, "spec.md")
      validate_spec_metadata(report, File.join("docs/specs", name, "spec.md"), spec_md, version)
    end
  end

  { version: version, status: status, boundary: boundary_active, checked: checked, computed_max: specs.map { |number, _| number }.max }
end

# Validate a single listed ADR: it exists (already resolved), declares the
# architecture version, carries every required heading (spec 8.1 / 12.2), and
# its `## Status` lifecycle word is COHERENT with the version file's status
# (finding 1) — an accepted version cannot list a still-Proposed ADR.
def validate_adr(report, rel, abs, version, status)
  text = File.read(abs)
  declared = text[/^##\s*Architecture version\s*\n+\s*(\d+)/m, 1]
  if declared.nil?
    report.error(rel, "ADR does not declare an '## Architecture version'")
  elsif version && declared.to_i != version
    report.error(rel, "ADR architecture version #{declared} does not match version-file version #{version}")
  end
  unless text =~ /^#\s+ADR-\d{4}\b/
    report.error(rel, "ADR is missing its '# ADR-NNNN …' title heading")
  end
  REQUIRED_ADR_HEADINGS.each do |h|
    unless text =~ /^##\s+#{Regexp.escape(h)}\s*$/
      report.error(rel, "ADR is missing the required heading '## #{h}'")
    end
  end
  if status
    expected = STATUS_TITLECASE[status]
    adr_status = text[/^##\s*Status\s*\n+\s*([A-Za-z]+)/m, 1]
    if adr_status.nil?
      report.error(rel, "ADR '## Status' does not state a lifecycle status word")
    elsif adr_status != expected
      report.error(rel, "ADR status '#{adr_status}' is incoherent with the #{status} architecture version (expected '#{expected}')")
    end
  end
end

# Verify a normative document's `**Status:** <word>` surface matches the version
# file's status (finding 1). Called for north-star.md and principles.md.
def validate_doc_status(report, rel, abs, status)
  return unless status
  text = File.read(abs)
  declared = text[/\*\*Status:\*\*\s*([A-Za-z]+)/, 1]
  if declared.nil?
    report.error(rel, "does not declare a '**Status:**' surface coherent with the #{status} architecture version")
  elsif declared.downcase != status
    report.error(rel, "'**Status:** #{declared}' is incoherent with the #{status} architecture version (expected '#{status}')")
  end
end

# --- main --------------------------------------------------------------------
root, json, compute_boundary = parse_args(ARGV)

if compute_boundary
  root_real = File.realpath(root) rescue nil
  if root_real.nil? || !File.directory?(root_real)
    warn "#{PROG}: --root is not a directory"
    exit 2
  end
  max = enumerate_specs(root_real).map { |number, _| number }.max
  puts(max.nil? ? "" : max.to_s)
  exit 0
end

report = Report.new
info = run(root, report)

payload = {
  "ok" => report.ok?,
  "architecture_version" => info[:version],
  "status" => info[:status],
  "adoption_boundary" => info[:boundary],
  "checked_specs" => info[:checked],
  # The highest four-digit spec prefix present now (informational): the stored
  # adoption_boundary, not this value, governs enforcement.
  "computed_max_spec" => info[:computed_max],
  "errors" => report.errors,
}

if json
  puts JSON.pretty_generate(payload)
else
  if report.ok?
    if info[:status] == "accepted"
      b = info[:boundary]
      puts "OK - architecture version #{info[:version]} is accepted and its contract is valid."
      puts "  adoption boundary: #{format('%04d', b)} (specs numbered after #{format('%04d', b)} must declare architecture_version: #{info[:version]})"
      puts "  post-boundary specs checked: #{info[:checked]} (all declare architecture_version: #{info[:version]})"
    elsif info[:status] == "proposed"
      puts "OK - architecture version #{info[:version]} is a valid PROPOSED configuration."
      puts "  the contract is NOT ratified: architecture_version enforcement is inactive until status becomes 'accepted'."
    else
      puts "OK - architecture configuration is valid (status: #{info[:status]})."
    end
  else
    warn "#{PROG}: FAILED — #{report.errors.length} problem(s):"
    report.errors.each { |e| warn "  #{e}" }
  end
end

exit(report.ok? ? 0 : 1)
