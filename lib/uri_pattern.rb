# frozen_string_literal: true

require_relative "uri_pattern/version"
require_relative "uri_pattern/tokenizer"
require_relative "uri_pattern/compiler"
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

  def initialize(input, base_url = nil, ignore_case: false)
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
      input: input.is_a?(Hash) ? input.inspect : input.to_s,
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
        raise URIPattern::Error, "Invalid baseURL: #{base_url.inspect}"
      end
      # Parse the pattern on its own (preserving pattern syntax like "{...}"), then
      # let unspecified components fall back to the baseURL — the same hierarchical
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
    # A dictionary input must not be paired with a baseURL argument.
    if base_url
      raise URIPattern::Error, "baseURL cannot be provided when input is a dictionary"
    end
    hash = normalize_hash_keys(hash)
    effective_base = hash[:base_url]
    if effective_base && !valid_base_url?(effective_base)
      raise URIPattern::Error, "Invalid baseURL: #{effective_base.inspect}"
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
      # Map WPT/WHATWG alternative names to our keys
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
    @patterns = {}

    # A literal, all-numeric port must be a valid port number (0..65535).
    if parts[:port] && parts[:port].match?(/\A\d+\z/) && parts[:port].to_i > 65_535
      raise URIPattern::Error, "Invalid port: #{parts[:port].inspect}"
    end

    # Normalize pattern pathname: resolve relative/dot-segment pathnames against baseURL
    if base_url && parts[:pathname]
      pathname = parts[:pathname]
      unless pathname.start_with?("/")
        parts = parts.dup
        parts[:pathname] = resolve_pattern_pathname(pathname, base_url)
      end
    elsif parts[:pathname] && parts[:pathname].include?(".") && !parts[:pathname].include?("*") &&
          !parts[:pathname].include?(":") && !parts[:pathname].include?("(")
      # Resolve dot segments in literal pathnames
      normalized = URIPattern::URLParser.normalize_pathname_input(parts[:pathname])
      if normalized != parts[:pathname]
        parts = parts.dup
        parts[:pathname] = normalized
      end
    end

    # Normalize pattern port: suppress default port when protocol is explicitly set
    if parts[:port] && parts[:protocol]
      proto = parts[:protocol].downcase.gsub(/[^a-z]/, "")
      default = URIPattern::URLParser::DEFAULT_PORTS[proto]
      if default && default.to_s == parts[:port]
        parts = parts.respond_to?(:dup) ? parts.dup : parts.clone
        parts[:port] = ""
      end
    end

    # Determine if the pathname is an opaque path context.
    # Opaque paths occur when the protocol is a non-special scheme that doesn't use authority.
    # We check: protocol is explicitly set, AND the protocol pattern can't match any special scheme.
    pathname_opaque = if parts[:protocol]
      proto_pat = parts[:protocol]
      # Only opaque if no authority components are set
      no_authority = (parts[:hostname].nil? || parts[:hostname].empty?) &&
                     (parts[:username].nil? || parts[:username].empty?) &&
                     (parts[:password].nil? || parts[:password].empty?) &&
                     (parts[:port].nil? || parts[:port].empty?)
      if no_authority
        compiled_proto = URIPattern::ComponentPattern.new(proto_pat, component: :protocol)
        SPECIAL_SCHEMES.none? { |s| compiled_proto.match(s) }
      else
        false
      end
    else
      false
    end

    # Components inherited from a baseURL are exact strings, so they must be
    # escaped into literal patterns ("escape a pattern string") — otherwise a base
    # query like "q=*&v=?" would be parsed as pattern syntax.
    escaped_authority = %i[protocol username password hostname port]
    escaped_path = %i[pathname query fragment]
    # Hierarchical baseURL fallback: components appearing *after* the last
    # explicitly-specified component (in COMPONENT_KEYS order) do not inherit from
    # the base — they are wildcarded. Only components at or before that boundary
    # fall back to the base URL value.
    last_specified = COMPONENT_KEYS.each_index.select { |idx| !parts[COMPONENT_KEYS[idx]].nil? }.max
    COMPONENT_KEYS.each_with_index do |key, idx|
      pattern = parts[key]
      if pattern.nil?
        after_boundary = base_url && last_specified && idx > last_specified
        if after_boundary
          pattern = COMPONENT_DEFAULTS[key]
        elsif base_components[key] && escaped_authority.include?(key)
          # Inherit literal pattern from baseURL for authority components
          pattern = base_components[key]
        elsif base_url && escaped_path.include?(key)
          # With a baseURL, path/query/fragment fall back to the (escaped) base value
          pattern = escape_pattern_string(base_components[key] || "")
        else
          pattern = COMPONENT_DEFAULTS[key]
        end
      end
      opaque = (key == :pathname) ? pathname_opaque : false
      @patterns[key] = URIPattern::ComponentPattern.new(pattern, component: key, ignore_case: ignore_case,
                                                         opaque_path: opaque)
    end
  end

  # Resolve a relative pattern pathname against the baseURL's path. This is pure
  # string manipulation — prepend the base path up to and including its last "/" —
  # so pattern-syntax characters ("{", "}", ":", …) are preserved rather than
  # percent-encoded by the URL parser.
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

  # A baseURL must be a parseable absolute URL (it needs a scheme). An empty
  # string or a relative reference is not valid.
  def valid_base_url?(base_url)
    return false if base_url.nil? || base_url.empty?
    if URIPattern::URLParser::WHATWG_AVAILABLE
      parsed = URI::WhatwgParser.new.split(base_url)
      scheme = parsed[URIPattern::URLParser::WHATWG_SCHEME]
      !scheme.nil? && !scheme.empty?
    else
      base_url.match?(/\A[a-zA-Z][a-zA-Z0-9+.\-]*:/)
    end
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
  rescue => _
    {}
  end

  def special_scheme?(protocol_pattern)
    SPECIAL_SCHEMES.include?(protocol_pattern.downcase.gsub(/[^a-z]/, ""))
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
    if effective_base
      base_components = URIPattern::URLParser.split_components(effective_base) rescue {}
      raw = {}
      COMPONENT_KEYS.each do |k|
        raw[k] = normalized.key?(k) ? normalized[k].to_s : (base_components[k] || "")
      end
      if normalized.key?(:pathname) && !normalized[:pathname].to_s.start_with?("/")
        raw[:pathname] = resolve_relative_pathname(normalized[:pathname].to_s, effective_base)
      end
      normalized_raw = URIPattern::URLParser.normalize_hash_input(raw)
      return nil if normalized_raw.nil?
      normalized_raw
    else
      raw = {}
      COMPONENT_KEYS.each { |k| raw[k] = normalized[k]&.to_s || "" }
      normalized_raw = URIPattern::URLParser.normalize_hash_input(raw)
      return nil if normalized_raw.nil?
      normalized_raw
    end
  rescue URIPattern::Error
    nil
  end

  def resolve_relative_pathname(pathname, base_url)
    return pathname if pathname.empty?
    if URIPattern::URLParser::WHATWG_AVAILABLE
      parsed = URI::WhatwgParser.new.split("#{base_url.chomp("/")}/#{pathname.sub(%r{\A/+}, "")}")
      parsed[URIPattern::URLParser::WHATWG_PATH] || pathname
    else
      base_path = URI.parse(base_url).path rescue "/"
      base_dir = base_path.end_with?("/") ? base_path : File.dirname(base_path) + "/"
      URI.join(base_url.split("?").first, base_dir + pathname.sub(%r{\A/+}, "")).path rescue pathname
    end
  rescue
    pathname
  end
end
