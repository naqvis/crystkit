require "../base"
require "../../features/external"

module CrystKit
  module Plugins
    # Plugin exposing OS-level "open" semantics to the frontend so web content
    # can hand URLs and files to the user's default system handler.
    #
    # Each command is flagged `IPC::RiskLevel::Sensitive`; the OS handler can
    # launch an external application with user-level privileges.
    #
    # Registers IPC commands:
    #   external:open_url  — open a URL in the default browser
    #   external:open_file — open a file with its default application
    #
    # Required capability: `external:open`
    #
    # ```
    # app.plugin(CrystKit::Plugins::External.new)
    # ```
    class External < Plugin::Base
      getter! opener

      # :nodoc:
      def initialize(@provider : Features::ExternalProvider = Features::NativeExternalProvider.new)
      end

      def identifier : String
        "external"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(external.open_url external.open_file external.open_path), "external:open", IPC::RiskLevel::Sensitive)

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(external:open),
          commands: %w(external.open_url external.open_file external.open_path),
          ipc: ipc,
        )
      end

      # Both commands return `"ok"` on success. `external.open_url` validates
      # the URL scheme and rejects dangerous schemes (`javascript:`, `data:`,
      # `vbscript:`); `external.open_file` rejects dangerous file extensions
      # (executables, scripts, shared libraries) and requires the path to point
      # to an existing file.
      def initialize_plugin(context : Plugin::Context) : Nil
        @opener = ex = Features::ExternalOpener.new(context.capabilities, @provider)

        context.command "external.open_url", String do |url|
          ex.open_url(url)
          "ok"
        end

        context.command "external.open_file", String do |path|
          ex.open_file(path)
          "ok"
        end

        context.command "external.open_path", String do |path|
          ex.open_path(path)
          "ok"
        end
      end
    end
  end
end
