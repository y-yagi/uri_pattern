# frozen_string_literal: true

class URIPattern
  class Tokenizer
    Token = Struct.new(:type, :value, :index, keyword_init: true)

    IDENTIFIER_RE = /\A[a-zA-Z_\u{80}-\u{10FFFF}][a-zA-Z0-9_\u{80}-\u{10FFFF}]*/u

    def initialize(pattern, policy: :lenient)
      @pattern = pattern
      @policy = policy
      @index = 0
      @tokens = []
    end

    def tokenize
      while @index < @pattern.length
        ch = @pattern[@index]

        case ch
        when "\\"
          if @index + 1 < @pattern.length
            emit(:escaped_char, @pattern[@index + 1])
            @index += 2
          else
            handle_invalid("trailing backslash")
          end
        when "{"
          emit(:open, ch)
          @index += 1
        when "}"
          emit(:close, ch)
          @index += 1
        when "("
          emit(:regexp_open, ch)
          @index += 1
        when ")"
          emit(:regexp_close, ch)
          @index += 1
        when "*"
          prev = @tokens.last
          if prev && %i[close regexp_close name asterisk].include?(prev.type)
            emit(:other_modifier, ch)
          else
            emit(:asterisk, ch)
          end
          @index += 1
        when "?", "+"
          # "?"/"+" are always modifier tokens. A modifier that does not follow a
          # group/name/regexp/wildcard is a dangling modifier; the compiler rejects
          # it. (A literal "?"/"+" must be escaped, e.g. "\\?".)
          emit(:other_modifier, ch)
          @index += 1
        when ":"
          rest = @pattern[(@index + 1)..]
          if (m = IDENTIFIER_RE.match(rest))
            emit(:name, m[0])
            @index += 1 + m[0].length
          else
            # ":" not followed by a valid name is a literal colon.
            emit(:char, ch)
            @index += 1
          end
        else
          emit(:char, ch)
          @index += 1
        end
      end
      emit(:end, "")
      @tokens
    end

    private

    def emit(type, value)
      @tokens << Token.new(type: type, value: value, index: @index)
    end

    def handle_invalid(reason)
      if @policy == :strict
        raise URIPattern::Error, "Invalid pattern at index #{@index}: #{reason}"
      else
        emit(:invalid_char, @pattern[@index])
        @index += 1
      end
    end
  end
end
