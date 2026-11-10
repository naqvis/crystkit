require "native_desktop"

module CrystKit::Features
  # Reports user idle time and monitors idle/active transitions.
  class IdleMonitor
    struct Change
      getter? idle : Bool
      getter seconds : Int32

      def initialize(@idle : Bool, @seconds : Int32)
      end
    end

    # :nodoc:
    abstract class Provider
      abstract def duration : Time::Span
      abstract def start(threshold : Time::Span, interval : Time::Span, &changed : Change ->) : Nil
      abstract def stop : Nil
    end

    # :nodoc:
    class NativeProvider < Provider
      @monitor = ::NativeDesktop::IdleMonitor.new

      def duration : Time::Span
        ::NativeDesktop::Idle.duration
      end

      def start(threshold : Time::Span, interval : Time::Span, &changed : Change ->) : Nil
        @monitor.start(threshold, interval) do |event|
          changed.call(Change.new(event.idle?, seconds(event.duration)))
        end
      end

      def stop : Nil
        @monitor.stop
      end

      private def seconds(duration : Time::Span) : Int32
        duration.total_seconds.clamp(0.0, Int32::MAX.to_f64).to_i32
      end
    end

    @lock = Mutex.new
    @channel : Channel(Change)?

    def initialize(@provider : Provider = NativeProvider.new)
    end

    # Returns seconds since the last user input.
    def idle_seconds : Int32
      @provider.duration.total_seconds.clamp(0.0, Int32::MAX.to_f64).to_i32
    end

    # Returns `true` after at least five minutes without user input.
    def idle? : Bool
      idle_seconds >= 300
    end

    # Emits the current state followed by idle/active transitions.
    def start_monitor(threshold : Time::Span = 5.minutes, interval : Time::Span = 30.seconds) : Channel(Change)
      raise ArgumentError.new("idle threshold cannot be negative") if threshold < 0.seconds
      raise ArgumentError.new("monitor interval must be positive") unless interval.positive?
      stop_monitor
      channel = Channel(Change).new(1)
      @lock.synchronize { @channel = channel }
      begin
        @provider.start(threshold, interval) do |change|
          @lock.synchronize do
            current = @channel
            if current && current.same?(channel)
              offer(channel, change)
            end
          end
        end
      rescue ex
        @lock.synchronize do
          current = @channel
          @channel = nil if current && current.same?(channel)
        end
        channel.close unless channel.closed?
        raise ex
      end
      channel
    end

    # Stops monitoring and closes the current event channel.
    def stop_monitor : Nil
      channel = @lock.synchronize do
        current = @channel
        @channel = nil
        current
      end
      @provider.stop
      channel.try { |value| value.close unless value.closed? }
    end

    def monitoring? : Bool
      @lock.synchronize { !@channel.nil? }
    end

    private def offer(channel : Channel(Change), change : Change) : Nil
      select
      when channel.send(change)
        return
      else
      end
      select
      when channel.receive
      else
      end
      select
      when channel.send(change)
      else
      end
    end
  end
end
