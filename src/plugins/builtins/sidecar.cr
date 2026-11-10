require "../base"
require "../../features/sidecar"

module CrystKit
  module Plugins
    # Builtin plugin that manages named "sidecar" processes — bundled
    # executables the application launches and supervises on demand.
    #
    # Sidecars are registered by name and path up front, then executed by
    # name so the frontend never handles raw paths. This is the CrystKit
    # equivalent of Tauri's sidecar feature: ship a helper binary alongside
    # the app and invoke it safely.
    #
    # Registers IPC commands:
    #   sidecar:execute — Execute a sidecar process
    #   sidecar:register — Register a sidecar by name and path
    #   sidecar:list — List registered sidecars
    #   sidecar:registered — Check if a sidecar is registered
    #
    # Required capability: `sidecar:execute`
    #
    # `sidecar.execute` accepts the sidecar name plus a JSON options object
    # with optional `args`, `cwd`, and `timeout`, and returns
    # `{stdout, stderr, exit_code, success}`.
    #
    # ```
    # app.plugin(CrystKit::Plugins::Sidecar.new)
    # ```
    class Sidecar < Plugin::Base
      # The sidecar manager, constructed with the app's capability system so
      # executions are capability-checked.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! manager : Features::SidecarManager

      # Returns the unique plugin identifier `"sidecar"`.
      def identifier : String
        "sidecar"
      end

      # Returns the metadata contract gating every sidecar command behind the
      # `sidecar:execute` capability. Applications that want the frontend to
      # spawn sidecars must explicitly grant `sidecar:execute`.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(sidecar.execute sidecar.register sidecar.list sidecar.registered), "sidecar:execute")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(sidecar:execute),
          commands: %w(sidecar.execute sidecar.register sidecar.list sidecar.registered),
          ipc: ipc,
        )
      end

      # Registers the IPC commands.
      #
      # `sidecar.register` records a name-to-path mapping and returns `"ok"`;
      # `sidecar.list` returns the registered sidecar names; `sidecar.registered`
      # is a boolean membership check. `sidecar.execute` runs the named sidecar
      # with the supplied options and returns the captured process result.
      def initialize_plugin(context : Plugin::Context) : Nil
        @manager = mgr = Features::SidecarManager.new(context.capabilities)

        context.command "sidecar.execute", String, JSON::Any do |name, opts|
          args = opts["args"]?.try(&.as_a.map(&.as_s)) || [] of String
          cwd = opts["cwd"]?.try(&.as_s)
          timeout = opts["timeout"]?.try(&.as_i)

          options = Features::SidecarOptions.new
          options.args = args
          options.cwd = Path[cwd] if cwd
          options.timeout = timeout.seconds if timeout

          result = mgr.execute(name, options)
          {
            "stdout"    => result.stdout,
            "stderr"    => result.stderr,
            "exit_code" => result.exit_code,
            "success"   => result.success?,
          }
        end

        context.command "sidecar.register", String, String do |name, path|
          mgr.register(name, path)
          "ok"
        end

        context.command "sidecar.list" do
          mgr.registered_sidecars
        end

        context.command "sidecar.registered", String do |name|
          mgr.registered?(name)
        end
      end
    end
  end
end
