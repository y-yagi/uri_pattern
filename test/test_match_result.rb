# frozen_string_literal: true

require "test_helper"

class TestMatchResult < Test::Unit::TestCase
  def make_component_result(input, groups = {})
    URIPattern::ComponentResult.new(input: input, groups: groups)
  end

  def make_match_result(inputs: ["https://example.com/users/42"], groups: {})
    URIPattern::MatchResult.new(
      inputs:   inputs,
      protocol: make_component_result("https"),
      username: make_component_result(""),
      password: make_component_result(""),
      hostname: make_component_result("example.com"),
      port:     make_component_result(""),
      pathname: make_component_result("/users/42", groups),
      query:    make_component_result(""),
      fragment: make_component_result("")
    )
  end

  def test_component_result_input
    cr = make_component_result("/users/42")
    assert_equal "/users/42", cr.input
  end

  def test_component_result_groups
    cr = make_component_result("/users/42", "id" => "42")
    assert_equal({ "id" => "42" }, cr.groups)
  end

  def test_component_result_nil_group_value
    cr = make_component_result("/path", "optional" => nil)
    assert_nil cr.groups["optional"]
  end

  def test_match_result_inputs
    mr = make_match_result
    assert_equal ["https://example.com/users/42"], mr.inputs
  end

  def test_match_inputs_string_only
    mr = URIPattern.new("https://example.com/users/:id").match("https://example.com/users/42")
    assert_equal ["https://example.com/users/42"], mr.inputs
  end

  def test_match_inputs_with_base_url
    mr = URIPattern.new("/users/:id", "https://example.com").match("/users/42", "https://example.com")
    assert_equal ["/users/42", "https://example.com"], mr.inputs
  end

  def test_match_inputs_hash_kept_as_is
    input = { pathname: "/users/42" }
    mr = URIPattern.new({ pathname: "/users/:id" }).match(input)
    assert_equal [input], mr.inputs
  end

  def test_match_result_all_readers
    mr = make_match_result
    assert_equal "https",       mr.protocol.input
    assert_equal "",            mr.username.input
    assert_equal "",            mr.password.input
    assert_equal "example.com", mr.hostname.input
    assert_equal "",            mr.port.input
    assert_equal "/users/42",   mr.pathname.input
    assert_equal "",            mr.query.input
    assert_equal "",            mr.fragment.input
  end

  def test_match_result_groups_content
    mr = make_match_result(groups: { "id" => "42" })
    assert_equal "42", mr.pathname.groups["id"]
  end
end
