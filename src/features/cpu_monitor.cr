require "log"
require "native_desktop"

module CrystKit::Features
  # Samples aggregate CPU utilization between successive calls.
  class CpuMonitor
    Log = ::Log.for(self)

    # :nodoc:
    abstract class Provider
      abstract def sample : Float64?
      abstract def reset : Nil
    end

    # :nodoc:
    class NativeProvider < Provider
      @sampler = ::NativeDesktop::CPUSampler.new

      def sample : Float64?
        @sampler.sample
      end

      def reset : Nil
        @sampler.reset
      end
    end

    @lock = Mutex.new

    def initialize(@provider : Provider = NativeProvider.new)
    end

    # Returns aggregate CPU usage since the previous call. The first call and
    # a call after reset return `0.0` because no sampling interval exists yet.
    def usage_pct : Float64
      value = @lock.synchronize { @provider.sample }
      (value || 0.0).clamp(0.0, 100.0).round(1)
    rescue ex
      Log.warn(exception: ex) { "could not sample CPU utilization" }
      0.0
    end

    # Discards the current sampling baseline.
    def reset : Nil
      @lock.synchronize { @provider.reset }
    end
  end
end
