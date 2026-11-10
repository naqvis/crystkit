require "json"
require "native_desktop"

module CrystKit::Features
  # Reports battery and external-power state.
  class PowerMonitor
    # Snapshot of the system's battery state.
    struct BatteryInfo
      include JSON::Serializable

      property? charging : Bool
      property level : Float64
      # Estimated hours until full or empty, or `nil` when unavailable.
      property time_remaining : Float64?
      property? external_power : Bool

      def initialize(@charging : Bool, @level : Float64, @time_remaining = nil, @external_power : Bool = charging)
      end
    end

    # :nodoc:
    abstract class Provider
      abstract def current : BatteryInfo?
      abstract def start(interval : Time::Span, &changed : BatteryInfo? ->) : Nil
      abstract def stop : Nil
    end

    # :nodoc:
    class NativeProvider < Provider
      @monitor = ::NativeDesktop::PowerMonitor.new

      def current : BatteryInfo?
        convert(::NativeDesktop::Power.battery)
      end

      def start(interval : Time::Span, &changed : BatteryInfo? ->) : Nil
        @monitor.start(interval) { |status| changed.call(convert(status)) }
      end

      def stop : Nil
        @monitor.stop
      end

      private def convert(status : ::NativeDesktop::BatteryStatus?) : BatteryInfo?
        return nil unless status
        BatteryInfo.new(
          charging: status.charging?,
          level: status.level || 1.0,
          time_remaining: status.remaining.try(&.total_hours),
          external_power: status.external_power?,
        )
      end
    end

    @lock = Mutex.new
    @channel : Channel(BatteryInfo)?

    def initialize(@provider : Provider = NativeProvider.new)
    end

    # Returns the current battery state, or `nil` on systems without a battery.
    def battery_info : BatteryInfo?
      @provider.current
    end

    # Returns `true` when a battery is present and external power is disconnected.
    def on_battery? : Bool
      info = battery_info
      info ? !info.external_power? : false
    end

    # Emits snapshots when the battery state changes. Restarting first closes
    # the previous channel and stops its monitor.
    def start_monitor(interval : Time::Span = 30.seconds) : Channel(BatteryInfo)
      raise ArgumentError.new("monitor interval must be positive") unless interval.positive?
      stop_monitor
      channel = Channel(BatteryInfo).new(1)
      @lock.synchronize { @channel = channel }
      begin
        @provider.start(interval) do |info|
          next unless info
          @lock.synchronize do
            current = @channel
            if current && current.same?(channel)
              select
              when channel.send(info)
              else
              end
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
  end
end
