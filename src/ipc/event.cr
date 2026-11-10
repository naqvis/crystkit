require "json"

module CrystKit::IPC
  # Type of a subscriber callback for `Router#subscribe_event` and
  # `Router#emit_event`.
  #
  # Events are fire-and-forget: the handler returns `nil` and cannot
  # produce a value flowing back to the emitter. Exceptions raised inside
  # a handler are caught and logged.
  alias EventHandler = Proc(JSON::Any, Nil)
end
