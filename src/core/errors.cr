require "./fibers"

module CrystKit
  # The CrystKit exception hierarchy.
  module Core
    # Base exception type for every error raised by CrystKit.
    #
    # Carries two optional fields beyond `message`:
    #
    # * `code` — a stable, machine-readable identifier (e.g. `"WINDOW_LABEL_REQUIRED"`).
    # * `context` — free-form situational detail (a path, window id, plugin id, etc.).
    #
    # Both are `nil` when the raise site did not provide them.
    #
    # ```
    # begin
    #   app.window(label: nil) # capabilities manifest requires labels
    # rescue e : Core::Error
    #   Log.error.exception(e) { "code=#{e.code} ctx=#{e.context}" }
    # end
    # ```
    class Error < Exception
      # Stable machine-readable error code, or `nil`. Codes are uppercase
      # ASCII identifiers (e.g. `"SERIALIZATION_FAILED"`) safe to forward
      # across the IPC boundary.
      getter code : String?

      # Free-form human-readable context string, or `nil`. Typically a
      # filesystem path, window id, or plugin identifier involved in the
      # failure.
      getter context : String?

      # Creates a new error with optional *code* and *context* metadata.
      def initialize(message : String, @code = nil, @context = nil)
        super(message)
      end

      # Appends `code` and `context` to *io* after `message`.
      #
      # Format: `<message> (code: <code>) (context: <context>)`.
      # Each segment is omitted when its value is `nil`.
      def to_s(io : IO) : Nil
        super
        io << " (code: " << code << ')' if code
        io << " (context: " << context << ')' if context
      end
    end

    # Raised by the IPC subsystem for transport, routing, serialization, and
    # policy failures. The `code` field typically identifies the failing
    # stage (e.g. `"SERIALIZATION_FAILED"`, `"COMMAND_NOT_FOUND"`).
    class IPCError < Error
    end

    # Raised by the plugin host when a plugin fails to load, register, or
    # execute a lifecycle hook. The `context` field usually carries the
    # offending plugin identifier.
    class PluginError < Error
    end

    # Raised by the security/capability subsystem when a capability is
    # missing, a scope boundary is violated, or a manifest fails to load.
    class SecurityError < Error
    end

    # Raised by filesystem operations (typically from plugins or capability
    # scopes) when a path is not accessible, missing, or outside an allowed
    # scope.
    class FileSystemError < Error
    end

    # Raised by network operations when a request fails at the transport
    # layer or a configured network capability is denied.
    class NetworkError < Error
    end

    # Raised when an operation exceeds its allotted time budget.
    class TimeoutError < Error
      # Creates a timeout error for *operation* that exceeded *timeout*.
      def initialize(operation : String, timeout : Time::Span)
        super("Operation '#{operation}' timed out after #{timeout.total_seconds} seconds")
      end
    end

    # Raised when an input or configuration value fails validation.
    #
    # Carries an optional `field` naming the offending configuration path
    # (e.g. `"ipc.commands.fs.read.permission"`).
    class ValidationError < Error
      # Identifier of the invalid field or configuration path, or `nil`.
      getter field : String?

      # Creates a validation error with *message* and optional *field*.
      def initialize(message : String, @field = nil)
        super(message)
      end
    end

    # Raised when an async command is cancelled because its timeout
    # elapsed before the handler completed.  The handler can check the
    # `CancellationToken` proactively via `cancel.check!` to bail out
    # early; if it doesn't, this error is raised in the orphaned fiber
    # after the timeout fires.
    class CancelledError < Error
    end
  end
end
