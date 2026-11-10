module CrystKit
  # A single-shot completion primitive for async shutdown interceptors.
  #
  # `Future(T)` bridges a Crystal value produced later (typically from a
  # native dialog callback running on the UI fiber) back to a fiber that
  # is waiting on the result. It is the asynchronous counterpart to
  # returning `Bool` synchronously from a lifecycle hook such as
  # `App#on_before_quit`.
  #
  # The future is resolved exactly once. The first `#resolve` wins; later
  # calls are ignored. `#get?` may be called more than once: after the
  # first resolution it returns the cached value without blocking.
  #
  # `#get?` accepts an optional timeout. When the timeout elapses before
  # the future resolves, `#get?` returns `nil` so callers can treat an
  # unresolved confirmation as a veto (e.g. do not quit while the user
  # has not answered "save changes?").
  #
  # ```
  # future = CrystKit::Future(Bool).new
  # show_save_dialog(on_result: ->(saving) { future.resolve(saving) })
  # future.get?(timeout: 30.seconds) # => true / false / nil
  # ```
  class Future(T)
    @value : T?
    @resolved = false
    @mutex = Mutex.new
    @waiters = [] of Channel(Bool)

    # Creates an unresolved future.
    def initialize
      @value = nil
    end

    # Resolves the future with *value*. The first call wins; subsequent
    # calls are no-ops. Wakes any fiber blocked in `#get?`.
    def resolve(value : T) : Nil
      waiters = [] of Channel(Bool)
      @mutex.synchronize do
        return if @resolved
        @value = value
        @resolved = true
        waiters = @waiters.dup
        @waiters.clear
      end
      waiters.each(&.send(true))
    end

    # Waits for the future to resolve and returns the value, or `nil` when
    # *timeout* elapses first. When *timeout* is `nil` the call blocks
    # indefinitely. Safe to call multiple times; after the first resolution
    # it returns the cached value immediately.
    def get?(timeout : Time::Span? = nil) : T?
      done = Channel(Bool).new(1)
      @mutex.synchronize do
        return @value if @resolved
        @waiters << done
      end

      if timeout
        select
        when done.receive
          @mutex.synchronize { @value }
        when timeout(timeout)
          @mutex.synchronize { @waiters.delete(done) }
          nil
        end
      else
        done.receive
        @mutex.synchronize { @value }
      end
    end

    # Waits indefinitely for the future to resolve and returns the value.
    def get : T?
      get?(nil)
    end

    # Returns `true` when the future has been resolved.
    def resolved? : Bool
      @mutex.synchronize { @resolved }
    end
  end
end
