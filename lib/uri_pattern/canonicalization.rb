# frozen_string_literal: true

class URIPattern
  # Per-component canonicalization of fixed (literal) text, shared by the regexp
  # Compiler and the pattern-string generator so both apply identical encoding.
  # Including classes must define @component, @opaque_path and @ipv6.
  module Canonicalization
    # Canonicalize one fixed-text run for the current component. The percent-encode
    # components (pathname/query/fragment/username/password) are delegated to the
    # spec's "dummy URL" canonicalizers in URLParser so the URL parser applies the
    # exact spec encode set and dot-segment handling. Hostname/port keep their
    # dedicated parsers; protocol (and anything else) passes through unchanged.
    def encode_run(run)
      case @component
      when :protocol
        URIPattern::URLParser.canonicalize_protocol_run(run)
      when :hostname
        @ipv6 ? canonicalize_ipv6(run) : canonicalize_hostname(run)
      when :port
        canonicalize_port(run)
      when :pathname
        URIPattern::URLParser.canonicalize_pathname_run(run, opaque_path: @opaque_path)
      when :query
        URIPattern::URLParser.canonicalize_search_run(run)
      when :fragment
        URIPattern::URLParser.canonicalize_hash_run(run)
      when :username
        URIPattern::URLParser.canonicalize_username_run(run)
      when :password
        URIPattern::URLParser.canonicalize_password_run(run)
      else
        run
      end
    end

    # WHATWG basic URL parser "port state": read leading ASCII digits, stop at the
    # first non-digit, fail if the number exceeds 65535, and serialize without
    # leading zeros. (Default-port stripping is protocol-dependent and not applied
    # to the pattern string.)
    def canonicalize_port(run)
      return run if run.empty?
      digits = run[/\A[0-9]*/]
      raise URIPattern::Error, "Invalid port #{run.inspect}" if digits.empty?
      number = digits.to_i
      raise URIPattern::Error, "Invalid port #{run.inspect}" if number > 65_535
      number.to_s
    end

    # WHATWG "canonicalize a hostname": strip tab/newline/CR, end the host at the
    # first path delimiter ("/", "\\", "#", "?"), then run the host parser. A host
    # that fails to parse (forbidden code points, bad IDN, etc.) raises.
    def canonicalize_hostname(run)
      return run if run.empty?
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
  end
end
