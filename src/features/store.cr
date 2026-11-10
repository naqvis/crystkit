require "json"
require "log"
require "../core/errors"

module CrystKit
  module Features
    # Thread-safe persistent key-value store with namespace isolation.
    #
    # Values are `JSON::Any`, so heterogeneous scalar types and nested
    # structures can coexist. A corrupt or unparseable backing file is logged
    # and yields an empty store rather than raising.
    #
    # Choose namespaces that are filesystem-safe and unique within
    # *storage_dir*: two stores with the same namespace and directory share
    # the same file.
    #
    # ```
    # store = CrystKit::Features::Store.new("settings")
    # store.set("theme", "dark")
    # store.set("window_width", 1024)
    # store.get("theme").try(&.as_s) # => "dark"
    # ```
    class Store
      @namespace : String
      @data : Hash(String, JSON::Any)
      @file_path : Path
      @mutex : Mutex

      # Creates a store for *namespace*, loading any previously persisted data.
      #
      # When *storage_dir* is `nil`, defaults to a per-user temp directory;
      # pass an explicit path (e.g. an app-data directory from
      # `SystemInfo#app_data_directories`) for production so data survives
      # temp cleanup.
      def initialize(@namespace : String, storage_dir : Path? = nil)
        dir = storage_dir || default_storage_dir
        @file_path = dir / "store_#{@namespace}.json"
        @data = Hash(String, JSON::Any).new
        @mutex = Mutex.new
        load_from_disk
      end

      # Store *value* under *key*, persisting immediately.
      #
      # Primitive Crystal values and `JSON::Any` are accepted. Overwrites any
      # prior value for *key*.
      def set(key : String, value : JSON::Any | String | Int | Float | Bool) : Nil
        any = case value
              when JSON::Any then value
              when Int       then JSON::Any.new(value.to_i64)
              when Float     then JSON::Any.new(value.to_f64)
              else                JSON::Any.new(value)
              end
        set_any(key, any)
      end

      # Retrieve the value stored under *key*, or `nil` if absent.
      #
      # Unwrap the result with `#as_s`, `#as_i`, etc.
      def get(key : String) : JSON::Any?
        @mutex.synchronize { @data[key]? }
      end

      # Retrieve the value stored under *key*, returning *default* when absent.
      def get(key : String, default : JSON::Any) : JSON::Any
        @mutex.synchronize { @data[key]? || default }
      end

      # Remove *key* and its value, persisting the change.
      #
      # Deleting a missing key is a no-op.
      def delete(key : String) : Nil
        @mutex.synchronize do
          @data.delete(key)
        end
        persist
      end

      # Returns `true` when *key* is present in the store.
      def has_key?(key : String) : Bool
        @mutex.synchronize { @data.has_key?(key) }
      end

      # Returns a fresh array of every key in the store.
      def keys : Array(String)
        @mutex.synchronize { @data.keys.dup }
      end

      # Remove every key/value pair and persist the empty store.
      def clear : Nil
        @mutex.synchronize { @data.clear }
        persist
      end

      # Returns the number of entries in the store.
      def size : Int32
        @mutex.synchronize { @data.size }
      end

      # :nodoc:
      private def set_any(key : String, value : JSON::Any) : Nil
        @mutex.synchronize { @data[key] = value }
        persist
      end

      # :nodoc:
      private def persist : Nil
        Dir.mkdir_p(@file_path.parent.to_s) unless Dir.exists?(@file_path.parent.to_s)
        @mutex.synchronize do
          File.write(@file_path.to_s, @data.to_json)
        end
      rescue ex
        Log.error { "Store '#{@namespace}': failed to persist to #{@file_path}: #{ex.message}" }
      end

      # :nodoc:
      private def load_from_disk : Nil
        return unless File.exists?(@file_path.to_s)
        begin
          content = File.read(@file_path.to_s)
          parsed = JSON.parse(content)
          if hash = parsed.as_h?
            @data = hash
          end
        rescue ex
          Log.warn { "Store '#{@namespace}': failed to load from #{@file_path}: #{ex.message}" }
          @data = Hash(String, JSON::Any).new
        end
      end

      # :nodoc:
      private def default_storage_dir : Path
        Path[Dir.tempdir] / "webview_app" / "stores"
      end
    end
  end
end
