# frozen_string_literal: true

class URIPattern
  ComponentResult = Data.define(:input, :groups)

  # +inputs+ mirrors URLPatternResult.inputs: [input] or [input, base_url].
  #
  # Member order matches URIPattern::COMPONENT_KEYS (kept in sync by hand: require
  # order means COMPONENT_KEYS is not yet defined when this file loads).
  MatchResult = Data.define(:inputs, :protocol, :username, :password,
                            :hostname, :port, :pathname, :query, :fragment)
end
