require "json"
require "base64"
require "../core/errors"

module CrystKit::IPC
  # JSON serialization helpers for the IPC boundary.
  #
  # Converts between Crystal domain objects and the `JSON::Any` values
  # that travel across the JS↔Crystal boundary.
  #
  # Conversion failures are raised as `Core::IPCError` with a
  # `VALIDATION_ERROR` or `SERIALIZATION_FAILED` code.
  module Codec
    extend self

    # Decodes a `JSON::Any` value into a `JSON::Serializable` type `T`.
    #
    # `T` must include `JSON::Serializable`. Raises `Core::IPCError`
    # (code `VALIDATION_ERROR`) when the value cannot be parsed into `T`.
    #
    # ```
    # struct Point
    #   include JSON::Serializable
    #   property x : Int32
    #   property y : Int32
    # end
    #
    # point = IPC::Codec.decode(payload, Point)
    # ```
    def decode(value : JSON::Any, type : T.class) : T forall T
      io = IO::Memory.new
      value.to_json(io)
      io.rewind
      T.from_json(io)
    rescue ex : JSON::SerializableError | JSON::ParseException | KeyError | TypeCastError
      raise Core::IPCError.new(
        "Invalid value for #{T}: #{ex.message}",
        code: "VALIDATION_ERROR",
        context: T.name,
      )
    end

    # Extracts a fixed number of positional arguments from an array payload.
    #
    # `params` must be a JSON array with exactly `expected` elements;
    # each element is then decoded individually by the caller via
    # `decode`.
    #
    # Raises `Core::IPCError` (code `VALIDATION_ERROR`) if the payload
    # is not an array or its length differs from `expected`.
    def arguments(params : JSON::Any, expected : Int32) : Array(JSON::Any)
      values = params.as_a?
      raise Core::IPCError.new("Expected an array with #{expected} arguments", code: "VALIDATION_ERROR") unless values
      raise Core::IPCError.new("Expected #{expected} arguments, received #{values.size}", code: "VALIDATION_ERROR") unless values.size == expected
      values
    end

    # Converts an arbitrary Crystal value into a `JSON::Any` suitable for
    # crossing the IPC boundary.
    #
    # `Bytes` is Base64-encoded so binary blobs survive JSON transit;
    # `UInt64` is narrowed to `Int64` when it fits (JS numbers are IEEE-754
    # doubles and cannot losslessly represent the full `UInt64` range),
    # and degrades to `Float64` when it exceeds `Int64::MAX` — the same
    # precision JS `Number` would have for such magnitudes, and the only
    # numeric `JSON::Any` can hold beyond the `Int64` range.
    #
    # Raises `Core::IPCError` (code `SERIALIZATION_FAILED`) if the
    # value cannot be turned into JSON.
    def to_json_any(value) : JSON::Any
      case value
      when JSON::Any then value
      when Array     then JSON::Any.new(value.map { |item| to_json_any(item) })
      when Hash      then JSON::Any.new(value.transform_values { |item| to_json_any(item) })
      when Bytes     then JSON::Any.new(Base64.strict_encode(value))
      when Enum      then JSON::Any.new(value.to_s)
      when UInt64    then JSON::Any.new(value <= Int64::MAX ? value.to_i64 : value.to_f64)
      else                JSON.parse(value.to_json)
      end
    rescue ex
      raise Core::IPCError.new(
        "Cannot serialize #{value.class} to JSON: #{ex.message}",
        code: "SERIALIZATION_FAILED",
        context: value.class.name,
      )
    end
  end
end
