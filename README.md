# URIPattern

Ruby port of the [WHATWG URLPattern specification](https://urlpattern.spec.whatwg.org/).

It lets you match URLs against patterns that contain named groups, wildcards, optional segments, and custom regular expressions, and read the captured values back out — the same matching model the `URLPattern` API provides in browsers, adapted to Ruby conventions (snake_case, keyword arguments, and `nil` in place of `undefined`).

## Installation

Install the gem and add it to the application's Gemfile by executing:

```bash
bundle add uri_pattern
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
gem install uri_pattern
```

## Usage

### Constructing a pattern

A pattern can be built from a full URL pattern string, or from a hash of
per-component pattern strings. Any component you omit defaults to the wildcard
`*`.

```ruby
require "uri_pattern"

# From a string
pattern = URIPattern.new("https://example.com/users/:id")

# From a hash of components
pattern = URIPattern.new({ hostname: "example.com", pathname: "/users/:id" })

# A relative pattern, resolved against a base URL
pattern = URIPattern.new("/users/:id", "https://example.com")

# Case-insensitive matching
pattern = URIPattern.new("https://example.com/Users/:id", ignore_case: true)
```

Pattern strings may use the special `{ }` syntax to group a run of text
together. A group acts as a single unit, so a modifier such as `?` (optional),
`+` (one or more), or `*` (zero or more) placed after the closing brace applies
to the whole group rather than to a single character:

```ruby
# "{s}?" makes the "s" optional, so the protocol matches both http and https
pattern = URIPattern.new({ protocol: "http{s}?:" })
pattern.match?("http://example.com")   # => true
pattern.match?("https://example.com")  # => true

# A group can wrap a named segment to make a whole path segment optional
pattern = URIPattern.new({ pathname: "/books{/:id}?" })
pattern.match?("https://example.com/books")      # => true
pattern.match?("https://example.com/books/123")  # => true
pattern.match("https://example.com/books/123").pathname.groups  # => { "id" => "123" }
```

### Testing for a match

`#match?` returns a boolean and is the fastest way to check a URL:

```ruby
pattern = URIPattern.new("https://example.com/users/:id")

pattern.match?("https://example.com/users/42")  # => true
pattern.match?("https://example.com/posts/42")  # => false
pattern.match?("https://other.com/users/42")    # => false
```

### Capturing values

`#match` returns a `URIPattern::MatchResult` on success, or `nil` when the URL
does not match. Each component exposes its matched `input` and named `groups`:

```ruby
pattern = URIPattern.new("https://example.com/users/:id")
result  = pattern.match("https://example.com/users/42")

result.pathname.input   # => "/users/42"
result.pathname.groups  # => { "id" => "42" }
result.hostname.input   # => "example.com"
result.hostname.groups  # => {}

pattern.match("https://other.com/users/42")  # => nil
```

Groups can be captured from any component, including the query string:

```ruby
pattern = URIPattern.new("https://example.com/search?q=:term")
result  = pattern.match("https://example.com/search?q=ruby")

result.query.groups  # => { "term" => "ruby" }
```

### Reading components back

Each component reader returns the pattern string for that component:

```ruby
pattern = URIPattern.new("https://*.example.com/books/:id?")

pattern.protocol  # => "https"
pattern.hostname  # => "*.example.com"
pattern.pathname  # => "/books/:id?"
pattern.query     # => "*"
pattern.fragment  # => "*"
```

`#has_regexp_groups?` reports whether any component contains a custom `(...)`
regexp group:

```ruby
URIPattern.new("https://example.com/users/:id(\\d+)").has_regexp_groups?  # => true
URIPattern.new("https://example.com/users/:id").has_regexp_groups?        # => false
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/y-yagi/uri_pattern.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
