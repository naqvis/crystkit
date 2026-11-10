require "../base"
require "../../features/websocket"

module CrystKit
  module Plugins
    # Builtin plugin that maintains a single outbound WebSocket connection
    # for the frontend.
    #
    # Tracks at most one live connection at a time: `ws.connect` closes any
    # existing socket before opening a new one. Lifecycle and message events
    # are bridged to the frontend as `ws.open`, `ws.message`, `ws.close`, and
    # `ws.error`. Binary messages are delivered Base64-encoded so they remain
    # JSON-safe.
    #
    # Registers IPC commands:
    #   ws:connect — Connect to a WebSocket server
    #   ws:send — Send a text message over the WebSocket
    #   ws:send_binary — Send a binary message over the WebSocket
    #   ws.close — Close the WebSocket connection
    #   ws:status — Get WebSocket connection status
    #
    # Emits events: `ws.open`, `ws.message`, `ws.close`, `ws.error`
    #
    # Required capability: `websocket:connect` (URL-scoped on `ws.connect`)
    #
    # `ws.connect` takes the URL plus a JSON options object with optional
    # `headers`, `timeout` (seconds, default 30), `protocols`, and
    # `auto_reconnect` (default false). `ws.send_binary` expects a
    # Base64-encoded string. `ws.send`/`ws.send_binary` raise
    # `Core::Error` (code `WS_NOT_CONNECTED` / `WS_CLOSED`) when there
    # is no live connection.
    #
    # ```
    # app.plugin(CrystKit::Plugins::WebSocket.new)
    # ```
    class WebSocket < Plugin::Base
      # The active WebSocket connection, or `nil` when disconnected.
      #
      # At most one connection is tracked at a time; `ws.connect` replaces
      # this field (closing the prior connection first) and `ws.close`/cleanup
      # reset it to `nil`.
      @ws : Features::WebSocket? = nil

      # Returns the unique plugin identifier `"websocket"`.
      def identifier : String
        "websocket"
      end

      # Returns the metadata contract scoping `ws.connect` to the
      # `websocket:connect` capability against the URL argument and gating the
      # remaining commands on the same capability. `ws.connect` uses
      # `IPC::PolicyCatalog#resource` with json_path `"0"` to authorize the
      # URL argument, so applications can restrict the frontend to an
      # allowlist of WebSocket origins.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .resource("ws.connect", "websocket:connect", "0")
          .require(%w(ws.send ws.send_binary ws.close ws.status), "websocket:connect")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(websocket:connect),
          commands: %w(ws.connect ws.send ws.send_binary ws.close ws.status),
          events: %w(ws.open ws.message ws.close ws.error),
          ipc: ipc,
        )
      end

      # Registers the IPC commands.
      #
      # `ws.status` reports `connected` and `url` (empty url when
      # disconnected).
      def initialize_plugin(context : Plugin::Context) : Nil
        client = Features::WebSocketClient.new(context.capabilities)

        context.command "ws.connect", String, JSON::Any do |url, opts|
          # Close any existing connection first
          @ws.try(&.close)
          @ws = nil

          headers = opts["headers"]?.try(&.as_h.transform_values { |v| v.as_s? || v.to_s }) || {} of String => String
          timeout = opts["timeout"]?.try(&.as_i) || 30
          protocols = opts["protocols"]?.try(&.as_a.map(&.as_s)) || [] of String
          auto_reconnect = opts["auto_reconnect"]?.try(&.as_bool) || false

          ws_opts = Features::WSOptions.new(
            headers: headers,
            timeout: timeout.seconds,
            protocols: protocols,
          )

          # WebSocketClient.connect builds the HTTP::WebSocket and wraps it
          w = client.connect(url, ws_opts)
          w.auto_reconnect = auto_reconnect
          @ws = w

          w.on_open do
            context.emit("ws.open", JSON::Any.new(nil))
          end

          w.on_message do |msg|
            payload = case msg.data
                      when Bytes then {"type" => "binary", "data" => Base64.strict_encode(msg.data.as(Bytes))}
                      else            {"type" => "text", "data" => msg.data.to_s}
                      end
            context.emit("ws.message", context.app.coerce_to_json(payload))
          end

          w.on_close do |code, reason|
            context.emit("ws.close", context.app.coerce_to_json({"code" => code, "reason" => reason}))
          end

          w.on_error do |ex|
            context.emit("ws.error", context.app.coerce_to_json({"message" => ex.message.to_s}))
          end

          # Run the blocking event loop in a background fiber
          Core::Fibers.spawn(name: "ws-run-#{url}") { w.run }

          {"connected" => true, "url" => url}
        end

        context.command "ws.send", String do |data|
          w = @ws
          raise Core::Error.new("WebSocket not connected", code: "WS_NOT_CONNECTED") unless w
          raise Core::Error.new("WebSocket is closed", code: "WS_CLOSED") if w.closed?
          w.send_text(data)
          "ok"
        end

        context.command "ws.send_binary", String do |data|
          w = @ws
          raise Core::Error.new("WebSocket not connected", code: "WS_NOT_CONNECTED") unless w
          raise Core::Error.new("WebSocket is closed", code: "WS_CLOSED") if w.closed?
          decoded = Base64.decode(data)
          w.send_binary(decoded)
          "ok"
        end

        context.command "ws.close", Int32? do |code|
          w = @ws
          raise Core::Error.new("WebSocket not connected", code: "WS_NOT_CONNECTED") unless w
          w.close(code || 1000)
          @ws = nil
          "ok"
        end

        context.command "ws.status" do
          w = @ws
          if w && !w.closed?
            {"connected" => true, "url" => w.url}
          else
            {"connected" => false, "url" => ""}
          end
        end
      end

      # Closes the active WebSocket connection, if any. No-op when there is no
      # live connection.
      def cleanup_plugin : Nil
        @ws.try(&.close)
        @ws = nil
      end
    end
  end
end
