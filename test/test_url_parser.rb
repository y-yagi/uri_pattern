# frozen_string_literal: true

require "test_helper"

class TestURLParser < Test::Unit::TestCase
  def split(url)
    URIPattern::URLParser.split_components(url)
  end

  def test_full_url_all_components
    result = split("https://user:pass@example.com:8080/path?q=1#frag")
    assert_equal "https", result[:protocol]
    assert_equal "user",  result[:username]
    assert_equal "pass",  result[:password]
    assert_equal "example.com", result[:hostname]
    assert_equal "8080",  result[:port]
    assert_equal "/path", result[:pathname]
    assert_equal "q=1",   result[:query]
    assert_equal "frag",  result[:fragment]
  end

  def test_no_port_returns_empty
    result = split("https://example.com/path")
    assert_equal "", result[:port]
  end

  def test_no_fragment_returns_empty
    result = split("https://example.com/path")
    assert_equal "", result[:fragment]
  end

  def test_no_query_returns_empty
    result = split("https://example.com/path")
    assert_equal "", result[:query]
  end

  def test_relative_url_resolution
    result = URIPattern::URLParser.split_components("/users/42", base_url: "https://example.com")
    assert_equal "example.com", result[:hostname]
    assert_equal "/users/42",   result[:pathname]
  end

  def test_pathname_only
    result = split("https://example.com/users/42")
    assert_equal "/users/42", result[:pathname]
  end

  def test_split_pattern_protocol
    result = URIPattern::URLParser.split_pattern("https://example.com/path")
    assert_equal "https", result[:protocol]
    assert_equal "example.com", result[:hostname]
    assert_equal "/path", result[:pathname]
  end

  def test_split_pattern_with_query_and_fragment
    result = URIPattern::URLParser.split_pattern("https://example.com/path?q=1#frag")
    assert_equal "q=1",  result[:query]
    assert_equal "frag", result[:fragment]
    assert_equal "/path", result[:pathname]
  end

  def test_split_pattern_relative
    result = URIPattern::URLParser.split_pattern("/users/:id")
    assert_nil result[:protocol]
    assert_equal "/users/:id", result[:pathname]
  end
end
