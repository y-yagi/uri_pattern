# frozen_string_literal: true

require "uri/whatwg_parser"

class URIPattern
  module URLParser
    module_function

    # Indices in the array returned by URI::WhatwgParser#split:
    # [scheme, userinfo, host, port, nil, path, opaque_path, query, fragment]
    SCHEME      = 0
    USERINFO    = 1
    HOST        = 2
    PORT        = 3
    PATH        = 5
    OPAQUE_PATH = 6
    QUERY       = 7
    FRAGMENT    = 8

    DEFAULT_PORTS = URI::WhatwgParser::SPECIAL_SCHEME.reject{ |_, v| v.nil? }.freeze
    SPECIAL_SCHEMES_SET = Set.new(URI::WhatwgParser::SPECIAL_SCHEME.keys).freeze

    # Whether a compiled component pattern can match at least one special scheme
    # name.
    def special_scheme_pattern?(component_pattern)
      SPECIAL_SCHEMES_SET.any? { |scheme| component_pattern.match(scheme) }
    end

    AUTHORITY_KEYS = %i[hostname username password port].freeze

    # Whether none of the authority components (hostname/username/password/port)
    # are set.
    def authority_empty?(components)
      AUTHORITY_KEYS.all? { |k| components[k].to_s.empty? }
    end

    # --- "dummy URL" canonicalization of a fixed pattern run --------------------
    #
    # The WHATWG URLPattern spec canonicalizes each fixed-text part of a pattern by
    # running it through a throwaway ("dummy") URL, so the URL parser applies the
    # exact spec percent-encode set and (for pathname) dot-segment handling. We
    # delegate here instead of maintaining encode-set tables by hand.
    #
    # DUMMY_URL is the spec's "create a dummy URL" input verbatim.
    DUMMY_URL = "https://dummy.invalid/"

    DUMMY_URL_TEMPLATE = URI::WHATWG_PARSER.parse(DUMMY_URL)

    # No-encode fast paths (cf. PATHNAME_NO_ENCODE_RE): these encode sets act per
    # code point with no cross-character transform, so a run made solely of code
    # points outside the component's encode set is returned unchanged by the URL
    # parser and the dummy-URL parse can be skipped (~70x). Each class below is
    # printable ASCII minus exactly that encode set:
    #   search:   special-query set ("\"#'<>") + the "?" query terminator
    #   hash:     fragment set ("\"#<>`")  ("#" cannot survive a fragment run)
    #   userinfo: userinfo set ("\"#/:;<=>?@[\\]^`{|}"), used for username & password
    # These classes were confirmed identical to the parser's true no-encode set over
    # large random-run fuzzing; broaden only with re-checks.
    SEARCH_NO_ENCODE_RE   = /\A[\x21-\x7e&&[^"#'<>?]]*\z/
    HASH_NO_ENCODE_RE     = /\A[\x21-\x7e&&[^"#<>`]]*\z/
    USERINFO_NO_ENCODE_RE = /\A[\x21-\x7e&&[^"#\/:;<=>?@\[\\\]^`{|}]]*\z/

    # A non-opaque pathname run made only of these code points (note: no ".", so no
    # dot-segments; no "?"/"#", so no termination; none in the path percent-encode
    # set) needs no encoding. Skipping the parse for such runs — the common case,
    # e.g. "/users/" — is a large construction-time win.
    PATHNAME_NO_ENCODE_RE = %r{\A[A-Za-z0-9\-_~/]*\z}

    def split_components(url, base_url: nil)
      url = resolve(url, base_url) if base_url && !url.empty?
      parsed = URI::WHATWG_PARSER.split(url)
      userinfo = parsed[USERINFO] || ""
      user, pass = userinfo.include?(":") ? userinfo.split(":", 2) : [userinfo, nil]
      {
        protocol: parsed[SCHEME] || "",
        username: user || "",
        password: pass || "",
        hostname: parsed[HOST] || "",
        port:     parsed[PORT] ? parsed[PORT].to_s : "",
        pathname: parsed[PATH] || parsed[OPAQUE_PATH] || "",
        query:    parsed[QUERY] || "",
        fragment: parsed[FRAGMENT] || ""
      }
    rescue URIPattern::Error
      raise
    rescue => e
      raise URIPattern::Error, "Failed to parse URL #{url.inspect}: #{e.message}"
    end

    def resolve(relative, base_url)
      URI::WHATWG_PARSER.parse(relative, base: base_url).to_s
    rescue => e
      raise URIPattern::Error, "Failed to resolve URL: #{e.message}"
    end

    # Parse a constructor string following the
    # WHATWG URLPattern "parse a constructor string" algorithm:
    # https://urlpattern.spec.whatwg.org/#constructor-string-parsing
    def split_pattern(pattern)
      tokens = URIPattern::Tokenizer.new(pattern, policy: :lenient).tokenize
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

    # Normalize a port string for use as a match input component: strip tabs, take
    # leading digits, suppress the default port. Returns nil on a parse failure.
    def normalize_port_input(port_str, protocol = "")
      port = port_str.to_s.gsub(/[\t\f]/, "")
      digits = port.match(/\A\d*/)[0]
      return nil if digits.empty? && !port.empty?
      return nil if digits.length > 0 && digits.to_i > 65535
      default = DEFAULT_PORTS[protocol.to_s.downcase]
      default && default.to_s == digits ? "" : digits
    end

    # Normalize a hostname: IDN, and strip CR/LF/tab.
    def normalize_hostname_input(hostname)
      return "" if hostname.nil? || hostname.empty?
      h = hostname.gsub(/[\r\n\t]/, "")
      return "" if h.empty?
      URI::WHATWG_PARSER.split("https://#{h}/")[HOST] || h
    rescue
      h
    end

    # Normalize a hash input through WHATWG URL rules for each component.
    # Returns nil if a required component fails normalization.
    def normalize_hash_input(hash)
      protocol = hash[:protocol].to_s.downcase
      # Opaque path: non-special scheme, no username/password/hostname/port set
      opaque_path = !protocol.empty? && !SPECIAL_SCHEMES_SET.include?(protocol) && authority_empty?(hash)
      result = {}
      hash.each do |k, v|
        value = normalize_input_component(k, v.to_s, protocol:, opaque_path:)
        return nil if value.nil?
        result[k] = value
      end
      result
    end

    # Normalize a single match-input hash component. Only :protocol and :port can
    # fail (returning nil, which normalize_hash_input propagates); every other
    # component either canonicalizes successfully or raises URIPattern::Error.
    def normalize_input_component(key, value, protocol:, opaque_path:)
      case key
      when :protocol
        canonicalize_protocol_input(value)
      when :port
        normalize_port_input(value, protocol)
      when :pathname
        canonicalize_pathname(value, opaque_path:)
      when :hostname
        normalize_hostname_input(value)
      when :username
        canonicalize_username(value)
      when :password
        canonicalize_password(value)
      when :query
        canonicalize_search(value)
      when :fragment
        canonicalize_hash(value)
      else
        value
      end
    end

    # "canonicalize a protocol" on a match input: a scheme is ASCII, starts with a
    # letter, and contains only letters, digits, "+", "-" and "."; a value with any
    # other code point (e.g. "café") cannot be a protocol, so matching fails.
    def canonicalize_protocol_input(value)
      return "" if value.empty?
      return nil unless value.match?(/\A[a-zA-Z][a-zA-Z0-9+.\-]*\z/)
      value.downcase
    end

    # "canonicalize a protocol" on a fixed pattern run. Unlike the other components,
    # the spec explicitly does NOT use a state override here (the scheme setter would
    # enforce restrictions inappropriate for a pattern fragment); instead it parses
    # the run as the scheme of a dummy URL and reads back the lowercased scheme.
    def canonicalize_protocol(run)
      return run if run.empty?
      parsed = URI::WHATWG_PARSER.split("#{run}://dummy.invalid/")
      parsed[SCHEME].to_s
    rescue => e
      raise URIPattern::Error, "Invalid protocol #{run.inspect}: #{e.message}"
    end

    def dummy_url
      DUMMY_URL_TEMPLATE.dup
    end

    # "canonicalize a search" / "...hash" / "...username" / "...password": set the
    # corresponding URL component on a dummy URL and read it back, so the
    # uri-whatwg_parser setters run the basic URL parser with the matching state
    # override and encode set. All four share the same shape, factored into
    # canonicalize_via_dummy_url below.
    DUMMY_CANONICALIZERS = {
      search:   [SEARCH_NO_ENCODE_RE,   :query=,    :query],
      hash:     [HASH_NO_ENCODE_RE,     :fragment=, :fragment],
      username: [USERINFO_NO_ENCODE_RE, :user=,     :user],
      password: [USERINFO_NO_ENCODE_RE, :password=, :password]
    }.freeze

    def canonicalize_via_dummy_url(kind, run)
      no_encode, writer, reader = DUMMY_CANONICALIZERS.fetch(kind)
      return run if run.match?(no_encode)
      u = dummy_url
      u.public_send(writer, run)
      u.public_send(reader).to_s
    rescue => e
      raise URIPattern::Error, "Invalid #{kind} #{run.inspect}: #{e.message}"
    end

    def canonicalize_search(run)   = canonicalize_via_dummy_url(:search, run)
    def canonicalize_hash(run)     = canonicalize_via_dummy_url(:hash, run)
    def canonicalize_username(run) = canonicalize_via_dummy_url(:username, run)
    def canonicalize_password(run) = canonicalize_via_dummy_url(:password, run)

    # "canonicalize a pathname" / "canonicalize an opaque pathname": run the fixed
    # text through a dummy URL with the spec's per-component state override rather
    # than a full URL parse.
    def canonicalize_pathname(run, opaque_path: false)
      return run if run.empty?
      return run if !opaque_path && run.match?(PATHNAME_NO_ENCODE_RE)
      if opaque_path
        # uri-whatwg_parser has no opaque-path setter, but parsing "data:" + run
        # routes the run straight through opaque path state (C0-control encode set,
        # terminating on "?"/"#" regardless of state override), giving the identical
        # result.
        parsed = URI::WHATWG_PARSER.split("data:#{run}")
        (parsed[OPAQUE_PATH] || parsed[PATH]).to_s
      else
        # PATH START STATE as the state override (uri-whatwg_parser's path= setter),
        # so "?"/"#" are part of the path and percent-encoded instead of terminating
        # it. The spec prepends "/-" to a non-"/"-prefixed run so the parser does not
        # add its own leading slash (and the "-" stops a leading dot from
        # collapsing); both inserted characters are dropped from the result.
        lead = run.start_with?("/")
        modified = lead ? run : "/-#{run}"
        u = dummy_url
        u.path = modified
        pathname = u.path.to_s
        lead ? pathname : pathname[2..]
      end
    rescue => e
      raise URIPattern::Error, "Invalid pathname #{run.inspect}: #{e.message}"
    end
  end

  # Implements the WHATWG URLPattern "constructor string parser" state machine.
  # https://urlpattern.spec.whatwg.org/#constructor-string-parsing
  #
  # Component keys use the spec names (`:search` / `:hash`); URLParser.split_pattern
  # maps them to `:query` / `:fragment`.
  class ConstructorStringParser
    NON_SPECIAL_CHAR_TYPES = %i[char escaped_char invalid_char].freeze
    SEARCH_PREFIX_BLOCKERS = %i[name regexp close asterisk].freeze

    HOSTNAME_DEFAULT_FROM = %i[protocol authority username password].freeze
    HOSTNAME_DEFAULT_TO = %i[port pathname search hash].freeze
    PATHNAME_DEFAULT_FROM = %i[protocol authority username password hostname port].freeze
    PATHNAME_DEFAULT_TO = %i[search hash].freeze
    SEARCH_DEFAULT_FROM = %i[protocol authority username password hostname port pathname].freeze
    # States that do not correspond to a stored component string in change_state.
    NON_COMPONENT_STATES = %i[init authority done].freeze

    # A protocol made of only scheme code points (no pattern metacharacters) compiles
    # to an anchored exact-match regexp, so it is a special scheme iff it equals one
    # verbatim — skip building a whole ComponentPattern + Regexp in that case.
    LITERAL_SCHEME_RE = /\A[a-zA-Z0-9+.\-]+\z/

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
          break unless step_end_state
        elsif group_open?
          @group_depth += 1
        elsif @group_depth.positive?
          if group_close?
            @group_depth -= 1
            step_state
          end
        else
          step_state
        end

        @token_index += @token_increment
      end

      @result[:port] = "" if @result.key?(:hostname) && !@result.key?(:port)
      @result
    end

    private

    # Handle the trailing :end token. :init and :authority still have a component to
    # close out (rewinding to re-derive it from what follows), so they return true
    # and let the main loop's token_index bump apply; any other state finalizes the
    # last component and returns false to stop the loop.
    def step_end_state
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
        true
      when :authority
        rewind_and_set_state(:hostname)
        true
      else
        change_state(:done, 0)
        false
      end
    end

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

    def protocol_suffix?     = non_special_pattern_char?(@token_index, ":")
    def identity_terminator? = non_special_pattern_char?(@token_index, "@")
    def password_prefix?     = non_special_pattern_char?(@token_index, ":")
    def port_prefix?         = non_special_pattern_char?(@token_index, ":")
    def pathname_start?      = non_special_pattern_char?(@token_index, "/")
    def hash_prefix?         = non_special_pattern_char?(@token_index, "#")
    def ipv6_open?           = non_special_pattern_char?(@token_index, "[")
    def ipv6_close?          = non_special_pattern_char?(@token_index, "]")
    def group_open?          = current.type == :open
    def group_close?         = current.type == :close

    def search_prefix?
      return true if non_special_pattern_char?(@token_index, "?")
      return false unless current.value == "?"

      previous_index = @token_index - 1
      return true if previous_index.negative?

      !SEARCH_PREFIX_BLOCKERS.include?(safe_token(previous_index).type)
    end

    def next_is_authority_slashes?
      non_special_pattern_char?(@token_index + 1, "/") && non_special_pattern_char?(@token_index + 2, "/")
    end

    def change_state(new_state, skip)
      unless NON_COMPONENT_STATES.include?(@state)
        @result[@state] = make_component_string
      end

      apply_implicit_defaults(new_state) if @state != :init && new_state != :done

      change_state_without_setting_component(new_state, skip)
    end

    # Advance to +new_state+, skipping +skip+ tokens and marking the new component's
    # start, without finalizing the current component or applying defaults.
    def change_state_without_setting_component(new_state, skip)
      @state = new_state
      @token_index += skip
      @component_start = @token_index
      @token_increment = 0
    end

    # When a transition skips over earlier components, those components still need a
    # When a transition skips over earlier components, those components still need a
    # value: per the spec's constructor-string parser, the skipped slots get their
    # defaults (empty, or "/" for a special-scheme pathname).
    def apply_implicit_defaults(new_state)
      if HOSTNAME_DEFAULT_FROM.include?(@state) &&
         HOSTNAME_DEFAULT_TO.include?(new_state) &&
         !@result.key?(:hostname)
        @result[:hostname] = ""
      end
      if PATHNAME_DEFAULT_FROM.include?(@state) &&
         PATHNAME_DEFAULT_TO.include?(new_state) &&
         !@result.key?(:pathname)
        @result[:pathname] = @protocol_special ? "/" : ""
      end
      if SEARCH_DEFAULT_FROM.include?(@state) &&
         new_state == :hash &&
         !@result.key?(:search)
        @result[:search] = ""
      end
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
      if protocol_string.match?(LITERAL_SCHEME_RE)
        # Schemes are case-insensitive: "canonicalize a protocol" lowercases.
        @protocol_special = URLParser::SPECIAL_SCHEMES_SET.include?(protocol_string.downcase)
        return
      end
      compiled = URIPattern::ComponentPattern.new(protocol_string, component: :protocol)
      @protocol_special = URLParser.special_scheme_pattern?(compiled)
    rescue URIPattern::Error
      @protocol_special = false
    end
  end
end
