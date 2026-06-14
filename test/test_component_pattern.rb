# frozen_string_literal: true

require "test_helper"

class TestComponentPattern < Test::Unit::TestCase
  def test_basic_match
    cp = URIPattern::ComponentPattern.new("/users/:id", component: :pathname)
    assert cp.match("/users/42")
  end

  def test_no_match
    cp = URIPattern::ComponentPattern.new("/users/:id", component: :pathname)
    assert_nil cp.match("/posts/42")
  end

  def test_named_group_extraction
    cp = URIPattern::ComponentPattern.new("/users/:id", component: :pathname)
    md = cp.match("/users/42")
    assert_equal "42", md["id"]
  end

  def test_pattern_reader
    cp = URIPattern::ComponentPattern.new("/users/:id", component: :pathname)
    assert_equal "/users/:id", cp.pattern
  end

  def test_wildcard_match
    cp = URIPattern::ComponentPattern.new("*", component: :pathname)
    assert cp.match("/anything/here")
  end

  def test_wildcard_group_name
    cp = URIPattern::ComponentPattern.new("*", component: :pathname)
    groups = cp.groups_for("/anything")
    assert groups.key?("0")
  end

  def test_ignore_case
    cp = URIPattern::ComponentPattern.new("/Users/:id", component: :pathname, ignore_case: true)
    assert cp.match("/users/42")
  end

  def test_empty_pattern_matches_empty
    cp = URIPattern::ComponentPattern.new("*", component: :protocol)
    assert cp.match("")
  end
end
