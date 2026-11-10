require "json"

module CrystKit
  module Security
    # Security configuration loaded from an application manifest
    # (`capabilities.json`).
    #
    # The manifest is the source of truth for the application's owned
    # authority: the capabilities it grants itself at startup, the
    # per-window IPC allow-lists, and the resource scopes (filesystem paths,
    # HTTP origins, process names) that narrow each capability prefix.
    # Plugin metadata may contribute additional capabilities at runtime, but
    # the manifest's set is loaded eagerly on `Context#load_manifest`.
    #
    # Validation lives in `.validate`, which performs format checks and
    # returns a list of human-readable error strings.
    class Manifest
      include JSON::Serializable

      # Additional app-owned capability grants.
      #
      # Each entry is a capability identifier of the form `"feature:verb"`
      # (e.g. `"fs:read"`, `"http:get"`). These are auto-granted into the
      # `CapabilitySystem` on `CapabilitySystem#load_manifest`. Plugin
      # metadata capabilities are granted automatically when plugins
      # register and do *not* need to be listed here.
      @[JSON::Field(description: "Additional app-owned capability grants; plugin metadata capabilities are granted automatically when plugins register")]
      getter capabilities : Array(String) = [] of String

      # Named groups of capabilities for reuse and organization.
      #
      # Each key is a group name; the value is the list of capability
      # identifiers that belong to the group. Groups are a manifest-level
      # authoring convenience, not directly enforced by the capability
      # system.
      @[JSON::Field(description: "Named groups of capabilities for reuse and organization")]
      getter groups : Hash(String, Array(String)) = {} of String => Array(String)

      # Per-window frontend IPC allow-lists, keyed by window id.
      #
      # The value is the list of capability identifiers that window is
      # permitted to use. Windows not present in this map inherit the
      # global capability set; windows present here are restricted to the
      # listed capabilities plus any inherited from ancestor windows (see
      # `CapabilitySystem#set_window_parent`).
      @[JSON::Field(description: "Per-window frontend IPC allow-lists, keyed by window label")]
      getter windows : Hash(String, Array(String)) = {} of String => Array(String)

      # Resource scopes for fine-grained access control.
      #
      # Keyed by capability prefix (`"fs"`, `"http"`, `"process"`); the
      # value is the list of prefix patterns that the application is
      # allowed to touch.
      @[JSON::Field(description: "Resource scopes for fine-grained access control, keyed by capability prefix (fs, http, process)")]
      getter scopes : Hash(String, Array(String)) = {} of String => Array(String)

      # Creates an empty manifest with default (empty) collections.
      # Production code typically uses `.from_json` to parse a manifest
      # from disk.
      def initialize
      end

      # Validates a manifest JSON string and returns a list of human-readable
      # error messages.
      #
      # Checks JSON syntax and schema, and ensures each `capabilities` entry
      # is non-empty and matches the allowed character class
      # `[a-zA-Z0-9_:.\-*]`.
      #
      # Returns an empty array for a valid manifest. Does not raise on
      # malformed input — intended to be called *before*
      # `Manifest.from_json` so the caller can surface validation errors
      # without crashing.
      #
      # ```
      # errors = Manifest.validate(File.read("capabilities.json"))
      # raise "bad manifest: #{errors.join(", ")}" unless errors.empty?
      # ```
      def self.validate(json : String) : Array(String)
        manifest = from_json(json)
      rescue ex : JSON::SerializableError
        ["Invalid manifest structure: #{ex.message}"]
      rescue ex : JSON::ParseException
        ["Invalid JSON syntax: #{ex.message}"]
      else
        errors = [] of String

        manifest.capabilities.each_with_index do |name, index|
          if name.empty?
            errors << "\"capabilities[#{index}]\" must not be empty"
          elsif !name.matches?(/\A[a-zA-Z0-9_:.\-*]+\z/)
            errors << "\"capabilities[#{index}]\" contains invalid characters: #{name.inspect}"
          end
        end

        manifest.windows.each do |window_id, caps|
          if window_id.empty?
            errors << "\"windows\" key must not be empty"
          end
          caps.each_with_index do |cap, i|
            if cap.empty?
              errors << "\"windows.#{window_id}[#{i}]\" must not be empty"
            elsif !cap.matches?(/\A[a-zA-Z0-9_:.\-*]+\z/)
              errors << "\"windows.#{window_id}[#{i}]\" contains invalid characters: #{cap.inspect}"
            end
          end
        end

        manifest.scopes.each do |prefix, patterns|
          if prefix.empty?
            errors << "\"scopes\" key must not be empty"
          end
          patterns.each_with_index do |pattern, i|
            if pattern.empty?
              errors << "\"scopes.#{prefix}[#{i}]\" must not be empty"
            end
          end
        end

        errors
      end
    end
  end
end
