# frozen_string_literal: true

require "uri"

class URIPattern
  module URLParser
    WHATWG_AVAILABLE = begin
      require "uri/whatwg_parser"
      true
    rescue LoadError
      false
    end

    module_function

    def split_components(url, base_url: nil)
      url = resolve(url, base_url) if base_url && !url.empty?
      if WHATWG_AVAILABLE
        split_whatwg(url)
      else
        split_stdlib(url)
      end
    end

    def resolve(relative, base_url)
      if WHATWG_AVAILABLE
        URI::WhatwgParser.new.parse(relative, base: base_url).to_s
      else
        URI.join(base_url, relative).to_s
      end
    rescue => e
      raise URIPattern::Error, "Failed to resolve URL: #{e.message}"
    end

    # Parse a constructor string into its eight pattern components, following the
    # WHATWG URLPattern "parse a constructor string" algorithm:
    # https://urlpattern.spec.whatwg.org/#constructor-string-parsing
    #
    # Returns a hash keyed by the eight component symbols. A component that does not
    # appear in the input is left as nil so that defaults can be applied downstream.
    def split_pattern(pattern)
      tokens = URIPattern::Tokenizer.new(pattern, policy: :lenient).tokenize
      tokens = coalesce_regexp_tokens(tokens)
      raw = ConstructorStringParser.new(pattern, tokens).parse
      {
        protocol: raw[:protocol],
        username: raw[:username],
        password: raw[:password],
        hostname: raw[:hostname],
        port:     raw[:port],
        pathname: raw[:pathname],
        query:    raw[:search],
        fragment: raw[:hash]
      }
    end

    # The spec tokenizer emits a single "regexp" token for a `(...)` group. Our
    # tokenizer instead emits matching `:regexp_open` / `:regexp_close` tokens with
    # the group contents in between. Collapse each balanced group back into one
    # synthetic `:regexp` token (indexed at the opening paren) so the constructor
    # string parser sees the same token stream the spec describes.
    def coalesce_regexp_tokens(tokens)
      out = []
      i = 0
      n = tokens.length
      while i < n
        tok = tokens[i]
        if tok.type == :regexp_open
          depth = 1
          j = i + 1
          while j < n && depth > 0 && tokens[j].type != :end
            case tokens[j].type
            when :regexp_open  then depth += 1
            when :regexp_close then depth -= 1
            end
            break if depth.zero?
            j += 1
          end
          out << URIPattern::Tokenizer::Token.new(type: :regexp, value: nil, index: tok.index)
          # Skip past the matching close paren. When the group is unbalanced, leave
          # the terminating token (e.g. :end) in place for the parser to consume.
          i = (j < n && tokens[j].type == :regexp_close) ? j + 1 : j
        else
          out << tok
          i += 1
        end
      end
      out
    end

    # Indices in the array returned by URI::WhatwgParser#split:
    # [scheme, userinfo, host, port, nil, path, opaque_path, query, fragment]
    WHATWG_SCHEME      = 0
    WHATWG_USERINFO    = 1
    WHATWG_HOST        = 2
    WHATWG_PORT        = 3
    WHATWG_PATH        = 5
    WHATWG_OPAQUE_PATH = 6
    WHATWG_QUERY       = 7
    WHATWG_FRAGMENT    = 8

    DEFAULT_PORTS = {
      "http"  => 80,
      "https" => 443,
      "ws"    => 80,
      "wss"   => 443,
      "ftp"   => 21
    }.freeze

    def split_whatwg(url)
      parsed = URI::WhatwgParser.new.split(url)
      userinfo = parsed[WHATWG_USERINFO] || ""
      user, pass = userinfo.include?(":") ? userinfo.split(":", 2) : [userinfo, nil]
      {
        protocol: parsed[WHATWG_SCHEME] || "",
        username: user || "",
        password: pass || "",
        hostname: parsed[WHATWG_HOST] || "",
        port:     parsed[WHATWG_PORT] ? parsed[WHATWG_PORT].to_s : "",
        pathname: parsed[WHATWG_PATH] || parsed[WHATWG_OPAQUE_PATH] || "",
        query:    parsed[WHATWG_QUERY] || "",
        fragment: parsed[WHATWG_FRAGMENT] || ""
      }
    rescue => _e
      split_stdlib(url)
    end

    # Normalize a port string for use as a match input component.
    # Strips tabs, takes leading numeric digits, and suppresses the default port.
    # Returns nil if the port string has no leading digits (parse failure).
    def normalize_port_input(port_str, protocol = "")
      port = port_str.to_s.gsub(/[\t\f]/, "")
      digits = port.match(/\A\d*/)[0]
      return nil if digits.empty? && !port.empty?
      return nil if digits.length > 0 && digits.to_i > 65535
      default = DEFAULT_PORTS[protocol.to_s.downcase]
      default && default.to_s == digits ? "" : digits
    end

    # Path percent-encode set: characters that must be encoded in URL path components.
    PATH_ENCODE_RE = /[ "<>#?`{}]|[^\x00-\x7E]/
    # C0 encode set: only C0 controls, and characters > U+007E (non-ASCII), plus #<>?`
    # Used for opaque paths (non-special URL schemes without authority)
    OPAQUE_PATH_ENCODE_RE = /[#<>?`]|[^\x20-\x7E]/

    SPECIAL_SCHEMES_SET = Set.new(%w[http https ws wss ftp file]).freeze

    # Normalize a pathname for a hash match input. `opaque_path` is true for non-special schemes.
    # Absolute pathnames (starting with /) are fully normalized via WHATWG parser.
    # Relative pathnames are percent-encoded in place without changing the path structure.
    def normalize_pathname_input(pathname, opaque_path: false)
      return "" if pathname.nil? || pathname.empty?
      if pathname.start_with?("/")
        return pathname unless WHATWG_AVAILABLE
        URI::WhatwgParser.new.split("https://a#{pathname}")[WHATWG_PATH] || pathname
      elsif opaque_path
        # Opaque paths use C0 + {#<>?`} — space is NOT encoded
        pathname.gsub(OPAQUE_PATH_ENCODE_RE) { |c| c.bytes.map { |b| "%%%02X" % b }.join }
      else
        pathname.gsub(PATH_ENCODE_RE) { |c| c.bytes.map { |b| "%%%02X" % b }.join }
      end
    rescue
      pathname
    end

    # Normalize a hostname: IDN, and strip CR/LF/tab.
    def normalize_hostname_input(hostname)
      return "" if hostname.nil? || hostname.empty?
      h = hostname.gsub(/[\r\n\t]/, "")
      return "" if h.empty?
      return h unless WHATWG_AVAILABLE
      URI::WhatwgParser.new.split("https://#{h}/")[WHATWG_HOST] || h
    rescue
      h
    end

    # Percent-encode non-ASCII bytes in a string component.
    def percent_encode_component(str)
      return "" if str.nil?
      str.to_s.gsub(/[^\x00-\x7F]/) do |c|
        c.bytes.map { |b| "%%%02X" % b }.join
      end
    end

    # Normalize a hash input through WHATWG URL rules for each component.
    # Returns nil if a required component fails normalization.
    def normalize_hash_input(hash)
      protocol = hash[:protocol].to_s.downcase
      # Opaque path: non-special scheme, no username/password/hostname/port set
      opaque_path = !protocol.empty? && !SPECIAL_SCHEMES_SET.include?(protocol) &&
                    (hash[:hostname].nil? || hash[:hostname].to_s.empty?) &&
                    (hash[:username].nil? || hash[:username].to_s.empty?) &&
                    (hash[:password].nil? || hash[:password].to_s.empty?) &&
                    (hash[:port].nil? || hash[:port].to_s.empty?)
      result = {}
      hash.each do |k, v|
        result[k] = case k
        when :protocol
          norm = canonicalize_protocol_input(v.to_s)
          return nil if norm.nil?
          norm
        when :port
          norm = normalize_port_input(v.to_s, protocol)
          return nil if norm.nil?
          norm
        when :pathname
          normalize_pathname_input(v.to_s, opaque_path: opaque_path)
        when :hostname
          normalize_hostname_input(v.to_s)
        when :username, :password
          percent_encode_component(v.to_s)
        when :query, :fragment
          percent_encode_component(v.to_s)
        else
          v.to_s
        end
      end
      result
    end

    # "canonicalize a protocol" on a match input: a scheme is ASCII, starts with a
    # letter, and contains only letters, digits, "+", "-" and ".". A value with any
    # other code point (e.g. "café") cannot be a protocol, so matching fails.
    def canonicalize_protocol_input(value)
      return "" if value.empty?
      return nil unless value.match?(/\A[a-zA-Z][a-zA-Z0-9+.\-]*\z/)
      value.downcase
    end

    def split_stdlib(url)
      require "uri" unless defined?(URI)
      uri = URI::RFC2396_Parser.new.parse(url)
      # Opaque URIs (e.g. about:blank, data:...) have no host or path in the normal sense
      if uri.respond_to?(:opaque) && uri.opaque
        return {
          protocol: uri.scheme || "",
          username: "", password: "",
          hostname: "", port: "",
          pathname: uri.opaque || "",
          query:    uri.query || "",
          fragment: uri.fragment || ""
        }
      end
      {
        protocol: uri.scheme || "",
        username: uri.user || "",
        password: uri.password || "",
        hostname: uri.host || "",
        port:     explicit_port?(url, uri) ? uri.port.to_s : "",
        pathname: uri.path || "",
        query:    uri.query || "",
        fragment: uri.fragment || ""
      }
    rescue URI::InvalidURIError, URI::Error
      {
        protocol: "", username: "", password: "",
        hostname: "", port: "",
        pathname: url, query: "", fragment: ""
      }
    end

    def explicit_port?(url, uri)
      uri.port && url.match?(%r{://[^/]*:#{uri.port}(?:[/?#]|$)})
    end
  end

  # Implements the WHATWG URLPattern "constructor string parser" state machine.
  # https://urlpattern.spec.whatwg.org/#constructor-string-parsing
  #
  # Walks the (regexp-coalesced) token list with a state machine, recording each
  # component into `result` as it is delimited. Component keys use the spec names
  # (`:search` / `:hash`); URLParser.split_pattern maps them to `:query` / `:fragment`.
  class ConstructorStringParser
    NON_SPECIAL_CHAR_TYPES = %i[char escaped_char invalid_char].freeze
    SEARCH_PREFIX_BLOCKERS = %i[name regexp close asterisk].freeze

    def initialize(input, tokens)
      @input = input
      @tokens = tokens
      @result = {}
      @component_start = 0
      @token_index = 0
      @token_increment = 1
      @group_depth = 0
      @ipv6_depth = 0
      @protocol_special = false
      @state = :init
    end

    def parse
      while @token_index < @tokens.length
        @token_increment = 1

        if current.type == :end
          case @state
          when :init
            rewind
            if hash_prefix?
              change_state(:hash, 1)
            elsif search_prefix?
              change_state(:search, 1)
            else
              change_state(:pathname, 0)
            end
            @token_index += @token_increment
            next
          when :authority
            rewind_and_set_state(:hostname)
            @token_index += @token_increment
            next
          else
            change_state(:done, 0)
            break
          end
        end

        if group_open?
          @group_depth += 1
          @token_index += @token_increment
          next
        end

        if @group_depth.positive?
          if group_close?
            @group_depth -= 1
          else
            @token_index += @token_increment
            next
          end
        end

        step_state

        @token_index += @token_increment
      end

      @result[:port] = "" if @result.key?(:hostname) && !@result.key?(:port)
      @result
    end

    private

    def step_state
      case @state
      when :init
        rewind_and_set_state(:protocol) if protocol_suffix?
      when :protocol
        step_protocol
      when :authority
        if identity_terminator?
          rewind_and_set_state(:username)
        elsif pathname_start? || search_prefix? || hash_prefix?
          rewind_and_set_state(:hostname)
        end
      when :username
        if password_prefix?
          change_state(:password, 1)
        elsif identity_terminator?
          change_state(:hostname, 1)
        end
      when :password
        change_state(:hostname, 1) if identity_terminator?
      when :hostname
        step_hostname
      when :port
        step_port_or_pathname
      when :pathname
        if search_prefix?
          change_state(:search, 1)
        elsif hash_prefix?
          change_state(:hash, 1)
        end
      when :search
        change_state(:hash, 1) if hash_prefix?
      when :hash
        # nothing to do
      end
    end

    def step_protocol
      return unless protocol_suffix?

      compute_protocol_matches_special_scheme
      next_state = :pathname
      skip = 1
      if next_is_authority_slashes?
        next_state = :authority
        skip = 3
      elsif @protocol_special
        next_state = :authority
      end
      change_state(next_state, skip)
    end

    def step_hostname
      if ipv6_open?
        @ipv6_depth += 1
      elsif ipv6_close?
        @ipv6_depth -= 1
      elsif port_prefix? && @ipv6_depth.zero?
        change_state(:port, 1)
      else
        step_port_or_pathname
      end
    end

    def step_port_or_pathname
      if pathname_start?
        change_state(:pathname, 0)
      elsif search_prefix?
        change_state(:search, 1)
      elsif hash_prefix?
        change_state(:hash, 1)
      end
    end

    def current
      @tokens[@token_index]
    end

    # "get a safe token": out-of-range indices resolve to the trailing :end token.
    def safe_token(index)
      return @tokens[index] if index < @tokens.length
      @tokens[@tokens.length - 1]
    end

    def non_special_pattern_char?(index, value)
      token = safe_token(index)
      return false unless token.value == value
      NON_SPECIAL_CHAR_TYPES.include?(token.type)
    end

    def protocol_suffix?    = non_special_pattern_char?(@token_index, ":")
    def identity_terminator? = non_special_pattern_char?(@token_index, "@")
    def password_prefix?    = non_special_pattern_char?(@token_index, ":")
    def port_prefix?        = non_special_pattern_char?(@token_index, ":")
    def pathname_start?     = non_special_pattern_char?(@token_index, "/")
    def hash_prefix?        = non_special_pattern_char?(@token_index, "#")
    def ipv6_open?          = non_special_pattern_char?(@token_index, "[")
    def ipv6_close?         = non_special_pattern_char?(@token_index, "]")
    def group_open?         = current.type == :open
    def group_close?        = current.type == :close

    def search_prefix?
      return true if non_special_pattern_char?(@token_index, "?")
      return false unless current.value == "?"

      previous_index = @token_index - 1
      return true if previous_index.negative?

      !SEARCH_PREFIX_BLOCKERS.include?(safe_token(previous_index).type)
    end

    def next_is_authority_slashes?
      non_special_pattern_char?(@token_index + 1, "/") &&
        non_special_pattern_char?(@token_index + 2, "/")
    end

    def change_state(new_state, skip)
      unless %i[init authority done].include?(@state)
        @result[@state] = make_component_string
      end

      if @state != :init && new_state != :done
        if %i[protocol authority username password].include?(@state) &&
           %i[port pathname search hash].include?(new_state) &&
           !@result.key?(:hostname)
          @result[:hostname] = ""
        end
        if %i[protocol authority username password hostname port].include?(@state) &&
           %i[search hash].include?(new_state) &&
           !@result.key?(:pathname)
          @result[:pathname] = @protocol_special ? "/" : ""
        end
        if %i[protocol authority username password hostname port pathname].include?(@state) &&
           new_state == :hash &&
           !@result.key?(:search)
          @result[:search] = ""
        end
      end

      @state = new_state
      @token_index += skip
      @component_start = @token_index
      @token_increment = 0
    end

    def rewind
      @token_index = @component_start
      @token_increment = 0
    end

    def rewind_and_set_state(new_state)
      rewind
      @state = new_state
    end

    def make_component_string
      token = @tokens[@token_index]
      start_token = safe_token(@component_start)
      @input[start_token.index...token.index]
    end

    def compute_protocol_matches_special_scheme
      protocol_string = make_component_string
      compiled = URIPattern::ComponentPattern.new(protocol_string, component: :protocol)
      @protocol_special = URLParser::SPECIAL_SCHEMES_SET.any? { |scheme| compiled.match(scheme) }
    rescue URIPattern::Error
      @protocol_special = false
    end
  end
end
