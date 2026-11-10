require "log"
require "file_watcher"
require "./watch_event"
require "../core/fibers"

module CrystKit
  module Features
    # Application-facing adapter around the file_watcher shard. Each watched
    # root receives an independent bounded channel; the shard owns all native
    # resources and backend fallback behaviour.
    class FileWatcher
      Log = ::Log.for(self)
      alias WatchEvent = Features::WatchEvent

      @watcher : ::FileWatcher::Watcher
      @channels = {} of String => Channel(WatchEvent)
      @recursive = {} of String => Bool
      @mutex = Mutex.new
      @pump_started = Atomic(Bool).new(false)
      @closed = Atomic(Bool).new(false)

      def initialize(poll_interval : Time::Span = 250.milliseconds)
        @watcher = ::FileWatcher::Watcher.new(poll_interval: poll_interval)
      end

      def watch(path : String, recursive : Bool = true) : Channel(WatchEvent)
        raise ::FileWatcher::ClosedError.new("watcher is closed") if @closed.get
        real_path = File.realpath(path)
        channel = Channel(WatchEvent).new(256)

        existing = @mutex.synchronize do
          if current = @channels[real_path]?
            current
          else
            @channels[real_path] = channel
            @recursive[real_path] = recursive
            nil
          end
        end
        return existing if existing

        begin
          events = @watcher.watch(real_path, recursive: recursive)
          start_pump(events)
        rescue ex
          @mutex.synchronize do
            @channels.delete(real_path)
            @recursive.delete(real_path)
          end
          channel.close
          raise ex
        end
        channel
      end

      def unwatch(path : String) : Nil
        real_path = canonical_path(path)
        channel = @mutex.synchronize do
          @recursive.delete(real_path)
          @channels.delete(real_path)
        end
        @watcher.unwatch(real_path) if channel
        channel.try(&.close)
      end

      def watcher_paths : Array(String)
        @mutex.synchronize { @channels.keys.dup }
      end

      def close : Nil
        return if @closed.swap(true)
        @watcher.close
        channels = @mutex.synchronize do
          result = @channels.values.dup
          @channels.clear
          @recursive.clear
          result
        end
        channels.each { |channel| channel.close unless channel.closed? }
      end

      private def start_pump(events : Channel(::FileWatcher::Event)) : Nil
        return if @pump_started.swap(true)
        Core::Fibers.spawn(name: "file_watcher-events") do
          loop do
            event = events.receive
            if event.change?
              dispatch(WatchEvent.new(event.kind.to_s.downcase, event.path, event.old_path))
            elsif event.error?
              Log.error(exception: event.exception) { "FileWatcher backend error" }
            end
          end
        rescue Channel::ClosedError
        ensure
          @pump_started.set(false)
        end
      end

      private def dispatch(event : WatchEvent) : Nil
        channels = @mutex.synchronize do
          @channels.compact_map do |root, channel|
            recursive = @recursive[root]
            matches?(event.path, root, recursive) ||
              event.old_path.try { |old_path| matches?(old_path, root, recursive) } ? channel : nil
          end
        end

        channels.each do |channel|
          select
          when channel.send(event)
          else
            Log.warn { "FileWatcher: dropping event for slow consumer: #{event.path}" }
          end
        rescue Channel::ClosedError
        end
      end

      private def matches?(path : String, root : String, recursive : Bool) : Bool
        canonical = canonical_path(path)
        {% if flag?(:win32) %}
          canonical = canonical.gsub('\\', '/')
          root = root.gsub('\\', '/')
        {% end %}
        return true if canonical == root
        return false unless canonical.starts_with?(root + '/')
        recursive || File.dirname(canonical) == root
      end

      private def canonical_path(path : String) : String
        File.realpath(path)
      rescue
        File.expand_path(path)
      end
    end
  end
end
