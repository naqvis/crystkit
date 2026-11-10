require "../base"
require "../../features/single_instance"

module CrystKit
  module Plugins
    # Builtin plugin that enforces single-instance semantics so only one copy
    # of the application can run at a time.
    #
    # On startup the frontend acquires the lock; a second launch fails to
    # acquire it, forwards its command-line arguments to the running instance
    # via the shared IPC router, and exits. The running instance receives the
    # args through the `single_instance.second_instance` event and can react
    # (e.g. focus its window or open the requested file). The application id
    # defaults to `app.config.identifier`, falling back to
    # `"com.crystkit.app"` when unset.
    #
    # Registers IPC commands:
    #   single_instance:acquire — Acquire the single-instance lock
    #   single_instance:release — Release the single-instance lock
    #   single_instance:locked — Check if the lock is held
    #   single_instance:send_args — Send command-line args to the existing instance
    #   single_instance:listen — Start listening for second-instance args
    #   single_instance:id — Get the application identifier
    #
    # Emits events: `single_instance.second_instance`
    #
    # Required capability: `single_instance:manage`
    #
    # ```
    # app.plugin(CrystKit::Plugins::SingleInstance.new)
    # ```
    class SingleInstance < Plugin::Base
      # IPC payload for `single_instance.send_args`.
      #
      # *args* is the list of command-line arguments to forward to the
      # already-running instance, typically `ARGV` from the second launch.
      struct SendArgsRequest
        include JSON::Serializable
        getter args : Array(String)
      end

      # The single-instance feature, lazily initialized during
      # `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! si : Features::SingleInstance

      # Returns the unique plugin identifier `"single_instance"`.
      def identifier : String
        "single_instance"
      end

      # Returns the metadata contract gating every command behind
      # `single_instance:manage` and declaring the
      # `single_instance.second_instance` event.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(single_instance.acquire single_instance.release single_instance.locked single_instance.send_args single_instance.listen single_instance.id), "single_instance:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(single_instance:manage),
          commands: %w(
            single_instance.acquire single_instance.release single_instance.locked
            single_instance.send_args single_instance.listen single_instance.id
          ),
          events: ["single_instance.second_instance"],
          ipc: ipc,
        )
      end

      # Registers the IPC commands.
      #
      # The application id is resolved from `app.config.identifier`
      # (defaulting to `"com.crystkit.app"`). `single_instance.id` returns the
      # resolved application id.
      def initialize_plugin(context : Plugin::Context) : Nil
        app_id = context.app.config.identifier
        app_id = app_id.empty? ? "com.crystkit.app" : app_id

        @si = si = Features::SingleInstance.new(app_id)

        si.attach_router(context.router)
        si.on_receive do |args|
          context.emit("single_instance.second_instance", context.app.coerce_to_json({"args" => args}))
        end

        context.command "single_instance.acquire" do
          si.acquire
        end

        context.command "single_instance.release" do
          si.release
        end

        context.command "single_instance.locked" do
          si.acquired?
        end

        context.command "single_instance.send_args", SendArgsRequest do |request|
          si.send_to_existing(request.args)
        end

        context.command "single_instance.listen" do
          si.listen_for_args
        end

        context.command "single_instance.id" do
          app_id
        end
      end

      # Releases the single-instance lock if it was acquired. No-op when the
      # plugin was never initialized or never acquired the lock.
      def cleanup_plugin : Nil
        @si.try(&.release)
      end
    end
  end
end
