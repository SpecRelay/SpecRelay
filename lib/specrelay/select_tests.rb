#!/usr/bin/env ruby
# frozen_string_literal: true
#
# select_tests.rb — change-aware test selection engine (spec 0017).
#
# This is the deterministic core of `scripts/test --changed[...]`. The bash
# runner owns everything Git-specific (gathering changed files from the working
# tree, a ref range, or an evidence file, and excluding runtime directories);
# this engine owns everything mapping-specific: parsing + validating
# test/test-selection.yml, matching changed files to rules with a documented,
# platform-independent glob implementation, computing the selection mode, and
# producing the explanation / machine-readable evidence. Keeping the two apart
# means selection is never coupled to a shell's glob configuration or to an AI
# provider.
#
# Parser choice mirrors lib/specrelay/config.sh: this repository's native
# runtime is Ruby, whose stdlib ships Psych (YAML). `YAML.safe_load` restricts
# parsing to plain scalars/arrays/hashes and never instantiates arbitrary
# objects. The map path is passed as argv, never interpolated.
#
# Glob semantics (deterministic; NOT shell globbing, NOT File.fnmatch whose
# `**` handling varies with FNM_PATHNAME across platforms):
#   *    matches any run of characters except '/'
#   ?    matches a single character except '/'
#   **   matches any run of characters INCLUDING '/'  (recursive)
#   **/  matches zero or more complete leading path segments
#   [..] a bracket character class; [!..] / [^..] negate; an unterminated
#        '[' is an invalid glob (rejected).
#   every other character is matched literally.
# Patterns are project-relative; a leading '/' or any '..' segment is rejected
# as "outside the repository".
#
# Usage:
#   select_tests.rb validate  --root R --map M
#   select_tests.rb plan      --root R --map M --changed-files F [--all-tests A]
#   select_tests.rb explain   --root R --map M --changed-files F [--all-tests A]
#   select_tests.rb json      --root R --map M --changed-files F --all-tests A [--run-id ID]
#   select_tests.rb coverage  --root R --map M --source-files S [--all-tests A]
#
# On any validation error the engine prints an actionable, `scripts/test:`-prefixed
# message to stderr and exits 2. Selection actions never modify anything.

require "yaml"
require "json"

PROG = "scripts/test"
MAP_KEYS  = %w[version rules always full_suite_if_changed documentation_only].freeze
RULE_KEYS = %w[id paths tests].freeze
TEST_DIR_PREFIX = "test/"

class SelectionError < StandardError; end
class InvalidGlob < StandardError; end

def die(lines)
  Array(lines).each { |l| warn "#{PROG}: #{l}" }
  exit 2
end

# --- deterministic glob -> anchored Regexp -----------------------------------
def glob_to_regex(pat)
  out = +"\\A"
  i = 0
  n = pat.length
  while i < n
    c = pat[i]
    if c == "*"
      if pat[i + 1] == "*"
        if pat[i + 2] == "/"
          # '**/' => zero or more complete leading path segments
          out << "(?:[^/]+/)*"
          i += 3
        else
          # trailing/standalone '**' => anything including '/'
          out << ".*"
          i += 2
        end
      else
        out << "[^/]*"
        i += 1
      end
    elsif c == "?"
      out << "[^/]"
      i += 1
    elsif c == "["
      j = i + 1
      j += 1 if pat[j] == "!" || pat[j] == "^"
      j += 1 if pat[j] == "]"
      j += 1 while j < n && pat[j] != "]"
      raise InvalidGlob, pat if j >= n # unterminated class
      body = pat[(i + 1)...j]
      body = body.sub(/\A[!^]/, "^")
      out << "[" << body << "]"
      i = j + 1
    else
      out << Regexp.escape(c)
      i += 1
    end
  end
  out << "\\z"
  Regexp.new(out)
end

def path_escapes_repo?(pat)
  return true if pat.nil? || pat.empty?
  return true if pat.start_with?("/")
  pat.split("/").include?("..")
end

def test_outside_test_dir?(t)
  return true unless t.start_with?(TEST_DIR_PREFIX)
  return true if t.split("/").include?("..")
  false
end

# --- mapping load + validation -----------------------------------------------
def load_map(root, map_path)
  unless File.file?(map_path)
    die(["test selection map not found: #{map_path}",
         "Fix:", "  create test/test-selection.yml"])
  end
  begin
    data = YAML.safe_load(File.read(map_path), permitted_classes: [], aliases: false)
  rescue Psych::SyntaxError, Psych::DisallowedClass => e
    die(["invalid test selection map (#{e.class}): #{e.message}", "Fix:", "  #{rel(root, map_path)}"])
  end
  unless data.is_a?(Hash)
    die(["invalid test selection map: top level must be a mapping", "Fix:", "  #{rel(root, map_path)}"])
  end

  fixline = "Fix:\n  #{rel(root, map_path)}".split("\n")

  unknown = data.keys - MAP_KEYS
  unless unknown.empty?
    die(["invalid test selection map: unknown key(s): #{unknown.join(', ')}",
         "Allowed top-level keys: #{MAP_KEYS.join(', ')}", *fixline])
  end

  unless data["version"] == 1
    die(["invalid test selection map: unknown schema version #{data['version'].inspect} (expected 1)", *fixline])
  end

  rules = data["rules"]
  unless rules.is_a?(Array) && !rules.empty?
    die(["invalid test selection map: empty mapping (at least one rule is required)", *fixline])
  end

  seen_ids = {}
  rules.each_with_index do |r, idx|
    unless r.is_a?(Hash)
      die(["invalid test selection map: rule ##{idx + 1} is not a mapping", *fixline])
    end
    unk = r.keys - RULE_KEYS
    unless unk.empty?
      die(["invalid test selection rule ##{idx + 1}: unknown key(s): #{unk.join(', ')}",
           "Allowed rule keys: #{RULE_KEYS.join(', ')}", *fixline])
    end
    id = r["id"]
    if id.nil? || !id.is_a?(String) || id.strip.empty?
      die(["invalid test selection rule ##{idx + 1}: missing or empty 'id'", *fixline])
    end
    if seen_ids[id]
      die(["invalid test selection map: duplicate rule id '#{id}'", *fixline])
    end
    seen_ids[id] = true

    paths = r["paths"]
    unless paths.is_a?(Array) && !paths.empty?
      die(["invalid test selection rule '#{id}': missing 'paths' (at least one path glob is required)", *fixline])
    end
    validate_patterns(root, map_path, id, paths)

    tests = r["tests"]
    unless tests.is_a?(Array) && !tests.empty?
      die(["invalid test selection rule '#{id}': missing 'tests' (at least one test file is required)", *fixline])
    end
    validate_tests(root, map_path, id, tests)
  end

  # always / full_suite_if_changed / documentation_only are optional.
  if data.key?("always")
    a = data["always"]
    die(["invalid test selection map: 'always' must be a list", *fixline]) unless a.is_a?(Array)
    validate_tests(root, map_path, "always", a) unless a.empty?
  end
  %w[full_suite_if_changed documentation_only].each do |k|
    next unless data.key?(k)
    v = data[k]
    die(["invalid test selection map: '#{k}' must be a list", *fixline]) unless v.is_a?(Array)
    validate_patterns(root, map_path, k, v) unless v.empty?
  end

  data
end

def validate_patterns(root, map_path, owner, patterns)
  fixline = ["Fix:", "  #{rel(root, map_path)}"]
  patterns.each do |p|
    unless p.is_a?(String) && !p.strip.empty?
      die(["invalid test selection rule '#{owner}': a path/pattern is empty or not a string", *fixline])
    end
    if path_escapes_repo?(p)
      die(["invalid test selection rule '#{owner}'",
           "Path/pattern escapes the repository (absolute path or '..' segment):",
           "  #{p}", *fixline])
    end
    begin
      glob_to_regex(p)
    rescue InvalidGlob
      die(["invalid test selection rule '#{owner}'",
           "Invalid glob syntax (unterminated '[' character class):",
           "  #{p}", *fixline])
    end
  end
end

def validate_tests(root, map_path, owner, tests)
  fixline = ["Fix:", "  #{rel(root, map_path)}"]
  tests.each do |t|
    unless t.is_a?(String) && !t.strip.empty?
      die(["invalid test selection rule '#{owner}': a test entry is empty or not a string", *fixline])
    end
    if test_outside_test_dir?(t)
      die(["invalid test selection rule '#{owner}'",
           "Referenced test is outside the allowed test directory (test/):",
           "  #{t}", *fixline])
    end
    unless File.file?(File.join(root, t))
      die(["invalid test selection rule '#{owner}'",
           "Referenced test does not exist:",
           "  #{t}", *fixline])
    end
  end
end

def rel(root, path)
  r = File.expand_path(root)
  p = File.expand_path(path)
  p.start_with?(r + "/") ? p[(r.length + 1)..] : path
end

# --- inputs ------------------------------------------------------------------
def read_lines(path)
  return [] if path.nil?
  unless File.file?(path)
    die(["cannot read input file: #{path}"])
  end
  File.readlines(path, chomp: true).map(&:strip).reject { |l| l.empty? }
end

# --- selection ---------------------------------------------------------------
Selection = Struct.new(
  :mode, :full_suite, :fallback_reason, :changed_files,
  :selected, :ignored, keyword_init: true
)

# Compile every pattern once (deterministic).
def compile_map(data)
  rules = data["rules"].map do |r|
    { id: r["id"],
      patterns: r["paths"].map { |p| [p, glob_to_regex(p)] },
      tests: r["tests"] }
  end
  full = (data["full_suite_if_changed"] || []).map { |p| [p, glob_to_regex(p)] }
  docs = (data["documentation_only"] || []).map { |p| [p, glob_to_regex(p)] }
  always = data["always"] || []
  { rules: rules, full: full, docs: docs, always: always }
end

def select(data, changed, all_tests)
  m = compile_map(data)

  full_reasons = []       # [ [file, pattern], ... ]
  unmapped = []           # files not matched by rule/doc/full -> full-suite fallback
  ignored = []            # [ {path:, reason:} ]
  # test path => { rules: Set, patterns: Set }
  sel = Hash.new { |h, k| h[k] = { rules: [], patterns: [] } }
  any_mapped = false
  any_doc = false

  changed.each do |f|
    hit_full = m[:full].find { |pat, re| re =~ f }
    if hit_full
      full_reasons << [f, hit_full[0]]
      next
    end
    matched_rules = m[:rules].select { |r| r[:patterns].any? { |_p, re| re =~ f } }
    unless matched_rules.empty?
      any_mapped = true
      matched_rules.each do |r|
        pats = r[:patterns].select { |_p, re| re =~ f }.map(&:first)
        r[:tests].each do |t|
          sel[t][:rules] |= [r[:id]]
          sel[t][:patterns] |= pats
        end
      end
      next
    end
    hit_doc = m[:docs].find { |pat, re| re =~ f }
    if hit_doc
      any_doc = true
      ignored << { path: f, reason: "documentation-only rule (#{hit_doc[0]})" }
      next
    end
    # Meaningful/unknown change with no rule: conservative full-suite fallback.
    unmapped << f
  end

  full_suite = !full_reasons.empty? || !unmapped.empty? || changed.empty?

  if full_suite
    reason =
      if !full_reasons.empty?
        f, p = full_reasons.first
        "changed file '#{f}' matches full-suite trigger '#{p}'"
      elsif !unmapped.empty?
        "changed file '#{unmapped.first}' is not covered by any rule (unmapped)"
      else
        "no changed files detected; cannot safely narrow the suite"
      end
    selected = all_tests.map { |t| { path: t, rules: ["full-suite"], patterns: [] } }
    return Selection.new(
      mode: "full-suite-fallback", full_suite: true, fallback_reason: reason,
      changed_files: changed, selected: selected, ignored: ignored
    )
  end

  # Add the always set to whatever narrow selection we have. A test that is
  # also selected by a rule keeps that rule id AND gains "always" (honest: it
  # was selected for both reasons).
  m[:always].each { |t| sel[t][:rules] |= ["always"] }

  selected = sel.keys.sort.map do |t|
    { path: t, rules: sel[t][:rules].sort, patterns: sel[t][:patterns].sort }
  end

  mode =
    if any_mapped
      "mapped"
    elsif any_doc
      "documentation-only"
    else
      "mapped"
    end

  Selection.new(
    mode: mode, full_suite: false, fallback_reason: nil,
    changed_files: changed, selected: selected, ignored: ignored
  )
end

# --- renderers ---------------------------------------------------------------
def render_plan(s)
  out = +""
  out << "mode\t#{s.mode}\n"
  out << "full_suite\t#{s.full_suite ? 1 : 0}\n"
  unless s.full_suite
    s.selected.each { |t| out << "test\t#{t[:path]}\n" }
  end
  out
end

def render_explain(s)
  out = +""
  out << "Changed files:\n"
  if s.changed_files.empty?
    out << "  (none detected)\n"
  else
    s.changed_files.each { |f| out << "  #{f}\n" }
  end

  out << "Selected tests:\n"
  if s.full_suite
    out << "  (complete standalone suite — #{s.selected.length} test files)\n"
  elsif s.selected.empty?
    out << "  (none)\n"
  else
    s.selected.each do |t|
      out << "  #{t[:path]}\n"
      if t[:rules] == ["always"]
        out << "    reason: always-run test (mapping 'always')\n"
      else
        label = t[:rules].length == 1 ? "rule #{t[:rules].first}" : "rules #{t[:rules].join(', ')}"
        out << "    reason: #{label}\n"
        out << "    matched: #{t[:patterns].join(', ')}\n" unless t[:patterns].empty?
      end
    end
  end

  out << "Ignored non-code changes:\n"
  if s.ignored.empty?
    out << "  (none)\n"
  else
    s.ignored.each do |ig|
      out << "  #{ig[:path]}\n"
      out << "    reason: #{ig[:reason]}\n"
    end
  end

  out << "Selection mode:\n  #{s.mode}\n"
  out << "Fallback:\n"
  if s.full_suite
    out << "  required\n"
    out << "Reason:\n  #{s.fallback_reason}\n"
  else
    out << "  not required\n"
  end
  out << "Full verification:\n  still required before final merge (release policy)\n"
  out
end

def render_json(s, run_id)
  doc = {
    "schema_version" => 1,
    "run_id" => run_id,
    "mode" => s.mode,
    "changed_files" => s.changed_files,
    "selected_tests" => s.selected.map { |t| { "path" => t[:path], "rules" => t[:rules] } },
    "ignored_files" => s.ignored.map { |ig| { "path" => ig[:path], "reason" => ig[:reason] } },
    "full_suite_fallback" => s.full_suite
  }
  doc["fallback_reason"] = s.fallback_reason if s.full_suite
  JSON.pretty_generate(doc) + "\n"
end

# --- coverage report (mapping drift) -----------------------------------------
def render_coverage(data, root, map_path, source_files)
  m = compile_map(data)
  rule_covered = []
  full_covered = []
  doc_covered = []
  unmatched = []
  source_files.each do |f|
    if m[:full].any? { |_p, re| re =~ f }
      full_covered << f
    elsif m[:rules].any? { |r| r[:patterns].any? { |_p, re| re =~ f } }
      rule_covered << f
    elsif m[:docs].any? { |_p, re| re =~ f }
      doc_covered << f
    else
      unmatched << f
    end
  end
  out = +""
  out << "Test selection map coverage (#{rel(root, map_path)}):\n"
  out << "  rules:                #{m[:rules].length}\n"
  out << "  always tests:         #{m[:always].length}\n"
  out << "  full-suite triggers:  #{m[:full].length}\n"
  out << "  documentation rules:  #{m[:docs].length}\n"
  out << "  source files scanned: #{source_files.length}\n"
  out << "  matched by a rule:    #{rule_covered.length}\n"
  out << "  full-suite triggers:  #{full_covered.length}\n"
  out << "  documentation-only:   #{doc_covered.length}\n"
  out << "  unmatched (→ full-suite fallback): #{unmatched.length}\n"
  unless unmatched.empty?
    out << "\nSource files not covered by any explicit rule (they safely fall back\n"
    out << "to the full suite; add a rule only when it is provably safe):\n"
    unmatched.sort.each { |f| out << "  #{f}\n" }
  end
  out << "\nNote: this checks mapping structure and coverage only; it does not\n"
  out << "prove semantic completeness of any rule.\n"
  out
end

# --- argument parsing --------------------------------------------------------
action = ARGV.shift
opts = { root: ".", map: nil, changed: nil, all: nil, sources: nil, run_id: "" }
until ARGV.empty?
  a = ARGV.shift
  case a
  when "--root"          then opts[:root] = ARGV.shift
  when "--map"           then opts[:map] = ARGV.shift
  when "--changed-files" then opts[:changed] = ARGV.shift
  when "--all-tests"     then opts[:all] = ARGV.shift
  when "--source-files"  then opts[:sources] = ARGV.shift
  when "--run-id"        then opts[:run_id] = ARGV.shift.to_s
  else die(["internal: unknown engine argument: #{a}"])
  end
end

die(["internal: no action given"]) if action.nil?
die(["internal: --map is required"]) if opts[:map].nil?

root = opts[:root]
map_path = opts[:map]
data = load_map(root, map_path)

case action
when "validate"
  # load_map already validated everything; success is silent.
  exit 0
when "coverage"
  sources = read_lines(opts[:sources])
  print render_coverage(data, root, map_path, sources)
  exit 0
when "plan", "explain", "json"
  changed = read_lines(opts[:changed])
  all_tests = read_lines(opts[:all])
  s = select(data, changed, all_tests)
  case action
  when "plan"    then print render_plan(s)
  when "explain" then print render_explain(s)
  when "json"    then print render_json(s, opts[:run_id])
  end
  exit 0
else
  die(["internal: unknown action: #{action}"])
end
