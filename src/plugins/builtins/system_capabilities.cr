require "../base"
require "../../features/system_capabilities"

module CrystKit::Plugins
  class SystemCapabilities < Plugin::Base
    getter! capabilities : Features::SystemCapabilities

    def identifier : String
      "system_capabilities"
    end

    def metadata : Plugin::Metadata
      ipc = IPC::PolicyCatalog.new
        .require(%w(system_capabilities.list system_capabilities.status), "system:info")
      Plugin::Metadata.new(
        identifier,
        capabilities: %w(system:info),
        commands: %w(system_capabilities.list system_capabilities.status),
        ipc: ipc,
      )
    end

    def initialize_plugin(context : Plugin::Context) : Nil
      @capabilities = feature = Features::SystemCapabilities.new
      context.command("system_capabilities.list") { feature.all }
      context.command("system_capabilities.status", String) { |id| feature.status(id) }
    end
  end
end
