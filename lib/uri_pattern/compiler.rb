# frozen_string_literal: true

class URIPattern
  class Compiler
    SEGMENT_REGEXPS = { pathname: "[^/]+?", hostname: "[^.]+?" }.freeze
    DEFAULT_SEGMENT = "[^#?{}]+?"
    DELIMITER_CHARS = { pathname: "/", hostname: "." }.freeze

    # Token types that carry literal text and are buffered rather than turned into
    # a capture.
    LITERAL_TOKEN_TYPES = %i[char escaped_char invalid_char].freeze

    # A literal run immediately followed by one of these part-introducing token
    # types has its trailing delimiter treated as the part's prefix (see
    # flush_literals).
    PART_LEADING_TOKEN_TYPES = %i[asterisk name open regexp].freeze

    WILDCARD_PREFIX = "_w"

    # ECMAScript "v"-flag character classes support a "--" set-subtraction operator
    # that Ruby's regexp engine lacks. Ruby does support "&&" intersection, so
    # rewrite "[A--B]" as "[A&&[^B]]".
    V_CLASS_SUBTRACTION = /(\[[^\[\]]+\])--(\[[^\[\]]+\]|[^\]]+?)(?=\])/

    # The spec compiles each custom regexp group as a Unicode-mode ECMAScript
    # regexp, where an identity escape ("\\x" for a literal x) is only valid for a
    # SyntaxCharacter, "/", or a recognized escape class. Letters like "m" or "H"
    # make the whole pattern invalid, even though Ruby would silently accept them.
    VALID_REGEXP_ESCAPE = /\A[\^$\\.*+?()\[\]{}|\/dDsSwWbBfnrtvcxukpP0-9]\z/

    include URIPattern::Canonicalization

    def initialize(tokens, component:, ignore_case: false, opaque_path: false, ipv6: false)
      @tokens = tokens
      @component = component
      @ignore_case = ignore_case
      @opaque_path = opaque_path
      @ipv6 = ipv6
      @wildcard_index = 0
      @names_order = []
      @wildcard_name_map = {}
      @literal_buf = +""
      @seen_names = {}
      @has_regexp_groups = false
    end

    def compile
      regexp_str = translate_v_class_sets(build_regexp_string)
      flags = @ignore_case ? Regexp::IGNORECASE : 0
      begin
        regexp = Regexp.new("\\A#{regexp_str}\\z", flags)
      rescue RegexpError => e
        raise URIPattern::Error, "Invalid pattern: #{e.message}"
      end
      { regexp:, names: @names_order, wildcard_name_map: @wildcard_name_map, has_regexp_groups: @has_regexp_groups }
    end

    private

    # Accumulate consecutive literal characters; flush_literals canonicalizes the
    # whole run through the component's encode callback (which may raise) and
    # appends the Regexp-escaped result.
    def flush_literals(result, before_part: false)
      return if @literal_buf.empty?
      run = @literal_buf
      @literal_buf = +""
      delim = delimiter_char
      # When this run is immediately followed by a part, a trailing delimiter ("/" for
      # pathname, "." for hostname) is that part's prefix, not part of this fixed run.
      # Canonicalize the run WITHOUT it — so e.g. pathname dot-segments collapse
      # correctly (`/a/../` → run `/a/..` → `/`) — and re-append the delimiter
      # verbatim for pull_delimiter_prefix / the next literal to consume.
      if before_part && !delim.empty? && run != delim && run.end_with?(delim)
        result << Regexp.escape(canonicalize_encode(run[0...-delim.length]))
        result << Regexp.escape(delim)
      else
        result << Regexp.escape(canonicalize_encode(run))
      end
    end

    def translate_v_class_sets(source)
      source.gsub(V_CLASS_SUBTRACTION) do
        lhs, rhs = $1, $2
        rhs_chars = rhs.start_with?("[") ? rhs[1..-2] : rhs
        "#{lhs}&&[^#{rhs_chars}]"
      end
    end

    def segment_regexp
      SEGMENT_REGEXPS.fetch(@component, DEFAULT_SEGMENT)
    end

    def delimiter_char
      # Opaque paths (non-special schemes like "data:") are not hierarchical, so
      # there is no "/" segment delimiter and no prefix to pull into a group.
      return "" if @component == :pathname && @opaque_path
      DELIMITER_CHARS[@component] || ""
    end

    def pull_delimiter_prefix(result)
      delim = delimiter_char
      return "" if delim.empty?
      escaped = Regexp.escape(delim)
      if result.end_with?(escaped)
        result.slice!(result.length - escaped.length, escaped.length)
        escaped
      else
        ""
      end
    end

    # A duplicate group name is a spec-level error ("URLPattern" raises TypeError).
    def register_name(name)
      if @seen_names[name]
        raise URIPattern::Error, "Duplicate group name #{name.inspect} in pattern"
      end
      @seen_names[name] = true
      @names_order << name
    end

    def next_wildcard_name
      external = @wildcard_index.to_s
      internal = "#{WILDCARD_PREFIX}#{@wildcard_index}"
      @wildcard_index += 1
      @wildcard_name_map[internal] = external
      @names_order << external
      internal
    end

    def modifier_regex(name, core, prefix, mod)
      delim = delimiter_char.empty? ? "" : Regexp.escape(delimiter_char)
      repeatable = !delim.empty? && !prefix.empty?
      case mod
      when "+"
        # One or more: all repetitions captured in a single named group.
        "#{prefix}(?<#{name}>#{repeatable ? "#{core}(?:#{delim}#{core})*" : "(?:#{core})+"})"
      when "*"
        # Zero or more: optional group, nil on zero occurrences
        "(?:#{prefix}(?<#{name}>#{repeatable ? "#{core}(?:#{delim}#{core})*" : "(?:#{core})*"}))?"
      when "?"
        "(?:#{prefix}(?<#{name}>#{core}))?"
      else
        "(?:#{prefix}(?<#{name}>#{core}))#{mod}"
      end
    end

    def build_regexp_string
      result = +""
      @index = 0

      while @index < @tokens.length
        token = current_token

        if LITERAL_TOKEN_TYPES.include?(token.type)
          @literal_buf << token.value
          @index += 1
          next
        end

        # A "{...}" group whose body is pure literal text and which carries no
        # modifier is a fixed-text part, not a group. Merge its text into the literal
        # run so adjacent literals canonicalize together (e.g. hostname
        # "example{.com/}foo" → the run "example.com/foo" → host-truncated at "/").
        if token.type == :open && (fixed = fixed_text_group(@index))
          @literal_buf << fixed[:text]
          @index = fixed[:next_index]
          next
        end

        flush_literals(result, before_part: PART_LEADING_TOKEN_TYPES.include?(token.type))

        case token.type
        when :end
          break
        when :asterisk
          compile_asterisk(result)
        when :name
          compile_name(result)
        when :open
          compile_group(result)
        when :regexp
          compile_inline_regexp(result)
        when :other_modifier
          raise URIPattern::Error, "Dangling modifier #{token.value.inspect} in pattern"
        else
          @index += 1
        end
      end

      flush_literals(result)
      result
    end

    def current_token
      @tokens[@index]
    end

    # Top-level "*" wildcard: unlike one nested in a "{...}" group (see
    # compile_group_inner) it pulls a delimiter prefix and supports a modifier.
    def compile_asterisk(result)
      internal_name = next_wildcard_name
      next_tok = @tokens[@index + 1]
      if next_tok && next_tok.type == :other_modifier
        prefix = pull_delimiter_prefix(result)
        # Wildcards match greedily; optional/one-or-more modifiers use lazy outer quantifier
        case next_tok.value
        when "+"
          result << "#{prefix}(?<#{internal_name}>.*)"
        when "*", "?"
          result << "(?:#{prefix}(?<#{internal_name}>.*))?\?"
        else
          result << "#{prefix}(?<#{internal_name}>.*)#{next_tok.value}"
        end
        @index += 2
      else
        result << "(?<#{internal_name}>.*)"
        @index += 1
      end
    end

    def compile_name(result)
      name = current_token.value
      register_name(name)
      next_tok = @tokens[@index + 1]
      seg = segment_regexp
      if next_tok&.type == :other_modifier
        prefix = pull_delimiter_prefix(result)
        result << modifier_regex(name, seg, prefix, next_tok.value)
        @index += 2
      elsif next_tok&.type == :regexp
        inner = regexp_inner(next_tok)
        mod_tok = @tokens[@index + 2]
        if mod_tok&.type == :other_modifier
          prefix = pull_delimiter_prefix(result)
          result << modifier_regex(name, inner, prefix, mod_tok.value)
          @index += 3
        else
          result << "(?<#{name}>(?:#{inner}))"
          @index += 2
        end
      else
        result << "(?<#{name}>#{seg})"
        @index += 1
      end
    end

    def compile_group(result)
      @index += 1
      inner_result, @index = compile_group_inner(@index)
      mod_tok = @tokens[@index]
      if mod_tok&.type == :other_modifier
        prefix = pull_delimiter_prefix(result)
        result << "(?:#{prefix}#{inner_result})#{mod_tok.value}"
        @index += 1
      else
        result << "(?:#{inner_result})"
      end
    end

    def compile_inline_regexp(result)
      inner = regexp_inner(current_token)
      internal_name = next_wildcard_name
      mod_tok = @tokens[@index + 1]
      if mod_tok&.type == :other_modifier
        prefix = pull_delimiter_prefix(result)
        result << modifier_regex(internal_name, inner, prefix, mod_tok.value)
        @index += 2
      else
        result << "(?<#{internal_name}>(?:#{inner}))"
        @index += 1
      end
    end

    # If the "{" group starting at index i contains only literal characters and is
    # not followed by a modifier, return its text and the index just past "}".
    def fixed_text_group(i)
      j = i + 1
      text = +""
      while j < @tokens.length
        tok = @tokens[j]
        case tok.type
        when :char, :escaped_char, :invalid_char
          text << tok.value
          j += 1
        when :close
          return nil if @tokens[j + 1]&.type == :other_modifier
          return { text: text, next_index: j + 1 }
        else
          return nil
        end
      end
      nil
    end

    def compile_group_inner(i)
      result = +""
      while i < @tokens.length
        token = @tokens[i]

        if LITERAL_TOKEN_TYPES.include?(token.type)
          @literal_buf << token.value
          i += 1
          next
        end

        flush_literals(result)

        case token.type
        when :close
          i += 1
          return [result, i]
        when :end
          raise URIPattern::Error, "Unclosed '{' group in pattern"
        when :name
          name = token.value
          register_name(name)
          next_tok = @tokens[i + 1]
          seg = segment_regexp
          if next_tok&.type == :other_modifier
            result << "(?<#{name}>#{seg})#{next_tok.value}"
            i += 2
          elsif next_tok&.type == :regexp
            inner = regexp_inner(next_tok)
            result << "(?<#{name}>(?:#{inner}))"
            i += 2
          else
            result << "(?<#{name}>#{seg})"
            i += 1
          end
        when :asterisk
          internal_name = next_wildcard_name
          result << "(?<#{internal_name}>.*)"
          i += 1
        when :regexp
          inner = regexp_inner(token)
          internal_name = next_wildcard_name
          result << "(?<#{internal_name}>(?:#{inner}))"
          i += 1
        when :open
          # A "{" group nested inside another "{" group is not allowed.
          raise URIPattern::Error, "Nested '{' group in pattern"
        when :other_modifier
          raise URIPattern::Error, "Dangling modifier #{token.value.inspect} in pattern"
        else
          i += 1
        end
      end
      raise URIPattern::Error, "Unclosed '{' group in pattern"
    end

    # Prepare a :regexp token's raw inner source for embedding: validate its identity
    # escapes (ECMAScript "u"-mode rules) and neutralize any author-written named
    # captures so only URLPattern-level names surface. The tokenizer already
    # enforced the structural rules (balance, no capturing sub-groups, ASCII).
    def regexp_inner(token)
      # Every "(...)" custom-regexp group is a spec "regexp" part, so the presence of
      # any one makes the whole pattern carry regexp groups.
      @has_regexp_groups = true
      inner = token.value.to_s
      validate_regexp_escapes(inner)
      strip_named_captures(inner)
    end

    def validate_regexp_escapes(inner)
      inner.scan(/\\(.)/m) { validate_regexp_escape($1) }
    end

    # Named captures written inside a custom regexp group must not surface in the
    # match result's groups, so convert them to plain non-capturing groups while
    # leaving lookbehind assertions "(?<=...)" / "(?<!...)" untouched.
    def strip_named_captures(inner)
      inner.gsub(/\(\?<(?![=!])[^>]*>/, "(?:").gsub(/\(\?'[^']*'/, "(?:")
    end

    def validate_regexp_escape(char)
      return if char.match?(VALID_REGEXP_ESCAPE)
      raise URIPattern::Error, "Invalid regexp escape \\#{char}"
    end
  end
end
