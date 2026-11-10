require "native_desktop"

module CrystKit::Features
  # Runtime support information reported by the operating-system integration
  # layer. Identifiers are strings so extension shards can add capabilities.
  record SystemCapability,
    id : String,
    state : String,
    reason : String? = nil do
    include JSON::Serializable

    def supported? : Bool
      state == "supported"
    end
  end

  class SystemCapabilities
    abstract class Provider
      abstract def all : Array(SystemCapability)
      abstract def status(id : String) : SystemCapability
    end

    class NativeProvider < Provider
      def all : Array(SystemCapability)
        ::NativeDesktop.capabilities.all.map { |capability| convert(capability) }
      end

      def status(id : String) : SystemCapability
        convert(::NativeDesktop.capabilities.status(id))
      end

      private def convert(capability : ::NativeDesktop::Capability) : SystemCapability
        SystemCapability.new(
          capability.feature.value,
          capability.state.to_s.underscore.gsub('_', '-'),
          capability.reason,
        )
      end
    end

    def initialize(@provider : Provider = NativeProvider.new)
    end

    def all : Array(SystemCapability)
      @provider.all
    end

    def status(id : String) : SystemCapability
      raise ArgumentError.new("capability identifier cannot be empty") if id.strip.empty?
      @provider.status(id)
    end

    def supported?(id : String) : Bool
      status(id).supported?
    end
  end
end
