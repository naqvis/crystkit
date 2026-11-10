require "json"
require "set"
require "../core/errors"

module CrystKit
  module IPC
    # What kind of scoped resource a policy extracts from the frontend
    # payload.
    enum ResourceKind
      # A filesystem-like path.
      Path

      # A non-file resource string such as a URL, process command, keychain
      # key, workspace id, or custom plugin id.
      Resource
    end

    # Operation requested against a scoped resource: read, write, or
    # execute.
    enum ResourcePermission
      Read
      Write
      Execute
    end

    # Risk classification for audit and permission-prompt flows. Does not
    # grant access by itself; capabilities and resource scopes still decide
    # allow/deny. `Public` is reserved for commands declared via
    # `PolicyCatalog#public`.
    enum RiskLevel
      Public
      Normal
      Sensitive
      Dangerous
    end

    # A single scoped-resource check attached to a `CommandPolicy`.
    #
    # On command invocation, the resource string located at `json_path`
    # inside the frontend payload is extracted and authorized against
    # `capability`.
    struct ResourceRule
      # The capability that must be granted for this resource access, e.g.
      # `"fs:write"` or `"net:fetch"`.
      getter capability : String

      # Which validator to run: `Path` for filesystem scope checks,
      # `Resource` for generic resource-scope checks.
      getter kind : ResourceKind

      # Dot/index path into the JSON payload that locates the resource
      # string to authorize. See `#extract` for the supported syntax.
      getter json_path : String

      # Required access level for `Path` rules. `nil` for `Resource` rules,
      # which do not distinguish read/write/execute.
      getter permission : ResourcePermission?

      # Creates a resource rule. `permission` only matters for `Path` rules
      # and defaults to `nil` (treated as read when unset).
      def initialize(
        @capability,
        @kind,
        @json_path,
        @permission = nil,
      )
      end

      # Extracts the resource value from an IPC payload.
      #
      # `json_path` is dot/index based:
      # - `"path"` reads `{ "path": "/tmp/a.txt" }`
      # - `"workspace.id"` reads `{ "workspace": { "id": "main" } }`
      # - `"0"` reads the first item from an array payload
      # - `""` treats the complete payload as the resource string
      #
      # Raises `Core::IPCError` (code `IPC_POLICY_RESOURCE_MISSING`) when
      # the path cannot be resolved or the leaf value is not a string.
      def extract(params : JSON::Any) : String
        return params.as_s if @json_path.empty?

        current = params
        @json_path.split('.').each do |part|
          if index = part.to_i?
            current = current.as_a[index]? || missing!
          else
            current = current.as_h[part]? || missing!
          end
        end
        current.as_s
      rescue TypeCastError | IndexError
        missing!
      end

      # :nodoc:
      private def missing! : NoReturn
        raise Core::IPCError.new(
          "Missing IPC policy resource '#{@json_path}'",
          code: "IPC_POLICY_RESOURCE_MISSING",
        )
      end
    end

    # The security policy attached to a single IPC command.
    #
    # When `capability` is `nil` *and* `resources` is empty, the command is
    # public and no security context is required. `CommandPolicy.public`
    # produces such a policy.
    struct CommandPolicy
      # Capability that must be granted to the caller, or `nil` if the
      # command only needs resource-scope checks (or is fully public).
      getter capability : String?

      # Per-resource rules that extract values from the payload and
      # authorize them. Empty for capability-only or public policies.
      getter resources : Array(ResourceRule)

      # Audit/prompt hint. Does not affect allow/deny by itself.
      getter risk : RiskLevel

      # Creates a policy. Defaults produce a capability-only `Normal`-risk
      # policy with no resource rules; pass `capability` and/or
      # `resources` to require authorization.
      def initialize(
        @capability = nil,
        @resources : Array(ResourceRule) = [] of ResourceRule,
        @risk = RiskLevel::Normal,
      )
      end

      # Returns a policy that allows the command without any capability or
      # resource checks. Use sparingly — it bypasses all frontend
      # authorization.
      def self.public : self
        new(risk: RiskLevel::Public)
      end
    end

    # Per-plugin command policy declarations used by
    # `Plugin::Metadata#ipc`.
    #
    # Use the narrowest helper that matches the command:
    # - `require` for capability-only checks.
    # - `path` for filesystem/path payloads that must pass path scopes.
    # - `resource` for non-file resource payloads, such as URLs or process
    #   names.
    # - `public` only for intentionally harmless commands.
    class PolicyCatalog
      # The registered command-to-policy mappings, keyed by command name.
      getter commands : Hash(String, CommandPolicy)

      # Creates an empty catalog. All helpers return `self` so
      # declarations can be chained.
      def initialize
        @commands = {} of String => CommandPolicy
      end

      # Alias for a read-style non-file resource policy. Prefer `resource`
      # when the command is not naturally read/write named.
      def read(command : String, capability : String, resource : String? = nil) : self
        @commands[command] = resource ? CommandPolicy.new(
          resources: [ResourceRule.new(capability, ResourceKind::Resource, resource)]
        ) : CommandPolicy.new(capability: capability)
        self
      end

      # Require only a capability before the command handler runs.
      def require(command : String, capability : String, risk : RiskLevel = RiskLevel::Normal) : self
        @commands[command] = CommandPolicy.new(capability: capability, risk: risk)
        self
      end

      # Require the same capability for several commands.
      def require(commands : Array(String), capability : String, risk : RiskLevel = RiskLevel::Normal) : self
        commands.each { |command| self.require(command, capability, risk) }
        self
      end

      # Require a capability and validate a filesystem/path-like resource.
      # `json_path` points into the frontend payload; the extracted string
      # is checked against path scopes with the given permission.
      def path(command : String, capability : String, json_path : String, permission : ResourcePermission, risk : RiskLevel = RiskLevel::Normal) : self
        @commands[command] = CommandPolicy.new(
          resources: [ResourceRule.new(capability, ResourceKind::Path, json_path, permission)],
          risk: risk,
        )
        self
      end

      # Require a capability and validate a non-file resource string. Use
      # for URLs, process/shell commands, storage keys, workspace ids, or
      # any plugin-defined resource that is not a filesystem path.
      def resource(command : String, capability : String, json_path : String, risk : RiskLevel = RiskLevel::Normal) : self
        @commands[command] = CommandPolicy.new(
          resources: [ResourceRule.new(capability, ResourceKind::Resource, json_path)],
          risk: risk,
        )
        self
      end

      # Register a fully custom command policy, usually for commands that
      # need more than one resource check.
      def resource(command : String, policy : CommandPolicy) : self
        @commands[command] = policy
        self
      end

      # Mark a command as frontend-callable without capability checks. Use
      # sparingly for harmless reads such as `window.exists`.
      def public(command : String) : self
        @commands[command] = CommandPolicy.public
        self
      end

      # Mark several commands as public.
      def public(commands : Array(String)) : self
        commands.each { |command| public(command) }
        self
      end
    end
  end
end
