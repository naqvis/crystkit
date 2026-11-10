require "../base"
require "../../features/deep_link"

module CrystKit
  module Plugins
    # Plugin wiring custom URL-scheme (deep link) handling into CrystKit's IPC
    # and window lifecycle.
    #
    # The executable path is resolved via `Process.executable_path`; if it
    # cannot be determined the plugin raises `Core::Error` with code
    # `EXECUTABLE_PATH_UNKNOWN`.
    #
    # Registers IPC commands:
    #   deep_link.register — Register a deep link scheme
    #   deep_link.unregister — Unregister a deep link scheme
    #   deep_link.registered — List registered schemes
    #   deep_link.mark_started — Mark the application as started
    #   deep_link.parse — Parse a deep link URL into its components
    #
    # Inbound deep links surface through `Features::DeepLink.received`, bridged
    # onto the shared IPC router.
    #
    # Required capability: `deep_link:manage`
    #
    # ```
    # app.plugin(CrystKit::Plugins::DeepLink.new)
    # ```
    class DeepLink < Plugin::Base
      @activation_subscription : Features::Activations::Subscription?

      # :nodoc:
      def initialize(@provider : Features::URLSchemeProvider = Features::NativeURLSchemeProvider.new)
      end

      # Request payload for `deep_link.register` / `deep_link.unregister`.
      struct SchemeRequest
        include JSON::Serializable
        # The scheme to register or unregister, without the trailing `:`.
        getter scheme : String
      end

      # Request payload for `deep_link.parse`.
      struct ParseRequest
        include JSON::Serializable
        # The absolute URL to parse, e.g. `"myapp://open?doc=42"`.
        getter url : String
      end

      getter! deep_link : Features::DeepLink

      def identifier : String
        "deep_link"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(deep_link.register deep_link.unregister deep_link.registered deep_link.mark_started deep_link.parse deep_link.registered? deep_link.started), "deep_link:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(deep_link:manage),
          commands: %w(
            deep_link.register deep_link.unregister deep_link.registered deep_link.registered?
            deep_link.mark_started deep_link.started deep_link.parse
          ),
          ipc: ipc,
        )
      end

      # `deep_link.parse` returns a hash with `scheme`, `host`, `path`,
      # `query_params`, and `raw_url` describing the URL.
      #
      # Raises `Core::Error` (code `EXECUTABLE_PATH_UNKNOWN`) when the
      # executable path cannot be resolved.
      def initialize_plugin(context : Plugin::Context) : Nil
        app_name = context.app.config.name
        app_exec = ::Process.executable_path
        unless app_exec
          raise Core::Error.new(
            "Unable to determine application executable path for deep link registration",
            code: "EXECUTABLE_PATH_UNKNOWN"
          )
        end
        @deep_link = dl = Features::DeepLink.new(
          app_name,
          app_exec,
          provider: @provider
        )
        @activation_subscription = context.app.runtime.activations.on_event do |activation|
          next unless activation.type == Features::ActivationTypes::URL
          activation.values.each { |url| dl.handle_url(url) }
        end

        dl.attach_router(context.router)
        dl.on_foreground do
          context.app.primary_window.try(&.focus)
        end

        context.command "deep_link.register", SchemeRequest do |request|
          dl.register_scheme(request.scheme)
        end

        context.command "deep_link.unregister", SchemeRequest do |request|
          dl.unregister_scheme(request.scheme)
        end

        context.command "deep_link.registered" do
          dl.registered_schemes
        end

        context.command "deep_link.mark_started" do
          dl.mark_started
        end

        context.command "deep_link.registered?", SchemeRequest do |request|
          {"registered" => dl.registered?(request.scheme)}
        end

        context.command "deep_link.started" do
          {"started" => dl.started?}
        end

        context.command "deep_link.parse", ParseRequest do |request|
          parsed = dl.parse_url(request.url)
          {
            "scheme"       => parsed.scheme,
            "host"         => parsed.host,
            "path"         => parsed.path,
            "query_params" => parsed.query_params,
            "raw_url"      => parsed.raw_url,
          }
        end
      end

      def cleanup_plugin : Nil
        @activation_subscription.try(&.close)
        @activation_subscription = nil
        @deep_link.try(&.unregister_all)
      end
    end
  end
end
