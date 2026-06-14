# frozen_string_literal: true

class URIPattern
  class ComponentPattern
    attr_reader :pattern

    def initialize(pattern_string, component:, ignore_case: false, opaque_path: false)
      @pattern = pattern_string
      tokens = Tokenizer.new(pattern_string, policy: :strict).tokenize
      ipv6 = component == :hostname && ipv6_hostname_pattern?(pattern_string)
      compiled = Compiler.new(tokens, component: component, ignore_case: ignore_case,
                               opaque_path: opaque_path, ipv6: ipv6).compile
      @regexp = compiled[:regexp]
      @names = compiled[:names]
      @wildcard_name_map = compiled[:wildcard_name_map]
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
