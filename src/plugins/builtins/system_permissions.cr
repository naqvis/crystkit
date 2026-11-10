require "../base"
require "../../features/system_permissions"

module CrystKit::Plugins
  class SystemPermissions < Plugin::Base
    getter! permissions : Features::SystemPermissions

    def identifier : String
      "system_permissions"
    end

    def metadata : Plugin::Metadata
      commands = %w(system_permissions.status system_permissions.request system_permissions.open_settings)
      ipc = IPC::PolicyCatalog.new.require(commands, "permissions:manage")
      Plugin::Metadata.new(
        identifier,
        capabilities: %w(permissions:manage),
        commands: commands,
        ipc: ipc,
      )
    end

    def initialize_plugin(context : Plugin::Context) : Nil
      @permissions = feature = Features::SystemPermissions.new
      context.command("system_permissions.status", String) { |id| feature.status(id) }
      context.command("system_permissions.request", String) { |id| feature.request(id) }
      context.command("system_permissions.open_settings", String) { |id| feature.open_settings(id) }
    end
  end
end
