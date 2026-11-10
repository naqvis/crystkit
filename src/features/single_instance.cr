require "json"
require "log"
require "native_desktop"
require "../core/errors"
require "../ipc/router"

module CrystKit
  module Features
    class SingleInstance
      abstract class Provider
        abstract def acquire : Bool
        abstract def release : Nil
        abstract def cleanup_stale : Bool
        abstract def path : Path

        def start_ipc_server(&handler : String ->) : Nil
          raise "IPC not supported"
        end

        def connect_to_primary(payload : String) : Nil
          raise "IPC not supported"
        end
      end

      class NativeProvider < Provider
        getter lock : ::NativeDesktop::InstanceLock

        def initialize(identifier : String)
          @lock = ::NativeDesktop.instance_lock(identifier)
        end

        def acquire : Bool
          @lock.acquire
        end

        def release : Nil
          @lock.release
          @lock.cleanup_ipc
        end

        def cleanup_stale : Bool
          @lock.cleanup_stale
        end

        def path : Path
          @lock.path
        end

        def start_ipc_server(&handler : String ->) : Nil
          @lock.start_ipc_server { |payload| handler.call(payload) }
        end

        def connect_to_primary(payload : String) : Nil
          @lock.connect_to_primary(payload)
        end
      end

      SECOND_INSTANCE_EVENT = "second-instance"
      IPC_TIMEOUT           = 2.seconds
      MAX_PAYLOAD_SIZE      = 65_536

      @app_id : String
      @provider : Provider
      @receive_handlers : Array(Proc(Array(String), Nil))
      @router : IPC::Router?
      @multi_instance : Bool
      @acquired : Bool
      @foreground_handler : Proc(Nil)?

      def initialize(
        @app_id : String,
        @multi_instance = false,
        provider : Provider? = nil,
      )
        @provider = provider || NativeProvider.new(@app_id)
        @receive_handlers = [] of Proc(Array(String), Nil)
        @router = nil
        @acquired = false
        @foreground_handler = nil
      end

      def acquire : Bool
        return true if @multi_instance
        begin
          @provider.cleanup_stale
          @acquired = @provider.acquire
          @acquired
        rescue ex
          raise Core::Error.new(
            "Failed to acquire single-instance lock for '#{@app_id}': #{ex.message}",
            code: "LOCK_ACQUIRE_FAILED"
          )
        end
      end

      def acquired? : Bool
        @acquired
      end

      def release : Nil
        @provider.release
        @acquired = false
        Log.debug { "SingleInstance: released lock for '#{@app_id}'" }
      end

      def send_to_existing(args : Array(String)) : Nil
        payload = args.to_json
        if payload.bytesize > MAX_PAYLOAD_SIZE
          raise Core::Error.new(
            "Argument payload exceeds maximum size of #{MAX_PAYLOAD_SIZE} bytes",
            code: "PAYLOAD_TOO_LARGE"
          )
        end
        begin
          @provider.connect_to_primary(payload)
          Log.debug { "SingleInstance: sent #{args.size} argument(s) to existing instance" }
        rescue ex
          raise Core::Error.new(
            "Failed to send arguments to existing instance of '#{@app_id}': #{ex.message}",
            code: "IPC_SEND_FAILED"
          )
        end
      end

      def on_receive(&handler : Array(String) ->) : Nil
        @receive_handlers << handler
      end

      def on_foreground(&handler : ->) : Nil
        @foreground_handler = handler
      end

      def attach_router(router : IPC::Router) : Nil
        @router = router
      end

      def listen_for_args : Nil
        return if @multi_instance
        return unless @acquired
        begin
          @provider.start_ipc_server { |payload| handle_payload(payload) }
          Log.debug { "SingleInstance: listening for second-instance arguments" }
        rescue ex
          Log.error { "SingleInstance: failed to start IPC server: #{ex.message}" }
        end
      end

      def cleanup_stale_locks : Nil
        return unless File.exists?(@provider.path.to_s)
        begin
          @provider.cleanup_stale
        rescue ex
          Log.warn { "SingleInstance: error during stale lock cleanup: #{ex.message}" }
        end
      end

      def lock_file_path : Path
        @provider.path
      end

      def socket_path : String
        socket_path_for(@app_id)
      end

      private def socket_path_for(app_id : String) : String
        hash = app_id.bytes.reduce(0_u32) { |accum, byte| (accum &* 31) &+ byte }
        port = 49152 + (hash % 16383)
        "127.0.0.1:#{port}"
      end

      private def handle_payload(payload : String) : Nil
        return if payload.empty?
        args = Array(String).from_json(payload)
        dispatch_args(args)
      rescue ex : JSON::ParseException
        Log.warn { "SingleInstance: received malformed argument payload: #{ex.message}" }
      rescue ex
        Log.error { "SingleInstance: error processing payload: #{ex.message}" }
      end

      private def dispatch_args(args : Array(String)) : Nil
        Log.debug { "SingleInstance: received #{args.size} argument(s) from new instance" }
        if handler = @foreground_handler
          begin
            handler.call
          rescue ex
            Log.error { "SingleInstance: foreground handler raised: #{ex.message}" }
          end
        end
        if router = @router
          begin
            payload = JSON::Any.new(args.map { |arg| JSON::Any.new(arg) })
            router.emit_event(SECOND_INSTANCE_EVENT, payload)
          rescue ex
            Log.error { "SingleInstance: failed to emit IPC event: #{ex.message}" }
          end
        end
        @receive_handlers.each do |handler_inner|
          begin
            handler_inner.call(args)
          rescue ex
            Log.error { "SingleInstance: on_receive handler raised: #{ex.message}" }
          end
        end
      end
    end
  end
end
