require "json-schema"
require "json"
require "log"
require "../app/app_config"

module CrystKit
  module Builder
    # Visual style applied to the webview's scroll bars.
    #
    # `Default` keeps the native platform chrome, `Overlay` renders
    # floating scroll bars on top of content, and `Hidden` removes them
    # entirely.
    enum ScrollBarStyle
      Default
      Overlay
      Hidden
    end

    # Native compositing effect applied to the window background.
    #
    # `None` yields a plain opaque window. Effective only when
    # `WindowConfig#transparent` is enabled and the platform supports the
    # requested effect.
    enum WindowEffect
      None
      Vibrancy
      Mica
      Acrylic
      Blur
    end

    # Runtime configuration for a single application window.
    #
    # Mirrors the `app.windows[*]` entries in `crystkit.json`. Every field
    # has a safe default so a window can be created from an empty config
    # object.
    struct WindowConfig
      include JSON::Serializable

      @[JSON::Field(description: "Window title")]
      property title : String = "App"

      @[JSON::Field(description: "Window width in pixels", minimum: 100)]
      property width : Int32 = 800

      @[JSON::Field(description: "Window height in pixels", minimum: 100)]
      property height : Int32 = 600

      @[JSON::Field(description: "X position on screen")]
      property x : Int32?

      @[JSON::Field(description: "Y position on screen")]
      property y : Int32?

      @[JSON::Field(description: "Center the window on screen")]
      property? center : Bool = true

      @[JSON::Field(description: "Show window decorations (title bar, borders)")]
      property? decorations : Bool = true

      @[JSON::Field(description: "Allow window resizing")]
      property? resizable : Bool = true

      @[JSON::Field(description: "Open window in fullscreen mode")]
      property? fullscreen : Bool = false

      @[JSON::Field(description: "Whether the window can receive focus")]
      property? focusable : Bool = true

      @[JSON::Field(description: "Whether the window is visible")]
      property? visible : Bool = true

      @[JSON::Field(description: "Whether the window is transparent")]
      property? transparent : Bool = false

      @[JSON::Field(description: "Keep window on top of others")]
      property? always_on_top : Bool = false

      @[JSON::Field(description: "Show close button")]
      property? closable : Bool = true

      @[JSON::Field(description: "Show maximize button")]
      property? maximizable : Bool = true

      @[JSON::Field(description: "Show minimize button")]
      property? minimizable : Bool = true

      @[JSON::Field(description: "Window opacity (0.0 to 1.0)", minimum: 0.0, maximum: 1.0)]
      property opacity : Float64 = 1.0

      @[JSON::Field(description: "Minimum window width in pixels")]
      property min_width : Int32?

      @[JSON::Field(description: "Minimum window height in pixels")]
      property min_height : Int32?

      @[JSON::Field(description: "Maximum window width in pixels")]
      property max_width : Int32?

      @[JSON::Field(description: "Maximum window height in pixels")]
      property max_height : Int32?

      @[JSON::Field(description: "URL to load in the window instead of HTML content")]
      property url : String?

      @[JSON::Field(description: "Window label for identification in code")]
      property label : String?

      @[JSON::Field(description: "Scroll bar style")]
      property scroll_bar_style : ScrollBarStyle = ScrollBarStyle::Default

      @[JSON::Field(description: "Prevent content from overflowing the window bounds")]
      property? prevent_overflow : Bool = false

      @[JSON::Field(description: "Visual window effect (Vibrancy, Mica, Acrylic, Blur)")]
      property window_effect : WindowEffect = WindowEffect::None

      @[JSON::Field(description: "Use HTTPS scheme for the dev server URL")]
      property? use_https_scheme : Bool = false

      # Creates a window configuration with all fields optionally overridable.
      def initialize(
        @title = "App",
        @width = 800,
        @height = 600,
        @x = nil,
        @y = nil,
        @center = true,
        @decorations = true,
        @resizable = true,
        @fullscreen = false,
        @focusable = true,
        @visible = true,
        @transparent = false,
        @always_on_top = false,
        @closable = true,
        @maximizable = true,
        @minimizable = true,
        @opacity = 1.0,
        @min_width = nil,
        @min_height = nil,
        @max_width = nil,
        @max_height = nil,
        @url = nil,
        @label = nil,
        @scroll_bar_style = ScrollBarStyle::Default,
        @prevent_overflow = false,
        @window_effect = WindowEffect::None,
        @use_https_scheme = false,
      )
      end
    end

    # macOS code signing identity and entitlements.
    #
    # Populated from `bundle.signing.macos` in `crystkit.json`.
    struct SigningIdentity
      include JSON::Serializable

      @[JSON::Field(description: "macOS code signing identity (e.g. Developer ID Application: Name (TEAMID))")]
      property identity : String

      @[JSON::Field(description: "Path to entitlements.plist for macOS code signing")]
      property entitlements_path : String?

      # Creates a signing identity.
      #
      # *identity* of `"-"` or an empty string selects ad-hoc signing.
      def initialize(@identity = "", @entitlements_path = nil)
      end
    end

    # Windows code signing certificate reference.
    #
    # Populated from `bundle.signing.windows` in `crystkit.json`.
    struct WindowsSigning
      include JSON::Serializable

      @[JSON::Field(description: "Path to Windows signing certificate file")]
      property certificate_path : String

      @[JSON::Field(description: "Environment variable name containing the certificate password")]
      property password_env : String?

      # Creates a Windows signing configuration.
      def initialize(
        @certificate_path = "",
        @password_env = nil,
      )
      end
    end

    # Aggregate code-signing configuration across platforms.
    #
    # Only the sections for platforms you target need to be populated.
    struct SigningConfig
      include JSON::Serializable

      @[JSON::Field(description: "macOS code signing configuration")]
      property macos : SigningIdentity?

      @[JSON::Field(description: "Windows code signing configuration")]
      property windows : WindowsSigning?

      # Creates a signing configuration with no platform entries set.
      def initialize(
        @macos = nil,
        @windows = nil,
      )
      end

      # `json-schema` 2.x omits `required` from a schema when every property is
      # nilable, but its `introspect` helper assumes the key exists whenever the
      # property carries a description. Supplying an empty list keeps the
      # generated schema stable and lets the builder track the latest shard.
      def self.json_schema(openapi : Bool? = nil, refs : R = nil) forall R
        schema = super
        {type: schema[:type], properties: schema[:properties], required: [] of String}
      end
    end

    # Describes an external binary to be bundled as a sidecar.
    #
    # Sidecars are standalone executables shipped alongside the main app
    # binary (e.g. a helper tool or language runtime).
    struct ExternalBinary
      include JSON::Serializable

      @[JSON::Field(description: "Name of the external binary")]
      property name : String

      @[JSON::Field(description: "Path to the external binary file or directory")]
      property path : String

      # Creates an external binary descriptor.
      def initialize(
        @name = "",
        @path = "binaries",
      )
      end
    end

    # Packaging configuration for distributable bundles.
    #
    # Corresponds to the `bundle` section of `crystkit.json`. The default
    # `targets` are platform-dependent: `dmg` on macOS,
    # `deb`/`appimage` on Linux, and `msi`/`nsis` on Windows.
    struct BundleConfig
      include JSON::Serializable

      @[JSON::Field(description: "Icon file paths for application icons")]
      property icon : Array(String) = [] of String

      @[JSON::Field(description: "Bundle target platforms (dmg, deb, msi, rpm, nsis, appimage)")]
      property targets : Array(String) = begin
        {% if flag?(:darwin) %}
          ["dmg"]
        {% elsif flag?(:linux) %}
          ["deb", "appimage"]
        {% elsif flag?(:win32) %}
          ["msi", "nsis"]
        {% else %}
          ["dmg", "deb", "msi"]
        {% end %}
      end

      @[JSON::Field(description: "Application category (Utility, Development, Business, etc.)")]
      property category : String = "Utility"

      @[JSON::Field(description: "Copyright notice for the application")]
      property copyright : String = ""

      @[JSON::Field(description: "macOS microphone privacy prompt text")]
      property macos_microphone_usage_description : String?

      @[JSON::Field(description: "macOS speech-recognition privacy prompt text")]
      property macos_speech_recognition_usage_description : String?

      @[JSON::Field(description: "Code signing configuration")]
      property signing : SigningConfig?

      @[JSON::Field(description: "MSI upgrade code (stable UUID for Windows installer). Generated at scaffold time.")]
      property upgrade_code : String?

      @[JSON::Field(description: "External binaries to bundle with the application")]
      property external_bin : Array(ExternalBinary) = [] of ExternalBinary

      @[JSON::Field(description: ".vpak archive configuration")]
      property pak : PakConfig = PakConfig.new

      # Creates a bundle configuration.
      def initialize(
        @icon : Array(String) = [] of String,
        @targets : Array(String) = begin
          {% if flag?(:darwin) %}
            ["dmg"]
          {% elsif flag?(:linux) %}
            ["deb", "appimage"]
          {% elsif flag?(:win32) %}
            ["msi", "nsis"]
          {% else %}
            ["dmg", "deb", "msi"]
          {% end %}
        end,
        @category = "Utility",
        @copyright = "",
        @macos_microphone_usage_description = nil,
        @macos_speech_recognition_usage_description = nil,
        @signing = nil,
        @upgrade_code = nil,
        @external_bin : Array(ExternalBinary) = [] of ExternalBinary,
        @pak : PakConfig = PakConfig.new,
      )
      end
    end

    # Configuration for the `.vpak` archive emitted by the bundler.
    struct PakConfig
      include JSON::Serializable

      @[JSON::Field(description: "Whether to emit a .vpak archive of frontend assets")]
      property? enabled : Bool = true

      @[JSON::Field(description: "Compression codec: none, deflate, gzip, or snappy")]
      property compress : String = "deflate"

      @[JSON::Field(description: "Chunk size for .vpak entries (e.g. 256k, 1m)")]
      property chunk_size : String = "256k"

      def initialize(
        @enabled = true,
        @compress = "deflate",
        @chunk_size = "256k",
      )
      end

      def chunk_size_bytes : Int32
        s = chunk_size.downcase
        if s.ends_with?("k")
          (s.rchop("k").to_i * 1024).to_i32
        elsif s.ends_with?("m")
          (s.rchop("m").to_i * 1024 * 1024).to_i32
        else
          s.to_i32
        end
      end

      def codec_symbol : Symbol
        case compress.downcase
        when "none"    then :none
        when "deflate" then :deflate
        when "gzip"    then :gzip
        when "snappy"  then :snappy
        else                :deflate
        end
      end
    end

    # Allow/deny globs governing which asset URLs the webview may load.
    #
    # Maps to `app.security.asset_protocol` in `crystkit.json`.
    struct AssetProtocolScope
      include JSON::Serializable

      # Glob patterns permitting access to matching asset paths.
      property allow : Array(String) = [] of String

      # Glob patterns explicitly blocking matching asset paths, overriding
      # `allow` entries.
      property deny : Array(String) = [] of String

      # Creates an asset protocol scope with empty allow/deny lists.
      def initialize(
        @allow : Array(String) = [] of String,
        @deny : Array(String) = [] of String,
      )
      end
    end

    # Runtime security policy for the application.
    #
    # Corresponds to `app.security` in `crystkit.json` and controls the
    # capabilities manifest, CORS, webview isolation, Content Security
    # Policy, prototype freezing, and the asset protocol scope.
    struct SecurityConfig
      include JSON::Serializable

      @[JSON::Field(description: "Path to the capabilities.json manifest file")]
      property capabilities_manifest : String?

      @[JSON::Field(description: "Allow CORS requests from webview content")]
      property? allow_cors : Bool = false

      @[JSON::Field(description: "Enable webview process isolation for security")]
      property? isolation : Bool = false

      @[JSON::Field(description: "List of URLs/domains allowed in isolated webview context")]
      property isolation_allowlist : Array(String) = [] of String

      @[JSON::Field(description: "Content Security Policy header value")]
      property csp : String?

      @[JSON::Field(description: "CSP override applied during development mode")]
      property dev_csp : String?

      @[JSON::Field(description: "Freeze JavaScript built-in prototypes to prevent tampering")]
      property? freeze_prototype : Bool = false

      property asset_protocol : AssetProtocolScope = AssetProtocolScope.new

      @[JSON::Field(description: "Dangerously disable CSP modification (not recommended for production)")]
      property? dangerous_disable_asset_csp_modification : Bool = false

      # Creates a security configuration with all policy fields defaulted to
      # safe, restrictive values.
      def initialize(
        @capabilities_manifest = nil,
        @allow_cors = false,
        @isolation = false,
        @isolation_allowlist : Array(String) = [] of String,
        @csp = nil,
        @dev_csp = nil,
        @freeze_prototype = false,
        @asset_protocol = AssetProtocolScope.new,
        @dangerous_disable_asset_csp_modification = false,
      )
      end
    end

    # Build pipeline and dev server settings.
    #
    # Corresponds to the `build` section of `crystkit.json`: where frontend
    # assets live, the dev URL to proxy, optional pre-build/pre-dev commands,
    # a custom Crystal entry point, extra compiler flags, and whether to
    # wait for the dev server before opening the window.
    struct BuildConfig
      include JSON::Serializable

      @[JSON::Field(description: "Path to frontend build output directory")]
      property frontend_dist : String = "./dist"

      @[JSON::Field(description: "Dev server URL", pattern: "^https?://")]
      property dev_url : String = "http://localhost:5173"

      @[JSON::Field(description: "Command to run before production build")]
      property before_build_command : String?

      @[JSON::Field(description: "Command to run before starting dev mode")]
      property before_dev_command : String?

      @[JSON::Field(description: "Custom Crystal entry point path")]
      property crystal_entry : String?

      @[JSON::Field(description: "Additional Crystal compiler flags")]
      property crystal_flags : Array(String) = [] of String

      @[JSON::Field(description: "Wait for dev server to be ready before opening the window")]
      property? wait_for_dev_url : Bool = true

      # Creates a build configuration with conventional defaults.
      def initialize(
        @frontend_dist = "./dist",
        @dev_url = "http://localhost:5173",
        @before_build_command = nil,
        @before_dev_command = nil,
        @crystal_entry = nil,
        @crystal_flags : Array(String) = [] of String,
        @wait_for_dev_url = true,
      )
      end

      # Validates the build configuration, raising on invalid values.
      #
      # Currently ensures `dev_url` is non-empty and uses an `http://` or
      # `https://` scheme. Called as part of `Config#validate!`.
      def validate! : Nil
        if dev_url.empty?
          raise "build.dev_url cannot be empty"
        end
        unless dev_url.starts_with?("http://") || dev_url.starts_with?("https://")
          raise "build.dev_url must start with http:// or https://"
        end
      end
    end

    # Custom URL protocol / deep-link handler configuration.
    #
    # Corresponds to entries under `app.protocols` in `crystkit.json`. Each
    # protocol registers a scheme (e.g. `myapp`) that the app handles.
    struct ProtocolConfig
      include JSON::Serializable

      @[JSON::Field(description: "Custom protocol scheme name (e.g. myapp)")]
      property scheme : String = "app"

      @[JSON::Field(description: "Serve static assets from the custom protocol")]
      property? serve_assets : Bool = false

      @[JSON::Field(description: "Root directory path for serving assets via the protocol")]
      property asset_root : String?

      @[JSON::Field(description: "URL the protocol should point to")]
      property url : String?

      # Creates a protocol configuration.
      def initialize(
        @scheme = "app",
        @serve_assets = false,
        @asset_root = nil,
        @url = nil,
      )
      end
    end

    # Runtime application configuration section of `crystkit.json`.
    #
    # Aggregates window definitions, the security policy, and custom
    # protocol handlers.
    struct AppConfigSection
      include JSON::Serializable

      @[JSON::Field(description: "Window definitions for runtime window creation")]
      property windows : Array(WindowConfig) = [] of WindowConfig

      @[JSON::Field(description: "Security configuration — CSP, isolation, asset protocol")]
      property security : SecurityConfig = SecurityConfig.new

      @[JSON::Field(description: "Custom protocol handlers for deep linking")]
      property protocols : Array(ProtocolConfig) = [] of ProtocolConfig

      # Creates an application config section with no windows, a default
      # security policy, and no custom protocols.
      def initialize(
        @windows : Array(WindowConfig) = [] of WindowConfig,
        @security = SecurityConfig.new,
        @protocols : Array(ProtocolConfig) = [] of ProtocolConfig,
      )
      end
    end

    # Application metadata used by the builder and bundler.
    #
    # Corresponds to the `package` section of `crystkit.json`: `name`,
    # `version`, and `identifier` name artifacts and populate platform
    # manifests; `authors`, `homepage`, `description`, and `license` are
    # embedded in installer metadata.
    struct PackageSection
      include JSON::Serializable

      @[JSON::Field(description: "Application display name", min_length: 1)]
      property name : String = "App"

      @[JSON::Field(description: "Application version in semver format", min_length: 1)]
      property version : String = "0.1.0"

      @[JSON::Field(description: "Reverse-domain application identifier (e.g. com.example.app)", pattern: "^[a-zA-Z0-9.\\-]+$")]
      property identifier : String = "com.example.app"

      @[JSON::Field(description: "List of application authors")]
      property authors : Array(String) = [] of String

      @[JSON::Field(description: "Project homepage URL")]
      property homepage : String?

      @[JSON::Field(description: "Short description of the application")]
      property description : String?

      @[JSON::Field(description: "SPDX license identifier (e.g. MIT, Apache-2.0)")]
      property license : String?

      # Creates a package section with conventional defaults.
      def initialize(
        @name = "App",
        @version = "0.1.0",
        @identifier = "com.example.app",
        @authors : Array(String) = [] of String,
        @homepage = nil,
        @description = nil,
        @license = nil,
      )
      end

      # Returns a maintainer string suitable for package manifests.
      #
      # Falls back to a placeholder `Unknown <unknown@example.com>` when no
      # authors are configured.
      def maintainer : String
        authors.first? || "Unknown <unknown@example.com>"
      end

      # Returns the publisher name with any email angle-addr stripped.
      #
      # Falls back to `"Unknown"` when no authors are configured.
      def publisher : String
        if first = authors.first?
          first.gsub(/\s*<[^>]*>\s*/, "").strip
        else
          "Unknown"
        end
      end

      # Returns the configured description, or a generated default that
      # interpolates the package name so installer metadata is never blank.
      def description_or_default : String
        description || "#{name} - Built with CrystKit"
      end

      # Validates required package fields, raising with a clear message.
      #
      # Ensures `name`, `version`, and `identifier` are non-empty and that
      # `identifier` contains at least one dot (e.g. `com.example.app`).
      def validate! : Nil
        if name.empty?
          raise "package.name is required"
        end
        if version.empty?
          raise "package.version is required"
        end
        if identifier.empty?
          raise "package.identifier is required"
        end
        unless identifier.includes?(".")
          raise "package.identifier must contain at least one dot (e.g. com.example.app)"
        end
      end
    end

    # Root configuration object for a CrystKit project, parsed from
    # `crystkit.json`.
    #
    # Ties together the four top-level sections — `package`, `build`, `app`,
    # and `bundle` — plus an open-ended `plugins` map.
    #
    # Use `load` to read and validate a file, `load_or_default` to fall
    # back to defaults when no config is present, and `to_app_config` to
    # derive the runtime `AppConfig` consumed by the application process.
    class Config
      include JSON::Serializable

      @[JSON::Field(description: "Application metadata — name, version, identifier, authors")]
      property package : PackageSection = PackageSection.new

      @[JSON::Field(description: "Build and dev server configuration")]
      property build : BuildConfig = BuildConfig.new

      @[JSON::Field(description: "Runtime application configuration — windows, security, protocols")]
      property app : AppConfigSection = AppConfigSection.new

      @[JSON::Field(description: "Packaging and bundling configuration — icons, targets, signing")]
      property bundle : BundleConfig = BundleConfig.new

      @[JSON::Field(description: "Plugin-specific configuration. Each key is a plugin identifier.")]
      property plugins : Hash(String, JSON::Any) = {} of String => JSON::Any

      # Filesystem path the config was loaded from, or `nil` for a default
      # config.
      @[JSON::Field(ignore: true)]
      property source_path : String? = nil

      # Creates a config with all sections defaulted.
      def initialize(
        @package = PackageSection.new,
        @build = BuildConfig.new,
        @app = AppConfigSection.new,
        @bundle = BundleConfig.new,
        @plugins : Hash(String, JSON::Any) = {} of String => JSON::Any,
        @source_path = nil,
      )
      end

      # Loads and validates a config from *path*, returning the populated
      # `Config`.
      #
      # Raises a descriptive error on parse or validation failure.
      def self.load(path : String) : Config
        config = Config.from_json(File.read(path))
        config.source_path = Path[path].expand.to_s
        config.validate!
        Log.info { "Loaded config from #{path}" }
        config
      rescue ex : JSON::ParseException
        raise "Failed to parse config from #{path}: #{ex.message}"
      rescue ex
        raise "Failed to load config from #{path}: #{ex.message}"
      end

      # Validates the config, raising a multi-line message aggregating all
      # section errors and actionable suggestions.
      def validate! : Nil
        errors = [] of String
        suggestions = [] of String

        begin
          package.validate!
        rescue ex
          errors << ex.message.to_s
          case ex.message
          when /name is required/
            suggestions << "Add \"package\": { \"name\": \"YourApp\" } to crystkit.json"
          when /version is required/
            suggestions << "Add \"version\": \"0.1.0\" under the package section"
          end
        end

        begin
          build.validate!
        rescue ex
          errors << ex.message.to_s
          case ex.message
          when /dev_url/
            suggestions << "Add \"build\": { \"dev_url\": \"http://localhost:5173\" }"
          end
        end

        unless errors.empty?
          msg = String.build do |io|
            io << "Config validation failed:\n"
            errors.each_with_index do |err, i|
              io << "  #{i + 1}. #{err}\n"
            end
            unless suggestions.empty?
              io << "\nSuggestions:\n"
              suggestions.each do |suggestion|
                io << "  - #{suggestion}\n"
              end
            end
          end
          raise msg.strip
        end
      end

      # Converts this builder config into a runtime `AppConfig`.
      #
      # Protocol `asset_root` values are resolved against `project_dir`.
      def to_app_config
        AppConfig.new(
          name: @package.name,
          version: @package.version,
          identifier: @package.identifier,
          capabilities_manifest: @app.security.capabilities_manifest.try { |s| Path[s] },
          csp: @app.security.csp,
          protocols: @app.protocols.map { |protocol|
            CrystKit::ProtocolConfig.new(
              scheme: protocol.scheme,
              serve_assets: protocol.serve_assets?,
              asset_root: protocol.asset_root.try { |path| resolve(path) },
            )
          },
          plugins_config: @plugins,
          frontend_dist: resolve(@build.frontend_dist).to_s,
        )
      end

      # Returns the directory the config file lives in, or the current
      # working directory for a default config.
      def project_dir : Path
        if sp = @source_path
          Path[sp].parent
        else
          Path[Dir.current]
        end
      end

      # Resolves *relative* against `project_dir`, returning an absolute,
      # normalized `Path`. Absolute paths are returned normalized unchanged.
      def resolve(relative : String) : Path
        p = Path[relative]
        p.absolute? ? p : (project_dir / relative).normalize
      end

      # File names searched for when auto-discovering a project config.
      CONFIG_FILENAMES = %w[crystkit.json]

      # Searches for a config file, returning its path or `nil`.
      #
      # When *path* is given and exists it is returned directly; otherwise
      # the current directory and its parents are scanned for the names in
      # `CONFIG_FILENAMES`.
      def self.find_config(path : String? = nil) : String?
        if path
          return path if File.file?(path)
          return nil
        end

        current = Dir.current
        loop do
          found = CONFIG_FILENAMES.find { |config_path| File.file?(File.join(current, config_path)) }
          return File.join(current, found) if found
          parent = File.dirname(current)
          break if parent == current
          current = parent
        end

        nil
      end

      # Loads a config from *path*, or returns a default `Config` when none is
      # found.
      #
      # Logs a warning when no config is located.
      def self.load_or_default(path : String? = nil) : Config
        if found = find_config(path)
          load(found)
        else
          Log.warn { "No crystkit.json found. Using default configuration." }
          new
        end
      end

      # Returns the value of the `CRYSTKIT_<KEY>` environment variable, or
      # *default* when unset.
      #
      # *key* is upper-cased and hyphens converted to underscores, so
      # `env_override("my-var", "x")` reads `CRYSTKIT_MY_VAR`.
      def self.env_override(key : String, default : String) : String
        ENV["CRYSTKIT_#{key.upcase.tr("-", "_")}"]? || default
      end
    end
  end
end
