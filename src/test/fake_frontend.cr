require "json"
require "../ipc/router"
require "../ipc/schema"
require "../ipc/command"
require "../app/app"

module CrystKit
  # Test utilities for CrystKit apps.
  module Test
    # A Crystal-side stand-in for `window.__CRYSTKIT_IPC__` that drives
    # the real `IPC::Router` without a native webview.
    #
    # `FakeFrontend` wraps an `App` (or a standalone `Router`) and mirrors
    # the JS bridge API -- `invoke`, `listen`, `emit`, `channel`, `state` --
    # so specs can exercise IPC, events, channels, and reactive state
    # end-to-end without opening a window or entering the run loop.
    #
    # It also captures every event the backend bridges to the frontend
    # (via `App#bridge_to_frontend`), which the real `running?` gate
    # suppresses in tests. Access captured events through `#emitted`,
    # `#emitted_events`, or `#clear`.
    #
    # ```
    # app = CrystKit::App.new(config)
    # app.command("greet", String) { |name| "Hello, #{name}" }
    #
    # frontend = CrystKit::Test::FakeFrontend.new(app)
    # result = frontend.invoke("greet", JSON::Any.new("Crystal"))
    # result.ok?.should be_true
    # result.value.not_nil!.as_s.should eq("Hello, Crystal")
    # ```
    class FakeFrontend
      Log = ::Log.for(self)

      # The app this frontend is attached to, or `nil` when constructed
      # from a standalone `Router`.
      getter app : ::CrystKit::App?

      # The router all invokes/events flow through.
      getter router : IPC::Router

      # Captured events bridged from the backend to the frontend, in
      # delivery order. Each entry is `{event, payload, target}`.
      getter emitted : Array({event: String, payload: JSON::Any, target: ::CrystKit::Core::Window?})

      # Captured state patches, in delivery order.
      getter state_patches : Array(JSON::Any)

      @context : IPC::Context
      @subscriptions = [] of UInt64
      @state_subscription : UInt64?
      @state_refs = {} of String => FakeStateRef

      # Creates a fake frontend attached to *app*. Installs capture hooks
      # on the app's runtime so backend-emitted events and state patches
      # are recorded even without entering the run loop.
      def initialize(@app : ::CrystKit::App)
        @router = app.router
        @emitted = [] of {event: String, payload: JSON::Any, target: ::CrystKit::Core::Window?}
        @state_patches = [] of JSON::Any
        @context = IPC::Context.new(
          app: app,
          security: app.security,
          plugins: app.plugins,
          frontend: true,
        )

        # Install capture hooks that bypass the running? gate.
        app.runtime.frontend_event_dispatcher = ->(event : String, payload : JSON::Any, target : ::CrystKit::Core::Window?) {
          @emitted << {event: event, payload: payload, target: target}
        }
        app.runtime.state_frontend_dispatcher = ->(payload : JSON::Any) {
          @state_patches << payload
        }

        # Subscribe to state patches on the router too (for standalone
        # router usage and to catch patches emitted directly on the router).
        @state_subscription = @router.subscribe_event("__crystkit.state.patch", ->(payload : JSON::Any) {
          unless @state_patches.includes?(payload)
            @state_patches << payload
            dispatch_state_patch(payload)
          end
        })
      end

      # Creates a fake frontend over a standalone *router* (no App).
      # Event capture is limited to events emitted on the router; the
      # `running?`-gated `App#bridge_to_frontend` path is not intercepted.
      def initialize(@router : IPC::Router)
        @app = nil
        @emitted = [] of {event: String, payload: JSON::Any, target: ::CrystKit::Core::Window?}
        @state_patches = [] of JSON::Any
        @context = IPC::Context.new(frontend: true)
        @state_subscription = @router.subscribe_event("__crystkit.state.patch", ->(payload : JSON::Any) {
          @state_patches << payload
          dispatch_state_patch(payload)
        })
      end

      # Invokes *command* with *params* (defaults to JSON null) and returns
      # the `ResponseEnvelope`. Routes to sync or async dispatch based on
      # the router's transport map, matching the JS `invoke()` behavior.
      def invoke(command : String, params : JSON::Any = JSON::Any.new(nil)) : IPC::ResponseEnvelope
        info = router.command_info?(command) || return IPC::ResponseEnvelope.failure(
          code: "COMMAND_NOT_FOUND",
          message: "Command '#{command}' is not registered",
        )
        router.authorize_frontend_command!(command, params, @context)
        if info.async?
          router.execute_async(info, @context, params)
        else
          begin
            IPC::ResponseEnvelope.success(router.execute_sync_for_bridge(info, @context, params))
          rescue ex : ::CrystKit::Core::Error
            IPC::ResponseEnvelope.failure(
              code: ex.code || "IPC_ERROR",
              message: ex.message || "",
              details: {"command" => JSON::Any.new(command)},
            )
          rescue ex
            IPC::ResponseEnvelope.failure(
              code: "INTERNAL_ERROR",
              message: ex.message || "",
              details: {"command" => JSON::Any.new(command)},
            )
          end
        end
      rescue ex : ::CrystKit::Core::Error
        IPC::ResponseEnvelope.failure(
          code: ex.code || "IPC_ERROR",
          message: ex.message || "",
          details: {"command" => JSON::Any.new(command)},
        )
      end

      # Subscribes *handler* to *event*. Returns an unsubscribe proc that
      # removes the subscription. Mirrors the JS `listen()` API.
      def listen(event : String, &handler : JSON::Any -> Nil) : ->
        id = router.subscribe_event(event, handler)
        -> { router.unsubscribe_event(id) }
      end

      # Emits *event* with *payload* from the frontend. The event must be
      # declared via `Router#declare_frontend_event` or the app config.
      # Returns a `ResponseEnvelope` mirroring the JS `emit()` binding.
      def emit(event : String, payload : JSON::Any = JSON::Any.new(nil)) : IPC::ResponseEnvelope
        router.emit_frontend_event(event, payload, @context)
        IPC::ResponseEnvelope.success(JSON::Any.new(nil))
      rescue ex : ::CrystKit::Core::Error
        IPC::ResponseEnvelope.failure(
          code: ex.code || "IPC_ERROR",
          message: ex.message || "",
        )
      end

      # Attaches to a streaming channel by *channel_id*. Returns a
      # `FakeChannel` that captures incoming data, end, and error events.
      def channel(channel_id : String) : FakeChannel
        FakeChannel.new(@router, channel_id)
      end

      # Attaches to a backend-owned reactive state slice by *name*.
      # Returns a `FakeStateRef` whose `value` updates when the backend
      # emits state patches.
      def state(name : String) : FakeStateRef
        if ref = @state_refs[name]?
          return ref
        end
        envelope = invoke("__crystkit.state.attach", JSON::Any.new(name))
        unless envelope.ok?
          raise ::CrystKit::Core::IPCError.new(
            "State slice '#{name}' is not registered",
            code: envelope.error.not_nil!.code,
          )
        end
        payload = envelope.value.not_nil!
        slice_name = payload["name"].as_s
        initial = payload["value"]
        ref = FakeStateRef.new(slice_name, initial)
        @state_refs[slice_name] = ref
        ref
      end

      # Returns the payloads of all captured events named *event*.
      def emitted_events(event : String) : Array(JSON::Any)
        @emitted.select { |e| e[:event] == event }.map(&.[:payload])
      end

      # Returns `true` when at least one event named *event* was captured.
      def emitted?(event : String) : Bool
        @emitted.any? { |e| e[:event] == event }
      end

      # Clears all captured events, state patches, and state ref values.
      def clear : Nil
        @emitted.clear
        @state_patches.clear
        @state_refs.each_value(&.clear)
      end

      # Detaches from the app, removing all subscriptions and capture hooks.
      # Call in `ensure` blocks to avoid leaking subscriptions between tests.
      def detach : Nil
        @subscriptions.each { |id| router.unsubscribe_event(id) }
        @subscriptions.clear
        @state_subscription.try { |id| router.unsubscribe_event(id) }
        @state_subscription = nil
        if app = @app
          app.runtime.frontend_event_dispatcher = nil
          app.runtime.state_frontend_dispatcher = nil
        end
      end

      # :nodoc:
      private def dispatch_state_patch(payload : JSON::Any) : Nil
        name = payload["name"]?.try(&.as_s) || return
        patch = payload["patch"]?
        ref = @state_refs[name]? || return
        ref.apply_patch(patch) if patch
      end
    end

    # A Crystal-side stand-in for the JS channel API returned by
    # `window.__CRYSTKIT_IPC__.channel(id)`.
    class FakeChannel
      # The channel id this fake subscribes to.
      getter id : String

      # Captured data values delivered to the channel, in order.
      getter data : Array(JSON::Any)

      # `true` when the channel received an end event.
      getter? ended : Bool

      # `true` when the channel received an error event.
      getter? errored : Bool

      # The error message when `#errored?` is true.
      getter error_message : String?

      @router : IPC::Router
      @sub_data : UInt64?
      @sub_close : UInt64?
      @sub_error : UInt64?

      # Creates a fake channel attached to *router* for channel *id*.
      def initialize(@router : IPC::Router, @id : String)
        @data = [] of JSON::Any
        @ended = false
        @errored = false
        @error_message = nil

        @sub_data = @router.subscribe_event("__channel_data:#{@id}", ->(payload : JSON::Any) {
          value = payload["value"]? || JSON::Any.new(nil)
          @data << value
        })
        @sub_close = @router.subscribe_event("__channel_close:#{@id}", ->(_payload : JSON::Any) {
          @ended = true
        })
        @sub_error = @router.subscribe_event("__channel_error:#{@id}", ->(payload : JSON::Any) {
          @errored = true
          @error_message = payload["error"]?.try(&.as_s)
        })
      end

      # Closes the fake channel, unsubscribing from all channel events.
      def close : Nil
        @sub_data.try { |id| @router.unsubscribe_event(id) }
        @sub_close.try { |id| @router.unsubscribe_event(id) }
        @sub_error.try { |id| @router.unsubscribe_event(id) }
        @sub_data = nil
        @sub_close = nil
        @sub_error = nil
      end
    end

    # A Crystal-side stand-in for the JS state ref returned by
    # `window.__CRYSTKIT_IPC__.state(name)`.
    class FakeStateRef
      # The state slice name.
      getter name : String

      # All patches applied to this ref, in order.
      getter patches : Array(JSON::Any)

      @value : JSON::Any
      @subscribers = [] of Proc(JSON::Any, Nil)

      # Creates a fake state ref with *name* and *initial* value.
      def initialize(@name : String, @value : JSON::Any)
        @patches = [] of JSON::Any
      end

      # Returns the current mirrored value.
      def value : JSON::Any
        @value
      end

      # Subscribes *handler* to value changes. Returns an unsubscribe proc.
      def subscribe(&handler : JSON::Any -> Nil) : ->
        @subscribers << handler
        -> { @subscribers.delete(handler) }
      end

      # :nodoc:
      # Applies a JSON Patch to the mirrored value and notifies subscribers.
      def apply_patch(patch : JSON::Any?) : Nil
        return unless patch
        @patches << patch
        @value = apply_patch_to_value(@value, patch)
        @subscribers.each do |handler|
          handler.call(@value)
        rescue ex
          Log.error { "State subscriber error for '#{@name}': #{ex.message}" }
        end
      end

      # :nodoc:
      def clear : Nil
        @patches.clear
        @subscribers.clear
      end

      private def apply_patch_to_value(root : JSON::Any, patch : JSON::Any) : JSON::Any
        return root unless patch.as_a?

        current = clone_json(root)
        patch.as_a.each do |op|
          current = apply_op(current, op)
        end
        current
      end

      private def apply_op(root : JSON::Any, op : JSON::Any) : JSON::Any
        path = op["path"]?.try(&.as_s) || return root
        operation = op["op"]?.try(&.as_s) || return root

        if path.empty?
          case operation
          when "replace", "add"
            return clone_json(op["value"]?)
          when "remove"
            return JSON::Any.new(nil)
          end
          return root
        end

        parts = decode_pointer(path)
        target = root

        parts.each_with_index do |part, i|
          is_last = i == parts.size - 1
          if is_last
            case operation
            when "remove"
              if target.raw.is_a?(Hash)
                target.as_h.delete(part)
              elsif target.raw.is_a?(Array)
                idx = part.to_i? || return root
                target.as_a.delete_at(idx) if idx < target.as_a.size
              end
            when "add", "replace"
              if target.raw.is_a?(Hash)
                target.as_h[part] = clone_json(op["value"]?)
              elsif target.raw.is_a?(Array)
                idx = part.to_i? || return root
                if idx < target.as_a.size
                  target.as_a[idx] = clone_json(op["value"]?)
                else
                  target.as_a << clone_json(op["value"]?)
                end
              end
            end
          else
            if target.raw.is_a?(Hash)
              target = target.as_h[part]? || return root
            elsif target.raw.is_a?(Array)
              idx = part.to_i? || return root
              target = target.as_a[idx]? || return root
            end
          end
        end
        root
      end

      private def decode_pointer(path : String) : Array(String)
        return [] of String if path.empty?
        raise "Invalid JSON Patch path: #{path}" unless path.starts_with?('/')
        path[1..].split('/').map(&.gsub("~1", "/").gsub("~0", "~"))
      end

      private def clone_json(value : JSON::Any?) : JSON::Any
        return JSON::Any.new(nil) if value.nil?
        JSON.parse(value.to_json)
      end
    end
  end
end
