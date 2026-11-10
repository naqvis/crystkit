require "./policy"

module CrystKit::IPC
  # Resolves the effective `CommandPolicy` for a command name.
  #
  # Policies come from two layers: *plugin* policies, registered by each
  # plugin's metadata via `register_plugin`, and *override* policies,
  # registered by the host application via `register_override` to tighten
  # or replace a plugin's declaration.
  #
  # Overrides win over plugins, and unknown commands resolve to
  # `CommandPolicy.public` (no capability required).
  class PolicyResolver
    # Creates an empty resolver. Lookups return `CommandPolicy.public`
    # until policies are added.
    def initialize
      @plugins = {} of String => CommandPolicy
      @overrides = {} of String => CommandPolicy
      @mutex = Mutex.new
    end

    # Registers a `CommandPolicy` declared by a plugin for `command`.
    def register_plugin(command : String, policy : CommandPolicy) : Nil
      @mutex.synchronize { @plugins[command] = policy }
    end

    # Registers a host-supplied `CommandPolicy` that supersedes any plugin
    # declaration for `command`.
    def register_override(command : String, policy : CommandPolicy) : Nil
      @mutex.synchronize { @overrides[command] = policy }
    end

    # Returns the effective policy for `command`: the override policy if
    # present, otherwise the plugin policy, otherwise
    # `CommandPolicy.public`. Never raises.
    def resolve(command : String) : CommandPolicy
      @mutex.synchronize do
        @overrides[command]? || @plugins[command]? || CommandPolicy.public
      end
    end
  end
end
