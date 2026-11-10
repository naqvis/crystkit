require "../base"
require "../../features/biometric"

module CrystKit
  module Plugins
    # Plugin exposing OS biometric authentication to the frontend.
    #
    # Registers IPC commands:
    #   biometric.available — Report whether biometric auth is available and its type
    #   biometric.authenticate — Prompt the user for biometric authentication
    #
    # Authentication requires the `biometric:authenticate` capability.
    class Biometric < Plugin::Base
      getter! authenticator : Features::BiometricAuth

      def identifier : String
        "biometric"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .public(%w(biometric.available))
          .require(%w(biometric.authenticate), "biometric:authenticate")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(biometric:authenticate),
          commands: %w(biometric.available biometric.authenticate),
          ipc: ipc,
        )
      end

      # `biometric.available` returns availability, normalized modality, and
      # whether the OS prompt supports caller-provided reason text.
      # `biometric.authenticate` takes a *reason* string and returns `success`
      # and optional `error` fields.
      def initialize_plugin(context : Plugin::Context) : Nil
        @authenticator = auth = Features::BiometricAuth.new(
          capabilities: context.app.runtime.security.capabilities,
        )

        context.command "biometric.available" do
          info = auth.info
          modality = info.modality
          {
            "available"        => info.available?,
            "modality"         => modality,
            "type"             => modality, # compatibility alias
            "reason_supported" => info.reason_supported?,
          }
        end

        context.command "biometric.authenticate", String do |reason|
          owner = context.app.primary_window.try do |window|
            handle = window.window
            ::NativeDesktop::Window.attach(handle) unless handle.null?
          end
          result = auth.authenticate(reason, owner)
          {
            "success" => result.success?,
            "error"   => result.error,
          }
        end
      end
    end
  end
end
