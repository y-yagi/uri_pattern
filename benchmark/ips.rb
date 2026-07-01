# frozen_string_literal: true

# Throughput benchmark for URIPattern (iterations per second).
#
#   ruby -Ilib benchmark/ips.rb
#
# Covers pattern construction (the allocation-heavy path) and matching against
# an already-compiled pattern.

require "uri_pattern"
require "benchmark/ips"

PATTERNS = {
  "simple"       => "https://example.com/",
  "named group"  => "https://example.com/books/:id",
  "regexp group" => "https://example.com/books/(\\d+)",
  "modifiers"    => "https://example.com/:category/:id?",
  "opaque"       => { protocol: "data", pathname: "text/:type" }
}.freeze

INPUTS = {
  "simple"       => "https://example.com/",
  "named group"  => "https://example.com/books/123",
  "regexp group" => "https://example.com/books/123",
  "modifiers"    => "https://example.com/fiction/42",
  "opaque"       => "data:text/plain"
}.freeze

puts "== construction =="
Benchmark.ips do |x|
  PATTERNS.each do |name, pat|
    x.report("new: #{name}") { URIPattern.new(pat) }
  end
  x.compare!
end

puts "\n== match? =="
Benchmark.ips do |x|
  PATTERNS.each do |name, pat|
    compiled = URIPattern.new(pat)
    input = INPUTS[name]
    x.report("match?: #{name}") { compiled.match?(input) }
  end
  x.compare!
end

puts "\n== match =="
Benchmark.ips do |x|
  PATTERNS.each do |name, pat|
    compiled = URIPattern.new(pat)
    input = INPUTS[name]
    x.report("match: #{name}") { compiled.match(input) }
  end
  x.compare!
end
