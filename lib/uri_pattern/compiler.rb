# frozen_string_literal: true

class URIPattern
  class Compiler
    SEGMENT_REGEXPS = {
      pathname: "[^/]+?",
      hostname: "[^.]+?"
    }.freeze
    DEFAULT_SEGMENT = "[^#?{}]+?"

    DELIMITER_CHARS = {
      pathname: "/",
      hostname: "."
    }.freeze

    # Percent-encode chars that would be encoded in real URLs for this component type.
    def encode_needed?(char, component)
      cp = char.ord
      # C0 controls and non-ASCII always encoded
      return true if cp > 0x7E || cp <= 0x1F
      case component
      when :pathname
        # Opaque paths (non-special schemes) use a smaller encode set — space is NOT encoded
        if @opaque_path
          "#<>?`".include?(char)
        else
          " \"<>#?`{}".include?(char)
        end
      when :query
        " \"<>#".include?(char)
      when :fragment
        " \"<>`".include?(char)
      when :username, :password
        " !\"#$&'()*+,/:;<=>?@[\\]^`{|}~".include?(char)
      else
        false
      end
    end

    def encode_literal(char)
      return char unless encode_needed?(char, @component)
      char.bytes.map { |b| "%%%02X" % b }.join
    end

    # Accumulate consecutive literal characters; flush_literals canonicalizes the
    # whole run through the component's encode callback (which may raise) and
    # appends the Regexp-escaped result. This mirrors the spec applying an
    # encoding callback to each fixed-text part of a pattern.
    def flush_literals(result)
      return if @literal_buf.empty?
      run = @literal_buf
      @literal_buf = +""
      result << Regexp.escape(encode_run(run))
    end

    def encode_run(run)
      case @component
      when :hostname
        @ipv6 ? canonicalize_ipv6(run) : canonicalize_hostname(run)
      else
        run.each_char.map { |c| encode_literal(c) }.join
      end
    end

    # WHATWG "canonicalize a hostname": strip tab/newline/CR, end the host at the
    # first path delimiter ("/", "\\", "#"), then run the host parser. A host that
    # fails to parse (forbidden code points, bad IDN, etc.) raises.
    def canonicalize_hostname(run)
      return run if run.empty?
      return run unless URIPattern::URLParser::WHATWG_AVAILABLE
      value = run.gsub(/[\t\n\r]/, "")
      return "" if value.empty?
      if (idx = value.index(/[\/\\#?]/))
        value = value[0, idx]
      end
      return "" if value.empty?
      URI::WhatwgParser::HostParser.new.parse(value)
    rescue => e
      raise URIPattern::Error, "Invalid hostname #{run.inspect}: #{e.message}"
    end

    # WHATWG "canonicalize an IPv6 hostname": only "[", "]", ":" and ASCII hex
    # digits are permitted; hex letters are lowercased.
    def canonicalize_ipv6(run)
      run.each_char.map do |c|
        case c
        when "[", "]", ":" then c
        when /[0-9a-fA-F]/  then c.downcase
        else
          raise URIPattern::Error, "Invalid IPv6 hostname character #{c.inspect} in #{run.inspect}"
        end
      end.join
    end

    WILDCARD_PREFIX = "_w"

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
    end

    def compile
      regexp_str = translate_v_class_sets(build_regexp_string)
      flags = @ignore_case ? Regexp::IGNORECASE : 0
      begin
        regexp = Regexp.new("\\A#{regexp_str}\\z", flags)
      rescue RegexpError => e
        raise URIPattern::Error, "Invalid pattern: #{e.message}"
      end
      { regexp: regexp, names: @names_order, wildcard_name_map: @wildcard_name_map }
    end

    private

    # ECMAScript "v"-flag character classes support a "--" set-subtraction operator
    # (e.g. "[[a-z]--a]" = "[a-z]" minus "a") that Ruby's regexp engine lacks. Ruby
    # does support "&&" intersection, so rewrite "[A--B]" as "[A&&[^B]]".
    V_CLASS_SUBTRACTION = /(\[[^\[\]]+\])--(\[[^\[\]]+\]|[^\]]+?)(?=\])/

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
      # there is no "/" segment delimiter and no delimiter prefix is pulled into
      # an optional/repeated group.
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
      case mod
      when "+"
        # One or more: capture all repetitions in a single group
        # prefix + (core)(delimiter+core)* → all in one named group
        delim = delimiter_char.empty? ? "" : Regexp.escape(delimiter_char)
        if delim.empty? || prefix.empty?
          "#{prefix}(?<#{name}>(?:#{core})+)"
        else
          "#{prefix}(?<#{name}>#{core}(?:#{delim}#{core})*)"
        end
      when "*"
        # Zero or more: optional group, nil on zero occurrences
        delim = delimiter_char.empty? ? "" : Regexp.escape(delimiter_char)
        if delim.empty? || prefix.empty?
          "(?:#{prefix}(?<#{name}>(?:#{core})*))?".dup
        else
          "(?:#{prefix}(?<#{name}>#{core}(?:#{delim}#{core})*))?".dup
        end
      when "?"
        # Zero or one
        "(?:#{prefix}(?<#{name}>#{core}))?"
      else
        "(?:#{prefix}(?<#{name}>#{core}))#{mod}"
      end
    end

    def build_regexp_string
      result = +""
      i = 0

      while i < @tokens.length
        token = @tokens[i]

        if %i[char escaped_char invalid_char].include?(token.type)
          @literal_buf << token.value
          i += 1
          next
        end

        # A "{...}" group whose body is pure literal text and which carries no
        # modifier is a fixed-text part, not a group. Merge its text into the
        # literal run so adjacent literals canonicalize together (e.g. hostname
        # "example{.com/}foo" → the run "example.com/foo" → host-truncated at "/").
        if token.type == :open && (fixed = fixed_text_group(i))
          @literal_buf << fixed[:text]
          i = fixed[:next_index]
          next
        end

        flush_literals(result)

        case token.type
        when :end
          break

        when :asterisk
          internal_name = next_wildcard_name
          next_tok = @tokens[i + 1]
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
            i += 2
          else
            result << "(?<#{internal_name}>.*)"
            i += 1
          end

        when :name
          name = token.value
          register_name(name)
          next_tok = @tokens[i + 1]
          seg = segment_regexp
          if next_tok&.type == :other_modifier
            prefix = pull_delimiter_prefix(result)
            result << modifier_regex(name, seg, prefix, next_tok.value)
            i += 2
          elsif next_tok&.type == :regexp_open
            i += 2
            inner, i = read_until_regexp_close(i)
            mod_tok = @tokens[i]
            if mod_tok&.type == :other_modifier
              prefix = pull_delimiter_prefix(result)
              result << modifier_regex(name, inner, prefix, mod_tok.value)
              i += 1
            else
              result << "(?<#{name}>(?:#{inner}))"
            end
          else
            result << "(?<#{name}>#{seg})"
            i += 1
          end

        when :open
          i += 1
          inner_result, i = compile_group_inner(i)
          mod_tok = @tokens[i]
          if mod_tok&.type == :other_modifier
            prefix = pull_delimiter_prefix(result)
            result << "(?:#{prefix}#{inner_result})#{mod_tok.value}"
            i += 1
          else
            result << "(?:#{inner_result})"
          end

        when :regexp_open
          i += 1
          inner, i = read_until_regexp_close(i)
          internal_name = next_wildcard_name
          mod_tok = @tokens[i]
          if mod_tok&.type == :other_modifier
            prefix = pull_delimiter_prefix(result)
            result << modifier_regex(internal_name, inner, prefix, mod_tok.value)
            i += 1
          else
            result << "(?<#{internal_name}>(?:#{inner}))"
          end

        when :other_modifier
          # A modifier here did not follow a group/name/regexp/wildcard.
          raise URIPattern::Error, "Dangling modifier #{token.value.inspect} in pattern"

        else
          i += 1
        end
      end

      flush_literals(result)
      result
    end

    # If the "{" group starting at index i contains only literal characters and is
    # not followed by a modifier, return its text and the index just past "}".
    # Otherwise return nil (it is a real group with a capture/wildcard/modifier).
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

        if %i[char escaped_char invalid_char].include?(token.type)
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
          elsif next_tok&.type == :regexp_open
            i += 2
            inner, i = read_until_regexp_close(i)
            result << "(?<#{name}>(?:#{inner}))"
          else
            result << "(?<#{name}>#{seg})"
            i += 1
          end
        when :asterisk
          internal_name = next_wildcard_name
          result << "(?<#{internal_name}>.*)"
          i += 1
        when :regexp_open
          i += 1
          inner, i = read_until_regexp_close(i)
          internal_name = next_wildcard_name
          result << "(?<#{internal_name}>(?:#{inner}))"
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

    def read_until_regexp_close(i)
      inner = +""
      depth = 1
      while i < @tokens.length
        tok = @tokens[i]
        case tok.type
        when :regexp_open
          depth += 1
          inner << tok.value
          i += 1
        when :regexp_close
          depth -= 1
          if depth == 0
            i += 1
            break
          else
            inner << tok.value
            i += 1
          end
        when :end
          raise URIPattern::Error, "Unclosed '(' in pattern"
        when :escaped_char
          validate_regexp_escape(tok.value)
          inner << "\\#{tok.value}"
          i += 1
        else
          raise URIPattern::Error, "Invalid character in regexp group" unless tok.value.match?(/\A[\x00-\x7F]*\z/)
          inner << tok.value
          i += 1
        end
      end
      [strip_named_captures(inner), i]
    end

    # Named captures written inside a custom regexp group — "(?<x>...)" / "(?'x'...)"
    # — must not surface in the match result's groups (only URLPattern-level names
    # and wildcard indices do). Convert them to plain non-capturing groups, while
    # leaving lookbehind assertions "(?<=...)" / "(?<!...)" untouched.
    def strip_named_captures(inner)
      inner.gsub(/\(\?<(?![=!])[^>]*>/, "(?:").gsub(/\(\?'[^']*'/, "(?:")
    end

    # The spec compiles each custom regexp group as a Unicode-mode ECMAScript
    # regexp, where an identity escape ("\\x" for a literal x) is only valid for a
    # SyntaxCharacter, "/", or a recognized escape class. Letters like "m" or "H"
    # have no such escape and make the whole pattern invalid, even though Ruby
    # would silently accept them.
    VALID_REGEXP_ESCAPE = /\A[\^$\\.*+?()\[\]{}|\/dDsSwWbBfnrtvcxukpP0-9]\z/
    def validate_regexp_escape(char)
      return if char.match?(VALID_REGEXP_ESCAPE)
      raise URIPattern::Error, "Invalid regexp escape \\#{char}"
    end
  end
end
