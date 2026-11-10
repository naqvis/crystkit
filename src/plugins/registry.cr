require "json"
require "http/client"
require "log"
require "../core/errors"
require "./base"

module CrystKit
  module Plugin
    # A discovered plugin entry from a `Plugin::Catalog`.
    #
    # Carries catalog metadata (name, description, version, author,
    # repository, shard coordinate, capabilities); not the runtime
    # `Plugin::Metadata` contract, which comes from `Plugin::Base#metadata`
    # after the plugin is loaded.
    struct PluginInfo
      include JSON::Serializable

      # Unique plugin name in the catalog index.
      property name : String

      # Human-readable summary shown in `Catalog#search` results.
      property description : String

      # Version string reported by the index; defaults to `0.1.0` when the
      # entry omits it.
      property version : String

      # Display name of the plugin's author or maintainer.
      property author : String

      # URL to the plugin's source repository.
      property repository : String

      # Optional shard coordinate (e.g. `owner/repo`) used by `Catalog#install`.
      property shard : String?

      # Capabilities the plugin declares, as advertised by the index.
      #
      # Informational for the catalog; runtime grants come from
      # `Plugin::Metadata#capabilities` after the plugin is loaded.
      property capabilities : Array(String)

      # Creates an empty `PluginInfo` with defaults (`version` = `0.1.0`,
      # `capabilities` = `[]`).
      def initialize(
        @name = "",
        @description = "",
        @version = "0.1.0",
        @author = "",
        @repository = "",
        @shard = nil,
        @capabilities : Array(String) = [] of String,
      )
      end
    end

    # Registry client for discovering and installing CrystKit plugins.
    #
    # Fetches a remote JSON index of `PluginInfo` entries, caches it for
    # five minutes, and offers listing, searching, lookup, and install
    # guidance. Performs *no* filesystem mutation: `install` logs the
    # `shard.yml` stanza to add and the `shards install` command to run,
    # then returns a boolean.
    #
    # Usage:
    # ```
    # catalog = CrystKit::Plugin::Catalog.new("https://plugins.crystkit.dev/index.json")
    # plugins = catalog.search("fs")
    # catalog.install("crystkit-fs")
    # ```
    class Catalog
      # :nodoc: Logger for catalog fetch/install diagnostics.
      Log = ::Log.for(self)

      # The index URL fetched for the plugin catalog.
      #
      # Defaults to the public CrystKit registry at
      # `https://plugins.crystkit.dev/index.json`.
      getter url : String

      @cache : Array(PluginInfo)?
      @cache_time : Time?

      # Creates a catalog client that fetches *url*.
      #
      # *url* should point to a JSON array of `PluginInfo` entries. The
      # first fetch is lazy.
      def initialize(@url = "https://plugins.crystkit.dev/index.json")
      end

      # Lists all available plugins.
      #
      # Returns the full index, served from the in-memory cache when it is
      # younger than five minutes and refetched otherwise. On fetch failure
      # returns the last cached index (or an empty array if nothing was
      # ever cached).
      def list : Array(PluginInfo)
        fetch_index
      end

      # Searches for plugins by keyword.
      #
      # Case-insensitive substring match against each entry's `name` and
      # `description`. Returns the matching subset in index order.
      def search(query : String) : Array(PluginInfo)
        all = fetch_index
        query = query.downcase
        all.select { |plugin|
          plugin.name.downcase.includes?(query) ||
            plugin.description.downcase.includes?(query)
        }
      end

      # Returns info about a specific plugin, or `nil` if no such entry
      # exists in the index.
      def info(name : String) : PluginInfo?
        all = fetch_index
        all.find { |plugin| plugin.name == name }
      end

      # Logs install instructions for *name* (the `shard.yml` stanza and
      # `shards install` command).
      #
      # Returns `true` if instructions were emitted, or `false` if *name*
      # is unknown to the index or has no installable source (neither
      # `shard` nor `repository`).
      def install(name : String) : Bool
        plugin = info(name)
        unless plugin
          Log.error { "Plugin '#{name}' not found in registry" }
          return false
        end

        shard = plugin.shard || plugin.repository
        unless shard
          Log.error { "Plugin '#{name}' has no installable source" }
          return false
        end

        Log.info { "To install #{name}, add to your shard.yml:" }
        Log.info { "" }
        Log.info { "  dependencies:" }
        Log.info { "    #{name}:" }
        Log.info { "      github: #{shard}" }
        Log.info { "" }
        Log.info { "Then run: shards install" }
        true
      end

      # Fetch and cache the plugin index.
      # :nodoc:
      private def fetch_index : Array(PluginInfo)
        if (cache_time = @cache_time) && (cache = @cache) && (Time.utc - cache_time) < 5.minutes
          return cache
        end

        begin
          uri = URI.parse(@url)
          HTTP::Client.new(uri) do |client|
            client.connect_timeout = 5.seconds
            client.read_timeout = 10.seconds
            response = client.get(uri.request_target)
            if response.status_code == 200
              cache = Array(PluginInfo).from_json(response.body)
              @cache = cache
              @cache_time = Time.utc
              cache
            else
              Log.warn { "Registry returned #{response.status_code}, using cached index" }
              @cache || [] of PluginInfo
            end
          end
        rescue ex
          Log.warn { "Failed to fetch plugin index: #{ex.message}" }
          @cache || [] of PluginInfo
        end
      end
    end

    # The single runtime owner for registered plugins.
    #
    # Enforces the plugin contract: identifier shape, dependency presence,
    # capability granting, command/event quotas, declared-vs-registered
    # command parity, declared-event-only emission, and IPC policy wiring;
    # rolls back partial registration on any validation failure.
    class Registry
      # Maximum IPC commands a single plugin may register.
      #
      # Exceeding it raises `Core::PluginError` and fails the registration.
      MAX_COMMANDS_PER_PLUGIN = 100

      # Maximum event subscriptions a single plugin may hold.
      #
      # Exceeding it raises `Core::PluginError` and fails the registration.
      MAX_EVENTS_PER_PLUGIN = 100

      # Plugin identifiers in registration order.
      getter load_order : Array(String)

      # Creates a registry that wires plugins onto *router*.
      #
      # App developers do not construct a `Registry` directly; `CrystKit::App`
      # builds one and exposes it via `App#plugins`.
      def initialize(@router : IPC::Router)
        @plugins = {} of String => Base
        @load_order = [] of String
        @command_owners = {} of String => String
        @subscription_owners = {} of UInt64 => String
        @contexts = {} of String => Context
        @metadata = {} of String => Metadata
      end

      # Validates and activates *plugin* with the wired *context*.
      #
      # On success stores the plugin and appends its id to `load_order`,
      # returning *plugin*. On *any* failure raises `Core::PluginError`
      # and rolls back, leaving the router and this registry as if the
      # plugin was never registered.
      def register(plugin : Base, context : Context) : Base
        id = plugin.identifier
        validate_identifier!(id)
        raise Core::PluginError.new("Plugin '#{id}' already registered") if @plugins.has_key?(id)

        metadata = plugin.metadata
        validate_metadata!(id, metadata)
        metadata.capabilities.each do |cap|
          unless cap.matches?(/\A[a-zA-Z0-9_:.\-]+\z/)
            raise Core::PluginError.new("Plugin '#{id}' declares invalid capability '#{cap}'")
          end
        end
        metadata.dependencies.each do |dependency|
          unless @plugins.has_key?(dependency)
            raise Core::PluginError.new("Plugin '#{id}' depends on missing plugin '#{dependency}'")
          end
        end

        @contexts[id] = context
        @metadata[id] = metadata
        grant_plugin_capabilities!(context, metadata)
        declare_plugin_events!(metadata)
        plugin.initialize_plugin(context)
        validate_registered_commands!(id, metadata)
        register_plugin_ipc_policy!(id, metadata)
        @plugins[id] = plugin
        @load_order << id
        plugin
      rescue ex
        cleanup_owner(id) if id
        raise ex
      end

      # Returns the plugin registered under *id*.
      #
      # Raises `Core::PluginError` if no plugin with that identifier is
      # registered.
      def find(id : String) : Base
        find?(id) || raise Core::PluginError.new("Plugin '#{id}' is not registered")
      end

      # Returns the plugin registered under *id*, or `nil` if none.
      def find?(id : String) : Base?
        @plugins[id]?
      end

      # Returns the stored `Metadata` for the plugin identified by *id*.
      #
      # Raises `Core::PluginError` if no plugin with that identifier is
      # registered.
      def metadata(id : String) : Metadata
        @metadata[id]? || raise Core::PluginError.new("Plugin '#{id}' is not registered")
      end

      # Returns the first registered plugin that is an instance of *type*.
      #
      # Raises `Core::PluginError` if no plugin of *type* is registered.
      def find(type : T.class) : T forall T
        find?(type) || raise Core::PluginError.new("Plugin #{type} is not registered")
      end

      # Returns the first registered plugin that is an instance of *type*, or
      # `nil` if none.
      def find?(type : T.class) : T? forall T
        @plugins.values.find(&.is_a?(T)).as?(T)
      end

      # Yields each registered plugin in registration order.
      def each(&) : Nil
        @plugins.each_value { |plugin| yield plugin }
      end

      # Tears down every registered plugin in reverse `load_order`.
      #
      # Calls `cleanup_plugin` on each (logging and swallowing any errors so a
      # single failure does not abort the sweep), then revokes all IPC
      # ownership for that plugin. Safe to call once at app shutdown.
      def cleanup_all : Nil
        @load_order.reverse_each do |id|
          begin
            @plugins[id]?.try(&.cleanup_plugin)
          rescue ex
            Log.warn { "Plugin '#{id}' cleanup failed: #{ex.message}" }
          ensure
            cleanup_owner(id)
          end
        end
      end

      # Registers a non-contextual command handler attributed to *plugin_id*.
      #
      # Enforces the `MAX_COMMANDS_PER_PLUGIN` quota and records ownership.
      def register_command(plugin_id : String, name : String, handler : IPC::CommandHandler) : Nil
        register_contextual_command(plugin_id, name, ->(_context : IPC::Context, params : JSON::Any) {
          handler.call(params)
        })
      end

      # Registers a contextual command handler attributed to *plugin_id*.
      #
      # Raises `Core::PluginError` if the quota is exceeded or the plugin
      # has no runtime context.
      def register_contextual_command(plugin_id : String, name : String, handler : IPC::ContextualCommandHandler) : Nil
        owned_count = @command_owners.count { |_, owner| owner == plugin_id }
        if owned_count >= MAX_COMMANDS_PER_PLUGIN
          raise Core::PluginError.new("Plugin '#{plugin_id}' has reached the maximum of #{MAX_COMMANDS_PER_PLUGIN} commands")
        end

        canonical_name = name
        plugin_context = @contexts[plugin_id]? || raise Core::PluginError.new("Plugin '#{plugin_id}' has no runtime context")
        @router.register_contextual_command(canonical_name, ->(invocation : IPC::Context, params : JSON::Any) {
          handler.call(
            IPC::Context.new(
              app: invocation.app || plugin_context.app,
              security: invocation.security || plugin_context.security,
              window: invocation.window,
              plugins: self,
              plugin_id: plugin_id,
            ),
            params,
          )
        })
        @command_owners[canonical_name] = plugin_id
      end

      # Registers an async command attributed to *plugin_id*.
      #
      # Like `#register_contextual_command` but the handler runs on a fiber
      # with a real timeout, so the UI thread stays responsive during
      # blocking I/O. The command is tracked in `@command_owners` so
      # `validate_registered_commands!` sees it.
      def register_async_command(plugin_id : String, name : String, handler : IPC::AsyncContextualCommandHandler,
                                 timeout : Time::Span? = nil) : Nil
        owned_count = @command_owners.count { |_, owner| owner == plugin_id }
        if owned_count >= MAX_COMMANDS_PER_PLUGIN
          raise Core::PluginError.new("Plugin '#{plugin_id}' has reached the maximum of #{MAX_COMMANDS_PER_PLUGIN} commands")
        end

        plugin_context = @contexts[plugin_id]? || raise Core::PluginError.new("Plugin '#{plugin_id}' has no runtime context")
        @router.register_async_command(name, ->(invocation : IPC::Context, params : JSON::Any, token : Core::CancellationToken) {
          handler.call(
            IPC::Context.new(
              app: invocation.app || plugin_context.app,
              security: invocation.security || plugin_context.security,
              window: invocation.window,
              plugins: self,
              plugin_id: plugin_id,
            ),
            params,
            token,
          )
        }, timeout: timeout)
        @command_owners[name] = plugin_id
      end

      # Returns the identifier of the plugin that owns *command*, or `nil` if
      # the command is not registered through any plugin.
      def command_owner(command : String) : String?
        @command_owners[command]?
      end

      # Subscribes *handler* to *event* attributed to *plugin_id*.
      #
      # Enforces the `MAX_EVENTS_PER_PLUGIN` quota. Returns the `UInt64`
      # subscription id. Raises `Core::PluginError` if the quota is
      # exceeded.
      def subscribe_event(plugin_id : String, event : String, handler : IPC::EventHandler) : UInt64
        owned_count = @subscription_owners.count { |_, owner| owner == plugin_id }
        if owned_count >= MAX_EVENTS_PER_PLUGIN
          raise Core::PluginError.new("Plugin '#{plugin_id}' has reached the maximum of #{MAX_EVENTS_PER_PLUGIN} event listeners")
        end

        id = @router.subscribe_event(event, handler)
        @subscription_owners[id] = plugin_id
        id
      end

      # Emits *event* with *payload* on behalf of *plugin_id*.
      #
      # Validates that *event* is declared in the plugin's metadata
      # `events` list. Raises `Core::PluginError` if *plugin_id* is
      # empty, has no runtime metadata, or emits an undeclared event.
      def emit_event(plugin_id : String, event : String, payload : JSON::Any) : Nil
        raise Core::PluginError.new("Plugin identifier cannot be empty") if plugin_id.empty?
        metadata = @metadata[plugin_id]? || raise Core::PluginError.new("Plugin '#{plugin_id}' has no runtime metadata")
        unless metadata.events.includes?(event)
          raise Core::PluginError.new("Plugin '#{plugin_id}' emitted undeclared event '#{event}'")
        end
        @router.emit_event(event, payload)
      end

      # :nodoc:
      private def validate_identifier!(id : String) : Nil
        unless id.matches?(/\A[a-zA-Z0-9_-]{1,64}\z/)
          raise Core::PluginError.new("Invalid plugin identifier '#{id}'")
        end
      end

      # :nodoc:
      private def validate_metadata!(id : String, metadata : Metadata) : Nil
        unless metadata.id == id
          raise Core::PluginError.new("Plugin '#{id}' metadata id must match its identifier")
        end
        if metadata.commands.uniq.size != metadata.commands.size
          raise Core::PluginError.new("Plugin '#{id}' metadata contains duplicate commands")
        end
        if metadata.events.uniq.size != metadata.events.size
          raise Core::PluginError.new("Plugin '#{id}' metadata contains duplicate events")
        end
      end

      # :nodoc:
      private def validate_registered_commands!(plugin_id : String, metadata : Metadata) : Nil
        registered = @command_owners.select { |_, owner| owner == plugin_id }.keys.sort!
        declared = metadata.commands.sort
        return if registered == declared

        undeclared = registered - declared
        missing = declared - registered
        details = [] of String
        details << "undeclared commands: #{undeclared.join(", ")}" unless undeclared.empty?
        details << "missing commands: #{missing.join(", ")}" unless missing.empty?
        raise Core::PluginError.new("Plugin '#{plugin_id}' command metadata mismatch (#{details.join("; ")})")
      end

      # :nodoc:
      private def register_plugin_ipc_policy!(plugin_id : String, metadata : Metadata) : Nil
        metadata.ipc.commands.each do |command, policy|
          unless metadata.commands.includes?(command)
            raise Core::PluginError.new("Plugin '#{plugin_id}' declares IPC policy for unknown command '#{command}'")
          end
          @router.policy_resolver.register_plugin(command, policy)
        end
      end

      # :nodoc:
      private def grant_plugin_capabilities!(context : Context, metadata : Metadata) : Nil
        return if context.capabilities.manifest_loaded?
        metadata.capabilities.each do |capability|
          context.capabilities.grant(capability)
        end
      end

      # Declares the plugin's `frontend_events` — events the frontend is
      # allowed to emit — as frontend-emittable via
      # `Router#declare_frontend_event`. Only events explicitly listed in
      # `frontend_events` are declared; `events` (backend-emitted) are not,
      # preserving the security boundary: the frontend cannot emit
      # backend-originated events like `menu.click` or `fs.changed`.
      # :nodoc:
      private def declare_plugin_events!(metadata : Metadata) : Nil
        metadata.frontend_events.each { |event| @router.declare_frontend_event(event) }
      end

      # :nodoc:
      private def cleanup_owner(plugin_id : String) : Nil
        @command_owners.select { |_, owner| owner == plugin_id }.each_key do |command|
          @router.unregister_command(command)
          @command_owners.delete(command)
        end
        @subscription_owners.select { |_, owner| owner == plugin_id }.each_key do |subscription_id|
          @router.unsubscribe_event(subscription_id)
          @subscription_owners.delete(subscription_id)
        end
        @contexts.delete(plugin_id)
        @metadata.delete(plugin_id)
      end
    end
  end
end
