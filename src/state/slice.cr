require "json"
require "json_patch"
require "../core/errors"
require "../ipc/codec"

module CrystKit
  module State
    # Payload sent over the private state bridge after a slice changes.
    struct Change
      # Name of the changed state slice.
      getter name : String

      getter patch : JSONPatch::Patch

      def initialize(@name : String, @patch : JSONPatch::Patch)
      end

      def to_json_any : JSON::Any
        JSON::Any.new({
          "name"  => JSON::Any.new(@name),
          "patch" => JSON.parse(@patch.to_json),
        })
      end
    end

    # Type-erased interface for heterogeneous state slices stored in a
    # `State::Registry`.
    abstract class AnySlice
      # Name used by the frontend to attach to this slice.
      abstract def name : String

      # Current slice value serialized for IPC.
      abstract def to_json_any : JSON::Any

      # JSON payload returned by the private attach command.
      def attach_payload : JSON::Any
        JSON::Any.new({
          "name"  => JSON::Any.new(name),
          "value" => to_json_any,
        })
      end
    end

    # A backend-owned, frontend-reactive state slice.
    #
    # The wrapped value is an ordinary Crystal object. It does not inherit
    # from CrystKit, include a CrystKit mixin, or use CrystKit property
    # macros. Mutate it inside `#update`; CrystKit serializes the value
    # before and after the transaction, computes JSON Patch, and propagates
    # that patch to frontend mirrors.
    class Slice(T) < AnySlice
      # Slice name used by `window.__CRYSTKIT_IPC__.state(name)` on the frontend.
      getter name : String

      @value : T
      @mutex : Mutex
      @on_change : Proc(Change, Nil)
      # Last serialized snapshot, carried forward between updates so each
      # `update` only serializes the new value once instead of serializing
      # both before and after. This halves the dominant serialization cost
      # for large state slices with no change to the public API.
      @serialized : JSON::Any?

      # Creates a typed state slice.
      def initialize(@name : String, @value : T, @on_change : Proc(Change, Nil))
        validate_name!(@name)
        @mutex = Mutex.new
      end

      # Returns the current backend value.
      #
      # Mutations made directly to a returned reference are not observed by
      # the framework. Use `#update` so CrystKit can capture and propagate
      # the patch.
      def value : T
        @mutex.synchronize { @value }
      end

      # Returns the current value serialized as `JSON::Any`.
      def to_json_any : JSON::Any
        @mutex.synchronize { serialize(@value) }
      end

      # Replaces the whole backend value and propagates the resulting JSON
      # Patch to frontend mirrors.
      def value=(value : T) : T
        update { |_current| value }
      end

      # Mutates the backend value inside an observed transaction.
      #
      # The block receives the current typed value and may either mutate it
      # in place and return it, or return a new value. After the block,
      # CrystKit computes a JSON Patch from the serialized before/after
      # values. Empty patches are ignored.
      def update(&block : T -> T) : T
        change = nil
        result = @mutex.synchronize do
          # Reuse the previous snapshot as `before` so only the new value is
          # serialized. For large state slices this cuts the dominant
          # serialization cost roughly in half versus serializing both
          # before and after on every update.
          before = @serialized || serialize(@value)
          @value = block.call(@value)
          after = serialize(@value)
          @serialized = after
          patch = before.diff(after)
          change = Change.new(@name, patch) unless patch.empty?
          @value
        end

        @on_change.call(change.not_nil!) if change
        result
      end

      private def serialize(value : T) : JSON::Any
        IPC::Codec.to_json_any(value)
      rescue ex : Core::IPCError
        raise ex
      rescue ex
        raise Core::IPCError.new(
          "Cannot serialize state slice '#{@name}' value #{T}: #{ex.message}",
          code: "STATE_SERIALIZATION_FAILED",
          context: T.name,
        )
      end

      private def validate_name!(name : String) : Nil
        if name.empty? || name.includes?(':') || name.includes?(' ')
          raise Core::ValidationError.new(
            "State slice name must be non-empty, dot-separated, and contain no spaces or colons",
            field: "state.#{name}",
          )
        end
      end
    end
  end
end
