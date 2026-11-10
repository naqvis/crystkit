require "../base"
require "../../features/kiosk_mode"

module CrystKit
  module Plugins
    # Kiosk mode plugin locking the window into a dedicated full-screen
    # presentation.
    #
    # Registers IPC commands:
    #   window:enter_kiosk — Enter kiosk mode
    #   window:exit_kiosk — Exit kiosk mode
    #   window:is_kiosk — Check if kiosk mode is active
    #
    # Entering and exiting kiosk mode requires the `window:manage` capability;
    # the read-only `window.is_kiosk` query is public.
    class Kiosk < Plugin::Base
      getter! kiosk : Features::KioskMode
      @installed = false

      def identifier : String
        "kiosk"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(window.enter_kiosk window.exit_kiosk), "window:manage")
          .public("window.is_kiosk")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(window:manage),
          commands: %w(window.enter_kiosk window.exit_kiosk window.is_kiosk),
          ipc: ipc,
        )
      end

      # `window.is_kiosk` returns `{"kiosk" => bool}`.
      def initialize_plugin(context : Plugin::Context) : Nil
        @kiosk = km = Features::KioskMode.new

        context.command "window.enter_kiosk" do
          km.enter
        end

        context.command "window.exit_kiosk" do
          km.exit
        end

        context.command "window.is_kiosk" do
          {"kiosk" => km.active?}
        end
      end

      def on_window_created(window : ::CrystKit::Core::Window) : Nil
        return if @installed
        kiosk.install(window.window)
        @installed = kiosk.installed?
      end

      def cleanup_plugin : Nil
        @kiosk.try(&.cleanup)
        @installed = false
      end
    end
  end
end
