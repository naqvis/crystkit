require "json"
require "../core/errors"
require "./slice"

module CrystKit
  module State
    # Owns every frontend-reactive state slice registered by an app.
    #
    # The registry stores slices through `AnySlice` because each slice may
    # have a different Crystal type. App code receives the typed
    # `State::Slice(T)` returned by `App#state`.
    class Registry
      @slices : Hash(String, AnySlice)
      @mutex : Mutex
      @on_change : Proc(Change, Nil)

      # Creates an empty registry. The *on_change* callback is invoked
      # whenever any slice emits a non-empty patch.
      def initialize(@on_change : Proc(Change, Nil))
        @slices = Hash(String, AnySlice).new
        @mutex = Mutex.new
      end

      # Creates and registers a typed state slice.
      #
      # State names are unique. Registering the same name twice raises
      # `Core::ValidationError`.
      def register(name : String, initial : T) : Slice(T) forall T
        @mutex.synchronize do
          if @slices.has_key?(name)
            raise Core::ValidationError.new(
              "State slice '#{name}' is already registered",
              field: "state.#{name}",
            )
          end

          slice = Slice(T).new(name, initial, @on_change)
          @slices[name] = slice
          slice
        end
      end

      # Returns the slice named *name*, or `nil` when none exists.
      def find?(name : String) : AnySlice?
        @mutex.synchronize { @slices[name]? }
      end

      # Returns the typed slice named *name*.
      #
      # Raises `Core::ValidationError` when no slice exists with that name,
      # or when the registered slice has a different value type.
      def fetch(name : String, type : T.class) : Slice(T) forall T
        slice = find?(name) || raise Core::ValidationError.new(
          "State slice '#{name}' is not registered",
          field: "state.#{name}",
        )

        typed = slice.as?(Slice(T))
        return typed if typed

        raise Core::ValidationError.new(
          "State slice '#{name}' is not a #{T}",
          field: "state.#{name}",
        )
      end

      # Returns the typed slice named *name*, or `nil` when the slice is
      # missing or was registered with a different value type.
      def fetch?(name : String, type : T.class) : Slice(T)? forall T
        find?(name).try(&.as?(Slice(T)))
      end

      # Returns a sorted list of registered state names.
      def names : Array(String)
        @mutex.synchronize { @slices.keys.sort! }
      end

      # Yields each registered slice to *block*. Iterates under the
      # registry lock so callers see a consistent snapshot.
      def each(& : AnySlice ->) : Nil
        @mutex.synchronize { @slices.each_value { |s| yield s } }
      end
    end
  end
end
