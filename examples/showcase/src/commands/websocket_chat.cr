require "../../../../src/app/app"
require "../../../../src/features/websocket"

# WebSocket bridge: connects to wss://echo.websocket.org, forwards messages
# both ways through the IPC event bus.
module Showcase
  module Commands
    module WebSocketChat
      extend self

      def setup(app : CrystKit::App) : Nil
        client = CrystKit::Features::WebSocketClient.new(app.capabilities)
        connection = nil.as(CrystKit::Features::WebSocket?)

        app.async "ws.connect", String do |url, _cancel|
          if connection
            "already_connected"
          else
            opts = CrystKit::Features::WSOptions.new(
              timeout: 10.seconds,
              headers: {"User-Agent" => "Crystal-Webview-Showcase/1.0"},
            )
            ws = client.connect(url, opts)
            connection = ws
            ws.auto_reconnect = true
            ws.reconnect_delay = 2.seconds
            ws.max_reconnect_attempts = 5

            ws.on_open { app.emit("ws:status", {"connected" => true, "url" => url}) }
            ws.on_message do |msg|
              text = msg.data.is_a?(String) ? msg.data.as(String) : "<binary>"
              app.emit("ws.message", {"text" => text})
            end
            ws.on_close { |code, reason| app.emit("ws:status", {"connected" => false, "code" => code, "reason" => reason}) }
            ws.on_error { |ex| app.emit("ws.error", {"message" => ex.message}) }

            spawn { ws.run }
            "connected"
          end
        end

        app.async "ws.send", String do |text, _cancel|
          if conn = connection
            conn.send_text(text)
            "sent"
          else
            raise "Not connected"
          end
        end

        app.async "ws.disconnect" do
          connection.try(&.close)
          connection = nil
          "ok"
        end
      end
    end
  end
end
