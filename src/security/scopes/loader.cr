require "./base_scope"
require "./fs_scope"
require "./http_scope"
require "./process_scope"

module CrystKit
  module Security
    module Scopes
      # Factory that turns a manifest's `scopes` map into `BaseScope`
      # instances.
      #
      # Selects the concrete subclass by capability prefix (`"fs"`,
      # `"http"`, `"process"`, `"shell"`). Unknown prefixes are logged at
      # warn level and skipped. `shell` is treated as an alias for
      # `process`: both produce a `ProcessScope`.
      module Loader
        extend self

        # Builds a `Hash(String, BaseScope)` from the manifest's *scopes*
        # map.
        #
        # Each *scopes* entry is keyed by capability prefix and maps to the
        # list of patterns for that scope. Empty pattern lists are
        # skipped.
        #
        # ```
        # scopes = Scopes::Loader.load(
        #   {"fs" => ["~/Documents"], "http" => ["https://api.example.com/*"]},
        # )
        # scopes["fs"].allows?("/home/alice/Documents/x") # => true
        # ```
        def load(scopes : Hash(String, Array(String))) : Hash(String, BaseScope)
          result = {} of String => BaseScope

          scopes.each do |prefix, patterns|
            next if patterns.empty?

            case prefix
            when "fs"
              result["fs"] = FsScope.new(patterns)
            when "http"
              result["http"] = HttpScope.new(patterns)
            when "process"
              result["process"] = ProcessScope.new(patterns)
            when "shell"
              result["shell"] = ProcessScope.new(patterns)
            else
              Log.warn { "Unknown scope type '#{prefix}' in capabilities manifest" }
            end
          end

          result
        end
      end
    end
  end
end
