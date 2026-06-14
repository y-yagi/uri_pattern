# frozen_string_literal: true

require "test_helper"

# Component getters expose the WHATWG "component pattern string": the parsed parts
# re-serialised with canonicalization applied, not the raw constructor input.
class TestPatternString < Test::Unit::TestCase
  def pattern(str, base = nil)
    URIPattern.new(str, base)
  end

  def test_wildcard_regexp_normalized_to_asterisk
    assert_equal "/foo/*", pattern("https://e.com/foo/(.*)").pathname
    assert_equal "*",      pattern("(.*)://e.com/").protocol
  end

  def test_wildcard_with_modifier
    assert_equal "/foo/*?", pattern("https://e.com/foo/(.*)?").pathname
    assert_equal "/foo/*+", pattern("https://e.com/foo/(.*)+").pathname
  end

  def test_redundant_fixed_group_unwrapped
    assert_equal "/foo/bar", pattern("https://e.com/foo{/bar}").pathname
  end

  def test_name_followed_by_text_is_grouped
    assert_equal "{:foo}bar", pattern("https://e.com/{:foo}bar").pathname.sub(%r{\A/}, "")
  end

  def test_hostname_is_punycoded
    assert_equal "xn--caf-dma.com", pattern("https://café.com/").hostname
  end

  def test_hostname_truncated_at_delimiters
    assert_equal "example.com", URIPattern.new({ hostname: "example.com/ignored" }).hostname
    assert_equal "example.com", URIPattern.new({ hostname: "example.com#ignored" }).hostname
  end

  def test_fixed_text_percent_encoded
    assert_equal "/caf%C3%A9", pattern("https://e.com/café").pathname
    assert_equal "q=caf%C3%A9", URIPattern.new({ query: "q=café" }).query
  end

  def test_port_canonicalized
    assert_equal "80", URIPattern.new({ protocol: "http", port: "80 " }).port
    assert_equal "80", URIPattern.new({ protocol: "http", port: "0080" }).port
  end

  def test_unspecified_components_are_wildcards
    p = URIPattern.new({ pathname: "/foo/bar", base_url: "https://example.com?query#hash" })
    assert_equal "*", p.username
    assert_equal "*", p.password
    assert_equal "*", p.query
    assert_equal "*", p.fragment
    assert_equal "https",       p.protocol
    assert_equal "example.com", p.hostname
  end

  def test_absolute_pattern_pathname_not_resolved_against_base
    assert_equal "/bar", URIPattern.new({ pathname: "{/bar}", base_url: "https://example.com/foo/" }).pathname
    assert_equal "/bar", URIPattern.new({ pathname: "\\/bar", base_url: "https://example.com/foo/" }).pathname
  end
end
