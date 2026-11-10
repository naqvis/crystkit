module CrystKit
  module Security
    # Namespace for resource scopes — in-memory prefix matchers that gate
    # which concrete resources a capability may touch.
    #
    # Contains the abstract `BaseScope` and the concrete subclasses
    # (`FsScope`, `HttpScope`, `ProcessScope`) used by
    # `Context#require_resource!` to validate that a resource string falls
    # within the application's manifest-declared authority. Unlike the
    # persisted `ScopeManager` layer (which is consulted for filesystem
    # *paths*), these scopes are consulted for resources addressed by
    # string identifiers (URLs, process names).
    module Scopes
      # Abstract base class for resource scopes.
      #
      # A scope is a predicate over resource strings: given a capability
      # prefix (`fs`, `http`, `process`, ...) and a list of patterns from
      # the manifest, the scope answers `#allows?` for a concrete resource
      # string. Concrete subclasses: `FsScope`, `HttpScope`,
      # `ProcessScope`.
      abstract class BaseScope
        # Returns `true` if *resource* falls within this scope's declared
        # authority.
        #
        # *resource* is the concrete resource string the caller wants to
        # access — a filesystem path for `FsScope`, a URL for `HttpScope`,
        # a process name for `ProcessScope`.
        abstract def allows?(resource : String) : Bool
      end
    end
  end
end
