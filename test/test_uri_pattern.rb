# frozen_string_literal: true

require "test_helper"

class TestURIPattern < Test::Unit::TestCase
  def test_that_it_has_a_version_number
    refute_nil ::URIPattern::VERSION
  end

  # US1: Pattern Matching
  def test_basic_pathname_match
    p = URIPattern.new("https://example.com/users/:id")
    assert p.match?("https://example.com/users/42")
  end

  def test_basic_pathname_no_match
    p = URIPattern.new("https://example.com/users/:id")
    refute p.match?("https://example.com/posts/42")
  end

  def test_wildcard_match
    p = URIPattern.new({ pathname: "/files/*" })
    assert p.match?("https://example.com/files/images/photo.jpg")
  end

  def test_default_wildcard_components
    p = URIPattern.new("https://example.com/users/:id")
    assert p.match?("https://example.com/users/42")
    refute p.match?("https://other.com/users/42")
  end

  def test_base_url_resolution
    p = URIPattern.new("/users/:id", "https://example.com")
    assert p.match?("https://example.com/users/42")
  end

  # US2: Named Parameter Extraction
  def test_match_returns_match_result
    p = URIPattern.new("https://example.com/users/:id")
    result = p.match("https://example.com/users/42")
    assert_instance_of URIPattern::MatchResult, result
  end

  def test_match_returns_nil_on_no_match
    p = URIPattern.new({ pathname: "/users/:id" })
    assert_nil p.match("https://example.com/products/42")
  end

  def test_match_single_named_param
    p = URIPattern.new("https://example.com/users/:id")
    result = p.match("https://example.com/users/42")
    assert_equal "42", result.pathname.groups["id"]
  end

  def test_match_multi_named_params
    p = URIPattern.new("https://example.com/users/:userId/posts/:postId")
    result = p.match("https://example.com/users/7/posts/99")
    assert_equal "7",  result.pathname.groups["userId"]
    assert_equal "99", result.pathname.groups["postId"]
  end

  def test_match_hostname_named_param
    p = URIPattern.new({ hostname: ":subdomain.example.com" })
    result = p.match("https://api.example.com/path")
    refute_nil result
    assert_equal "api", result.hostname.groups["subdomain"]
  end

  def test_match_wildcard_auto_group
    p = URIPattern.new({ pathname: "/files/*" })
    result = p.match("https://example.com/files/images/photo.jpg")
    refute_nil result
    refute result.pathname.groups.empty?
  end

  # US3: Hash-form constructor
  def test_hash_form_hostname_and_pathname
    p = URIPattern.new({ hostname: "example.com", pathname: "/docs/*" })
    assert p.match?("https://example.com/docs/intro")
    refute p.match?("https://other.com/docs/intro")
  end

  def test_hash_form_pathname_only
    p = URIPattern.new({ pathname: "/users/:id" })
    assert p.match?("https://example.com/users/42")
    assert p.match?("https://other.com/users/42")
  end

  def test_hash_form_default_wildcard_components
    p = URIPattern.new({ pathname: "/users/:id" })
    assert_equal "*", p.protocol
    assert_equal "*", p.query
  end

  def test_ignore_case_option
    p = URIPattern.new("/Users/:id", "https://example.com", ignore_case: true)
    assert p.match?("https://example.com/users/42")
    assert p.match?("https://example.com/USERS/42")
  end

  def test_hash_form_base_url_conflict_raises
    assert_raises(URIPattern::Error) do
      URIPattern.new({ pathname: "/path", base_url: "https://example.com" }, "https://other.com")
    end
  end

  # Component reader methods
  def test_component_readers_string_form
    p = URIPattern.new("https://*.example.com/users/:id")
    assert_equal "https",         p.protocol
    assert_equal "*.example.com", p.hostname
    assert_equal "/users/:id",    p.pathname
  end

  def test_component_readers_hash_form
    p = URIPattern.new({ hostname: "example.com", pathname: "/users/:id" })
    assert_equal "example.com", p.hostname
    assert_equal "/users/:id",  p.pathname
    assert_equal "*",           p.protocol
  end

  # Error handling
  def test_invalid_pattern_raises_error
    assert_raises(URIPattern::Error) do
      URIPattern.new("https://example.com/{unclosed")
    end
  end
end
