require "log"
require "./shell"

module CrystKit::Builder
  # Helpers for installing Crystal shard dependencies before a build.
  module CrystalDependencies
    # :nodoc:
    Log = ::Log.for(self)

    # Ensures shard dependencies are installed for the project at
    # *project_dir*.
    #
    # A no-op returning `true` when no `shard.yml` is present. When
    # *required* is `true` (the default) an exception is raised on a
    # missing `shards` executable or failed install. When `false`, a
    # missing `shards` or failed install is logged as a warning and
    # `false` is returned so non-critical callers can proceed.
    def self.install(project_dir : Path | String, required : Bool = true) : Bool
      dir = project_dir.to_s
      shard_file = File.join(dir, "shard.yml")

      unless File.exists?(shard_file)
        Log.debug { "No shard.yml found in #{dir}; skipping shards install." }
        return true
      end

      if required
        Shell.require_executable("shards")
      elsif !Shell.which?("shards")
        Log.warn { "Could not find 'shards'. Try: cd #{dir} && shards install" }
        return false
      end

      Log.info { "Installing Crystal dependencies..." }
      if Shell.exec("shards", ["install"], chdir: dir)
        Log.info { "Crystal dependencies installed." }
        true
      elsif required
        raise "Crystal dependency installation failed. Run `shards install` in #{dir} and try again."
      else
        Log.warn { "Could not run 'shards install'. Try: cd #{dir} && shards install" }
        false
      end
    end
  end
end
