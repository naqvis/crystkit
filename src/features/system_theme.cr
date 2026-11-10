require "json"
require "native_desktop"

module CrystKit::Features
  # Reads and monitors the operating system's light or dark appearance.
  class SystemTheme
    enum Theme
      Light
      Dark
      System
    end

    # :nodoc:
    abstract class Provider
      abstract def current : Theme
      abstract def start(interval : Time::Span, &changed : Theme ->) : Nil
      abstract def stop : Nil
    end

    # :nodoc:
    class NativeProvider < Provider
      @monitor = ::NativeDesktop::ThemeMonitor.new

      def current : Theme
        convert(::NativeDesktop::SystemTheme.current)
      end

      def start(interval : Time::Span, &changed : Theme ->) : Nil
        @monitor.start(interval) { |scheme| changed.call(convert(scheme)) }
      end

      def stop : Nil
        @monitor.stop
      end

      private def convert(scheme : ::NativeDesktop::ColorScheme) : Theme
        scheme.dark? ? Theme::Dark : Theme::Light
      end
    end

    @lock = Mutex.new
    @channel : Channel(String)?

    def initialize(@provider : Provider = NativeProvider.new)
    end

    # Returns the current effective appearance.
    def current : Theme
      @provider.current
    end

    # Emits lowercase theme names whenever the effective appearance changes.
    # Calling this again first stops and closes the previous monitor channel.
    def start_monitor(interval : Time::Span = 5.seconds) : Channel(String)
      raise ArgumentError.new("monitor interval must be positive") unless interval.positive?
      stop_monitor
      channel = Channel(String).new(1)
      @lock.synchronize { @channel = channel }
      begin
        @provider.start(interval) do |theme|
          @lock.synchronize do
            current = @channel
            if current && current.same?(channel)
              select
              when channel.send(theme.to_s.downcase)
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
