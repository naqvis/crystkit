require "native_desktop"

module CrystKit::Features
  record SessionChange,
    type : String,
    timestamp : Time do
    include JSON::Serializable
  end

  class SessionLifecycle
    abstract class Subscription
      abstract def close : Nil
    end

    abstract class Provider
      abstract def subscribe(&handler : SessionChange -> Nil) : Subscription
    end

    class NativeSubscription < Subscription
      def initialize(@registration : ::NativeDesktop::Registration)
      end

      def close : Nil
        @registration.close
      end
    end

    class NativeProvider < Provider
      def subscribe(&handler : SessionChange -> Nil) : Subscription
        registration = ::NativeDesktop.session.on_event do |event|
          handler.call(SessionChange.new(event.type.value, event.timestamp))
        end
        NativeSubscription.new(registration)
      end
    end

    @subscription : Subscription?

    def initialize(@provider : Provider = NativeProvider.new)
    end

    def start(&handler : SessionChange -> Nil) : Nil
      stop
      @subscription = @provider.subscribe(&handler)
    end

    def stop : Nil
      @subscription.try(&.close)
      @subscription = nil
    end
  end
end
