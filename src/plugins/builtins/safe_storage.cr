require "../base"
require "../../features/safe_storage"

module CrystKit
  module Plugins
    # Builtin plugin that exposes the OS keychain (or credential store) to the
    # frontend for secure secret storage.
    #
    # Splits access into read and write capabilities so an application can
    # grant the frontend read-only access to stored secrets without letting
    # it mutate them. Every command takes an optional *service* name that
    # namespaces entries within the keychain; when omitted it defaults to
    # `"CrystKit"` so a single app's secrets do not collide with others.
    #
    # Registers IPC commands:
    #   safe_storage:set — Store a value in the system keychain
    #   safe_storage:get — Retrieve a value from the system keychain
    #   safe_storage:delete — Delete a value from the system keychain
    #   safe_storage:list — List keys stored in the system keychain
    #
    # Required capabilities: `safe_storage:read`, `safe_storage:write`
    #
    # The `safe_storage.get` command returns `nil` (rather than raising) when
    # the requested key is absent, so callers can distinguish "no secret" from
    # a transport error.
    #
    # ```
    # app.plugin(CrystKit::Plugins::SafeStorage.new)
    # ```
    class SafeStorage < Plugin::Base
      # The safe-storage feature, lazily initialized during `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! storage : Features::SafeStorage

      # Returns the unique plugin identifier `"safe_storage"`.
      def identifier : String
        "safe_storage"
      end

      # Returns the metadata contract splitting keychain access into read and
      # write capabilities.
      #
      # `safe_storage.set` and `safe_storage.delete` require
      # `safe_storage:write`; `safe_storage.get` and `safe_storage.list`
      # require `safe_storage:read`.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(safe_storage.set safe_storage.delete), "safe_storage:write")
          .require(%w(safe_storage.get safe_storage.list), "safe_storage:read")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(safe_storage:read safe_storage:write),
          commands: %w(safe_storage.set safe_storage.get safe_storage.delete safe_storage.list),
          ipc: ipc,
        )
      end

      # Registers the IPC commands.
      #
      # Each command forwards an optional *service* argument, defaulting to
      # `"CrystKit"` when the caller omits it. The `safe_storage.list`
      # command returns `{"keys" => [...]}` rather than a bare array so the
      # payload shape is self-describing.
      def initialize_plugin(context : Plugin::Context) : Nil
        @storage = ss = Features::SafeStorage.new

        context.command "safe_storage.set", String, String, String? do |key, value, service|
          ss.set(key, value, service || "CrystKit")
        end

        context.command "safe_storage.get", String, String? do |key, service|
          ss.get(key, service || "CrystKit")
        end

        context.command "safe_storage.delete", String, String? do |key, service|
          ss.delete(key, service || "CrystKit")
        end

        context.command "safe_storage.list", String? do |service|
          {"keys" => ss.list(service || "CrystKit")}
        end
      end
    end
  end
end
