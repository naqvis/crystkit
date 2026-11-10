require "json"
require "../base"
require "../../features/dev_server"

module CrystKit
  module Plugins
    # Plugin exposing dev server status and control via IPC.
    #
    # The server is constructed by the application's dev bootstrap and passed
    # in via the constructor; the plugin only reports status. When no server
    # is supplied the plugin still loads: `dev.status` reports
    # `{"running": false, "url": null, "root": null}` so the IPC contract is
    # stable in production builds that omit the dev server.
    #
    # Registers IPC commands:
    #   dev.status — returns running state and URL of the dev server
    #   dev.ping   — health check endpoint; returns `{"status": "pong"}`
    #
    # Required capability: `dev:read`
    #
    # Pass `nil` (or omit the argument) to the constructor for a no-op status
    # plugin that always reports a stopped server.
    #
    # ```
    # app.plugin(CrystKit::Plugins::DevServerPlugin.new(dev_server))
    # ```
    class DevServerPlugin < Plugin::Base
      getter server : Features::DevServer?

      def initialize(@server = nil)
      end

      def identifier : String
        "dev_server"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(dev.status dev.ping), "dev:read")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(dev:read),
          commands: %w(dev.status dev.ping),
          ipc: ipc,
        )
      end

      # `dev.status` returns a hash with `running` (bool), `url` (full
      # `http://localhost:<port>` URL, or `nil` when no server is attached),
      # and `root` (the absolute path being served, or `nil`). `dev.ping`
      # unconditionally returns `{"status": "pong"}`.
      def initialize_plugin(context : Plugin::Context) : Nil
        context.command "dev.status" do
          if srv = @server
            {
              "running" => srv.running?,
              "url"     => "http://localhost:#{srv.port}",
              "root"    => File.expand_path(srv.root),
            }
          else
            {"running" => false, "url" => nil, "root" => nil}
          end
        end

        context.command "dev.ping" do
          {"status" => "pong"}
        end
      end
    end
  end
end
