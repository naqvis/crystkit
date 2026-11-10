require "log"
require "file_utils"

module CrystKit::Builder
  # Resolves and lazily creates CrystKit's per-user filesystem layout.
  #
  # Every accessor creates its directory on first access and memoizes
  # the result, so repeated calls do not re-stat or re-create the
  # directory. The root can be overridden with the `CRYSTKIT_HOME`
  # environment variable.
  module Paths
    extend self

    @@home : Path?
    @@cache_dir : Path?
    @@config_dir : Path?
    @@icons_cache_dir : Path?
    @@build_cache_dir : Path?
    @@template_dir : Path?

    # Returns the CrystKit home directory, defaulting to
    # `~/.crystkit` or the value of `CRYSTKIT_HOME`. Computed once and
    # cached.
    def home : Path
      @@home ||= Path[ENV["CRYSTKIT_HOME"]? || File.join(ENV["HOME"]? || Dir.home, ".crystkit")]
    end

    # Returns (and creates) the shared cache directory under `home`.
    def cache_dir : Path
      @@cache_dir ||= ensure_dir(home / "cache")
    end

    # Returns (and creates) the config directory under `home`.
    def config_dir : Path
      @@config_dir ||= ensure_dir(home / "config")
    end

    # Returns (and creates) the icons cache directory under the cache.
    def icons_cache_dir : Path
      @@icons_cache_dir ||= ensure_dir(cache_dir / "icons")
    end

    # Returns (and creates) the build cache directory under the cache.
    def build_cache_dir : Path
      @@build_cache_dir ||= ensure_dir(cache_dir / "build")
    end

    # Returns the path to the plugin registry file (`plugins.json`).
    # The parent directory is created on first access via `config_dir`.
    def plugin_registry_path : Path
      config_dir / "plugins.json"
    end

    # Returns (and creates) the user templates directory under `home`.
    def template_dir : Path
      @@template_dir ||= ensure_dir(home / "templates")
    end

    # Returns the path to the CLI state file (`state.json`). The parent
    # directory is created on first access via `config_dir`.
    def cli_state_path : Path
      config_dir / "state.json"
    end

    private def ensure_dir(path : Path) : Path
      Dir.mkdir_p(path.to_s)
      path
    end
  end
end
