require "log"

module CrystKit
  module Core
    # Owns application running state and shutdown callbacks.
    #
    # Shutdown hooks run in *reverse* registration order. Exceptions raised
    # by a hook are logged and do not prevent subsequent hooks from running.
    #
    # Not thread-safe; intended for use on the application's main thread.
    class Lifecycle
      # Whether the application is currently inside its run loop.
      property? running : Bool

      # Registered shutdown hooks, in registration order (a copy).
      def shutdown_hooks : Array(Proc(Nil))
        @shutdown_hooks.dup
      end

      def initialize
        @running = false
        @shutdown_hooks = [] of Proc(Nil)
      end

      # Append a shutdown hook. Hooks run in reverse registration order
      # during `#shutdown`. Exceptions are logged and swallowed.
      def on_shutdown(&block : -> Nil) : Nil
        @shutdown_hooks << block
      end

      # Run every registered shutdown hook in reverse registration order.
      # The hook list is not cleared; re-invoking re-runs all hooks.
      def shutdown : Nil
        @shutdown_hooks.reverse_each do |hook|
          hook.call
        rescue ex
          Log.warn { "Shutdown hook failed: #{ex.message}" }
        end
      end
    end
  end
end
