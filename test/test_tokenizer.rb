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

  def test_regexp_open_close
    tokens = tokenize("(abc)")
    assert_equal [:regexp_open, :char, :char, :char, :regexp_close, :end], types(tokens)
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
    tokens = tokenize("a:1b")
    assert_equal [:char, :char, :char, :char, :end], types(tokens)
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
    assert_equal [:regexp_open, :char, :char, :char, :regexp_close, :other_modifier, :end], types(tokens)
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
