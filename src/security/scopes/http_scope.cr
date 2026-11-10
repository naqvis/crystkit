require "./base_scope"

module CrystKit
  module Security
    module Scopes
      # HTTP resource scope.
      #
      # Gates which HTTP(S) origins the `http:*` family of capabilities may
      # touch. Each entry in `#patterns` is matched against a resource URL
      # using one of three rules, evaluated in order:
      #
      # 1. *Exact match* — the resource equals the pattern verbatim.
      # 2. *Trailing-wildcard* — a pattern ending in `*` matches any
      #    resource that starts with the pattern with the `*` stripped
      #    (e.g. `https://api.example.com/*` matches
      #    `https://api.example.com/v1/users`).
      # 3. *Trailing-slash* — a pattern ending in `/` matches any resource
      #    that starts with the pattern (e.g. `https://api.example.com/`
      #    matches `https://api.example.com/v1`).
      #
      # The special pattern `"*"` allows any origin; all other patterns
      # must use explicit `http://` / `https://` schemes.
      #
      # ```
      # scope = HttpScope.new(["https://api.example.com/*"])
      # scope.allows?("https://api.example.com/v1/users") # => true
      # ```
      class HttpScope < BaseScope
        # The list of URL patterns this scope allows.
        #
        # Each entry is either a literal origin/URL, an origin with a
        # trailing `*` wildcard, an origin ending in `/`, or the special
        # single-character `"*"` that allows everything.
        getter patterns : Array(String)

        # Creates a new HTTP scope from *patterns*. Every pattern must
        # start with `http://` or `https://`, or be exactly `"*"`;
        # otherwise raises `Core::ValidationError`.
        def initialize(@patterns : Array(String))
          validate_patterns
        end

        # Returns `true` if *resource* matches any pattern in `#patterns`,
        # using the exact / wildcard / trailing-slash rules described in
        # the class documentation.
        #
        # *resource* is expected to be a full URL including scheme (e.g.
        # `https://api.example.com/v1/users`). Bare hostnames will not
        # match `https://`-prefixed patterns.
        def allows?(resource : String) : Bool
          @patterns.any? do |pattern|
            resource == pattern ||
              (pattern.ends_with?('*') && resource.starts_with?(pattern.rchop('*'))) ||
              (pattern.ends_with?('/') && resource.starts_with?(pattern))
          end
        end

        # :nodoc:
        private def validate_patterns : Nil
          @patterns.each do |p|
            unless p.starts_with?("http://") || p.starts_with?("https://") || p == "*"
              raise CrystKit::Core::ValidationError.new(
                "HTTP scope pattern must start with http:// or https://, got: #{p}",
                field: "scopes.http"
              )
            end
            next if p == "*"
            # Reject patterns with no host and no wildcard (e.g. bare
            # "https://"). Patterns like "https://*" (any HTTPS host) or
            # "http://localhost*" are valid.
            host_part = p.sub(/^https?:\/\//, "")
            host = host_part.rchop('*').rstrip('/')
            if host.empty? && !host_part.starts_with?('*')
              raise CrystKit::Core::ValidationError.new(
                "HTTP scope pattern must include a host, got: #{p}",
                field: "scopes.http"
              )
            end
          end
        end
      end
    end
  end
end
