# frozen_string_literal: true

class URIPattern
  class Tokenizer
    # Positional (not keyword_init) Struct: tokenizing allocates one Token per
    # character and keyword construction is markedly slower, so this is a hot path.
    Token = Struct.new(:type, :value, :index)

    # A ":name" identifier follows the spec's "regexIdentifierStart" /
    # "regexIdentifierPart" (path-to-regex-modified):
    #   start = /[$_\p{ID_Start}]/u,  part = /[$_‌‍\p{ID_Continue}]/u
    # In Ruby "_", ZWNJ and ZWJ are already in \p{ID_Continue} (and "$" is not),
    # while "_" is not in \p{ID_Start}; so the start class adds "$" and "_" and the
    # part class adds only "$". Matching the spec here (rather than a permissive
    # "[\u{80}-\u{10FFFF}]") makes e.g. ":$foo" a name and rejects a name starting
    # with a non-ID_Start code point (e.g. ":🚲"), as the reference does.
    IDENTIFIER_RE = /\A[$_\p{ID_Start}][$\p{ID_Continue}]*/u

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
          # Lex the whole "(...)" group atomically into one :regexp token, as the
          # spec's tokenizer does (validating it during the scan).
          scan_regexp_group
        when ")"
          # A ")" not consumed by a group scan is a literal character (the spec's
          # tokenizer falls through to a CHAR token here).
          emit(:char, ch)
          @index += 1
        when "*"
          prev = @tokens.last
          if prev && %i[close regexp name asterisk].include?(prev.type)
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
            # ":" must be followed by a valid name. When it is not, the spec's
            # tokenizer reports "missing parameter name": strict tokenizing (used
            # when compiling a component) raises, while lenient tokenizing
            # (constructor string parsing) emits an :invalid_char so the ":" is
            # still recognized as a protocol/password/port delimiter by the
            # constructor string parser (which treats :invalid_char as a
            # non-special char, like :char).
            handle_invalid("missing parameter name")
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
      @tokens << Token.new(type, value, @index)
    end

    def handle_invalid(reason)
      if @policy == :strict
        raise URIPattern::Error, "Invalid pattern at index #{@index}: #{reason}"
      else
        emit(:invalid_char, @pattern[@index])
        @index += 1
      end
    end

    # Scan a "(...)" regexp group starting at @index (the "("), following the
    # spec/path-to-regexp tokenizer. On success emits a single :regexp token whose
    # value is the raw inner regexp source and advances @index past the closing ")".
    # On a spec violation calls handle_invalid_group (strict raises; lenient emits an
    # :invalid_char for the "(" and re-scans the remainder).
    def scan_regexp_group
      start = @index
      j = start + 1

      # "Pattern cannot start with '?'": a top-level group may not open with "?".
      return handle_invalid_group(start, "regexp group cannot start with '?'") if @pattern[j] == "?"

      count = 1
      inner = +""
      while j < @pattern.length
        c = @pattern[j]
        # Inside a group only ASCII is allowed (the escaped char after "\" is exempt).
        return handle_invalid_group(start, "invalid character #{c.inspect} in regexp group") if c.ord >= 0x80

        if c == "\\"
          # Escaped pair: keep the backslash and the next char verbatim.
          return handle_invalid_group(start, "trailing backslash in regexp group") if j + 1 >= @pattern.length
          inner << c << @pattern[j + 1]
          j += 2
          next
        end

        if c == ")"
          count -= 1
          if count.zero?
            j += 1
            break
          end
          inner << c
          j += 1
          next
        elsif c == "("
          count += 1
          # A nested group must be non-capturing ("(?:...)" etc.); a bare "(" would
          # introduce a capturing group, which is not allowed.
          return handle_invalid_group(start, "capturing groups are not allowed") if @pattern[j + 1] != "?"
          inner << c
          j += 1
          next
        end

        inner << c
        j += 1
      end

      return handle_invalid_group(start, "unbalanced regexp group") unless count.zero?
      return handle_invalid_group(start, "missing pattern in regexp group") if inner.empty?

      @tokens << Token.new(:regexp, inner, start)
      @index = j
    end

    def handle_invalid_group(at, reason)
      if @policy == :strict
        raise URIPattern::Error, "Invalid pattern at index #{at}: #{reason}"
      else
        @tokens << Token.new(:invalid_char, @pattern[at], at)
        @index = at + 1
      end
    end
  end
end
