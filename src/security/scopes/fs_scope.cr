require "./base_scope"

module CrystKit
  module Security
    module Scopes
      # Filesystem resource scope.
      #
      # Gates which filesystem paths the `fs:*` family of capabilities may
      # touch. Paths are matched as *string prefixes*: a resource is
      # allowed when it starts with (the expanded form of) any pattern in
      # `#paths`. `~` and `~/...` patterns are expanded to the user's
      # home directory. The special pattern `"*"` matches every path
      # (expands to root `"/"`).
      #
      # ```
      # scope = FsScope.new(["~/Documents", "/tmp/crystkit", "*"])
      # scope.allows?("/home/alice/Documents/notes.txt") # => true (if home is /home/alice)
      # scope.allows?("/etc/passwd")                     # => true (via "*")
      # ```
      class FsScope < BaseScope
        # The list of path patterns this scope allows. Each pattern acts
        # as a prefix match against the resource string.
        getter paths : Array(String)

        @expanded_paths : Array(String)

        # Creates a new filesystem scope from *paths*. Empty patterns are
        # rejected, so an `FsScope` never silently allows everything via an
        # empty-string prefix.
        def initialize(@paths : Array(String))
          validate_paths
          @expanded_paths = @paths.map { |p| expand(p) }
        end

        # Returns `true` if *resource* starts with the expanded form of
        # any pattern in `#paths`.
        #
        # The *resource* is expanded and normalized internally (via
        # `Path#expand(home: true)` and `Path#normalize`) so that traversal
        # sequences such as `..` are resolved before matching. Callers may
        # pass a path as-is without pre-normalizing it.
        def allows?(resource : String) : Bool
          res = Path[resource].expand(home: true).normalize.to_s
          @expanded_paths.any? do |pattern|
            pattern == "/" || res == pattern || Path::SEPARATORS.any? { |s| res.starts_with?("#{pattern}#{s}") }
          end
        end

        # :nodoc:
        private def expand(pattern : String) : String
          return Path.home.to_s if pattern == "~"
          return "/" if pattern == "*"
          Path[pattern].expand(home: true).normalize.to_s
        end

        # :nodoc:
        private def validate_paths : Nil
          @paths.each do |p|
            if p.empty?
              raise CrystKit::Core::ValidationError.new("Filesystem scope path cannot be empty", field: "scopes.fs")
            end
          end
        end
      end
    end
  end
end
