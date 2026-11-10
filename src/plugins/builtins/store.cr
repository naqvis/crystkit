require "../base"
require "../../features/store"

module CrystKit
  module Plugins
    # Builtin plugin that provides namespaced, auto-persisting key/value
    # storage for application state.
    #
    # Each namespace persists to its own JSON file under
    # `app.config.storage_dir/store`. Values are arbitrary `JSON::Any`, so
    # the frontend can store structured data without serializing it first.
    #
    # Registers IPC commands:
    #   store:get, store:set, store:delete, store:keys, store:has, store:clear
    #
    # Each command accepts a `namespace` parameter.
    #
    # Required capability: `store:manage`
    #
    # ```
    # app.plugin(CrystKit::Plugins::Store.new)
    # ```
    class Store < Plugin::Base
      Log = ::Log.for(self)

      @stores = {} of String => Features::Store
      @stores_lock = Mutex.new

      # Returns the unique plugin identifier `"store"`.
      def identifier : String
        "store"
      end

      # Returns the metadata contract gating every store command behind the
      # `store:manage` capability. There is no read/write split — any context
      # granted `store:manage` can read, write, and clear any namespace.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(store.get store.set store.delete store.keys store.has store.clear store.size), "store:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(store:manage),
          commands: %w(store.get store.set store.delete store.keys store.has store.clear store.size),
          ipc: ipc,
        )
      end

      # Registers the IPC commands. The storage directory is
      # `app.config.storage_dir/store`.
      def initialize_plugin(context : Plugin::Context) : Nil
        storage_dir = context.app.config.storage_dir / "store"

        get_store = ->(ns : String) {
          safe_ns = sanitize_namespace(ns)
          @stores_lock.synchronize do
            @stores[safe_ns] ||= Features::Store.new(safe_ns, storage_dir)
          end
        }

        context.command "store.get", String, String do |namespace, key|
          get_store.call(namespace).get(key)
        end

        context.command "store.set", String, String, JSON::Any do |namespace, key, value|
          get_store.call(namespace).set(key, value)
          "ok"
        end

        context.command "store.delete", String, String do |namespace, key|
          get_store.call(namespace).delete(key)
          "ok"
        end

        context.command "store.keys", String do |namespace|
          get_store.call(namespace).keys
        end

        context.command "store.has", String, String do |namespace, key|
          get_store.call(namespace).has_key?(key)
        end

        context.command "store.clear", String do |namespace|
          get_store.call(namespace).clear
          "ok"
        end

        context.command "store.size", String do |namespace|
          get_store.call(namespace).size
        end
      end

      def cleanup_plugin : Nil
        @stores_lock.synchronize do
          @stores.clear
        end
      end

      # :nodoc:
      private def sanitize_namespace(ns : String) : String
        sanitized = ns.gsub(/[^a-zA-Z0-9_\-]/, "_")
        raise Core::Error.new("Namespace cannot be empty", code: "INVALID_NAMESPACE") if sanitized.empty?
        sanitized
      end
    end
  end
end
