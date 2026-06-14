# frozen_string_literal: true

class URIPattern
  # Generates the WHATWG "component pattern string" returned by the component
  # getters (protocol, hostname, pathname, ...). It parses the raw component
  # pattern into a part list — applying the same per-component canonicalization
  # used for matching — and re-serialises it ("generate a pattern string"), so
  # wildcards become "*", hostnames are punycoded, fixed text is percent-encoded,
  # redundant "{}" groups are dropped, and so on.
  #
  # This is a port of the path-to-regexp-derived parse()/partsToPattern() used by
  # the reference URLPattern implementation.
  class PatternString
    include URIPattern::Canonicalization

    FULL_WILDCARD_REGEXP = ".*"

    # Identifier continuation code points. The reference uses
    # /[$_‌‍\p{ID_Continue}]/u; in Ruby "_", ZWNJ and ZWJ are already in
    # \p{ID_Continue}, so only "$" needs to be added (avoids a duplicate-range warning).
    IDENTIFIER_PART = /[$\p{ID_Continue}]/u

    Part = Struct.new(:type, :name, :prefix, :value, :suffix, :modifier) do
      def custom_name?
        name.is_a?(String) && !name.empty?
      end
    end

    def self.generate(pattern_string, component:, opaque_path: false, ipv6: false)
      new(pattern_string, component: component, opaque_path: opaque_path, ipv6: ipv6).generate
    end

    def initialize(pattern_string, component:, opaque_path: false, ipv6: false)
      @input = pattern_string
      @component = component
      @opaque_path = opaque_path
      @ipv6 = ipv6
      @delimiter, @prefixes = options_for(component, opaque_path)
      @segment_wildcard_regexp = "[^#{escape_regexp_string(@delimiter)}]+?"
    end

    def generate
      parts_to_pattern(parse)
    end

    private

    # delimiter / prefix characters per component, matching the reference
    # DEFAULT_OPTIONS / HOSTNAME_OPTIONS / PATHNAME_OPTIONS.
    def options_for(component, opaque_path)
      case component
      when :hostname then [".", ""]
      when :pathname then opaque_path ? ["", ""] : ["/", "/"]
      else ["", ""]
      end
    end

    def encode_part(value)
      encode_run(value)
    end

    # --- parse: token list -> part list ------------------------------------

    def parse
      tokens = adapt_tokens(Tokenizer.new(@input, policy: :strict).tokenize)
      @tokens = tokens
      @index = 0
      @key = 0
      @name_set = {}
      @pending = +""
      @parts = []

      while @index < @tokens.length
        char_token = try_consume(:CHAR)
        name_token = try_consume(:NAME)
        regexp_or_wildcard = try_consume(:REGEX)
        if !name_token && !regexp_or_wildcard
          regexp_or_wildcard = try_consume(:ASTERISK)
        end

        if name_token || regexp_or_wildcard
          prefix = char_token || ""
          unless @prefixes.include?(prefix) && !prefix.empty?
            @pending << prefix
            prefix = ""
          end
          maybe_add_pending_fixed
          modifier_token = try_consume_modifier
          add_part(prefix, name_token, regexp_or_wildcard, "", modifier_token)
          next
        end

        value = char_token || try_consume(:ESCAPED_CHAR)
        if value
          @pending << value
          next
        end

        open_token = try_consume(:OPEN)
        if open_token
          prefix = consume_text
          name_token = try_consume(:NAME)
          regexp_or_wildcard = try_consume(:REGEX)
          if !name_token && !regexp_or_wildcard
            regexp_or_wildcard = try_consume(:ASTERISK)
          end
          suffix = consume_text
          must_consume(:CLOSE)
          modifier_token = try_consume_modifier
          add_part(prefix, name_token, regexp_or_wildcard, suffix, modifier_token)
          next
        end

        maybe_add_pending_fixed
        must_consume(:END)
      end

      @parts
    end

    def try_consume(type)
      return nil unless @index < @tokens.length && @tokens[@index].type == type
      value = @tokens[@index].value
      @index += 1
      value
    end

    def try_consume_modifier
      try_consume(:OTHER_MODIFIER) || try_consume(:ASTERISK)
    end

    def must_consume(type)
      value = try_consume(type)
      return value unless value.nil?
      raise URIPattern::Error, "Unexpected token, expected #{type}"
    end

    def consume_text
      result = +""
      while (value = try_consume(:CHAR) || try_consume(:ESCAPED_CHAR))
        result << value
      end
      result
    end

    def maybe_add_pending_fixed
      return if @pending.empty?
      @parts << Part.new(:fixed, "", "", encode_part(@pending), "", :none)
      @pending = +""
    end

    MODIFIER_MAP = { "?" => :optional, "*" => :zero_or_more, "+" => :one_or_more }.freeze

    def add_part(prefix, name_token, regexp_or_wildcard, suffix, modifier_token)
      modifier = MODIFIER_MAP.fetch(modifier_token, :none)

      # A "{ ... }" group of only fixed text with no modifier: buffer it.
      if !name_token && !regexp_or_wildcard && modifier == :none
        @pending << prefix
        return
      end

      maybe_add_pending_fixed

      # Fixed-string grouping such as "{foo}?": the text is the prefix.
      if !name_token && !regexp_or_wildcard
        return if prefix.empty?
        @parts << Part.new(:fixed, "", "", encode_part(prefix), "", modifier)
        return
      end

      regexp_value =
        if !regexp_or_wildcard
          @segment_wildcard_regexp
        elsif regexp_or_wildcard == "*"
          FULL_WILDCARD_REGEXP
        else
          regexp_or_wildcard
        end

      type = :regexp
      if regexp_value == @segment_wildcard_regexp
        type = :segment_wildcard
        regexp_value = ""
      elsif regexp_value == FULL_WILDCARD_REGEXP
        type = :full_wildcard
        regexp_value = ""
      end

      name =
        if name_token
          name_token
        elsif regexp_or_wildcard
          n = @key
          @key += 1
          n
        else
          ""
        end

      if @name_set.key?(name)
        raise URIPattern::Error, "Duplicate name #{name.inspect}"
      end
      @name_set[name] = true

      @parts << Part.new(type, name, encode_part(prefix), regexp_value, encode_part(suffix), modifier)
    end

    # --- generate: part list -> pattern string -----------------------------

    def parts_to_pattern(parts)
      result = +""
      parts.each_with_index do |part, i|
        if part.type == :fixed
          if part.modifier == :none
            result << escape_pattern_string(part.value)
          else
            result << "{#{escape_pattern_string(part.value)}}#{modifier_to_string(part.modifier)}"
          end
          next
        end

        custom_name = part.custom_name?

        needs_grouping =
          !part.suffix.empty? ||
          (!part.prefix.empty? && (part.prefix.length != 1 || !@prefixes.include?(part.prefix)))

        last_part = i > 0 ? parts[i - 1] : nil
        next_part = i < parts.length - 1 ? parts[i + 1] : nil

        if !needs_grouping && custom_name &&
           part.type == :segment_wildcard && part.modifier == :none &&
           next_part && next_part.prefix.empty? && next_part.suffix.empty?
          if next_part.type == :fixed
            code = next_part.value.empty? ? "" : next_part.value[0]
            needs_grouping = IDENTIFIER_PART.match?(code)
          else
            needs_grouping = !next_part.custom_name?
          end
        end

        if !needs_grouping && part.prefix.empty? && last_part && last_part.type == :fixed
          code = last_part.value[-1]
          needs_grouping = !code.nil? && @prefixes.include?(code)
        end

        result << "{" if needs_grouping
        result << escape_pattern_string(part.prefix)
        result << ":#{part.name}" if custom_name

        case part.type
        when :regexp
          result << "(#{part.value})"
        when :segment_wildcard
          result << "(#{@segment_wildcard_regexp})" unless custom_name
        when :full_wildcard
          if !custom_name && (last_part.nil? ||
             last_part.type == :fixed ||
             last_part.modifier != :none ||
             needs_grouping ||
             !part.prefix.empty?)
            result << "*"
          else
            result << "(#{FULL_WILDCARD_REGEXP})"
          end
        end

        if part.type == :segment_wildcard && custom_name && !part.suffix.empty? &&
           IDENTIFIER_PART.match?(part.suffix[0])
          result << "\\"
        end

        result << escape_pattern_string(part.suffix)
        result << "}" if needs_grouping
        result << modifier_to_string(part.modifier) if part.modifier != :none
      end
      result
    end

    def modifier_to_string(modifier)
      case modifier
      when :zero_or_more then "*"
      when :optional     then "?"
      when :one_or_more  then "+"
      else ""
      end
    end

    def escape_pattern_string(value)
      value.gsub(/([+*?:{}()\\])/, '\\\\\1')
    end

    def escape_regexp_string(value)
      value.gsub(%r{([.+*?^${}()\[\]|/\\])}, '\\\\\1')
    end

    # --- token adaptation --------------------------------------------------

    AdaptedToken = Struct.new(:type, :value)

    # Convert our Tokenizer output into the flat token stream the parser expects.
    # A "(...)" group is already a single :regexp token (carrying the raw regexp
    # source), so it maps straight to a :REGEX token.
    def adapt_tokens(tokens)
      out = []
      i = 0
      while i < tokens.length
        t = tokens[i]
        case t.type
        when :regexp                then out << AdaptedToken.new(:REGEX, t.value); i += 1
        when :char, :invalid_char then out << AdaptedToken.new(:CHAR, t.value); i += 1
        when :escaped_char        then out << AdaptedToken.new(:ESCAPED_CHAR, t.value); i += 1
        when :name                then out << AdaptedToken.new(:NAME, t.value); i += 1
        when :asterisk            then out << AdaptedToken.new(:ASTERISK, "*"); i += 1
        when :open                then out << AdaptedToken.new(:OPEN, "{"); i += 1
        when :close               then out << AdaptedToken.new(:CLOSE, "}"); i += 1
        when :other_modifier      then out << AdaptedToken.new(:OTHER_MODIFIER, t.value); i += 1
        when :end                 then out << AdaptedToken.new(:END, ""); i += 1
        else i += 1
        end
      end
      out << AdaptedToken.new(:END, "") unless out.last&.type == :END
      out
    end
  end
end
