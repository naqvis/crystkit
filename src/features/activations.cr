require "native_desktop"

module CrystKit::Features
  module ActivationTypes
    URL            = "url"
    Files          = "files"
    SecondInstance = "second-instance"
  end

  record Activation,
    type : String,
    values : Array(String),
    timestamp : Time do
    include JSON::Serializable
  end

  class Activations
    abstract class Subscription
      abstract def close : Nil
    end

    abstract class Provider
      abstract def subscribe(&handler : Activation -> Nil) : Subscription
    end

    class NativeSubscription < Subscription
      def initialize(@registration : ::NativeDesktop::Registration)
      end

      def close : Nil
        @registration.close
      end
    end

    class CallbackSubscription < Subscription
      @closed = false

      def initialize(&@close_action : -> Nil)
      end

      def close : Nil
        return if @closed
        @closed = true
        @close_action.call
      end
    end

    class NativeProvider < Provider
      def subscribe(&handler : Activation -> Nil) : Subscription
        registration = ::NativeDesktop.activations.on_event do |event|
          handler.call(Activation.new(event.type.value, event.values, event.timestamp))
        end
        NativeSubscription.new(registration)
      end
    end

    @subscription : Subscription
    @handlers = {} of UInt64 => Proc(Activation, Nil)
    @history = [] of Activation
    @next_handler_id = 0_u64
    @lock = Mutex.new

    def initialize(@provider : Provider = NativeProvider.new)
      @subscription = @provider.subscribe { |activation| dispatch(activation) }
    end

    # Subscribes to all activation types. Recent cold-start activations are
    # replayed so plugins installed after `App` construction do not miss them.
    def on_event(replay : Bool = true, &handler : Activation -> Nil) : Subscription
      id, history = @lock.synchronize do
        @next_handler_id &+= 1
        @handlers[@next_handler_id] = handler
        {@next_handler_id, replay ? @history.dup : [] of Activation}
      end
      history.each(&handler)
      CallbackSubscription.new { @lock.synchronize { @handlers.delete(id) } }
    end

    def cleanup : Nil
      @subscription.close
      @lock.synchronize do
        @handlers.clear
        @history.clear
      end
    end

    private def dispatch(activation : Activation) : Nil
      handlers = @lock.synchronize do
        @history.shift if @history.size >= 64
        @history << activation
        @handlers.values.dup
      end
      handlers.each(&.call(activation))
    end
  end
end
