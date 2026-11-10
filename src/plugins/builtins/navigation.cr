require "../base"
require "../../features/navigation_policy"

module CrystKit
  module Plugins
    # Plugin fronting the webview navigation policy to the frontend, letting web
    # content query whether a URL may be navigated to and clear the installed
    # handler.
    #
    # Registers IPC commands:
    #   window:set_navigation_handler — Evaluate and handle navigation for a URL
    #   window:clear_navigation_handler — Clear the navigation handler
    #
    # Required capability: `window:navigation`
    class Navigation < Plugin::Base
      getter! policy : Features::NavigationPolicy

      def identifier : String
        "navigation"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(window.set_navigation_handler window.clear_navigation_handler), "window:navigation")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(window:navigation),
          commands: %w(window.set_navigation_handler window.clear_navigation_handler),
          ipc: ipc,
        )
      end

      # `window.set_navigation_handler` evaluates the *url* against any handler
      # previously installed via `Features::NavigationPolicy#on_navigation` and
      # returns `{"decision", "url"}` with the decision lowercased (`"allow"`,
      # `"deny"`, or `"external"`). When no handler is installed the decision
      # defaults to `Allow`. `window.clear_navigation_handler` drops the
      # installed handler so all subsequent navigations are allowed.
      def initialize_plugin(context : Plugin::Context) : Nil
        @policy = np = Features::NavigationPolicy.new

        context.command "window.set_navigation_handler", String do |url|
          decision = np.evaluate(url)
          {"decision" => decision.to_s.downcase, "url" => url}
        end

        context.command "window.clear_navigation_handler" do
          np.clear
        end
      end
    end
  end
end
