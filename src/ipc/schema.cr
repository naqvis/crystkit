require "json"

module CrystKit::IPC
  # Error detail block carried inside a `ResponseEnvelope` when a command
  # or emit failed.
  #
  # `code` is a stable machine-readable string the frontend can branch
  # on, `message` is human-readable, and `details` carries extra
  # diagnostic key/value pairs. Serialized as the `error` field of
  # `ResponseEnvelope`.
  struct ErrorEnvelope
    include JSON::Serializable

    # Stable machine-readable error code the frontend switches on
    # (e.g. `COMMAND_NOT_FOUND`, `IPC_POLICY_MISSING`, `INTERNAL_ERROR`).
    getter code : String

    # Human-readable description of what went wrong. Never assume a
    # specific format; parse via `code` instead.
    getter message : String

    # Additional diagnostic context. May be empty.
    getter details : Hash(String, JSON::Any)

    # Creates an error envelope with an optional `details` map defaulting
    # to an empty hash.
    def initialize(
      @code,
      @message,
      @details = {} of String => JSON::Any,
    )
    end
  end

  # The canonical wire shape for every IPC command and emit response.
  #
  # - success: `{"ok": true, "value": <any>}`
  # - failure: `{"ok": false, "error": {"code", "message", "details"}}`
  #
  # The JS client parses this and either resolves with `value` or
  # rejects with an `Error` carrying the error `code` and `details`.
  struct ResponseEnvelope
    include JSON::Serializable

    # `true` for a successful response (carries `value`), `false` for a
    # failure (carries `error`).
    getter? ok : Bool

    # The command's return value, present only when `ok` is `true`. May
    # be `nil`/JSON null for commands that return nothing.
    getter value : JSON::Any?

    # The failure detail block, present only when `ok` is `false`.
    getter error : ErrorEnvelope?

    # Low-level constructor. Prefer `ResponseEnvelope.success` and
    # `ResponseEnvelope.failure`.
    def initialize(
      @ok,
      @value = nil,
      @error = nil,
    )
    end

    # Builds a success envelope carrying `value` as its payload.
    #
    # ```
    # envelope = IPC::ResponseEnvelope.success(JSON::Any.new(42))
    # ```
    def self.success(value : JSON::Any) : self
      new(true, value)
    end

    # Builds a failure envelope with a stable `code`, human-readable
    # `message`, and optional `details` map. The frontend throws an
    # `Error` carrying the same `code` and `details`.
    #
    # ```
    # envelope = IPC::ResponseEnvelope.failure(
    #   code: "IPC_POLICY_MISSING",
    #   message: "fs:write is not granted",
    #   details: {"command" => JSON::Any.new("fs.save")},
    # )
    # ```
    def self.failure(
      code : String,
      message : String,
      details : Hash(String, JSON::Any) = {} of String => JSON::Any,
    ) : self
      new(false, error: ErrorEnvelope.new(code, message, details))
    end

    # Converts this envelope to a `JSON::Any` value, centralizing the
    # round-trip through `JSON.parse(to_json)` used by the JS bridge.
    def to_json_any : JSON::Any
      JSON.parse(to_json)
    end
  end
end
