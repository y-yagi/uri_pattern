# frozen_string_literal: true

require "test_helper"

class TestTokenizer < Test::Unit::TestCase
  def tokenize(pattern, policy: :lenient)
    URIPattern::Tokenizer.new(pattern, policy: policy).tokenize
  end

  def types(tokens)
    tokens.map(&:type)
  end

  def values(tokens)
    tokens.map(&:value)
  end

  def test_empty_string
    tokens = tokenize("")
    assert_equal [:end], types(tokens)
  end

  def test_plain_chars
    tokens = tokenize("abc")
    assert_equal [:char, :char, :char, :end], types(tokens)
    assert_equal %w[a b c], values(tokens.first(3))
  end

  def test_asterisk
    tokens = tokenize("*")
    assert_equal [:asterisk, :end], types(tokens)
  end

  def test_open_close
    tokens = tokenize("{}")
    assert_equal [:open, :close, :end], types(tokens)
  end

  def test_regexp_group_is_one_token
    # A "(...)" group is lexed atomically into a single :regexp token whose value
    # is the raw inner source (the spec's REGEX token).
    tokens = tokenize("(abc)")
    assert_equal [:regexp, :end], types(tokens)
    assert_equal "abc", tokens[0].value
  end

  def test_name_token
    tokens = tokenize(":id")
    assert_equal [:name, :end], types(tokens)
    assert_equal "id", tokens[0].value
  end

  def test_name_token_with_suffix
    tokens = tokenize(":id/rest")
    assert_equal [:name, :char, :char, :char, :char, :char, :end], types(tokens)
    assert_equal "id", tokens[0].value
  end

  def test_colon_without_identifier
    # ":" not followed by a valid name is "missing parameter name": lenient
    # tokenizing emits an :invalid_char (so the ":" is still seen by the
    # constructor string parser), strict tokenizing raises.
    tokens = tokenize("a:1b")
    assert_equal [:char, :invalid_char, :char, :char, :end], types(tokens)
    assert_equal ":", tokens[1].value
    assert_raise(URIPattern::Error) { tokenize("a:1b", policy: :strict) }
  end

  def test_colon_inside_regexp_group_is_literal
    # Inside a "(...)" regexp group ":" is regexp text, not a name delimiter; the
    # whole group is one :regexp token carrying the raw source verbatim.
    tokens = tokenize("(a:b)", policy: :strict)
    assert_equal %i[regexp end], types(tokens)
    assert_equal "a:b", tokens[0].value
  end

  def test_regexp_group_spec_rejections
    # Empty group, a top-level "(?...)", and a nested *capturing* group are all
    # spec errors in strict mode (lenient emits an :invalid_char for the "(").
    assert_raise(URIPattern::Error) { tokenize("()", policy: :strict) }
    assert_raise(URIPattern::Error) { tokenize("(?:x)", policy: :strict) }
    assert_raise(URIPattern::Error) { tokenize("(a(b))", policy: :strict) }
    assert_raise(URIPattern::Error) { tokenize("(abc", policy: :strict) }
    assert_equal :invalid_char, tokenize("()")[0].type

    # A nested *non-capturing* group is allowed.
    tokens = tokenize("(a(?:b))", policy: :strict)
    assert_equal %i[regexp end], types(tokens)
    assert_equal "a(?:b)", tokens[0].value
  end

  def test_lone_close_paren_is_literal
    # A ")" with no matching "(" is a literal character.
    tokens = tokenize("x)", policy: :strict)
    assert_equal %i[char char end], types(tokens)
    assert_equal ["x", ")", ""], values(tokens)
  end

  def test_escaped_char
    tokens = tokenize("\\*")
    assert_equal [:escaped_char, :end], types(tokens)
    assert_equal "*", tokens[0].value
  end

  def test_escaped_char_backslash
    tokens = tokenize("\\\\")
    assert_equal [:escaped_char, :end], types(tokens)
    assert_equal "\\", tokens[0].value
  end

  def test_modifier_after_close
    tokens = tokenize("{}?")
    assert_equal [:open, :close, :other_modifier, :end], types(tokens)
    assert_equal "?", tokens[2].value
  end

  def test_modifier_after_name
    tokens = tokenize(":id?")
    assert_equal [:name, :other_modifier, :end], types(tokens)
  end

  def test_modifier_question_after_asterisk
    tokens = tokenize("*?")
    assert_equal [:asterisk, :other_modifier, :end], types(tokens)
  end

  def test_star_as_modifier_after_name
    tokens = tokenize(":id*")
    assert_equal [:name, :other_modifier, :end], types(tokens)
    assert_equal "*", tokens[1].value
  end

  def test_star_as_modifier_after_close
    tokens = tokenize("{}*")
    assert_equal [:open, :close, :other_modifier, :end], types(tokens)
  end

  def test_modifier_after_regexp_close
    tokens = tokenize("(abc)?")
    assert_equal [:regexp, :other_modifier, :end], types(tokens)
    assert_equal "abc", tokens[0].value
  end

  def test_plus_as_modifier_after_close
    tokens = tokenize("{}+")
    assert_equal [:open, :close, :other_modifier, :end], types(tokens)
    assert_equal "+", tokens[2].value
  end

  def test_question_mark_as_modifier
    tokens = tokenize("a?b")
    assert_equal [:char, :other_modifier, :char, :end], types(tokens)
  end

  def test_plus_as_modifier
    tokens = tokenize("a+b")
    assert_equal [:char, :other_modifier, :char, :end], types(tokens)
  end

  def test_lenient_trailing_backslash
    tokens = tokenize("\\", policy: :lenient)
    assert types(tokens).include?(:invalid_char)
  end

  def test_strict_trailing_backslash
    assert_raises(URIPattern::Error) do
      tokenize("\\", policy: :strict)
    end
  end

  def test_nested_groups
    tokens = tokenize("{:name}")
    assert_equal [:open, :name, :close, :end], types(tokens)
    assert_equal "name", tokens[1].value
  end

  def test_complex_pattern
    tokens = tokenize("/users/:id/posts")
    # /users/ (7 chars) + :id (name) + /posts (6 chars) + end
    expected_types = [:char, :char, :char, :char, :char, :char, :char, :name, :char, :char, :char, :char, :char, :char, :end]
    assert_equal expected_types, types(tokens)
  end
end
