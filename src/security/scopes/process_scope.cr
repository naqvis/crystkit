require "./base_scope"

module CrystKit::Security::Scopes
  # Process resource scope.
  #
  # Gates which processes the `process:*` and `shell:*` families of
  # capabilities may target. Matching is plain string-prefix: a
  # resource is allowed when it starts with any pattern in `#patterns`,
  # or when any pattern is the literal `"*"` wildcard (allow-all).
  #
  # Empty patterns are rejected (they would match every resource).
  #
  # ```
  # scope = ProcessScope.new(["git", "ls"])
  # scope.allows?("git status") # => true
  # ```
  class ProcessScope < BaseScope
    # The list of process-name prefixes this scope allows, plus
    # optionally the `"*"` wildcard.
    getter patterns : Array(String)

    # Creates a new process scope from *patterns*. Empty patterns are
    # rejected because an empty prefix matches every resource.
    def initialize(@patterns : Array(String))
      @patterns.each do |p|
        if p.empty?
          raise CrystKit::Core::ValidationError.new(
            "Process scope pattern cannot be empty",
            field: "scopes.process",
          )
        end
      end
    end

    # Returns `true` if *resource* starts with any pattern in
    # `#patterns`, or if any pattern is the `"*"` wildcard.
    #
    # Matching is prefix-based so `"git"` allows both `"git"` and
    # `"git status"`; supply the exact name if you want exact matching
    # only.
    def allows?(resource : String) : Bool
      @patterns.any? { |p| p == "*" || resource.starts_with?(p) }
    end
  end
end
