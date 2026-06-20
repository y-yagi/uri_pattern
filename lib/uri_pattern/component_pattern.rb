# frozen_string_literal: true

class URIPattern
  class ComponentPattern
    # A pure-wildcard ("*") component compiles to the same regexp and pattern
    # string regardless of component type (an asterisk token uses neither the
    # segment regexp nor a delimiter), and the resulting object is immutable after
    # init. So the default wildcard component — by far the most common one, since
    # every unspecified component defaults to "*" — can be built once and shared.
    @wildcard_cache = {}

    # Return a ComponentPattern for +pattern_string+. The pure-wildcard, no-options
    # case is served from a per-component cache to skip tokenize/compile/Regexp work.
    def self.build(pattern_string, component:, ignore_case: false, opaque_path: false)
      if pattern_string == "*" && !ignore_case && !opaque_path
        @wildcard_cache[component] ||= new(pattern_string, component: component)
      else
        new(pattern_string, component: component,
            ignore_case: ignore_case, opaque_path: opaque_path)
      end
    end

    def initialize(pattern_string, component:, ignore_case: false, opaque_path: false)
      tokens = Tokenizer.new(pattern_string, policy: :strict).tokenize
      ipv6 = component == :hostname && ipv6_hostname_pattern?(pattern_string)
      compiled = Compiler.new(tokens, component: component, ignore_case: ignore_case,
                               opaque_path: opaque_path, ipv6: ipv6).compile
      @regexp = compiled[:regexp]
      @wildcard_name_map = compiled[:wildcard_name_map]
      # Arguments retained so the "component pattern string" can be generated lazily
      # on first #pattern access (see below).
      @raw_pattern = pattern_string
      @component = component
      @opaque_path = opaque_path
      @ipv6 = ipv6
    end

    # The canonicalized "component pattern string" (see PatternString), not the raw
    # input. Generated lazily and memoized: generating it for every component at
    # construction time dominated build cost, yet the getters are often never read.
    def pattern
      @pattern ||= PatternString.generate(@raw_pattern, component: @component,
                                          opaque_path: @opaque_path, ipv6: @ipv6)
    end

    # WHATWG "hostname pattern is an IPv6 address": true when the pattern starts
    # with "[" (optionally wrapped in a "{" group). Such hostnames use the IPv6
    # encode callback (lowercase hex + char validation) instead of host parsing.
    def ipv6_hostname_pattern?(str)
      return false if str.length < 2
      str[0] == "[" || (str[0] == "{" && str[1] == "[")
    end

    def match(string)
      @regexp.match(string)
    end

    def groups_for(string)
      md = @regexp.match(string)
      return nil unless md
      caps = md.named_captures
      @wildcard_name_map.each do |internal, external|
        caps[external] = caps.delete(internal) if caps.key?(internal)
      end
      caps
    end
  end
end
