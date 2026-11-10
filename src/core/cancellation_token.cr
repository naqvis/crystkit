module CrystKit::Core
  # Cooperative cancellation signal passed to async command handlers.
  #
  # The framework creates one token per `app.async` invocation.  When the
  # command's timeout elapses, the framework calls `#cancel`.  The handler
  # can poll `#cancelled?` or call `#check!` at natural boundaries to bail
  # out early and release resources sooner than the orphaned fiber would
  # otherwise die on its own.
  #
  # Crystal cannot forcibly kill a fiber, so cancellation is cooperative —
  # the handler must opt in by checking the token.  Handlers that ignore
  # the token will still run to completion in the background; the token
  # merely gives well-behaved handlers a way to exit promptly.
  #
  # ```
  # app.async "db.query", String do |sql, cancel|
  #   rows = [] of Row
  #   DB.query(sql).each do |row|
  #     cancel.check! # bail out between rows if timed out
  #     rows << row
  #   end
  #   rows
  # end
  # ```
  class CancellationToken
    @cancelled : Atomic(Bool) = Atomic.new(false)

    # Returns `true` if `#cancel` has been called.
    def cancelled? : Bool
      @cancelled.get
    end

    # Marks the token as cancelled.  Called by the framework when the
    # command's timeout fires.  Idempotent.
    def cancel : Nil
      @cancelled.set(true)
    end

    # Raises `CancelledError` if the token has been cancelled.  Handlers
    # call this at natural boundaries (between loop iterations, before
    # starting a new sub-task) to exit promptly when the timeout has
    # elapsed.
    def check! : Nil
      raise CancelledError.new("Async command was cancelled") if @cancelled.get
    end
  end
end
