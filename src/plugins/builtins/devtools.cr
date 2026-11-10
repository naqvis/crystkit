require "../base"
require "../../features/devtools"
require "../../platform/backends/window_integration_backend"

module CrystKit
  module Plugins
    # Plugin surfacing browser DevTools controls to the frontend and priming
    # new windows for inspection.
    #
    # The frontend can open, close, or toggle the inspector on the primary
    # window by name, and query whether the feature is currently enabled at the
    # application level.
    #
    # Registers IPC commands:
    #   devtools.open — Open DevTools window
    #   devtools.close — Close DevTools window
    #   devtools.toggle — Toggle DevTools window
    #   devtools.status — Check DevTools open/enabled status
    #
    # Required capability: `devtools:manage`
    #
    # ```
    # app.plugin(CrystKit::Plugins::DevTools.new)
    # ```
    class DevTools < Plugin::Base
      getter! devtools : Features::DevTools

      # :nodoc: Cached window-integration backend used to prime new windows.
      @window_integration : Platform::WindowIntegrationBackend?

      def identifier : String
        "devtools"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(devtools.open devtools.close devtools.toggle devtools.status), "devtools:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(devtools:manage),
          commands: %w(devtools.open devtools.close devtools.toggle devtools.status),
          ipc: ipc,
        )
      end

      # `devtools.status` returns `{"open": ..., "enabled": ...}` reflecting
      # the feature's current state.
      def initialize_plugin(context : Plugin::Context) : Nil
        @window_integration = context.app.runtime.platform.window_integration
        wi = @window_integration || raise Core::PluginError.new("DevTools plugin requires window integration")
        @devtools = dt = Features::DevTools.new(Features::DevTools.default_config, wi)

        context.command "devtools.open" do
          wv = context.app.primary_window
          ptr = wv ? wv.native_handle(::Webview::NativeHandleKind::BROWSER_CONTROLLER) : Pointer(Void).null
          dt.open(ptr)
          {"status" => "opened"}
        end

        context.command "devtools.close" do
          wv = context.app.primary_window
          ptr = wv ? wv.native_handle(::Webview::NativeHandleKind::BROWSER_CONTROLLER) : Pointer(Void).null
          dt.close(ptr)
          {"status" => "closed"}
        end

        context.command "devtools.toggle" do
          wv = context.app.primary_window
          ptr = wv ? wv.native_handle(::Webview::NativeHandleKind::BROWSER_CONTROLLER) : Pointer(Void).null
          dt.toggle(ptr)
          {"status" => "toggled"}
        end

        context.command "devtools.status" do
          {"open" => dt.open?, "enabled" => dt.enabled?}
        end
      end

      # No-op when the feature is disabled (for example in a production build).
      def on_window_created(window : ::CrystKit::Core::Window) : Nil
        return unless @devtools.try(&.enabled?)

        @window_integration.try(&.enable_devtools(window.native))
      end
    end
  end
end
