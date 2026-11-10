module CrystKit
  module Core
    # Framework-internal coordinator that owns the background execution context for non-GUI fibers.
    #
    # The main fiber runs the webview's native event loop (`NSApplication.run`, `gtk_main`, …) on the default execution context, which we keep at parallelism 1 so the main thread is left alone for GUI work. Background fibers (IPC handlers, monitors, servers, watchers) spawn into a separate `Parallel` context started here, so they never get scheduled onto the main thread and the GUI loop never starves.
    #
    # Fibers are tied to their execution context — the main fiber's context has no other schedulers, so background work physically cannot land on the main thread. Cross-context communication (channels, sync primitives) works normally.
    #
    # The global `spawn` method is overridden so that plain `spawn do ... end` from anywhere — framework code, examples, user code, third-party shards — automatically routes to the
    # background context. Users never need to think about which context their fibers run on.
    module Fibers
      # Default maximum parallelism for the background context. Respects the `CRYSTAL_WORKERS` environment variable when set, otherwise defaults to 4.
      def self.default_max_workers : Int
        maximum = ENV["CRYSTAL_WORKERS"]?.try(&.to_i?) || 4
        maximum > 0 ? maximum : 4
      end

      @@app_ctx : Fiber::ExecutionContext::Parallel?
      @@owners = 0
      @@context_lock = Mutex.new
      @@child_reaper_stop : Channel(Nil)?

      # Starts the shared background `Parallel` execution context with a
      # maximum parallelism of *maximum*. Each start acquires one ownership
      # reference; the context is released after the matching final stop.
      def self.start(maximum : Int = 4) : Nil
        raise ArgumentError.new("maximum must be greater than zero") unless maximum > 0
        @@context_lock.synchronize do
          unless @@app_ctx
            @@app_ctx = context = Fiber::ExecutionContext::Parallel.new("crystkit", maximum: maximum)
            start_child_reaper(context)
          end
          @@owners += 1
        end
      end

      # Returns the background execution context, or `nil` if `start` has not been called (specs, CLI builder).
      def self.app_ctx? : Fiber::ExecutionContext::Parallel?
        @@context_lock.synchronize { @@app_ctx }
      end

      # Spawns *block* as a fiber on the background execution context. If `start` has not been called, spawns on the current (default) context so specs and the CLI builder work unchanged.
      #
      # This method never calls the global `spawn` — it calls `ExecutionContext#spawn` directly to avoid infinite recursion (the global `spawn` is overridden to call this method).
      def self.spawn(*, name : String? = nil, &block : ->) : Fiber
        if ctx = app_ctx?
          ctx.spawn(name: name, &block)
        else
          Fiber::ExecutionContext.current.spawn(name: name, &block)
        end
      end

      # Releases one ownership reference to the background context. Called
      # by `Runtime#shutdown`. In-flight fibers retain the context until
      # they finish; the runtime reclaims its threads on process exit.
      def self.stop : Nil
        @@context_lock.synchronize do
          return if @@owners == 0
          @@owners -= 1
          if @@owners == 0
            @@child_reaper_stop.try(&.send(nil))
            @@child_reaper_stop = nil
            @@app_ctx = nil
          end
        end
      end

      # Crystal's POSIX child-process notification loop belongs to the
      # default execution context. A native GUI loop occupies that context,
      # so explicitly reap exited children from the background context.
      # `SignalChildHandler` forwards each status to the channel already
      # owned by `Process#wait`.
      private def self.start_child_reaper(context : Fiber::ExecutionContext::Parallel) : Nil
        {% if flag?(:unix) %}
          stop = Channel(Nil).new(1)
          @@child_reaper_stop = stop
          context.spawn(name: "crystkit-child-reaper") do
            loop do
              ::Crystal::System::SignalChildHandler.call
              select
              when stop.receive
                break
              when timeout(25.milliseconds)
              end
            end
          end
        {% end %}
      end
    end
  end
end

# Crystal's default context has a single scheduler, but the runtime monitor
# may still move that scheduler to another system thread while a syscall is
# blocked. CrystKit reserves the default context for AppKit/GTK/Win32 and
# sends all other fibers to `Fibers.app_ctx`, so moving its scheduler only
# breaks the GUI thread affinity it exists to preserve.
#
# Keep monitoring every other context normally. In particular, the CrystKit
# parallel context still transfers blocked schedulers and scales as usual.
class Fiber::ExecutionContext::Monitor
  private def transfer_schedulers_blocked_on_syscall : Nil
    Fiber::ExecutionContext.each do |execution_context|
      next if execution_context.same?(Fiber::ExecutionContext.default)

      execution_context.each_scheduler do |scheduler|
        next unless scheduler.detach_syscall?

        Crystal.trace :sched, "reassociate",
          scheduler: scheduler,
          syscall: scheduler.thread.current_fiber

        pool = Fiber::ExecutionContext.thread_pool
        pool.detach(scheduler.thread)
        pool.checkout(scheduler)
      end
    end
  end
end

# Override the global `spawn` so that plain `spawn do ... end` from anywhere routes to CrystKit's background execution context instead of the default (main-thread) context.
#
# This is the transparent ergonomics path: users, examples, and third-party shards don't need to know about `Core::Fibers` — they just use `spawn` as they normally would, and fibers automatically land on a background thread.
def spawn(*, name : String? = nil, same_thread = false, &block)
  ::CrystKit::Core::Fibers.spawn(name: name, &block)
end
