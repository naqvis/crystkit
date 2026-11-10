require "../base"
require "../../features/shortcuts"

module CrystKit
  module Plugins
    # Builtin plugin that registers global (system-wide) keyboard shortcuts
    # and forwards trigger events to the frontend.
    #
    # Shortcuts registered here are global — they fire even when the
    # application is not focused — so applications should register only
    # accelerators the user expects to be available everywhere (e.g. a global
    # "show window" hotkey). Each registered accelerator emits a
    # `shortcuts.triggered` event carrying the accelerator string when pressed.
    #
    # Registers IPC commands:
    #   shortcuts:register — Register a global keyboard shortcut
    #   shortcuts:unregister — Unregister a global keyboard shortcut
    #   shortcuts:unregister_all — Unregister all global keyboard shortcuts
    #   shortcuts:start_listening — Start listening for shortcuts
    #   shortcuts:stop_listening — Stop listening for shortcuts
    #   shortcuts:list — List registered shortcuts
    #
    # Emits events: `shortcuts.triggered`
    #
    # Required capability: `shortcuts:manage`
    #
    # ```
    # app.plugin(CrystKit::Plugins::Shortcuts.new)
    # ```
    class Shortcuts < Plugin::Base
      # The global-shortcuts feature, lazily initialized during
      # `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! shortcuts : Features::GlobalShortcuts

      # Returns the unique plugin identifier `"shortcuts"`.
      def identifier : String
        "shortcuts"
      end

      # Returns the metadata contract gating every shortcuts command behind
      # the `shortcuts:manage` capability and declaring the
      # `shortcuts.triggered` event.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(shortcuts.register shortcuts.unregister shortcuts.unregister_all shortcuts.start_listening shortcuts.stop_listening shortcuts.list shortcuts.listening), "shortcuts:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(shortcuts:manage),
          commands: %w(shortcuts.register shortcuts.unregister shortcuts.unregister_all shortcuts.start_listening shortcuts.stop_listening shortcuts.list shortcuts.listening),
          events: %w(shortcuts.triggered),
          ipc: ipc,
        )
      end

      # Registers the IPC commands.
      #
      # `shortcuts.register` takes an accelerator string (e.g. `"CmdOrCtrl+Shift+D"`)
      # and installs a callback that emits `shortcuts.triggered` with the
      # accelerator when the user presses it. `shortcuts.list` returns the
      # currently registered accelerators. Listening must be explicitly started
      # and stopped; registrations persist across listen state.
      def initialize_plugin(context : Plugin::Context) : Nil
        @shortcuts = sc = Features::GlobalShortcuts.new

        context.command "shortcuts.register", String do |accelerator|
          sc.register(accelerator) {
            context.emit("shortcuts.triggered", context.app.coerce_to_json({"accelerator" => accelerator}))
          }
        end

        context.command "shortcuts.unregister", String do |accelerator|
          sc.unregister(accelerator)
        end

        context.command "shortcuts.unregister_all" do
          sc.unregister_all
        end

        context.command "shortcuts.start_listening" do
          sc.start_listening
        end

        context.command "shortcuts.stop_listening" do
          sc.stop_listening
        end

        context.command "shortcuts.list" do
          sc.registered
        end

        context.command "shortcuts.listening" do
          {"listening" => sc.listening?}
        end
      end

      # Tears down all shortcuts and stops listening. No-op if never initialized.
      #
      # Releasing the registrations here is important: global shortcuts
      # outlive the window and would otherwise linger after the app exits.
      def cleanup_plugin : Nil
        return unless sc = @shortcuts
        sc.stop_listening rescue nil
        sc.unregister_all rescue nil
      end
    end
  end
end
