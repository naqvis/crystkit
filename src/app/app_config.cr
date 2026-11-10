require "json"
require "path"

module CrystKit
  # Configuration for a custom URL scheme registered with the CrystKit.
  struct ProtocolConfig
    # URL scheme to register, without the trailing `://` (e.g. `"app"`).
    getter scheme : String

    # When `true`, serve requests for this scheme from `#asset_root`.
    getter? serve_assets : Bool

    # Filesystem root to serve assets from when `#serve_assets?` is true.
    getter asset_root : Path?

    def initialize(
      @scheme = "app",
      @serve_assets = false,
      @asset_root = nil,
    )
    end
  end

  # Per-command IPC policy override.
  struct IPCCommandOverride
    include JSON::Serializable

    # Capability the command requires (e.g. `"fs"`). When `nil` and
    # `#resource` is also `nil`, the command is public.
    getter capability : String?

    # Resource expression (path pattern, URL, etc.) the capability is
    # scoped to. When present, `#capability` must also be present.
    getter resource : String?

    # How `#resource` should be interpreted — `"resource"` (default) or
    # `"path"`.
    getter resource_kind : String?

    # Permission level required on `#resource`: `"read"`, `"write"`,
    # `"execute"`, or `nil`.
    getter permission : String?

    def initialize(
      @capability = nil,
      @resource = nil,
      @resource_kind = nil,
      @permission = nil,
    )
    end
  end

  # Aggregate IPC configuration.
  struct IPCConfig
    include JSON::Serializable

    # Map of IPC command name to policy override.
    getter commands : Hash(String, IPCCommandOverride)

    def initialize(@commands : Hash(String, IPCCommandOverride) = {} of String => IPCCommandOverride)
    end
  end

  # Runtime configuration for a CrystKit application.
  #
  # Carries the application's identity, storage paths, capability manifest
  # reference, Content Security Policy, custom protocols, plugin
  # configuration, and IPC command policy overrides.
  #
  # ```
  # config = AppConfig.new(
  #   name: "My App",
  #   identifier: "com.example.myapp",
  #   csp: "default-src 'self'",
  #   capabilities_manifest: Path["~/.config/myapp/capabilities.json"].expand,
  # )
  # app = CrystKit::App.new(config)
  # ```
  class AppConfig
    DEFAULT_NAME       = "CrystKit Application"
    DEFAULT_IDENTIFIER = "app.crystkit"
    DEFAULT_VERSION    = "0.1.0"

    # Human-readable application name.
    property name : String

    # Application version string.
    property version : String

    # Reverse-DNS identifier namespacing the application's storage
    # directory and platform integrations.
    property identifier : String

    # Filesystem directory for persistent state (scopes, window state,
    # plugin data). Defaults to `.default_storage_dir(identifier)`.
    property storage_dir : Path

    # Path to a JSON capability manifest. When set, `App` loads it
    # during initialization.
    property capabilities_manifest : Path?

    # Content Security Policy injected into every window as a
    # `<meta http-equiv="Content-Security-Policy">` tag. `nil` disables
    # CSP injection.
    property csp : String?

    # Custom protocols registered for every window.
    property protocols : Array(ProtocolConfig)

    # Per-plugin configuration, keyed by plugin identifier.
    property plugins_config : Hash(String, JSON::Any)

    # IPC command policy overrides.
    property ipc : IPCConfig

    # When `false`, disables auto-registration of the built-in
    # `crystkit://` asset protocol. Default: `true`.
    property? asset_protocol_enabled : Bool = true

    # Whether the built-in asset protocol serves `index.html` for
    # missing extensionless paths (SPA routing). Default: `true`.
    property? asset_spa_fallback : Bool = true

    # Directory containing frontend assets for dev mode, when no
    # `assets.vpak` is found. Typically set from `build.frontend_dist`
    # in `crystkit.json`, or directly in code. `nil` means rely on
    # the pak only (production).
    property frontend_dist : String?

    # Creates a configuration. When *storage_dir* is `nil` it is
    # computed from *identifier* via `.default_storage_dir`.
    def initialize(
      @name = DEFAULT_NAME,
      @version = DEFAULT_VERSION,
      @identifier = DEFAULT_IDENTIFIER,
      storage_dir : Path? = nil,
      @capabilities_manifest = nil,
      @csp = nil,
      @protocols = [] of ProtocolConfig,
      @plugins_config = {} of String => JSON::Any,
      @ipc = IPCConfig.new,
      @asset_protocol_enabled = true,
      @asset_spa_fallback = true,
      @frontend_dist = nil,
    )
      @storage_dir = storage_dir || self.class.default_storage_dir(@identifier)
    end

    # Compute the per-app storage directory using OS conventions.
    #
    # Returns a `Path` rooted at the platform's standard application
    # data location, namespaced by *identifier*:
    #
    # * macOS: `~/Library/Application Support/<identifier>`
    # * Linux: `$XDG_DATA_HOME/<identifier>` (or `~/.local/share/…`)
    # * Windows: `%APPDATA%/<identifier>` (or `%USERPROFILE%`)
    # * Other: `~/<identifier>`
    def self.default_storage_dir(identifier : String) : Path
      base = {% if flag?(:darwin) %}
               Path[ENV["HOME"]? || "/tmp"] / "Library" / "Application Support"
             {% elsif flag?(:linux) %}
               Path[ENV["XDG_DATA_HOME"]? || "#{ENV["HOME"]? || "/tmp"}/.local/share"]
             {% elsif flag?(:windows) %}
               Path[ENV["APPDATA"]? || ENV["USERPROFILE"]? || "."]
             {% else %}
               Path[ENV["HOME"]? || "/tmp"]
             {% end %}
      base / identifier
    end
  end
end
