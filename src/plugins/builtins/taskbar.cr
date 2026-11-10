require "../base"
require "../../features/taskbar_progress"
require "../../features/asset_resolution"
require "../../platform/icon_source"

module CrystKit
  module Plugins
    # Builtin plugin that controls the operating-system taskbar/dock
    # representation of the application window.
    #
    # Wraps `Features::TaskbarProgress` over the platform's taskbar backend.
    # This is primarily a Windows taskbar feature (progress overlay, badge,
    # overlay icon, progress state) but the backend is a no-op on platforms
    # that lack native support, so commands are safe to call everywhere. The
    # plugin operates on the application's primary window.
    #
    # Registers IPC commands:
    #   taskbar:set_progress — Set taskbar progress value
    #   taskbar:clear_progress — Clear taskbar progress
    #   taskbar:set_badge — Set the taskbar badge text
    #   taskbar:set_overlay_icon — Set a taskbar overlay icon
    #   taskbar:set_progress_state — Set the taskbar progress state
    #
    # Required capability: `taskbar:manage`
    #
    # ```
    # app.plugin(CrystKit::Plugins::Taskbar.new)
    # ```
    class Taskbar < Plugin::Base
      # The taskbar-progress feature backing this plugin, lazily initialized
      # during `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      Log = ::Log.for(self)

      getter! progress : Features::TaskbarProgress
      @application_id = ""
      @installed = false

      # Returns the unique plugin identifier `"taskbar"`.
      def identifier : String
        "taskbar"
      end

      # Returns the metadata contract gating every command behind the
      # `taskbar:manage` capability.
      #
      # The capability is auto-granted to this plugin on registration, so its
      # own commands run without an additional manifest grant.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(taskbar.set_progress taskbar.clear_progress taskbar.set_badge taskbar.set_overlay_icon taskbar.set_progress_state), "taskbar:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(taskbar:manage),
          commands: %w(taskbar.set_progress taskbar.clear_progress taskbar.set_badge taskbar.set_overlay_icon taskbar.set_progress_state),
          ipc: ipc,
        )
      end

      # Constructs the taskbar-progress feature and registers the IPC commands.
      #
      # `taskbar.set_progress` takes a `Float64` in the range 0.0–1.0.
      # `taskbar.set_badge` and `taskbar.set_overlay_icon` accept nullable
      # strings; passing `nil` clears the badge/icon. `taskbar.set_progress_state`
      # parses its string argument into a `Features::TaskbarProgress::ProgressState`
      # (e.g. `"normal"`, `"indeterminate"`, `"error"`, `"paused"`).
      def initialize_plugin(context : Plugin::Context) : Nil
        @progress = tb = Features::TaskbarProgress.new
        @application_id = context.app.config.identifier
        asset_source = context.app.asset_source

        context.command "taskbar.set_progress", Float64 do |value|
          tb.progress = value
        end

        context.command "taskbar.clear_progress" do
          tb.clear_progress
        end

        context.command "taskbar.set_badge", String? do |text|
          tb.badge = text
        end

        context.command "taskbar.set_overlay_icon", String? do |icon_str|
          if icon_str.nil?
            tb.overlay_icon = nil
          elsif icon_str.starts_with?("http://") || icon_str.starts_with?("https://")
            # Network URL — would need AssetFetcher; for now pass nil and log
            Log.warn { "taskbar: network overlay icon not yet supported via plugin" }
            tb.overlay_icon = nil
          else
            tb.overlay_icon = Features::AssetResolution.resolve(icon_str, asset_source)
          end
        end

        context.command "taskbar.set_progress_state", String do |state_str|
          state = Features::TaskbarProgress::ProgressState.parse(state_str)
          tb.progress_state = state
        end
      end

      def on_window_created(window : ::CrystKit::Core::Window) : Nil
        return if @installed
        progress.install(window.window, @application_id)
        @installed = progress.installed?
      end

      def cleanup_plugin : Nil
        @progress.try(&.cleanup)
        @installed = false
      end
    end
  end
end
