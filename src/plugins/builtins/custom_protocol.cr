require "http"
require "../base"
require "../../features/custom_protocol"

module CrystKit
  module Plugins
    # Plugin letting the frontend register custom URL schemes served by the
    # application.
    #
    # Registered protocols are tracked in memory and cleared on cleanup.
    #
    # Registers IPC commands:
    #   protocol:register — Register a custom URL scheme
    #   protocol:unregister — Unregister a custom URL scheme
    #   protocol:list — List registered protocols
    #
    # The `protocol.register` and `protocol.list` commands require the
    # `protocol:manage` capability.
    class CustomProtocol < Plugin::Base
      getter protocols : Array(Features::CustomProtocol)

      @protocols : Array(Features::CustomProtocol) = [] of Features::CustomProtocol

      def identifier : String
        "custom_protocol"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(protocol.register protocol.list), "protocol:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(protocol:manage),
          commands: %w(protocol.register protocol.list),
          ipc: ipc,
        )
      end

      def initialize
        @protocols = [] of Features::CustomProtocol
      end

      # `protocol.register` takes a scheme, an asset root (empty to disable
      # asset serving), and a resolver type. Returns
      # `{"success" => false, "error" => "No window"}` if no primary window
      # exists at call time.
      def initialize_plugin(context : Plugin::Context) : Nil
        context.command "protocol.register", String, String, String do |scheme, asset_root, resolver_type|
          opts = Features::ProtocolOptions.new(
            scheme: scheme,
            serve_assets: !asset_root.empty?,
            asset_root: asset_root.empty? ? nil : Path[asset_root],
          )

          if resolver_type == "custom"
            # Register with a simple resolver that delegates to IPC
            opts.resolver = ->(_path : String, _headers : ::HTTP::Headers) : String? {
              nil # Placeholder — custom logic can be added
            }
          end

          proto = Features::CustomProtocol.new(opts, context.app.runtime.platform.custom_protocol)

          wv = context.app.primary_window
          if wv
            proto.register(wv)
            @protocols << proto
            {"success" => true, "scheme" => scheme}
          else
            {"success" => false, "error" => "No window"}
          end
        end

        context.command "protocol.list" do
          {"protocols" => @protocols.map(&.options.scheme)}
        end
      end

      def cleanup_plugin : Nil
        @protocols.clear
      end
    end
  end
end
