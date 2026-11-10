require "json"
require "http/web_socket"
require "log"
require "../core/errors"
require "../security/capability"

module CrystKit
  module Features
    # WebSocket message types reported by `WSMessage`:
    # `Text` (UTF-8 strings) and `Binary` (raw bytes).
    enum WSMessageType
      Text
      Binary
    end

    # A received WebSocket message delivered to `WebSocket#on_message` handlers.
    #
    # Wraps the raw *data* (a `String` for text frames, `Bytes` for binary
    # frames) together with the *type* indicating which it is. Handlers
    # should branch on *type* before unwrapping *data*.
    struct WSMessage
      getter data : String | Bytes
      getter type : WSMessageType

      # Creates a message.
      def initialize(@data : String | Bytes, @type : WSMessageType)
      end
    end

    # Connection options for a `WebSocket` opened via `WebSocketClient#connect`.
    struct WSOptions
      # HTTP request headers sent during the WebSocket handshake.
      property headers : Hash(String, String)
      # Connection and read timeout for the initial handshake.
      property timeout : Time::Span
      # Sub-protocols offered to the server (e.g. `["chat", "v1.stomp"]`).
      property protocols : Array(String)

      # Creates an options bundle.
      def initialize(
        @headers : Hash(String, String) = Hash(String, String).new,
        @timeout = 30.seconds,
        @protocols : Array(String) = [] of String,
      )
      end
    end

    # A live WebSocket connection handle with optional auto-reconnect.
    #
    # Provides a unified `on_message` handler that receives both text and
    # binary frames as a `WSMessage`, optional automatic reconnection
    # with exponential backoff (`#auto_reconnect`, `#reconnect_delay`,
    # `#max_reconnect_attempts`), and `Core::NetworkError` wrapping for
    # send/close failures.
    #
    # The event loop is run by calling `#run` inside a fiber; that call
    # blocks until the socket closes or an error occurs. Instances are
    # not safe to share across fibers for concurrent sends — use a mutex
    # in calling code if needed.
    class WebSocket
      # Whether the socket should automatically reconnect after a close or
      # error. Defaults to `false`. When enabled, reconnection uses
      # exponential backoff based on `#reconnect_delay`.
      property? auto_reconnect : Bool = false
      # Base delay for exponential-backoff reconnection (doubled per attempt).
      property reconnect_delay : Time::Span = 1.second
      # Maximum number of reconnection attempts before giving up.
      property max_reconnect_attempts : Int32 = 5

      @ws : HTTP::WebSocket
      getter url : String
      @options : WSOptions
      @open_handler : Proc(Nil)?
      @message_handler : Proc(WSMessage, Nil)?
      @close_handler : Proc(Int32, String, Nil)?
      @error_handler : Proc(Exception, Nil)?
      @closed : Bool = false
      @reconnect_count : Int32 = 0

      # Creates a connection handle. Normally obtained via
      # `WebSocketClient#connect`.
      def initialize(@ws : HTTP::WebSocket, @url : String, @options : WSOptions)
        setup_handlers
      end

      # Send a text *message* on the socket.
      #
      # Raises `Core::NetworkError` (code `WS_CLOSED`) if the socket is
      # already closed, or `WS_SEND_ERROR` if the underlying send fails.
      def send_text(message : String) : Nil
        raise Core::NetworkError.new("WebSocket is closed", code: "WS_CLOSED") if @closed
        @ws.send(message)
      rescue ex
        raise Core::NetworkError.new("Failed to send text: #{ex.message}", code: "WS_SEND_ERROR")
      end

      # Send a binary *data* payload on the socket.
      #
      # Raises `Core::NetworkError` (code `WS_CLOSED`) if the socket is
      # already closed, or `WS_SEND_ERROR` if the underlying send fails.
      def send_binary(data : Bytes) : Nil
        raise Core::NetworkError.new("WebSocket is closed", code: "WS_CLOSED") if @closed
        @ws.send(data)
      rescue ex
        raise Core::NetworkError.new("Failed to send binary: #{ex.message}", code: "WS_SEND_ERROR")
      end

      # Closes the socket with an optional *code* and *reason*.
      #
      # After this call `#closed?` is `true` and `#auto_reconnect` is
      # disabled so the close is permanent. Safe to call when already
      # closed (no-op). Errors from the underlying close are logged at
      # warn level rather than raised.
      def close(code : Int32 = 1000, reason : String = "") : Nil
        return if @closed
        @closed = true
        @auto_reconnect = false
        @ws.close
      rescue ex
        Log.warn { "WebSocket close error: #{ex.message}" }
      end

      # Register *block* as the open handler, called once when `#run`
      # begins (and again after each successful reconnect).
      def on_open(&block : ->)
        @open_handler = block
      end

      # Register *block* as the message handler for both text and binary
      # frames. Only one handler is kept; registering a new one replaces
      # the previous.
      def on_message(&block : WSMessage ->)
        @message_handler = block
      end

      # Register *block* as the close handler, receiving the close *code*
      # and *reason* string.
      def on_close(&block : Int32, String ->)
        @close_handler = block
      end

      # Register *block* as the error handler for transport-level failures.
      def on_error(&block : Exception ->)
        @error_handler = block
      end

      # Returns `true` once the socket has been closed (either via `#close`
      # or a server-initiated close frame).
      def closed? : Bool
        @closed
      end

      # Runs the WebSocket event loop (blocking). Call in a fiber.
      #
      # Invokes the open handler, then blocks dispatching incoming frames
      # until the socket closes or an error occurs. On error, the error
      # handler is invoked and — if `#auto_reconnect` is enabled and the
      # socket was not deliberately closed — a reconnection is attempted
      # with exponential backoff.
      def run : Nil
        @open_handler.try(&.call)
        @ws.run
      rescue ex
        @error_handler.try(&.call(ex))
        attempt_reconnect if @auto_reconnect && !@closed
      end

      # :nodoc:
      private def setup_handlers
        @ws.on_message do |msg|
          @message_handler.try(&.call(WSMessage.new(msg, WSMessageType::Text)))
        end

        @ws.on_binary do |bytes|
          @message_handler.try(&.call(WSMessage.new(bytes, WSMessageType::Binary)))
        end

        @ws.on_close do |code, reason|
          @closed = true
          close_code = case code
                       when HTTP::WebSocket::CloseCode then code.value
                       when Int32                      then code
                       else                                 1000
                       end
          @close_handler.try(&.call(close_code, reason || ""))
          attempt_reconnect if @auto_reconnect
        end
      end

      # :nodoc:
      private def attempt_reconnect
        return if @reconnect_count >= @max_reconnect_attempts

        delay = @reconnect_delay * (2 ** @reconnect_count) # exponential backoff
        @reconnect_count += 1

        Core::Fibers.spawn do
          sleep delay
          begin
            new_ws = HTTP::WebSocket.new(URI.parse(@url))
            @ws = new_ws
            @closed = false
            setup_handlers
            @open_handler.try(&.call)
            @ws.run
          rescue ex
            @error_handler.try(&.call(ex))
            attempt_reconnect if @auto_reconnect && @reconnect_count < @max_reconnect_attempts
          end
        end
      end
    end

    # WebSocket client factory enforcing the `websocket:connect` capability.
    # Returns a `WebSocket` handle for further interaction.
    class WebSocketClient
      @capabilities : Security::CapabilitySystem

      # Creates a client that consults *capabilities* on every `#connect`.
      def initialize(@capabilities : Security::CapabilitySystem)
      end

      # Establishes a WebSocket connection to *url* with the given *options*.
      #
      # Supports `ws://` and `wss://` schemes only; other schemes raise
      # `Core::NetworkError` with code `INVALID_WS_URL`. The
      # `websocket:connect` capability is required for *url*. Returns a
      # `WebSocket` ready for `#run` — the caller is responsible for
      # launching the event loop in a fiber.
      #
      # Raises `Core::SecurityError` if the capability is denied and
      # `Core::NetworkError` (code `WS_CONNECT_ERROR`) for other
      # connection failures.
      def connect(url : String, options : WSOptions = WSOptions.new) : WebSocket
        @capabilities.require!("websocket:connect", url)

        uri = URI.parse(url)
        unless uri.scheme == "ws" || uri.scheme == "wss"
          raise Core::NetworkError.new(
            "Invalid WebSocket URL scheme '#{uri.scheme}': must be ws:// or wss://",
            code: "INVALID_WS_URL"
          )
        end

        headers = HTTP::Headers.new
        options.headers.each { |k, v| headers[k] = v }

        ws = HTTP::WebSocket.new(uri, headers)
        WebSocket.new(ws, url, options)
      rescue ex : Core::NetworkError | Core::SecurityError
        raise ex
      rescue ex
        raise Core::NetworkError.new(
          "Failed to connect to #{url}: #{ex.message}",
          code: "WS_CONNECT_ERROR"
        )
      end
    end
  end
end
