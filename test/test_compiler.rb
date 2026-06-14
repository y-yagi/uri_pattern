# frozen_string_literal: true

require "test_helper"

class TestCompiler < Test::Unit::TestCase
  def compile(pattern, component: :pathname, ignore_case: false)
    tokens = URIPattern::Tokenizer.new(pattern, policy: :lenient).tokenize
    URIPattern::Compiler.new(tokens, component: component, ignore_case: ignore_case).compile
  end

  def test_plain_string_pathname
    result = compile("/users")
    assert_match result[:regexp], "/users"
    refute_match result[:regexp], "/users/extra"
  end

  def test_named_capture_pathname
    result = compile("/users/:id")
    md = result[:regexp].match("/users/42")
    assert_equal "42", md["id"]
  end

  def test_wildcard_auto_name
    result = compile("*")
    md = result[:regexp].match("anything/here")
    assert_equal "0", result[:names].first
    internal = result[:wildcard_name_map].key("0")
    assert_equal "anything/here", md[internal]
  end

  def test_multiple_named_captures
    result = compile("/users/:userId/posts/:postId")
    md = result[:regexp].match("/users/7/posts/99")
    assert_equal "7", md["userId"]
    assert_equal "99", md["postId"]
  end

  def test_optional_group
    result = compile("/api{/v:version}?/users")
    assert_match result[:regexp], "/api/v1/users"
    assert_match result[:regexp], "/api/users"
  end

  def test_one_or_more_modifier
    result = compile("/{:segment}+")
    assert_match result[:regexp], "/foo"
    assert_match result[:regexp], "/foo/bar"
    refute_match result[:regexp], "/"
  end

  def test_zero_or_more_modifier
    result = compile("/{:segment}*")
    assert_match result[:regexp], "/foo"
    assert_match result[:regexp], "/foo/bar"
  end

  def test_pathname_segment_regexp
    result = compile("/:segment")
    refute_match result[:regexp], "/foo/bar"
    assert_match result[:regexp], "/foo"
  end

  def test_hostname_segment_regexp
    result = compile(":subdomain.example.com", component: :hostname)
    assert_match result[:regexp], "api.example.com"
    refute_match result[:regexp], "api.v2.example.com"
  end

  def test_other_component_segment_regexp
    result = compile(":value", component: :query)
    md = result[:regexp].match("something")
    assert_equal "something", md["value"]
  end

  def test_ignore_case_false
    result = compile("/Users/:id", ignore_case: false)
    refute_match result[:regexp], "/users/42"
    assert_match result[:regexp], "/Users/42"
  end

  def test_ignore_case_true
    result = compile("/Users/:id", ignore_case: true)
    assert_match result[:regexp], "/users/42"
    assert_match result[:regexp], "/USERS/42"
  end

  def test_escaped_char
    result = compile("/users\\*")
    assert_match result[:regexp], "/users*"
    refute_match result[:regexp], "/usersXXX"
  end

  def test_regexp_group
    result = compile("/:id(\\d+)")
    assert_match result[:regexp], "/42"
    refute_match result[:regexp], "/abc"
  end

  def test_wildcard_pathname
    result = compile("/files/*")
    assert_match result[:regexp], "/files/photo.jpg"
    assert_match result[:regexp], "/files/images/photo.jpg"
    internal = result[:wildcard_name_map].key("0")
    md = result[:regexp].match("/files/photo.jpg")
    assert_equal "photo.jpg", md[internal]
  end

  def test_anchoring
    result = compile("/users")
    refute_match result[:regexp], "prefix/users"
    refute_match result[:regexp], "/users/suffix"
  end
end
