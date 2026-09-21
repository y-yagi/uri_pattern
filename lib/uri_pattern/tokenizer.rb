# frozen_string_literal: true

require "strscan"

class URIPattern
  class Tokenizer
    Token = Struct.new(:type, :value, :index)

    # :char values can be multi-character runs (not just a single literal
    # character). The following are always emitted as their own single-character
    # token, never folded into a run: \ { } ( ) * ? + : @ / # [ ] .
    # Downstream consumers (Compiler, ConstructorStringParser, PatternString) rely
    # on this invariant: a run never straddles a pattern-meta or URL-structural
    # delimiter, so their single-character comparisons against a token's value
    # (e.g. token.value == "/") still hold.

    # A run of one or more characters that are none of the delimiters above. This
    # is what lets a stretch of plain literal text collapse into a single :char
    # token instead of one token per character.
    PLAIN_RE = %r{[^\\{}()*?+:@/#\[\].]+}

    # A ":name" identifier follows the spec's "regexIdentifierStart" /
    # "regexIdentifierPart":
    #   start = /[$_\p{ID_Start}]/u,  part = /[$_‌‍\p{ID_Continue}]/u
    # In Ruby "_", ZWNJ and ZWJ are already in \p{ID_Continue} (and "$" is not),
    # while "_" is not in \p{ID_Start}. StringScanner#scan is always anchored at
    # the current position, so no "\G" is needed here.
    IDENTIFIER_RE = /[$_\p{ID_Start}][$\p{ID_Continue}]*/u

    # A run of ASCII characters inside a "(...)" regexp group, stopping short of
    # the characters the group scanner needs to inspect one at a time ("\", "(",
    # ")"). Used to scan the group body in chunks instead of char by char.
    GROUP_CHUNK_RE = /[\u0000-\u007F&&[^\\()]]+/

    # Token types after which a "*" is a modifier (repeat) rather than a standalone
    # wildcard.
    MODIFIABLE_PREV_TYPES = %i[close regexp name asterisk].freeze

    def initialize(pattern, policy: :lenient)
      @pattern = pattern
      @policy = policy
      @s = StringScanner.new(pattern)
      # Character index (not the StringScanner's byte-based #pos), kept in sync
      # by hand so Token#index stays a character offset; make_component_string
      # in ConstructorStringParser slices @input with it.
      @index = 0
      @tokens = []
    end

    def tokenize
      until @s.eos?
        if (run = @s.scan(PLAIN_RE))
          emit(:char, run)
          @index += run.length
          next
        end

        ch = @s.getch
        case ch
        when "\\"
          if (esc = @s.getch)
            emit(:escaped_char, esc)
            @index += 2
          else
            handle_invalid(ch, "trailing backslash")
          end
        when "{"
          emit(:open, "{")
          @index += 1
        when "}"
          emit(:close, "}")
          @index += 1
        when "("
          # Lex the whole "(...)" group atomically into one :regexp token, as the
          # spec's tokenizer does. Rewind to the "(" so scan_regexp_group can walk
          # it from the start.
          @s.pos -= 1
          scan_regexp_group(@s.pos)
        when "*"
          prev = @tokens.last
          if prev && MODIFIABLE_PREV_TYPES.include?(prev.type)
            emit(:other_modifier, "*")
          else
            emit(:asterisk, "*")
          end
          @index += 1
        when "?"
          # "?"/"+" are always modifier tokens; the compiler rejects a dangling one.
          # (A literal "?"/"+" must be escaped, e.g. "\\?".)
          emit(:other_modifier, "?")
          @index += 1
        when "+"
          emit(:other_modifier, "+")
          @index += 1
        when ":"
          if (name = @s.scan(IDENTIFIER_RE))
            emit(:name, name)
            @index += 1 + name.length
          else
            # The spec's tokenizer reports "missing parameter name" here. Lenient
            # tokenizing emits an :invalid_char so the ":" is still recognized as a
            # protocol/password/port delimiter by the constructor string parser.
            handle_invalid(ch, "missing parameter name")
          end
        when "@", "/", "#", "[", "]", ")", "."
          # A single literal character with no pattern meaning of its own. Kept
          # out of the run so ConstructorStringParser's 1-character comparisons
          # against a token's value still hold; a ")" not consumed by a group
          # scan falls here too.
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

    def handle_invalid(ch, reason)
      if @policy == :strict
        raise URIPattern::Error, "Invalid pattern at index #{@index}: #{reason}"
      else
        # ch was already consumed by the getch above, so @s.pos is already
        # correctly positioned past it; no rewind needed.
        emit(:invalid_char, ch)
        @index += 1
      end
    end

    # Scan a "(...)" regexp group starting at the "(" (already positioned at
    # @s, whose byte pos is start_pos), following the spec tokenizer. On success
    # emits a single :regexp token whose value is the raw inner regexp source;
    # on a violation handle_invalid_group raises (strict) or emits an
    # :invalid_char for the "(" and re-scans the remainder (lenient).
    #
    # @s is the sole scanning cursor; character counts are tracked by addition
    # only (no @pattern[j] indexing, which is O(n) on a non-ASCII pattern).
    def scan_regexp_group(start_pos)
      start = @index
      @s.getch
      chars = 1

      return handle_invalid_group(start_pos, start, "regexp group cannot start with '?'") if @s.peek(1) == "?"

      count = 1
      inner = +""
      loop do
        if (chunk = @s.scan(GROUP_CHUNK_RE))
          inner << chunk
          chars += chunk.length
        end
        return handle_invalid_group(start_pos, start, "unbalanced regexp group") if @s.eos?

        c = @s.getch
        chars += 1
        case c
        when "\\"
          return handle_invalid_group(start_pos, start, "trailing backslash in regexp group") if @s.eos?

          esc = @s.getch
          chars += 1
          inner << c << esc
        when ")"
          count -= 1
          break if count.zero?

          inner << c
        when "("
          count += 1
          # A nested group must be non-capturing ("(?:...)"); a bare "(" would
          # introduce a capturing group.
          return handle_invalid_group(start_pos, start, "capturing groups are not allowed") if @s.peek(1) != "?"

          inner << c
        else
          # GROUP_CHUNK_RE already consumed every ASCII char except "\ ( )", so
          # only a non-ASCII character (the escaped char after "\" is exempt) can
          # reach here.
          return handle_invalid_group(start_pos, start, "invalid character #{c.inspect} in regexp group")
        end
      end

      return handle_invalid_group(start_pos, start, "missing pattern in regexp group") if inner.empty?

      @tokens << Token.new(:regexp, inner, start)
      @index = start + chars
    end

    def handle_invalid_group(start_pos, at, reason)
      if @policy == :strict
        raise URIPattern::Error, "Invalid pattern at index #{at}: #{reason}"
      else
        @s.pos = start_pos
        @tokens << Token.new(:invalid_char, @s.getch, at)
        @index = at + 1
      end
    end
  end
end
