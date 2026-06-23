# frozen_string_literal: true

require "uri"
require "uri/whatwg_parser"

class URIPattern
  module URLParser
    module_function

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

    SPECIAL_SCHEMES_SET = Set.new(%w[http https ws wss ftp file]).freeze

    # --- "dummy URL" canonicalization of a fixed pattern run --------------------
    #
    # The WHATWG URLPattern spec canonicalizes each fixed-text part of a pattern by
    # running it through a throwaway ("dummy") URL, so the URL parser applies the
    # exact spec percent-encode set and (for pathname) dot-segment handling. We
    # delegate here instead of maintaining encode-set tables by hand, which both
    # simplifies the code and tracks the spec precisely.
    #
    # DUMMY_URL is the spec's "create a dummy URL" input verbatim
    # (https://urlpattern.spec.whatwg.org/ — "Let dummyInput be `https://dummy.invalid/`").
    DUMMY_URL = "https://dummy.invalid/"

    # Parse the dummy URL once and hand out dups. Re-running the basic URL parser on
    # every canonicalization is the dominant cost here (~13x a dup); the component
    # setters reassign their ivars rather than mutating in place, so dups never
    # corrupt the shared template (verified across all five setters).
    DUMMY_URL_TEMPLATE = URI::WhatwgParser.new.parse(DUMMY_URL)

    # No-encode fast paths (cf. PATHNAME_NO_ENCODE_RE): each encode set acts per code
    # point, and — unlike pathname — these components have no cross-character
    # transform (no dot-segments). So a run made solely of code points that are NOT
    # in the component's percent-encode set, and that carry no positional meaning,
    # needs no encoding and is returned unchanged by the URL parser; we can skip the
    # dummy-URL parse (~70x). Each class below is printable ASCII minus exactly that
    # encode set:
    #   search:   special-query set ("\"#'<>") + the "?" query terminator
    #   hash:     fragment set ("\"#<>`")  ("#" cannot survive a fragment run)
    #   userinfo: userinfo set ("\"#/:;<=>?@[\\]^`{|}"), used for username & password
    # These classes were derived to equal the parser's true no-encode set exactly and
    # confirmed identical over large random-run fuzzing; broaden only with re-checks.
    SEARCH_NO_ENCODE_RE   = /\A[\x21-\x7e&&[^"#'<>?]]*\z/
    HASH_NO_ENCODE_RE     = /\A[\x21-\x7e&&[^"#<>`]]*\z/
    USERINFO_NO_ENCODE_RE = /\A[\x21-\x7e&&[^"#\/:;<=>?@\[\\\]^`{|}]]*\z/

    # A non-opaque pathname run made only of these code points (note: no ".", so no
    # dot-segments; no "?"/"#", so no termination; none in the path percent-encode
    # set) needs no encoding and is returned unchanged by the URL parser. Skipping
    # the parse for such runs — the common case, e.g. "/users/" — is a large
    # construction-time win.
    PATHNAME_NO_ENCODE_RE = %r{\A[A-Za-z0-9\-_~/]*\z}

    def split_components(url, base_url: nil)
      url = resolve(url, base_url) if base_url && !url.empty?
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
    rescue URIPattern::Error
      raise
    rescue => e
      raise URIPattern::Error, "Failed to parse URL #{url.inspect}: #{e.message}"
    end

    def resolve(relative, base_url)
      URI::WhatwgParser.new.parse(relative, base: base_url).to_s
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

    # Normalize a hostname: IDN, and strip CR/LF/tab.
    def normalize_hostname_input(hostname)
      return "" if hostname.nil? || hostname.empty?
      h = hostname.gsub(/[\r\n\t]/, "")
      return "" if h.empty?
      URI::WhatwgParser.new.split("https://#{h}/")[WHATWG_HOST] || h
    rescue
      h
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
          canonicalize_pathname_run(v.to_s, opaque_path: opaque_path)
        when :hostname
          normalize_hostname_input(v.to_s)
        when :username
          canonicalize_username_run(v.to_s)
        when :password
          canonicalize_password_run(v.to_s)
        when :query
          canonicalize_search_run(v.to_s)
        when :fragment
          canonicalize_hash_run(v.to_s)
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

    # "canonicalize a protocol" on a fixed pattern run. Unlike the other components,
    # the spec explicitly does NOT use a state override here (the scheme setter would
    # enforce restrictions inappropriate for a pattern fragment); instead it parses
    # the run as the scheme of a dummy URL through the normal entry point and reads
    # back the validated, lowercased scheme.
    def canonicalize_protocol_run(run)
      return run if run.empty?
      parsed = URI::WhatwgParser.new.split("#{run}://dummy.invalid/")
      parsed[WHATWG_SCHEME].to_s
    rescue => e
      raise URIPattern::Error, "Invalid protocol #{run.inspect}: #{e.message}"
    end

    # Hand out a dup of the pre-parsed dummy URL template for "dummy URL"
    # canonicalization of a fixed pattern run.
    def dummy_url
      DUMMY_URL_TEMPLATE.dup
    end

    # "canonicalize a search" / "...hash" / "...username" / "...password": the
    # polyfill sets the corresponding URL component and reads it back. The
    # uri-whatwg_parser setters run the basic URL parser with the matching state
    # override and apply the spec encode sets (special-query for search, userinfo
    # for username/password, etc.).
    def canonicalize_search_run(run)
      return run if run.match?(SEARCH_NO_ENCODE_RE)
      u = dummy_url
      u.query = run
      u.query.to_s
    rescue => e
      raise URIPattern::Error, "Invalid search #{run.inspect}: #{e.message}"
    end

    def canonicalize_hash_run(run)
      return run if run.match?(HASH_NO_ENCODE_RE)
      u = dummy_url
      u.fragment = run
      u.fragment.to_s
    rescue => e
      raise URIPattern::Error, "Invalid hash #{run.inspect}: #{e.message}"
    end

    def canonicalize_username_run(run)
      return run if run.match?(USERINFO_NO_ENCODE_RE)
      u = dummy_url
      u.user = run
      u.user.to_s
    rescue => e
      raise URIPattern::Error, "Invalid username #{run.inspect}: #{e.message}"
    end

    def canonicalize_password_run(run)
      return run if run.match?(USERINFO_NO_ENCODE_RE)
      u = dummy_url
      u.password = run
      u.password.to_s
    rescue => e
      raise URIPattern::Error, "Invalid password #{run.inspect}: #{e.message}"
    end

    # "canonicalize a pathname" / "canonicalize an opaque pathname": run the fixed
    # text through a dummy URL with the spec's per-component state override rather
    # than a full URL parse, so the basic URL parser applies the path/opaque-path
    # state exactly as https://urlpattern.spec.whatwg.org/ defines.
    def canonicalize_pathname_run(run, opaque_path: false)
      return run if run.empty?
      return run if !opaque_path && run.match?(PATHNAME_NO_ENCODE_RE)
      if opaque_path
        # "canonicalize an opaque pathname": parse the run with OPAQUE PATH STATE as
        # the state override. uri-whatwg_parser has no opaque-path setter, but
        # parsing "data:" + run routes the run straight through opaque path state
        # (which percent-encodes with the C0-control set and terminates on "?"/"#"
        # regardless of state override), giving the identical result.
        parsed = URI::WhatwgParser.new.split("data:#{run}")
        (parsed[WHATWG_OPAQUE_PATH] || parsed[WHATWG_PATH]).to_s
      else
        # "canonicalize a pathname": run the fixed text through the basic URL parser
        # with PATH START STATE as the state override (uri-whatwg_parser's path=
        # setter calls split(..., state_override: :path_start_state)). With the
        # override set, "?"/"#" are part of the path and percent-encoded instead of
        # terminating it. The spec prepends "/-" to a non-"/"-prefixed run so the
        # parser does not add its own leading slash (and the "-" stops a leading dot
        # from collapsing); both inserted characters are dropped from the result.
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
  # Walks the (regexp-coalesced) token list with a state machine, recording each
  # component into `result` as it is delimited. Component keys use the spec names
  # (`:search` / `:hash`); URLParser.split_pattern maps them to `:query` / `:fragment`.
  class ConstructorStringParser
    NON_SPECIAL_CHAR_TYPES = %i[char escaped_char invalid_char].freeze
    SEARCH_PREFIX_BLOCKERS = %i[name regexp close asterisk].freeze

    # A protocol made of only scheme code points (no pattern metacharacters)
    # compiles to an anchored exact-match regexp, so it is a special scheme iff it
    # equals one verbatim (case-sensitive, like the regexp). Skip building a whole
    # ComponentPattern + Regexp in that common case.
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

      apply_implicit_defaults(new_state) if @state != :init && new_state != :done

      change_state_without_setting_component(new_state, skip)
    end

    # Advance to +new_state+, skipping +skip+ tokens and marking the new component's
    # start, without finalizing the current component or applying defaults. Mirrors
    # the spec/polyfill "change state without setting component" helper.
    def change_state_without_setting_component(new_state, skip)
      @state = new_state
      @token_index += skip
      @component_start = @token_index
      @token_increment = 0
    end

    # When a transition skips over earlier components, those components still need a
    # value. Per the spec's constructor-string parser, jumping from an authority-side
    # state straight to a later one fills the skipped slots with their defaults
    # (empty, or "/" for a special-scheme pathname). Driven by @state -> new_state.
    def apply_implicit_defaults(new_state)
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
        # Schemes are case-insensitive: "canonicalize a protocol" lowercases, so
        # compare the lowercased run against the special-scheme set.
        @protocol_special = URLParser::SPECIAL_SCHEMES_SET.include?(protocol_string.downcase)
        return
      end
      compiled = URIPattern::ComponentPattern.new(protocol_string, component: :protocol)
      @protocol_special = URLParser::SPECIAL_SCHEMES_SET.any? { |scheme| compiled.match(scheme) }
    rescue URIPattern::Error
      @protocol_special = false
    end
  end
end
