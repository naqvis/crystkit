require "../core/errors"

module CrystKit
  module Core
    # Framework-internal coordinator that runs work on the webview's
    # main thread from any fiber. Not a scheduler — a channel-based
    # coordination pattern that borrows the primary `EnhancedWindow`'s
    # `dispatch` queue.
    #
    # Framework features that wrap native OS GUI calls (file dialogs,
    # tray, menus, notifications, shortcuts, taskbar progress) route
    # their backend calls through `dispatch_sync`. Application code
    # never calls this directly.
    #
    # If `dispatch_sync` is called before a window has been registered
    # (e.g. from a background fiber started during initialization), the
    # calling fiber waits until `register` is called and the main event
    # loop is ready. This lets developers start background monitors and
    # other features in any order without worrying about window
    # registration timing.
    module MainThread
      @@main_fiber : Fiber?
      # The dispatch closure: queues a block onto the primary window's
      # webview event loop. Set by `App#wire_window`.
      @@dispatch : Proc(Proc(Nil), Nil)?
      # In-flight dispatch_sync cancel procs, keyed by an incrementing id.
      # When the window is destroyed, each cancel proc is called with a
      # WINDOW_DESTROYED error so the waiting fiber wakes immediately.
      @@pending = {} of UInt64 => Proc(Exception, Nil)
      @@counter = Atomic(UInt64).new(0)

      # Fibers waiting for `register` to be called. Each gets its own
      # notification channel; `register` signals all of them.
      @@registration_waiters = [] of Channel(Bool)
      # Protects registration, dispatch acquisition, and the pending/waiter
      # registries as one lifecycle state.
      @@state_lock = Mutex.new

      # Captures the main fiber without registering a dispatch closure.
      # Called by `App#initialize`.
      def self.capture_main_fiber : Nil
        @@state_lock.synchronize { @@main_fiber = Fiber.current }
      end

      # Registers the dispatch closure used to queue work onto the
      # primary window's webview event loop. Called by `App#wire_window`
      # when the first window is wired. Idempotent. Wakes any fibers
      # that are waiting for registration.
      def self.register(main_fiber : Fiber, dispatch : Proc(Proc(Nil), Nil)) : Nil
        waiters = @@state_lock.synchronize do
          @@main_fiber = main_fiber
          @@dispatch = dispatch
          registered_waiters = @@registration_waiters.dup
          @@registration_waiters.clear
          registered_waiters
        end
        waiters.each(&.send(true))
      end

      # Convenience overload that builds the dispatch closure from a
      # `Core::Window` (which already has a `dispatch` method).
      def self.register(main_fiber : Fiber, window : Core::Window) : Nil
        register(main_fiber, ->(block : Proc(Nil)) { window.dispatch { block.call } })
      end

      # Clears all registration. Called by `App#shutdown`. Safe to call
      # repeatedly. Wakes any fibers still waiting for registration with
      # `false` so they can raise instead of hanging.
      def self.clear : Nil
        error = Core::Error.new(
          "MainThread cleared while dispatch_sync was in flight",
          code: "MAINTHREAD_NOT_REGISTERED",
        )
        pending, waiters = @@state_lock.synchronize do
          @@dispatch = nil
          @@main_fiber = nil
          pending_requests = @@pending.values
          registration_waiters = @@registration_waiters.dup
          @@pending.clear
          @@registration_waiters.clear
          {pending_requests, registration_waiters}
        end
        pending.each(&.call(error))
        waiters.each(&.send(false))
      end

      # True when the calling fiber is the webview's main fiber. If no
      # fiber has been registered, treats `Fiber.current` as main (so
      # specs that run on the main thread without an App get the inline
      # fast path).
      def self.on_main? : Bool
        main = @@state_lock.synchronize { @@main_fiber }
        main.nil? || main.same?(Fiber.current)
      end

      # Run `block` on the main thread and return its value.
      #
      # - On main: runs inline, no channel, no dispatch.
      # - Off main, window registered: queues onto the primary window's
      #   `dispatch`, blocks the calling fiber on `Channel.receive` until
      #   the main event loop drains the queued block, returns the result.
      # - Off main, no window yet: blocks until `register` is called,
      #   then proceeds as above. This lets background fibers started
      #   during initialization (before `app.window`) wait for the main
      #   thread to be ready instead of failing.
      # - If the registered window is destroyed while a fiber waits,
      #   raises `WINDOW_DESTROYED`.
      # - If `clear` is called (shutdown) while waiting for registration,
      #   raises `MAINTHREAD_NOT_REGISTERED`.
      def self.dispatch_sync(&block : -> T) : T forall T
        return block.call if on_main?

        # If no dispatch closure yet, wait for registration.
        unless @@state_lock.synchronize { !@@dispatch.nil? }
          wait_for_registration
        end

        id = @@counter.add(1) + 1
        # Use T? instead of T so NoReturn (from blocks that always raise)
        # reduces to Nil, which is a valid Channel type parameter.
        done = Channel(T?).new(1)
        err = Channel(Exception).new(1)
        completed = Atomic(Bool).new(false)

        cancel = Proc(Exception, Nil).new do |e|
          err.send(e) if completed.compare_and_set(false, true)
        end
        dispatch = @@state_lock.synchronize do
          registered_dispatch = @@dispatch || raise Core::Error.new(
            "MainThread.dispatch_sync called before App registered a window",
            code: "MAINTHREAD_NOT_REGISTERED",
          )
          @@pending[id] = cancel
          registered_dispatch
        end

        queued_block = -> {
          begin
            value = block.call
            done.send(value) if completed.compare_and_set(false, true)
          rescue ex : Core::Error
            err.send(ex) if completed.compare_and_set(false, true)
          rescue ex
            if completed.compare_and_set(false, true)
              err.send(Core::Error.new(
                "dispatch_sync block failed: #{ex.message}",
                code: "MAINTHREAD_BLOCK_ERROR",
                context: ex.class.name,
              ))
            end
          end
        }

        begin
          dispatch.call(queued_block)
        rescue ex
          completed.set(true)
          @@state_lock.synchronize { @@pending.delete(id) }
          raise Core::Error.new(
            "MainThread dispatch failed: #{ex.message}",
            code: "MAINTHREAD_DISPATCH_ERROR",
            context: ex.class.name,
          )
        end

        select
        when v = done.receive
          @@state_lock.synchronize { @@pending.delete(id) }
          return v if v.is_a?(T)
          raise Core::Error.new("unreachable", code: "MAINTHREAD_INTERNAL")
        when e = err.receive
          @@state_lock.synchronize { @@pending.delete(id) }
          raise e
        end
      end

      # Fire-and-forget: queue work onto main, do not wait. Same as
      # `EnhancedWindow#dispatch` today. Safe to call from any fiber.
      # If no dispatch closure is registered yet the block is called
      # inline on the current fiber — the work still happens even in
      # test / early-init scenarios where no window exists.
      def self.dispatch(&block : -> Nil) : Nil
        return block.call if on_main?
        dispatch = @@state_lock.synchronize { @@dispatch }
        if dispatch
          dispatch.call(block)
        else
          block.call
        end
      end

      # Called by `EnhancedWindow#destroy` to fail any in-flight
      # `dispatch_sync` requests so waiting fibers wake with a clear
      # error instead of hanging.
      def self.fail_all_pending(reason : String, code : String) : Nil
        error = Core::Error.new(reason, code: code)
        pending = @@state_lock.synchronize do
          pending_requests = @@pending.values
          @@pending.clear
          pending_requests
        end
        pending.each(&.call(error))
      end

      # Block the calling fiber until `register` is called. If `clear`
      # is called instead (shutdown), raises `MAINTHREAD_NOT_REGISTERED`.
      private def self.wait_for_registration : Nil
        ch = Channel(Bool).new
        @@state_lock.synchronize do
          # Double-check: dispatch may have been registered between the
          # unlocked check outside and our lock acquisition here.
          return unless @@dispatch.nil?
          @@registration_waiters << ch
        end
        registered = ch.receive
        unless registered
          raise Core::Error.new(
            "MainThread.dispatch_sync called before App registered a window",
            code: "MAINTHREAD_NOT_REGISTERED",
          )
        end
      end
    end
  end
end
