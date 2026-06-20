# frozen_string_literal: true

require_relative "uri_pattern/version"
require_relative "uri_pattern/tokenizer"
require_relative "uri_pattern/canonicalization"
require_relative "uri_pattern/compiler"
require_relative "uri_pattern/pattern_string"
require_relative "uri_pattern/component_pattern"
require_relative "uri_pattern/url_parser"
require_relative "uri_pattern/match_result"

class URIPattern
  class Error < StandardError; end

  COMPONENT_KEYS = %i[protocol username password hostname port pathname query fragment].freeze

  COMPONENT_DEFAULTS = {
    protocol: "*",
    username: "*",
    password: "*",
    hostname: "*",
    port:     "*",
    pathname: "*",
    query:    "*",
    fragment: "*"
  }.freeze

  SPECIAL_SCHEMES = %w[http https ws wss ftp file].freeze

  # Authority components inherit the base_url value verbatim (already a literal
  # string); path components inherit it as an *escaped* pattern string.
  ESCAPED_AUTHORITY = %i[protocol hostname port].freeze
  ESCAPED_PATH = %i[pathname query fragment].freeze
  # ignoreCase only applies to these three components (per the spec's create
  # algorithm, which only mixes ignoreCaseOptions into pathname/search/hash).
  IGNORE_CASE_COMPONENTS = %i[pathname query fragment].freeze

  def initialize(input = {}, base_url = nil, ignore_case: false)
    if input.is_a?(Hash)
      init_from_hash(input, base_url, ignore_case: ignore_case)
    else
      init_from_string(input.to_s, base_url, ignore_case: ignore_case)
    end
  end

  def match?(input, base_url = nil)
    components = parse_input(input, base_url)
    return false unless components

    COMPONENT_KEYS.all? do |key|
      @patterns[key].match(components[key] || "")
    end
  rescue RegexpError => e
    raise URIPattern::Error, e.message
  end

  def match(input, base_url = nil)
    components = parse_input(input, base_url)
    return nil unless components

    results = {}
    COMPONENT_KEYS.each do |key|
      value = components[key] || ""
      groups = @patterns[key].groups_for(value)
      return nil unless groups
      results[key] = URIPattern::ComponentResult.new(input: value, groups: groups)
    end

    URIPattern::MatchResult.new(
      inputs: base_url.nil? ? [input] : [input, base_url],
      protocol:  results[:protocol],
      username:  results[:username],
      password:  results[:password],
      hostname:  results[:hostname],
      port:      results[:port],
      pathname:  results[:pathname],
      query:     results[:query],
      fragment:  results[:fragment]
    )
  end

  COMPONENT_KEYS.each do |key|
    define_method(key) { @patterns[key].pattern }
  end

  private

  def init_from_string(pattern_string, base_url, ignore_case:)
    if base_url
      unless valid_base_url?(base_url)
        raise URIPattern::Error, "Invalid base_url: #{base_url.inspect}"
      end
      # Parse the pattern on its own (preserving pattern syntax like "{...}"), then
      # let unspecified components fall back to the base_url — the same hierarchical
      # fallback used for dictionary inputs. Merging into a URL string first would
      # corrupt pattern-syntax characters via percent-encoding.
      parts = URIPattern::URLParser.split_pattern(pattern_string)
      build_patterns(parts, ignore_case: ignore_case, base_url: base_url)
    else
      parts = URIPattern::URLParser.split_pattern(pattern_string)
      # A relative URL pattern (one whose protocol is never determined — e.g.
      # "/foo", "example.com/foo", or "{https://}example.com" where the scheme is
      # hidden inside a group) is invalid without a base URL.
      if parts[:protocol].nil?
        raise URIPattern::Error, "Relative URL pattern requires a base URL"
      end
      build_patterns(parts, ignore_case: ignore_case)
    end
  end

  def init_from_hash(hash, base_url, ignore_case:)
    # A dictionary input must not be paired with a base_url argument.
    if base_url
      raise URIPattern::Error, "base_url cannot be provided when input is a dictionary"
    end
    hash = normalize_hash_keys(hash)
    effective_base = hash[:base_url]
    if effective_base && !valid_base_url?(effective_base)
      raise URIPattern::Error, "Invalid base_url: #{effective_base.inspect}"
    end
    parts = {}
    COMPONENT_KEYS.each { |k| parts[k] = hash[k]&.to_s }
    # "process protocol for init": a protocol value provided via a dictionary may
    # carry a single trailing ":" (e.g. "http{s}?:"), which is stripped before
    # compiling the component.
    if parts[:protocol]&.end_with?(":")
      parts[:protocol] = parts[:protocol][0...-1]
    end
    # "process search/hash for init": strip a single leading "?"/"#" prefix.
    if parts[:query]&.start_with?("?")
      parts[:query] = parts[:query][1..]
    end
    if parts[:fragment]&.start_with?("#")
      parts[:fragment] = parts[:fragment][1..]
    end
    build_patterns(parts, ignore_case: ignore_case, base_url: effective_base)
  end

  def normalize_hash_keys(hash)
    hash.transform_keys do |k|
      sym = k.to_sym
      # Map WPT/WHATWG alternative names to uri gem keys
      case sym
      when :search  then :query
      when :hash    then :fragment
      when :baseURL then :base_url
      else sym
      end
    end
  end

  def build_patterns(parts, ignore_case:, base_url: nil)
    base_components = base_url ? parse_base_url(base_url) : {}

    validate_port!(parts[:port])
    parts = normalize_pattern_parts(parts, base_url)
    pathname_opaque = opaque_pathname_context?(parts)

    @patterns = compile_components(parts, base_components, base_url:, ignore_case:,
                                   pathname_opaque:)
  end

  def validate_port!(port)
    return unless port && port.match?(/\A\d+\z/) && port.to_i > 65_535
    raise URIPattern::Error, "Invalid port: #{port.inspect}"
  end

  def normalize_pattern_parts(parts, base_url)
    parts = resolve_pattern_pathname_part(parts, base_url)
    parts = suppress_default_port(parts)
    parts
  end

  def resolve_pattern_pathname_part(parts, base_url)
    # Dot-segment collapsing of a pattern pathname is now handled per fixed run by
    # the component canonicalizer (URLParser.canonicalize_pathname_run), so it works
    # even when pattern tokens are present. Only base_url-relative resolution remains
    # here.
    if base_url && parts[:pathname]
      return parts if absolute_pattern_pathname?(parts[:pathname])
      parts = parts.dup
      parts[:pathname] = resolve_pattern_pathname(parts[:pathname], base_url)
    end
    parts
  end

  # Suppress the default port only when the protocol pattern is *exactly* a special
  # scheme name and the port is that scheme's default port. The comparison is an
  # exact, case-sensitive string match (per the spec's create step /
  # defaultPortForProtocol): a pattern like "http{s}?" or "HTTPS" is not the
  # concrete scheme "https", so it must not trigger suppression.
  def suppress_default_port(parts)
    return parts unless parts[:port] && parts[:protocol]
    default = URIPattern::URLParser::DEFAULT_PORTS[parts[:protocol]]
    return parts unless default && default.to_s == parts[:port]
    parts = parts.dup
    parts[:port] = ""
    parts
  end

  # An opaque path context occurs when the protocol is explicitly set, no authority
  # components are present, and the protocol pattern can't match any special scheme.
  def opaque_pathname_context?(parts)
    return false unless parts[:protocol]
    return false unless authority_empty?(parts)
    compiled_proto = URIPattern::ComponentPattern.new(parts[:protocol], component: :protocol)
    SPECIAL_SCHEMES.none? { |s| compiled_proto.match(s) }
  end

  def authority_empty?(parts)
    %i[hostname username password port].all? { |k| parts[k].nil? || parts[k].empty? }
  end

  def compile_components(parts, base_components, base_url:, ignore_case:, pathname_opaque:)
    # Hierarchical base_url fallback: components appearing *after* the last
    # explicitly-specified component (in COMPONENT_KEYS order) do not inherit from
    # the base — they are wildcarded. Only components at or before that boundary
    # fall back to the base URL value.
    last_specified = COMPONENT_KEYS.each_index.select { |idx| !parts[COMPONENT_KEYS[idx]].nil? }.max
    COMPONENT_KEYS.each_with_index.to_h do |key, idx|
      pattern = parts[key] || default_pattern(key, idx, base_components, base_url, last_specified)
      opaque = (key == :pathname) ? pathname_opaque : false
      component_ignore_case = ignore_case && IGNORE_CASE_COMPONENTS.include?(key)
      [key, URIPattern::ComponentPattern.build(pattern, component: key,
                                               ignore_case: component_ignore_case, opaque_path: opaque)]
    end
  end

  # The pattern for a component that was not explicitly specified. Components
  # inherited from a base_url are exact strings: authority components are taken
  # verbatim, while path components are escaped ("escape a pattern string") so a
  # base query like "q=*&v=?" is not reinterpreted as pattern syntax.
  # username/password are never inherited from a base_url (spec "process a
  # URLPatternInit" guards them with "is not a pattern"); they stay wildcards.
  def default_pattern(key, idx, base_components, base_url, last_specified)
    if base_url && last_specified && idx > last_specified
      COMPONENT_DEFAULTS[key]
    elsif base_components[key] && ESCAPED_AUTHORITY.include?(key)
      base_components[key]
    elsif base_url && ESCAPED_PATH.include?(key)
      escape_pattern_string(base_components[key] || "")
    else
      COMPONENT_DEFAULTS[key]
    end
  end

  # Resolve a relative pattern pathname against the base_url's path. This is pure
  # string manipulation — prepend the base path up to and including its last "/" —
  # so pattern-syntax characters ("{", "}", ":", …) are preserved rather than
  # percent-encoded by the URL parser.
  # WHATWG "is an absolute pathname" for a pattern: a leading "/", or (because this
  # is a pattern, not a URL) an escaped "\\/" or a "{/" grouping that yields a
  # leading slash. Such pathnames are NOT resolved against the base_url's path.
  def absolute_pattern_pathname?(pathname)
    return false if pathname.empty?
    return true if pathname.start_with?("/")
    return false if pathname.length < 2
    (pathname[0] == "\\" || pathname[0] == "{") && pathname[1] == "/"
  end

  def resolve_pattern_pathname(pathname, base_url)
    base_path = parse_base_url(base_url)[:pathname].to_s
    base_path = "/" if base_path.empty?
    slash = base_path.rindex("/")
    prefix = slash ? base_path[0..slash] : "/"
    remove_dot_segments("#{prefix}#{pathname}")
  rescue
    "/#{pathname}"
  end

  # RFC 3986 §5.2.4 "remove dot segments", operating purely on the string so that
  # only whole "." / ".." path segments are collapsed (pattern syntax is untouched).
  def remove_dot_segments(path)
    input = path.dup
    output = +""
    until input.empty?
      if input.start_with?("../")
        input = input[3..]
      elsif input.start_with?("./")
        input = input[2..]
      elsif input.start_with?("/./")
        input = "/#{input[3..]}"
      elsif input == "/."
        input = "/"
      elsif input.start_with?("/../")
        input = "/#{input[4..]}"
        output.sub!(%r{/?[^/]*\z}, "")
      elsif input == "/.."
        input = "/"
        output.sub!(%r{/?[^/]*\z}, "")
      elsif input == "." || input == ".."
        input = ""
      else
        m = input.match(%r{\A(/?[^/]*)})
        output << m[1]
        input = input[m[1].length..]
      end
    end
    output
  end

  # A base_url must be a parseable absolute URL (it needs a scheme). An empty
  # string or a relative reference is not valid.
  def valid_base_url?(base_url)
    return false if base_url.nil? || base_url.empty?
    parsed = URI::WhatwgParser.new.split(base_url)
    scheme = parsed[URIPattern::URLParser::WHATWG_SCHEME]
    !scheme.nil? && !scheme.empty?
  rescue
    false
  end

  # WHATWG "escape a pattern string": backslash-escape every code point that has
  # special meaning in pattern syntax so the string matches literally.
  PATTERN_ESCAPE_CHARS = "+*?:{}()\\"
  def escape_pattern_string(str)
    str.each_char.map { |c| PATTERN_ESCAPE_CHARS.include?(c) ? "\\#{c}" : c }.join
  end

  def parse_base_url(base_url)
    URIPattern::URLParser.split_components(base_url)
  rescue URIPattern::Error
    {}
  end

  def parse_input(input, base_url)
    if input.is_a?(Hash)
      # base_url with a Hash input is always an error (must propagate, not be silenced)
      raise URIPattern::Error, "base_url must not be provided when input is a Hash" if base_url
      parse_hash_input(input)
    else
      begin
        URIPattern::URLParser.split_components(input.to_s, base_url: base_url)
      rescue URIPattern::Error
        nil
      end
    end
  end

  def parse_hash_input(input)
    normalized = normalize_hash_keys(input)
    effective_base = normalized.delete(:base_url)
    raw = hash_input_components(normalized, effective_base)
    URIPattern::URLParser.normalize_hash_input(raw)
  rescue URIPattern::Error
    nil
  end

  # Build the eight raw component strings for a dictionary match input. With no
  # base_url each component defaults to "". With a base_url, unspecified components
  # are inherited from it and a relative pathname is resolved against its path.
  def hash_input_components(normalized, effective_base)
    unless effective_base
      return COMPONENT_KEYS.to_h { |k| [k, normalized[k]&.to_s || ""] }
    end

    base_components = parse_base_url(effective_base)
    raw = COMPONENT_KEYS.to_h do |k|
      [k, normalized.key?(k) ? normalized[k].to_s : (base_components[k] || "")]
    end
    if normalized.key?(:pathname) && !normalized[:pathname].to_s.start_with?("/")
      raw[:pathname] = resolve_relative_pathname(normalized[:pathname].to_s, effective_base)
    end
    raw
  end

  # Resolve a relative pathname against the base_url using WHATWG relative-URL
  # resolution (replace the base's last path segment, honour dot segments), the
  # same algorithm node's URLPattern uses for a dictionary match input. A previous
  # hand-rolled concatenation appended to the full base path and broke on a
  # base_url carrying a query/fragment.
  def resolve_relative_pathname(pathname, base_url)
    return pathname if pathname.empty?
    URIPattern::URLParser.split_components(pathname, base_url: base_url)[:pathname]
  rescue
    pathname
  end
end
