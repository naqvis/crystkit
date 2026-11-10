require "uuid"
require "json"
require "log"
require "../core/errors"
require "./router"

module CrystKit::IPC
  # A bidirectional streaming channel between Crystal backend and JS
  # frontend.
  #
  # Channels allow the backend to push a stream of values to the frontend
  # after an IPC command has returned its initial response. Unlike raw
  # events, channels provide:
  #   - Ordered delivery (values arrive in the order they are sent)
  #   - Lifecycle management (auto-cleanup on close)
  #   - Backpressure hints via thresholds
  #
  # Usage (Crystal):
  # ```
  # context.command "data.stream" do
  #   ch = Channel(String).new(context.router)
  #   spawn do
  #     ["a", "b", "c"].each { |s| ch.send(s); sleep 0.1 }
  #     ch.close
  #   end
  #   {"channel_id" => ch.id}
  # end
  # ```
  #
  # Usage (JavaScript):
  # ```js
  # const res = await window.__CRYSTKIT_IPC__.invoke("data:stream");
  # const ch = window.__CRYSTKIT_IPC__.channel(res.channel_id);
  # ch.onData((val) => console.log(val));
  # ch.onEnd(() => console.log("done"));
  # ```
  class Channel(T)
    # Logger scoped to this channel type, surfaced as `Channel(T).Log`.
    Log = ::Log.for(self)

    # The UUID identifying this channel. The frontend uses this id to
    # subscribe via `window.__CRYSTKIT_IPC__.channel(id)`.
    getter id : String

    # `true` once `close` or `close_with_error` has been called. After
    # this flag is set, further `#send` calls raise `Core::IPCError`.
    @closed : Bool

    @ipc : Router
    @send_count : UInt64
    @buffer_size_threshold : Int32
    @mutex = Mutex.new

    # Creates a new channel bound to `ipc`.
    #
    # When `owner` is supplied, the channel is registered with the router
    # so that frontend subscription requests can be authorized.
    # `target_window_id` restricts the channel to a single window; `nil`
    # allows any window.
    #
    # `buffer_size_threshold` is a backpressure hint (currently
    # informational).
    def initialize(
      @ipc,
      @buffer_size_threshold = 1024,
      owner : String? = nil,
      target_window_id : String? = nil,
    )
      @id = UUID.random.to_s
      @closed = false
      @send_count = 0_u64
      @ipc.register_channel_owner(@id, owner, target_window_id) if owner
    end

    # Send a value to the frontend through the channel. Values are delivered
    # in order.
    #
    # Raises `Core::IPCError` (code `CHANNEL_CLOSED`) if called after
    # `#close` or `#close_with_error`.
    def send(value : T) : Nil
      payload = @mutex.synchronize do
        raise Core::IPCError.new(
          "Channel '#{@id}' is closed",
          code: "CHANNEL_CLOSED"
        ) if @closed

        @send_count += 1

        event_payload = JSON::Any.new({
          "channel_id" => JSON::Any.new(@id),
          "seq"        => JSON::Any.new(@send_count.to_i64),
          "value"      => to_json_any(value),
        })

        event_payload
      end
      @ipc.emit_event("__channel_data:#{@id}", payload)
      nil
    end

    # Closes the channel, signalling the frontend that no more values will
    # arrive. After closing, further `#send` calls raise. Idempotent.
    def close : Nil
      payload = @mutex.synchronize do
        return if @closed
        @closed = true

        event_payload = JSON::Any.new({
          "channel_id" => JSON::Any.new(@id),
        })
        event_payload
      end
      @ipc.emit_event("__channel_close:#{@id}", payload)
      Log.debug { "Channel[#{@id}]: closed after #{@send_count} values" }
    end

    # Closes the channel with an error; the frontend receives `message` via
    # its `onError` callback. Idempotent like `#close`.
    def close_with_error(message : String) : Nil
      payload = @mutex.synchronize do
        return if @closed
        @closed = true

        event_payload = JSON::Any.new({
          "channel_id" => JSON::Any.new(@id),
          "error"      => JSON::Any.new(message),
        })
        event_payload
      end
      @ipc.emit_event("__channel_error:#{@id}", payload)
      Log.debug { "Channel[#{@id}]: closed with error: #{message}" }
    end

    # Returns `true` when at least one value has been sent and the channel
    # has not been closed.
    def active? : Bool
      @mutex.synchronize { @send_count > 0 && !@closed }
    end

    # Returns whether this channel has been closed.
    def closed? : Bool
      @mutex.synchronize { @closed }
    end

    # :nodoc:
    private def to_json_any(value : T) : JSON::Any forall T
      if value.is_a?(JSON::Any)
        value
      else
        JSON.parse(value.to_json)
      end
    end
  end
end
