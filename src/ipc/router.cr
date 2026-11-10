require "json"
require "log"
require "set"
require "../core/errors"
require "../core/cancellation_token"
require "./command"
require "./event"
require "./schema"
require "./codec"
require "./policy_resolver"

module CrystKit
  module IPC
    # The central registry and dispatch loop for IPC commands, events,
    # channel authorization, and policy enforcement.
    #
    # There is normally one `Router` per `CrystKit::App`, shared with every
    # plugin context and every window's IPC bridge.
    #
    # Handlers run inside `#execute`, which raises `Core::IPCError` on
    # failure (re-raising `Core::Error` subclasses unchanged).
    # `#invoke_envelope` converts any raised `CrystKitError` into a failure
    # `ResponseEnvelope` with a stable code, so the JS frontend always gets a
    # structured error rather than a thrown C++ exception.
    class Router
      # Maximum byte size of any command or event payload. Defaults to 10 MiB.
      # Oversized payloads are rejected with `Core::IPCError` (code
      # `PAYLOAD_TOO_LARGE`) before the handler runs.
      property max_payload_size : Int32 = 10_485_760

      # Default timeout for commands whose registration did not specify one.
      # A handler that exceeds its timeout is aborted with
      # `Core::TimeoutError` (error code `TIMEOUT`).
      property command_timeout : Time::Span = 30.seconds

      # The policy resolver consulted on every frontend invocation.
      getter policy_resolver : PolicyResolver

      @commands : Hash(String, CommandInfo)
      @event_subscriptions : Hash(String, Array(EventSubscription))
      @frontend_events : Set(String)
      @channel_owners : Hash(String, ChannelOwner)
      @subscription_counter : Atomic(UInt64)
      @command_transports_cache : Hash(String, String)?
      @registry_lock : Mutex

      # Creates an empty router with a fresh `PolicyResolver`.
      def initialize
        @commands = Hash(String, CommandInfo).new
        @event_subscriptions = Hash(String, Array(EventSubscription)).new
        @frontend_events = Set(String).new
        @channel_owners = Hash(String, ChannelOwner).new
        @subscription_counter = Atomic(UInt64).new(0)
        @command_transports_cache = nil
        @registry_lock = Mutex.new
        @policy_resolver = PolicyResolver.new
      end

      # Registers a context-free command under `name`. The handler receives
      # only the JSON payload.
      def command(name : String, &handler : JSON::Any -> JSON::Any) : Nil
        register_command(name, handler)
      end

      # Registers a context-aware command under `name`. The handler receives
      # the `IPC::Context` and the JSON payload.
      def command_context(name : String, &handler : Context, JSON::Any -> JSON::Any) : Nil
        register_contextual_command(name, handler)
      end

      # Decodes a `JSON::Any` payload into a `JSON::Serializable` type `T`.
      def self.decode(value : JSON::Any, type : T.class) : T forall T
        Codec.decode(value, type)
      end

      # Extracts exactly `expected` positional arguments from an array
      # payload.
      def self.arguments(params : JSON::Any, expected : Int32) : Array(JSON::Any)
        Codec.arguments(params, expected)
      end

      # Registers a command handler that ignores the invocation context.
      # `timeout` overrides `#command_timeout` for this command only.
      def register_command(name : String, handler : CommandHandler, timeout : Time::Span? = nil) : Nil
        register_contextual_command(name, ->(_context : Context, params : JSON::Any) {
          handler.call(params)
        }, timeout)
      end

      # Registers a context-aware command handler under `name`.
      #
      # `name` must be non-empty, dot-separated (colons are rejected), and
      # unique — duplicate registrations raise `Core::IPCError`. `timeout`
      # overrides `#command_timeout` for this command only.
      def register_contextual_command(name : String, handler : ContextualCommandHandler, timeout : Time::Span? = nil) : Nil
        raise Core::IPCError.new("Command name cannot be empty") if name.empty?
        if name.includes?(':')
          raise Core::IPCError.new("Command '#{name}' must use a dot-separated name")
        end
        @registry_lock.synchronize do
          raise Core::IPCError.new("Command '#{name}' is already registered") if @commands.has_key?(name)
          @commands[name] = CommandInfo.new(name, handler, timeout || @command_timeout)
          @command_transports_cache = nil
        end
      end

      # Registers an async command handler under `name`.
      #
      # Same naming and uniqueness rules as `#register_contextual_command`.
      # The handler receives a `Core::CancellationToken` as its third
      # argument; it can poll `#cancelled?` or call `#check!` to bail out
      # early when the timeout fires.  The framework dispatches the handler
      # on a fiber and delivers the response to the frontend via
      # `webview_return` when the handler completes or the timeout elapses
      # — whichever comes first.
      def register_async_command(name : String, handler : AsyncContextualCommandHandler,
                                 timeout : Time::Span? = nil) : Nil
        raise Core::IPCError.new("Command name cannot be empty") if name.empty?
        if name.includes?(':')
          raise Core::IPCError.new("Command '#{name}' must use a dot-separated name")
        end
        # Wrap the async handler in a sync ContextualCommandHandler shell
        # so that invoke_command/execute can treat both uniformly.  The
        # actual fiber dispatch happens in JSClientSetup, which checks
        # command_info.async? and calls execute_async instead.
        #
        # The token passed to the handler via this sync wrapper is a fresh,
        # never-cancelled CancellationToken — it exists only so the handler
        # signature matches. Real cancellation only happens through
        # execute_async, which manages its own token and select-timeout.
        # Calling invoke_command on an async command directly (bypassing
        # the JS bridge) runs the handler inline with no timeout
        # enforcement; this is a degraded fallback, not the normal path.
        sync_wrapper = ContextualCommandHandler.new { |ctx, params|
          token = Core::CancellationToken.new
          handler.call(ctx, params, token)
        }
        @registry_lock.synchronize do
          raise Core::IPCError.new("Command '#{name}' is already registered") if @commands.has_key?(name)
          @commands[name] = CommandInfo.new(
            name, sync_wrapper, timeout || @command_timeout,
            async: true, async_handler: handler,
          )
          @command_transports_cache = nil
        end
      end

      # Removes a command registration. No-op if the command was not registered.
      def unregister_command(name : String) : Nil
        @registry_lock.synchronize do
          @commands.delete(name)
          @command_transports_cache = nil
        end
      end

      # Invokes a registered command by name, returning its raw `JSON::Any`
      # result.
      #
      # Raises `Core::IPCError` (code `COMMAND_NOT_FOUND`) if the command
      # is not registered, runs frontend policy enforcement when
      # `context.frontend?` is true, and wraps handler failures in
      # `Core::IPCError`. Use `#invoke_envelope` to obtain a
      # `ResponseEnvelope` instead.
      def invoke_command(name : String, params : JSON::Any, context : Context = Context.new) : JSON::Any
        validate_payload_size!(params, "Payload")
        command_info = command_info?(name) || raise Core::IPCError.new(
          "Command '#{name}' is not registered",
          code: "COMMAND_NOT_FOUND",
        )
        authorize_frontend_command_impl!(command_info.name, params, context) if context.frontend?
        execute(command_info, context, params)
      end

      # Invokes a command and wraps the outcome in a `ResponseEnvelope`.
      #
      # Successes become `ResponseEnvelope.success` with the handler's
      # return value. Failures are converted into
      # `ResponseEnvelope.failure` with a stable error code:
      #
      # - `Core::Error` subclasses use the exception's own `code`,
      #   or `TIMEOUT` for `Core::TimeoutError`, or `IPC_ERROR` as a
      #   fallback.
      # - any other exception becomes `INTERNAL_ERROR`.
      #
      # `details` always carries the command name and the exception's class
      # name. Never raises — returns failures as envelopes so the JS bridge
      # can pass them across the FFI boundary.
      def invoke_envelope(name : String, params : JSON::Any, context : Context = Context.new) : ResponseEnvelope
        ResponseEnvelope.success(invoke_command(name, params, context))
      rescue ex : Core::Error
        ResponseEnvelope.failure(
          code: ex.code || default_error_code(ex),
          message: ex.message || "IPC command failed",
          details: {
            "command" => JSON::Any.new(name),
            "type"    => JSON::Any.new(ex.class.name),
          },
        )
      rescue ex
        ResponseEnvelope.failure(
          code: "INTERNAL_ERROR",
          message: ex.message || "Unexpected IPC error",
          details: {
            "command" => JSON::Any.new(name),
            "type"    => JSON::Any.new(ex.class.name),
          },
        )
      end

      # Synchronously delivers `payload` to every subscriber of event `name`.
      #
      # Subscribers are called in registration order. If `target` is given,
      # only subscriptions created without a target or with the same
      # target receive the event. Subscriber exceptions are caught and
      # logged so one faulty listener cannot break delivery to the rest.
      #
      # Payload size is validated against `#max_payload_size` first.
      def emit_event(name : String, payload : JSON::Any, target : ::CrystKit::Core::Window? = nil) : Nil
        validate_payload_size!(payload, "Event payload")
        subscribers = @registry_lock.synchronize { @event_subscriptions[name]?.try(&.dup) }
        return unless subscribers

        start_time = Time.instant
        subscribers.each do |subscription|
          next if target && subscription.target && subscription.target != target

          begin
            subscription.handler.call(payload)
          rescue ex
            Log.error { "Error in event listener for '#{name}': #{ex.message}" }
          end
        end

        elapsed = Time.instant - start_time
        if elapsed > 100.milliseconds
          Log.warn { "Event '#{name}' delivery took #{elapsed.total_milliseconds}ms (exceeds 100ms target)" }
        end
      end

      # Marks `name` as an event the frontend is allowed to emit.
      #
      # `#emit_frontend_event` raises `Core::SecurityError` (code
      # `IPC_POLICY_MISSING`) for any event not declared here. The event
      # name must be non-empty.
      def declare_frontend_event(name : String) : Nil
        raise Core::IPCError.new("Event name cannot be empty") if name.empty?
        @registry_lock.synchronize { @frontend_events << name }
      end

      # Emits an event originating from the frontend.
      #
      # Raises `Core::SecurityError` (code `IPC_POLICY_MISSING`) if `name`
      # was not declared via `#declare_frontend_event`.
      def emit_frontend_event(name : String, payload : JSON::Any, context : Context) : Nil
        unless @registry_lock.synchronize { @frontend_events.includes?(name) }
          raise Core::SecurityError.new(
            "Event '#{name}' is not declared as frontend-emittable",
            code: "IPC_POLICY_MISSING",
          )
        end

        emit_event(name, payload)
      end

      # Records ownership for a streaming channel so the router can later
      # authorize frontend subscription requests.
      #
      # `owner` is the plugin or component that created the channel;
      # `target_window_id`, when set, restricts the channel to a single
      # window.
      def register_channel_owner(channel_id : String, owner : String, target_window_id : String? = nil) : Nil
        @registry_lock.synchronize do
          @channel_owners[channel_id] = ChannelOwner.new(owner, target_window_id)
        end
      end

      # Raises `Core::SecurityError` unless `context` is allowed to use the
      # streaming channel `channel_id`.
      #
      # Unknown channel ids raise with code `IPC_POLICY_MISSING`. When the
      # channel was registered with a `target_window_id`, the context's
      # `window_authority_id` must match it exactly, otherwise
      # `IPC_WINDOW_DENIED` is raised. Channels without a target window are
      # available to any window.
      def authorize_frontend_channel!(channel_id : String, context : Context) : Nil
        owner = @registry_lock.synchronize { @channel_owners[channel_id]? } || raise Core::SecurityError.new(
          "Unknown IPC channel '#{channel_id}'",
          code: "IPC_POLICY_MISSING",
        )

        if expected = owner.target_window_id
          unless context.window_authority_id == expected
            raise Core::SecurityError.new(
              "IPC channel '#{channel_id}' is not available to this window",
              code: "IPC_WINDOW_DENIED",
            )
          end
        end
      end

      # Subscribes `handler` to event `name` and returns a subscription id.
      #
      # The returned id can be passed to `#unsubscribe_event` to remove
      # just this subscription. If `target` is given, the subscription
      # only receives events emitted with a matching `target` (or with no
      # `target`).
      def subscribe_event(name : String, handler : EventHandler, target : ::CrystKit::Core::Window? = nil) : UInt64
        subscription_id = @subscription_counter.add(1) + 1
        subscription = EventSubscription.new(subscription_id, name, handler, target)
        @registry_lock.synchronize do
          @event_subscriptions[name] ||= [] of EventSubscription
          @event_subscriptions[name] << subscription
        end
        subscription_id
      end

      # Removes the subscription with the given id across all events.
      # No-op when the id does not match any active subscription.
      def unsubscribe_event(subscription_id : UInt64) : Nil
        @registry_lock.synchronize do
          to_delete = [] of String
          @event_subscriptions.each do |event_name, subscriptions|
            subscriptions.reject! { |subscription| subscription.id == subscription_id }
            to_delete << event_name if subscriptions.empty?
          end
          to_delete.each { |name| @event_subscriptions.delete(name) }
        end
      end

      # Removes *every* subscription for `event_name`.
      def unsubscribe_all(event_name : String) : Nil
        @registry_lock.synchronize { @event_subscriptions.delete(event_name) }
      end

      # Returns the names of all currently registered commands.
      def registered_commands : Array(String)
        @registry_lock.synchronize { @commands.keys }
      end

      # Returns a map of `{command_name => "sync" | "async"}` for all
      # currently registered commands. Used by the JS bridge to inject
      # a transport map into the frontend so `invoke()` routes to the
      # correct binding.
      # :nodoc:
      def command_transports : Hash(String, String)
        @registry_lock.synchronize do
          transports = @command_transports_cache ||= @commands.transform_values { |info| info.async? ? "async" : "sync" }
          transports.dup
        end
      end

      # Returns the `CommandInfo` for `name`, or `nil` if not registered.
      # Used by the JS bridge to decide between sync and async dispatch.
      # :nodoc:
      def command_info?(name : String) : CommandInfo?
        @registry_lock.synchronize { @commands[name]? }
      end

      # Runs frontend policy enforcement for `name`.  Raises on denial.
      # Exposed so the async bridge can authorize before dispatching.
      # :nodoc:
      def authorize_frontend_command!(name : String, params : JSON::Any, context : Context) : Nil
        validate_payload_size!(params, "Payload")
        authorize_frontend_command_impl!(name, params, context)
      end

      # Synchronously executes a command and returns the raw result.
      # Used by the async bridge for sync commands — still runs on a
      # fiber (spawned by the bridge), so the UI thread is not blocked.
      # :nodoc:
      def execute_sync_for_bridge(command_info : CommandInfo, context : Context, params : JSON::Any) : JSON::Any
        execute(command_info, context, params)
      end

      # Returns the names of events that currently have at least one
      # subscriber.
      def subscribed_events : Array(String)
        @registry_lock.synchronize { @event_subscriptions.keys }
      end

      # Converts an arbitrary Crystal value into a `JSON::Any` for the IPC
      # boundary.
      def to_json_any(value) : JSON::Any
        Codec.to_json_any(value)
      end

      # :nodoc:
      private def default_error_code(error : Core::Error) : String
        error.is_a?(Core::TimeoutError) ? "TIMEOUT" : "IPC_ERROR"
      end

      # :nodoc:
      private def validate_payload_size!(payload : JSON::Any, label : String) : Nil
        payload_size = payload.to_json.bytesize
        return if payload_size <= @max_payload_size

        raise Core::IPCError.new(
          "#{label} size (#{payload_size} bytes) exceeds maximum allowed size (#{@max_payload_size} bytes)",
          code: "PAYLOAD_TOO_LARGE",
        )
      end

      # :nodoc:
      private def authorize_frontend_command_impl!(name : String, params : JSON::Any, context : Context) : Nil
        policy = @policy_resolver.resolve(name)
        return if policy.capability.nil? && policy.resources.empty?

        security = context.security || raise Core::SecurityError.new(
          "Command '#{name}' requires a security context",
          code: "IPC_SECURITY_CONTEXT_MISSING",
        )

        if capability = policy.capability
          security.require!(capability, context: "ipc:#{name}")
        end

        policy.resources.each do |rule|
          resource = rule.extract(params)
          case rule.kind
          in ResourceKind::Path
            permission = case rule.permission || ResourcePermission::Read
                         in ResourcePermission::Read
                           ::CrystKit::Security::Permission::Read
                         in ResourcePermission::Write
                           ::CrystKit::Security::Permission::Write
                         in ResourcePermission::Execute
                           ::CrystKit::Security::Permission::Execute
                         end
            security.require_path!(rule.capability, Path[resource], permission)
          in ResourceKind::Resource
            security.require_resource!(rule.capability, resource)
          end
        end
      end

      # Synchronously executes *command_info*'s handler and returns its raw
      # result.
      #
      # Sync commands run inline on the webview's thread. Crystal cannot
      # preempt a running fiber, so a real timeout cannot be enforced here —
      # the handler always runs to completion regardless of
      # `command_info.timeout`. Checking elapsed time after the fact only
      # raises an error the caller never benefits from (the UI was already
      # blocked for the handler's full duration), so we deliberately do not
      # time-check sync commands. Use `#register_async_command` when a
      # handler needs an enforceable timeout.
      # :nodoc:
      private def execute(command_info : CommandInfo, context : Context, params : JSON::Any) : JSON::Any
        command_info.handler.call(context, params)
      rescue ex : Core::Error
        raise ex
      rescue ex
        raise Core::IPCError.new(
          "Command '#{command_info.name}' failed: #{ex.message}",
          code: "COMMAND_EXECUTION_ERROR",
          context: ex.class.name,
        )
      end

      # Execute an async command on a fiber with a real `select` timeout.
      # Returns a `ResponseEnvelope` (never raises) so the caller can pass
      # it directly to `webview_return`.
      #
      # If the handler completes before the timeout, the envelope carries
      # the result.  If the timeout fires first, the envelope carries a
      # `TIMEOUT` failure and the cancellation token is set so the
      # orphaned handler fiber can check it and bail out early.
      #
      # :nodoc:
      def execute_async(command_info : CommandInfo, context : Context, params : JSON::Any) : ResponseEnvelope
        token = Core::CancellationToken.new
        done = ::Channel(JSON::Any | Core::Error).new(1)

        Core::Fibers.spawn do
          begin
            if handler = command_info.async_handler
              result = handler.call(context, params, token)
            else
              result = command_info.handler.call(context, params)
            end
            done.send(result)
          rescue ex : Core::Error
            done.send(ex)
          rescue ex
            done.send(Core::IPCError.new(
              "Command '#{command_info.name}' failed: #{ex.message}",
              code: "COMMAND_EXECUTION_ERROR",
              context: ex.class.name,
            ))
          end
        end

        select
        when result = done.receive
          if result.is_a?(Core::Error)
            ResponseEnvelope.failure(
              code: result.code || default_error_code(result),
              message: result.message || "Async command failed",
              details: {"command" => JSON::Any.new(command_info.name),
                        "type"    => JSON::Any.new(result.class.name)},
            )
          else
            ResponseEnvelope.success(result)
          end
        when timeout(command_info.timeout)
          token.cancel
          ResponseEnvelope.failure(
            code: "TIMEOUT",
            message: "Command '#{command_info.name}' timed out after #{command_info.timeout.total_seconds}s",
            details: {"command" => JSON::Any.new(command_info.name)},
          )
        end
      end

      # :nodoc:
      private record CommandInfo, name : String, handler : ContextualCommandHandler,
        timeout : Time::Span, async : Bool = false,
        async_handler : AsyncContextualCommandHandler? = nil do
        def async? : Bool
          @async
        end
      end

      # :nodoc:
      private record EventSubscription, id : UInt64, event_name : String,
        handler : EventHandler, target : ::CrystKit::Core::Window? = nil

      # :nodoc:
      private record ChannelOwner, owner : String, target_window_id : String? = nil
    end
  end
end
