# frozen_string_literal: true

class URIPattern
  ComponentResult = Struct.new(:input, :groups, keyword_init: true)

  class MatchResult
    attr_reader :input, :protocol, :username, :password, :hostname,
                :port, :pathname, :query, :fragment

    def initialize(input:, protocol:, username:, password:, hostname:,
                   port:, pathname:, query:, fragment:)
      @input    = input
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
