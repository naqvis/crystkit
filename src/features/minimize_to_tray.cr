require "log"
require "../core/errors"
require "../security/capability"

module CrystKit::Features
  # Coordinates user-driven "minimize to system tray" behaviour.
  #
  # Holds the enabled/disabled flag, optionally calls a user-supplied handler
  # when the minimize gesture fires, and gates the enable transition behind
  # the `tray:minimize` capability. The tray icon surface itself is owned by
  # `Features::Tray`.
  #
  # ```
  # mtt = CrystKit::Features::MinimizeToTray.new(caps)
  # mtt.on_minimize { window.hide; tray.show }
  # mtt.enable
  # mtt.trigger_minimize # called from the window's on_minimize hook
  # ```
  class MinimizeToTray
    Log = ::Log.for(self)

    @enabled : Bool
    @on_minimize : Proc(Nil)?

    # Creates a minimize-to-tray controller optionally bound to a capability
    # system.
    #
    # The instance starts disabled; call `#enable` to turn it on (which
    # performs the `tray:minimize` capability check). *capabilities* may be
    # `nil` for an unrestricted instance.
    def initialize(@capabilities : Security::CapabilitySystem? = nil)
      @enabled = false
      @on_minimize = nil
    end

    # Enables minimize-to-tray behaviour after a capability check.
    #
    # Requires the `tray:minimize` capability; raises `Core::SecurityError`
    # (code `CAPABILITY_DENIED`) on denial. No-op (other than the check) when
    # already enabled.
    def enable : Nil
      @capabilities.try(&.require!("tray:minimize"))
      @enabled = true
      Log.info { "Minimize-to-tray enabled" }
    end

    # Disables minimize-to-tray behaviour.
    #
    # Subsequent `#trigger_minimize` calls return `false` without invoking
    # the handler. Idempotent.
    def disable : Nil
      @enabled = false
      Log.info { "Minimize-to-tray disabled" }
    end

    # Returns `true` when minimize-to-tray is currently enabled.
    def enabled? : Bool
      @enabled
    end

    # Registers the block invoked when `#trigger_minimize` fires.
    #
    # The block receives no arguments. Only one handler is kept at a time;
    # re-calling replaces the previous one.
    def on_minimize(&block : -> Nil) : Nil
      @on_minimize = block
    end

    # Fires the minimize-to-tray transition.
    #
    # Returns `false` immediately when `#enabled?` is `false` — the handler
    # is *not* invoked. When enabled the registered `on_minimize` block (if
    # any) runs synchronously, and `true` is returned. The boolean return
    # lets callers short-circuit window logic based on whether CrystKit took
    # ownership of the gesture.
    def trigger_minimize : Bool
      return false unless @enabled
      @on_minimize.try(&.call)
      true
    end
  end
end
