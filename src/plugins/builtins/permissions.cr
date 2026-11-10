require "../base"
require "../../features/permissions"
require "../../platform/backends/window_integration_backend"

module CrystKit
  module Plugins
    # Builtin plugin that mediates per-origin permission decisions between web
    # content and the host OS.
    #
    # The shared `Features::Permissions` resolver answers both IPC-driven
    # decisions and the webview's native permission prompts (installed in
    # `#on_window_created`), so both paths stay consistent and persisted.
    #
    # Registers IPC commands:
    #   permissions.request, permissions.set_default, permissions.status,
    #   permissions.persist, permissions.reset
    #
    # Required capability: `permissions:manage`
    class Permissions < Plugin::Base
      # The `Features::Permissions` resolver, lazily initialized during
      # `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! permissions_manager : Features::Permissions

      # The platform window integration backend used to install the per-window
      # permission delegate, or `nil` when the current platform does not
      # provide one.
      @window_integration : Platform::WindowIntegrationBackend?

      # Returns the unique plugin identifier `"permissions"`.
      def identifier : String
        "permissions"
      end

      # Returns the metadata contract binding all five commands to the
      # `permissions:manage` capability. Arguments encode permission type,
      # origin, and state rather than scoped resources, so the catalog uses
      # capability-only `require` policies.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(permissions.request permissions.set_default permissions.status permissions.persist permissions.reset permissions.grant permissions.deny), "permissions:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(permissions:manage),
          commands: %w(permissions.request permissions.set_default permissions.status permissions.persist permissions.reset permissions.grant permissions.deny),
          ipc: ipc,
        )
      end

      # Constructs the resolver, prepares the platform for permission prompts,
      # and registers the IPC commands.
      #
      # The persisted permission store is rooted at
      # `<storage_dir>/.crystkit/permissions` (defaulting to the working
      # directory when `storage_dir` is not provided in the plugin config).
      #
      # Command return shapes:
      #   `permissions.request`    — `{"type", "state"}` or `{"error"}` for
      #     an unknown permission type.
      #   `permissions.set_default` — `{"success" => true}` or `{"error"}`.
      #   `permissions.status`     — `{"type", "default", "persisted"}` when
      #     an origin is supplied, otherwise `{"type", "default"}`.
      #   `permissions.persist`    — `{"success" => true}` or `{"error"}`.
      #   `permissions.reset`      — `{"success" => true}` after resetting
      #     camera, microphone, and geolocation defaults to `Prompt`.
      def initialize_plugin(context : Plugin::Context) : Nil
        storage = Path[context.config["storage_dir"]?.try(&.as_s) || Dir.current] / ".crystkit" / "permissions"
        pm = Features::Permissions.new(storage)
        @permissions_manager = pm
        @window_integration = context.app.runtime.platform.window_integration
        @window_integration.try(&.prepare_permissions)

        context.command "permissions.request", String, String do |type_str, origin_str|
          ptype = Features::PermissionType.parse?(type_str)
          next {"error" => "Unknown permission type: #{type_str}"} unless ptype
          origin = URI.parse(origin_str)
          state = pm.handle_request(ptype, origin)
          {"type" => type_str, "state" => state.to_s}
        end

        context.command "permissions.set_default", String, String do |type_str, state_str|
          ptype = Features::PermissionType.parse?(type_str)
          pstate = Features::PermissionState.parse?(state_str)
          next {"error" => "Invalid type or state"} unless ptype && pstate
          pm.set_default(ptype, pstate)
          {"success" => true}
        end

        context.command "permissions.status", String, String? do |type_str, origin_str|
          ptype = Features::PermissionType.parse?(type_str)
          next {"error" => "Unknown permission type: #{type_str}"} unless ptype
          if origin_str
            origin = URI.parse(origin_str)
            persisted = pm.persisted_state(origin, ptype)
            {"type" => type_str, "default" => pm.default(ptype).to_s, "persisted" => persisted.try(&.to_s)}
          else
            {"type" => type_str, "default" => pm.default(ptype).to_s}
          end
        end

        context.command "permissions.persist", String, String, String do |type_str, origin_str, state_str|
          ptype = Features::PermissionType.parse?(type_str)
          pstate = Features::PermissionState.parse?(state_str)
          next {"error" => "Invalid type or state"} unless ptype && pstate
          origin = URI.parse(origin_str)
          pm.persist(origin, ptype, pstate)
          {"success" => true}
        end

        context.command "permissions.grant", String do |type_str|
          ptype = Features::PermissionType.parse?(type_str)
          next {"error" => "Unknown permission type: #{type_str}"} unless ptype
          pm.grant(ptype)
          {"success" => true}
        end

        context.command "permissions.deny", String do |type_str|
          ptype = Features::PermissionType.parse?(type_str)
          next {"error" => "Unknown permission type: #{type_str}"} unless ptype
          pm.deny(ptype)
          {"success" => true}
        end

        context.command "permissions.reset" do
          pm.set_default(Features::PermissionType::Camera, Features::PermissionState::Prompt)
          pm.set_default(Features::PermissionType::Microphone, Features::PermissionState::Prompt)
          pm.set_default(Features::PermissionType::Geolocation, Features::PermissionState::Prompt)
          {"success" => true}
        end
      end

      # Installs the platform permission delegate for *window*.
      #
      # Registers a callback on the platform `WindowIntegrationBackend` that
      # the webview invokes for each native permission request. The callback
      # parses the permission *type*, asks the shared resolver for a decision,
      # and maps `Granted` and `Prompt` to `"granted"` (so the OS shows its
      # native prompt when the resolver is undecided) and `Denied` to
      # `"denied"`. Unknown types default to `"granted"` to avoid blocking
      # features the host does not model.
      def on_window_created(window : ::CrystKit::Core::Window) : Nil
        pm = @permissions_manager.as(Features::Permissions)
        @window_integration.try do |integration|
          integration.register_permissions(window.native) do |origin, type|
            ptype = Features::PermissionType.parse?(type)
            next "granted" unless ptype
            state = pm.handle_request(ptype, URI.parse(origin))
            state.granted? || state.prompt? ? "granted" : "denied"
          end
        end
      end
    end
  end
end
