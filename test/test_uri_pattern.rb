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

  def test_no_arg_constructor_is_all_wildcards
    # No-arg construction is equivalent to passing an empty hash: every component
    # defaults to "*" and the pattern matches any URL.
    p = URIPattern.new
    assert_equal "*", p.protocol
    assert_equal "*", p.hostname
    assert_equal "*", p.pathname
    assert p.match?("https://example.com/foo")
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

  # Relative pathname in a dictionary match input is resolved against the base_url
  # using WHATWG relative-URL resolution (replace the base's last segment), the
  # same result node's URLPattern produces.
  def test_hash_match_input_relative_pathname_resolution
    p = URIPattern.new({ pathname: "/foo/:name" })
    result = p.match({ pathname: "baz", base_url: "https://example.com/foo/bar" })
    refute_nil result
    assert_equal "baz", result.pathname.groups["name"]
  end

  def test_hash_match_input_relative_pathname_dot_segments
    p = URIPattern.new({ pathname: "/:name" })
    result = p.match({ pathname: "../baz", base_url: "https://example.com/foo/bar" })
    refute_nil result
    assert_equal "baz", result.pathname.groups["name"]
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

  # A dictionary member is a USVString, so a non-string value is coerced with JS
  # String() before parsing. For an array that is Array.prototype.join(","), which
  # then flows through normal validation just like the browser.
  def test_hash_array_value_coerced_like_js_string
    # {pathname: ["/foo"]} -> "/foo"; {pathname: ["/foo","/bar"]} -> "/foo,/bar"
    assert_equal "/foo",     URIPattern.new({ pathname: ["/foo"] }).pathname
    assert_equal "/foo,/bar", URIPattern.new({ pathname: ["/foo", "/bar"] }).pathname
  end

  def test_hash_array_value_invalid_after_join_raises
    # ["http","https"] joins to "http,https", an invalid protocol, so this raises
    # exactly as the browser does for {protocol: ["http","https"]}.
    assert_raises(URIPattern::Error) do
      URIPattern.new({ protocol: ["http", "https"] })
    end
  end

  # hasRegExpGroups
  def test_has_regexp_groups_true_with_named_regexp_group
    p = URIPattern.new("https://example.com/users/:id(\\d+)")
    assert p.has_regexp_groups?
  end

  def test_has_regexp_groups_true_with_anonymous_regexp_group
    p = URIPattern.new({ pathname: "/(\\d+)" })
    assert p.has_regexp_groups?
  end

  def test_has_regexp_groups_true_in_non_pathname_component
    p = URIPattern.new({ hostname: "(sub.)?example.com" })
    assert p.has_regexp_groups?
  end

  def test_has_regexp_groups_false_for_named_and_wildcard_groups
    # ":id" is a segment wildcard and "*" is a full wildcard; neither is a regexp group.
    p = URIPattern.new("https://*.example.com/users/:id")
    refute p.has_regexp_groups?
  end

  def test_has_regexp_groups_false_for_all_wildcards
    refute URIPattern.new.has_regexp_groups?
  end

  # Error handling
  def test_invalid_pattern_raises_error
    assert_raises(URIPattern::Error) do
      URIPattern.new("https://example.com/{unclosed")
    end
  end
end
