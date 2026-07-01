# frozen_string_literal: true

# Object-allocation benchmark for URIPattern.
#
# Reports how many objects each operation allocates, split by construction
# (URIPattern.new) versus matching (#match? / #match). Run before and after a
# change to see the effect on allocation counts:
#
#   ruby -Ilib benchmark/allocations.rb
#
# GC is disabled around each measured block so freed objects do not hide
# allocations; count_objects gives the gross number created.

require "uri_pattern"
require "objspace"

PATTERNS = {
  "simple"         => "https://example.com/",
  "named group"    => "https://example.com/books/:id",
  "regexp group"   => "https://example.com/books/(\\d+)",
  "modifiers"      => "https://example.com/:category/:id?",
  "opaque (data:)" => { protocol: "data", pathname: "text/:type" },
  "hash input"     => { protocol: "https", hostname: "example.com", pathname: "/books/:id" }
}.freeze

# Concrete inputs to match against each compiled pattern.
INPUTS = {
  "simple"         => "https://example.com/",
  "named group"    => "https://example.com/books/123",
  "regexp group"   => "https://example.com/books/123",
  "modifiers"      => "https://example.com/fiction/42",
  "opaque (data:)" => "data:text/plain",
  "hash input"     => "https://example.com/books/123"
}.freeze

def count_alloc
  GC.disable
  before = ObjectSpace.count_objects.dup
  yield
  after = ObjectSpace.count_objects
  GC.enable
  total = (after[:TOTAL] - after[:FREE]) - (before[:TOTAL] - before[:FREE])
  keys = %i[T_STRING T_STRUCT T_ARRAY T_HASH T_MATCH T_REGEXP T_OBJECT T_DATA]
  breakdown = keys.filter_map do |k|
    d = after[k].to_i - before[k].to_i
    "#{k.to_s.sub('T_', '')}=#{d}" if d > 0
  end
  [total, breakdown.join(" ")]
end

# Warm up autoloads / frozen constants so first-call bookkeeping is excluded.
PATTERNS.each_value { |p| URIPattern.new(p) }

puts "== construction (URIPattern.new) =="
PATTERNS.each do |name, pat|
  total, detail = count_alloc { URIPattern.new(pat) }
  puts format("  %-16s total=%-5d %s", name, total, detail)
end

puts "\n== match? =="
PATTERNS.each do |name, pat|
  compiled = URIPattern.new(pat)
  input = INPUTS[name]
  compiled.match?(input) # warm up
  total, detail = count_alloc { compiled.match?(input) }
  puts format("  %-16s total=%-5d %s", name, total, detail)
end

puts "\n== match =="
PATTERNS.each do |name, pat|
  compiled = URIPattern.new(pat)
  input = INPUTS[name]
  compiled.match(input) # warm up
  total, detail = count_alloc { compiled.match(input) }
  puts format("  %-16s total=%-5d %s", name, total, detail)
end
