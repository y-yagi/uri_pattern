# frozen_string_literal: true

class URIPattern
  ComponentResult = Struct.new(:input, :groups, keyword_init: true)

  class MatchResult
    # +inputs+ is the array of arguments passed to #match: [input] or
    # [input, base_url], mirroring URLPatternResult.inputs in the spec.
    attr_reader :inputs, :protocol, :username, :password, :hostname,
                :port, :pathname, :query, :fragment

    def initialize(inputs:, protocol:, username:, password:, hostname:,
                   port:, pathname:, query:, fragment:)
      @inputs   = inputs
      @protocol = protocol
      @username = username
      @password = password
      @hostname = hostname
      @port     = port
      @pathname = pathname
      @query    = query
      @fragment = fragment
    end
  end
end
