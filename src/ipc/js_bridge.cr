require "json"
require "../core/errors"
require "../core/main_thread"
require "./router"

module CrystKit
  module IPC
    # Version of the JS IPC client injected into webviews, mirrored from the
    # shard version at compile time.
    #
    # Exposed on the frontend as `window.__CRYSTKIT_IPC__.version`.
    BRIDGE_VERSION = ::CrystKit::VERSION

    # JavaScript injected on every page. Provides:
    #   window.__CRYSTKIT_IPC__.invoke(name, params) -> Promise
    #   window.__CRYSTKIT_IPC__.listen(event, handler) -> unsubscribe()
    #   window.__CRYSTKIT_IPC__.emit(event, payload)
    #   window.__CRYSTKIT_IPC__.channel(channelId) -> { onData, onEnd, onError, close }
    #   window.__CRYSTKIT_IPC__.state(name) -> Promise<StateRef>
    #
    # The client is idempotent: re-injection on the same page is a no-op
    # that merely re-aliases `window.CrystKit` to the existing bridge.
    #
    # All responses flow through `handleEnvelope`, which parses the
    # `ResponseEnvelope` JSON and either returns the `value` or throws an
    # `Error` carrying the error `code` and `details`.
    IPC_JS_CLIENT = <<-JS
      (function() {
        if (typeof window.__CRYSTKIT_IPC__ !== 'undefined') {
          window.CrystKit = window.__CRYSTKIT_IPC__;
          return;
        }

        var _listeners = {};
        var _channels = {};
        var _states = {};
        var _statePatchUnsubscribe = null;

        function handleEnvelope(raw, fallbackMessage) {
          var parsed;
          if (typeof raw === 'string') {
            try { parsed = JSON.parse(raw); } catch (_) {
              throw new Error('Invalid IPC response envelope');
            }
          } else if (raw && typeof raw === 'object') {
            parsed = raw;
          } else {
            throw new Error('Invalid IPC response envelope');
          }
          if (parsed && typeof parsed === 'object' && parsed.ok === true &&
              Object.prototype.hasOwnProperty.call(parsed, 'value')) {
            return parsed.value;
          }
          if (parsed && typeof parsed === 'object' && parsed.ok === false && parsed.error) {
            var err = new Error(parsed.error.message || fallbackMessage);
            err.code = parsed.error.code;
            err.details = parsed.error.details || {};
            throw err;
          }
          throw new Error('Invalid IPC response envelope');
        }

        function cloneJson(value) {
          if (value === undefined) return undefined;
          return JSON.parse(JSON.stringify(value));
        }

        function decodePointer(path) {
          if (path === '') return [];
          if (!path || path.charAt(0) !== '/') {
            throw new Error('Invalid JSON Patch path: ' + path);
          }
          return path.slice(1).split('/').map(function(part) {
            return part.replace(/~1/g, '/').replace(/~0/g, '~');
          });
        }

        function patchParent(root, path) {
          var parts = decodePointer(path);
          var parent = root;
          for (var i = 0; i < parts.length - 1; i++) {
            parent = parent[parts[i]];
          }
          return { parent: parent, key: parts[parts.length - 1], root: root };
        }

        function applyPatch(root, patch) {
          var next = cloneJson(root);
          (patch || []).forEach(function(op) {
            if (!op || typeof op !== 'object') return;
            if (op.path === '') {
              if (op.op === 'replace' || op.op === 'add') {
                next = cloneJson(op.value);
                return;
              }
              if (op.op === 'remove') {
                next = null;
                return;
              }
            }

            var target = patchParent(next, op.path);
            if (Array.isArray(target.parent)) {
              var index = target.key === '-' ? target.parent.length : parseInt(target.key, 10);
              if (op.op === 'remove') {
                target.parent.splice(index, 1);
              } else if (op.op === 'add') {
                target.parent.splice(index, 0, cloneJson(op.value));
              } else if (op.op === 'replace') {
                target.parent[index] = cloneJson(op.value);
              }
            } else if (target.parent && typeof target.parent === 'object') {
              if (op.op === 'remove') {
                delete target.parent[target.key];
              } else if (op.op === 'add' || op.op === 'replace') {
                target.parent[target.key] = cloneJson(op.value);
              }
            }
          });
          return next;
        }

        function ensureStatePatchListener(api) {
          if (_statePatchUnsubscribe) return;
          _statePatchUnsubscribe = api.listen('__crystkit.state.patch', function(payload) {
            if (!payload || !payload.name) return;
            var ref = _states[payload.name];
            if (!ref) return;
            ref._applyPatch(payload.patch || []);
          });
        }

        function createStateRef(name, initialValue) {
          var subscribers = [];
          var current = cloneJson(initialValue);
          return {
            name: name,
            get value() { return current; },
            get: function() { return current; },
            subscribe: function(handler) {
              subscribers.push(handler);
              return function() {
                var index = subscribers.indexOf(handler);
                if (index >= 0) subscribers.splice(index, 1);
              };
            },
            _applyPatch: function(patch) {
              current = applyPatch(current, patch);
              subscribers.slice().forEach(function(handler) {
                try { handler(current); } catch (e) { console.error('state subscriber error', name, e); }
              });
            }
          };
        }

        window.__CRYSTKIT_IPC__ = {
          version: #{BRIDGE_VERSION.to_json},

          invoke: function(command, params) {
            // Route based on the transport map injected at setup time.
            // Sync commands go through __crystal_ipc_invoke_sync (runs
            // on the webview's thread). Async commands go through
            // __crystal_ipc_invoke (bind_async — handler runs on a fiber).
            // Both return Promises — the webview C API always uses
            // async messaging (webview_bind + webview_return).
            //
            // Commands registered after window creation may not appear
            // in the transport map. Those fall through to the async
            // binding, which dispatches sync commands to the main thread
            // via MainThread.dispatch_sync — correct, just not as fast
            // as the inline sync path.
            var transport = window.__CRYSTKIT_IPC_TRANSPORTS__ &&
                            window.__CRYSTKIT_IPC_TRANSPORTS__[command];
            if (transport === 'sync') {
              return window.__crystal_ipc_invoke_sync(JSON.stringify({
                command: command,
                params: params !== undefined ? params : null
              })).then(function(raw) {
                return handleEnvelope(raw, 'IPC command failed');
              });
            }
            return window.__crystal_ipc_invoke(JSON.stringify({
              command: command,
              params: params !== undefined ? params : null
            })).then(function(raw) {
              return handleEnvelope(raw, 'IPC command failed');
            });
          },

          listen: function(event, handler) {
            (_listeners[event] = _listeners[event] || []).push(handler);
            return function() {
              var arr = _listeners[event];
              if (!arr) return;
              var i = arr.indexOf(handler);
              if (i >= 0) arr.splice(i, 1);
              if (arr.length === 0) delete _listeners[event];
            };
          },

          emit: function(event, payload) {
            return window.__crystal_ipc_emit(JSON.stringify({event: event, payload: payload}))
              .then(function(raw) {
                return handleEnvelope(raw, 'IPC emit failed');
              });
          },

          // Subscribe to a streaming channel by ID.
          // Returns { onData, onEnd, onError, close }.
          channel: function(channelId) {
            if (_channels[channelId]) return _channels[channelId];

            var dataHandler = null;
            var endHandler = null;
            var errorHandler = null;
            var unsubData = null;
            var unsubEnd = null;
            var unsubError = null;
            var self = this;

            var api = {
              onData: function(fn) {
                dataHandler = fn;
                return api;
              },
              onEnd: function(fn) {
                endHandler = fn;
                return api;
              },
              onError: function(fn) {
                errorHandler = fn;
                return api;
              },
              close: function() {
                if (unsubData) { unsubData(); unsubData = null; }
                if (unsubEnd) { unsubEnd(); unsubEnd = null; }
                if (unsubError) { unsubError(); unsubError = null; }
                delete _channels[channelId];
              }
            };

            _channels[channelId] = api;

            unsubData = self.listen('__channel_data:' + channelId, function(payload) {
              if (dataHandler && payload && payload.value !== undefined) {
                dataHandler(payload.value);
              }
            });

            unsubEnd = self.listen('__channel_close:' + channelId, function() {
              if (endHandler) endHandler();
              api.close();
            });

            unsubError = self.listen('__channel_error:' + channelId, function(payload) {
              if (errorHandler && payload && payload.error) {
                errorHandler(payload.error);
              }
              api.close();
            });

            return api;
          },

          state: function(name) {
            var self = this;
            ensureStatePatchListener(self);
            if (_states[name]) return Promise.resolve(_states[name]);
            return self.invoke('__crystkit.state.attach', name).then(function(payload) {
              var ref = createStateRef(payload.name, payload.value);
              _states[payload.name] = ref;
              return ref;
            });
          },

          // Internal: called by Crystal to dispatch a backend event.
          _dispatchEvent: function(event, payload) {
            var arr = _listeners[event];
            if (!arr) return;
            arr.forEach(function(h) {
              try { h(payload); } catch (e) { console.error('listener error', event, e); }
            });
          }
        };

        window.CrystKit = window.__CRYSTKIT_IPC__;
      })();
    JS

    # Mixin module added to CrystKit::Webview that injects the JS client and
    # binds the thunks that route frontend calls into the IPC core.
    #
    # Mixed into `EnhancedWindow`, so every CrystKit window automatically
    # gets a working `window.__CRYSTKIT_IPC__`. The host application calls
    # `#setup_ipc_client` while wiring a window.
    module JSClientSetup
      # :nodoc:
      @alive = Atomic(Bool).new(true)

      # `true` while this host's native `webview` is alive.
      def ipc_alive? : Bool
        @alive.get
      end

      # Flip the lifetime flag to `false` and discard any work that
      # would otherwise be routed back to this host after destruction.
      # Called by `EnhancedWindow#destroy` before `super` frees the
      # underlying C++ `webview`.
      def mark_dead! : Nil
        @alive.set(false)
      end

      # Injects the JS client and binds the Crystal thunks that route
      # frontend calls into `router`.
      #
      # `context` provides the app, security, window, and plugin registry
      # shared with the frontend; a copy is made with `frontend: true` so
      # the router enforces `CommandPolicy` on every call coming through
      # this window. The bind callbacks return a `ResponseEnvelope` JSON
      # string.
      #
      # Both thunks wrap their work in a rescue barrier so Crystal
      # exceptions never escape into the native webview binding. Any error
      # is returned as a failure envelope, letting the JS Promise resolve
      # with an `error` field.
      def setup_ipc_client(router : Router, context : Context = Context.new)
        init(IPC_JS_CLIENT)

        # Inject the transport map so the JS client routes each command
        # to the correct binding (sync via __crystal_ipc_invoke_sync,
        # async via __crystal_ipc_invoke).
        transports_json = router.command_transports.to_json
        init("window.__CRYSTKIT_IPC_TRANSPORTS__ = #{transports_json};")

        frontend_context = Context.new(
          app: context.app,
          security: context.security,
          window: context.window,
          plugins: context.plugins,
          plugin_id: context.plugin_id,
          frontend: true,
          origin: context.origin,
        )

        # Frontend invoke → backend command → JSON result.
        #
        # Dispatch is split across two bindings so the JS client can
        # route each command to the right transport (see the transport
        # map injected above and the `invoke` function in
        # `IPC_JS_CLIENT`):
        #
        #   * `bind("__crystal_ipc_invoke_sync")` runs inline on the
        #     webview's thread. Sync handlers — including those that call
        #     OS GUI features (dialogs, window ops) — must run here so
        #     Crystal's fiber scheduler never reschedules them onto a
        #     background thread.
        #   * `bind_async("__crystal_ipc_invoke")` spawns a fiber and
        #     resolves via `respond`. Only async commands travel this
        #     path; the spawn is load-bearing because `execute_async`
        #     uses a `select` with a timeout and a `CancellationToken`.
        bind("__crystal_ipc_invoke_sync", JSProc.new { |args|
          begin
            message = JSON.parse(args[0].as_s)
            command_name = message["command"].as_s
            params = message["params"]

            if command_info = router.command_info?(command_name)
              router.authorize_frontend_command!(command_name, params, frontend_context)
              if command_info.async?
                # Safety: a sync binding should never receive an async
                # command. Return a structured error rather than crashing.
                envelope = ResponseEnvelope.failure(
                  code: "IPC_TRANSPORT_MISMATCH",
                  message: "Command '#{command_name}' is async but invoked via sync binding",
                  details: {"command" => JSON::Any.new(command_name)},
                )
              else
                envelope = ResponseEnvelope.success(
                  router.execute_sync_for_bridge(command_info, frontend_context, params)
                )
              end
            else
              envelope = ResponseEnvelope.failure(
                code: "COMMAND_NOT_FOUND",
                message: "Command '#{command_name}' is not registered",
                details: {"command" => JSON::Any.new(command_name)},
              )
            end
            envelope.to_json_any
          rescue ex : Core::Error
            ResponseEnvelope.failure(
              code: ex.code || "IPC_ERROR",
              message: ex.message || "IPC command failed",
              details: {"type" => JSON::Any.new(ex.class.name)},
            ).to_json_any
          rescue ex
            ResponseEnvelope.failure(
              code: "INVALID_REQUEST",
              message: ex.message || "Invalid IPC request",
              details: {"type" => JSON::Any.new(ex.class.name)},
            ).to_json_any
          end
        })

        # Async binding — handler runs on a background fiber. The global `spawn` is overridden to route to CrystKit's background execution context, keeping the main thread free for the webview's native event loop. In single-threaded mode (specs, no execution-context flag), `spawn` runs on the default context.
        bind_async("__crystal_ipc_invoke") do |seq, args|
          Core::Fibers.spawn do
            begin
              message = JSON.parse(args[0].as_s)
              command_name = message["command"].as_s
              params = message["params"]

              if command_info = router.command_info?(command_name)
                router.authorize_frontend_command!(command_name, params, frontend_context)

                if command_info.async?
                  envelope = router.execute_async(command_info, frontend_context, params)
                  respond(seq, 0, envelope.to_json)
                else
                  result = Core::MainThread.dispatch_sync do
                    router.execute_sync_for_bridge(command_info, frontend_context, params)
                  end
                  respond(seq, 0, ResponseEnvelope.success(result).to_json)
                end
              else
                respond(seq, 0, ResponseEnvelope.failure(
                  code: "COMMAND_NOT_FOUND",
                  message: "Command '#{command_name}' is not registered",
                  details: {"command" => JSON::Any.new(command_name)},
                ).to_json)
              end
            rescue ex : Core::Error
              respond(seq, 0, ResponseEnvelope.failure(
                code: ex.code || "IPC_ERROR",
                message: ex.message || "IPC command failed",
                details: {"type" => JSON::Any.new(ex.class.name)},
              ).to_json)
            rescue ex
              respond(seq, 0, ResponseEnvelope.failure(
                code: "INVALID_REQUEST",
                message: ex.message || "Invalid IPC request",
                details: {"type" => JSON::Any.new(ex.class.name)},
              ).to_json)
            end
          end
        end

        # Frontend emit → backend event bus. Fire-and-forget.
        bind("__crystal_ipc_emit", JSProc.new { |args|
          begin
            message = JSON.parse(args[0].as_s)
            payload = message["payload"]? || JSON::Any.new({} of String => JSON::Any)
            router.emit_frontend_event(message["event"].as_s, payload, frontend_context)
            ResponseEnvelope.success(JSON::Any.new(nil)).to_json_any
          rescue ex : Core::Error
            ResponseEnvelope.failure(
              code: ex.code || "IPC_ERROR",
              message: ex.message || "IPC emit failed",
              details: {"type" => JSON::Any.new(ex.class.name)},
            ).to_json_any
          rescue ex
            ResponseEnvelope.failure(
              code: "INVALID_REQUEST",
              message: ex.message || "Invalid IPC emit request",
              details: {"type" => JSON::Any.new(ex.class.name)},
            ).to_json_any
          end
        })
      end

      # Push a backend event down to frontend listeners on this webview.
      # No-op when the bridge has not been installed or the window has
      # been destroyed (the dispatched `eval` would otherwise touch a
      # freed C++ `webview`).
      #
      # The `@alive` check is performed *inside* the dispatch block so
      # that a `mark_dead!` call that fires between the outer call and
      # the deferred execution is still caught.
      def emit_to_frontend(event_name : String, payload : JSON::Any)
        js = "if (window.__CRYSTKIT_IPC__) { window.__CRYSTKIT_IPC__._dispatchEvent(#{event_name.to_json}, #{payload.to_json}); }"
        dispatch do
          next unless @alive.get
          eval(js)
        end
      end
    end
  end
end
