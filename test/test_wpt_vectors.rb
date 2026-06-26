# frozen_string_literal: true

require "test_helper"
require "json"

class TestWptVectors < Test::Unit::TestCase
  FIXTURE = File.join(__dir__, "fixtures", "urlpatterntestdata.json")

  WPT_KEY_MAP = {
    "search"  => "query",
    "hash"    => "fragment",
    "baseURL" => "base_url"
  }.freeze

  # A valid high+low surrogate pair (U+D800..U+DBFF followed by U+DC00..U+DFFF)
  # is a real code point that JSON.parse decodes correctly, so keep it intact.
  # Only *lone* surrogates (which cannot exist in a Ruby UTF-8 string) are
  # replaced with U+FFFD, matching how a JS engine would coerce them.
  HI_SURROGATE = /\\u[Dd][89ABab][0-9A-Fa-f]{2}/.source
  LO_SURROGATE = /\\u[Dd][CDEFcdef][0-9A-Fa-f]{2}/.source

  def self.load_data
    raw = File.read(FIXTURE)
    clean = raw.gsub(/#{HI_SURROGATE}#{LO_SURROGATE}|#{HI_SURROGATE}|#{LO_SURROGATE}/) do |m|
      m.match?(/\A#{HI_SURROGATE}#{LO_SURROGATE}\z/) ? m : "\\uFFFD"
    end
    JSON.parse(clean)
  end

  DATA = load_data

  # WPT entries that cannot be faithfully run in Ruby, mapped to the reason they
  # are skipped rather than asserted.
  SKIP = {}.freeze

  def self.build_tests
    DATA.each_with_index do |entry, idx|
      pattern_args = entry["pattern"]
      inputs = entry["inputs"]
      expected = entry["expected_match"]
      expected_obj = entry["expected_obj"]
      exactly_empty = entry["exactly_empty_components"] || []
      # Absent when the entry does not assert hasRegExpGroups; the :absent sentinel
      # distinguishes that from an explicit `false`.
      has_regexp_groups = entry.fetch("hasRegExpGroups", :absent)

      form = pattern_args.empty? || pattern_args[0].is_a?(Hash) ? "hash" : "str"
      define_method("test_wpt_#{idx}_#{form}") do
        omit("WPT ##{idx}: #{SKIP[idx]}") if SKIP.key?(idx)
        run_wpt_entry(pattern_args, inputs, expected, expected_obj, exactly_empty,
                      has_regexp_groups, idx)
      end
    end
  end

  def run_wpt_entry(pattern_args, inputs, expected, expected_obj, exactly_empty,
                    has_regexp_groups, idx)
    ctx = wpt_context(idx, pattern_args, inputs, expected)
    pattern_input = build_pattern_input(pattern_args[0])
    # Trailing args are [base_url?, options?]: a base_url string precedes an options
    # hash. A hash appearing before a string is the wrong argument order, which the
    # spec treats as a construction error.
    base_url_arg = nil
    ignore_case = false
    seen_options = false
    bad_arg_order = false
    (pattern_args[1..] || []).each do |arg|
      if arg.is_a?(Hash)
        seen_options = true
        ignore_case = arg["ignoreCase"] || arg[:ignoreCase] || false
      elsif arg.is_a?(String)
        bad_arg_order = true if seen_options
        base_url_arg = arg
      end
    end

    construct = lambda do
      raise URIPattern::Error, "invalid argument order (options before base_url)" if bad_arg_order
      URIPattern.new(pattern_input, base_url_arg, ignore_case: ignore_case)
    end

    # null inputs, or expected_obj == "error", => construction must raise
    if inputs.nil? || expected_obj == "error"
      assert_raises(URIPattern::Error, "expected construction to raise\n#{ctx}") { construct.call }
      return
    end

    uri_pattern = begin
      construct.call
    rescue URIPattern::Error => e
      flunk "Unexpected URIPattern::Error on construction: #{e.message}\n#{ctx}"
      return
    end

    # When expected_obj lists component pattern strings, each component getter must
    # return that canonicalized pattern string (spec "component pattern string").
    verify_expected_obj(uri_pattern, expected_obj, ctx) if expected_obj.is_a?(Hash)

    # exactly_empty_components lists components whose pattern getter must be exactly
    # the empty string (e.g. a default port suppressed to "").
    verify_exactly_empty_components(uri_pattern, exactly_empty, ctx)

    # hasRegExpGroups, when asserted, must match across the whole pattern.
    unless has_regexp_groups == :absent
      assert_equal has_regexp_groups, uri_pattern.has_regexp_groups?,
                   "hasRegExpGroups mismatch\n#{ctx}"
    end

    # Empty inputs list => no matching test, just verify construction succeeded
    if inputs.empty?
      assert_instance_of URIPattern, uri_pattern
      return
    end

    match_input  = build_match_input(inputs[0])
    match_base   = inputs[1]  # second element is base_url for match, if any

    # expected "error" => match call must raise
    if expected == "error"
      assert_raises(URIPattern::Error, "expected match() to raise\n#{ctx}") do
        uri_pattern.match(match_input, match_base)
      end
      return
    end

    if expected.nil?
      refute uri_pattern.match?(match_input, match_base),
             "expected no match, but got a match\n#{ctx}"
    else
      result = uri_pattern.match(match_input, match_base)
      refute_nil result, "expected a match, but got nil\n#{ctx}"
      verify_match_result(result, expected, ctx)
    end
  end

  # Human-readable dump of a WPT entry, appended to every assertion message so a
  # failure shows the pattern, inputs and expected result without grepping the
  # fixture by index.
  def wpt_context(idx, pattern_args, inputs, expected)
    [
      "  WPT entry: ##{idx}",
      "  pattern:   #{pattern_args.inspect}",
      "  inputs:    #{inputs.inspect}",
      "  expected:  #{expected.inspect}"
    ].join("\n")
  end

  def build_pattern_input(raw)
    return {} if raw.nil?
    return raw if raw.is_a?(String)
    remap_keys(raw)
  end

  def build_match_input(raw)
    return raw if raw.is_a?(String) || raw.nil?
    hash = remap_keys(raw)
    hash.transform_keys(&:to_sym)
  end

  def remap_keys(hash)
    hash.transform_keys { |k| WPT_KEY_MAP.fetch(k, k) }
  end

  # Resolve a WPT component name to its component getter symbol. expected_obj should
  # only ever name per-component getters; anything else is a typo or a newly-added
  # WPT field, so fail loudly rather than silently skip it (which could hide a
  # coverage gap). "hasRegExpGroups" is a top-level entry key asserted as a
  # whole-pattern property in run_wpt_entry, not here.
  def component_reader(wpt_component, ctx)
    reader = WPT_KEY_MAP.fetch(wpt_component, wpt_component).to_sym
    return reader if URIPattern::COMPONENT_KEYS.include?(reader)

    flunk "unrecognised WPT key #{wpt_component.inspect} in expected_obj " \
          "(typo or new field?)\n#{ctx}"
  end

  # expected_obj maps WPT component names to the canonicalized pattern string the
  # corresponding getter must return.
  def verify_expected_obj(uri_pattern, expected_obj, ctx)
    expected_obj.each do |wpt_component, exp_pattern|
      reader = component_reader(wpt_component, ctx)

      assert_equal exp_pattern, uri_pattern.public_send(reader),
                   "#{wpt_component} pattern string mismatch\n#{ctx}"
    end
  end

  # Each component named in exactly_empty_components must have a pattern getter that
  # returns exactly the empty string.
  def verify_exactly_empty_components(uri_pattern, exactly_empty, ctx)
    exactly_empty.each do |wpt_component|
      reader = component_reader(wpt_component, ctx) or next

      assert_equal "", uri_pattern.public_send(reader),
                   "#{wpt_component} expected to be exactly empty\n#{ctx}"
    end
  end

  def verify_match_result(result, expected, ctx = nil)
    expected.each do |wpt_component, exp_val|
      reader = component_reader(wpt_component, ctx) or next

      comp = result.public_send(reader)
      assert_equal exp_val["input"], comp.input, "#{wpt_component}.input mismatch\n#{ctx}"
      exp_groups = exp_val["groups"] || {}
      assert_equal exp_groups, comp.groups,      "#{wpt_component}.groups mismatch\n#{ctx}"
    end

    # A named capture only ever appears in the component whose pattern declared it,
    # so any component the expectation does not mention must carry no named groups.
    # (Default/wildcard components legitimately expose auto-named numeric groups
    # such as "0", which are allowed.) This catches a named capture leaking into an
    # unasserted component, which the per-component checks above would otherwise miss.
    verified = expected.keys.map { |k| WPT_KEY_MAP.fetch(k, k).to_sym }
    (URIPattern::COMPONENT_KEYS - verified).each do |reader|
      leaked = result.public_send(reader).groups.keys.reject { |k| k.match?(/\A\d+\z/) }
      assert_empty leaked, "#{reader} carried unexpected named groups\n#{ctx}"
    end
  end

  build_tests
end
