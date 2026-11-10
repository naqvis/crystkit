require "option_builder"
require "log"
require "./config"
require "./build"
require "./paths"
require "./bundle/bundler"
require "./commands/init"
require "./commands/info"
require "./commands/plugin"
require "./commands/icon"
require "./commands/dev"
require "./commands/schema"
require "./shell"
require "./scaffold/scaffold"

# Configures the `crystkit` command-line interface and dispatches
# subcommands to the `CrystKit::Builder::Commands::*` handlers.
#
# Executable entry point for the builder CLI.
Log.setup_from_env(log_level_env: "CRYSTKIT_LOG")

# Version string reported by `crystkit --version`.
VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify }}

# Default value for the global `--ci` flag.
CI_MODE = false

cmd = OptionBuilder.command("crystkit", "CrystKit Builder — Lightweight native desktop application toolkit") do |command|
  command.version VERSION

  command.on_error do |ex|
    case ex
    when CrystKit::Core::Error
      STDERR.puts "Error: #{ex.message}"
      STDERR.puts "  code: #{ex.code}" if ex.code
    when OptionParser::Exception, OptionBuilder::CommandError
      STDERR.puts "Error: #{ex.message}"
    else
      STDERR.puts "Error: #{ex.message}"
    end
    exit 1
  end

  verbosity = 0
  command.persistent_count_flag('v', "verbose", description: "Verbosity level (-v, -vv, -vvv)") { |v| verbosity = v }
  ci_mode = false
  command.persistent_flag(nil, "ci", Bool, description: "CI mode — no colors, no prompts, minimal output") { |v| ci_mode = v }
  command.persistent_flag(nil, "log-level", String, env: "CRYSTKIT_LOG", description: "Log level (debug, info, warn, error)", hidden: true) { |v| Log.setup(Log::Severity.parse(v)) }

  command.persistent_pre_run do
    Log.setup(Log::Severity::Debug) if verbosity > 0
    Log.setup(Log::Severity::Warn) if ci_mode
  end

  command.example "crystkit init MyApp", "Scaffold a new CrystKit project"
  command.example "crystkit init --interactive", "Scaffold interactively with prompts"
  command.example "crystkit dev", "Start dev server with hot reload"
  command.example "crystkit build --target dmg,deb", "Build binary and bundle for distribution"
  command.example "crystkit info", "Show system information"
  command.example "crystkit doctor", "Check system requirements"
  command.example "crystkit icon input.png -o icons", "Generate app icons"
  command.example "crystkit plugin add ../my-plugin", "Add a plugin to the project"
  command.example "crystkit completion bash", "Generate bash completion script"

  command.subcommand_group "Core Commands", "init", "dev", "build", "bundle"
  command.subcommand_group "Diagnostics", "info", "doctor"
  command.subcommand_group "Tooling", "plugin", "icon", "completion", "schema"

  command.subcommand("init", "Scaffold a new CrystKit project") do |init|
    name = ""
    interactive = false
    template = ""
    list_only = false

    init.positional("name", String, required: false, description: "Project name") { |v| name = v }
    init.flag(nil, "interactive", Bool, description: "Interactive mode with prompts") { |v| interactive = v }
    init.flag(nil, "template", String, description: "Scaffold template name or path") { |v| template = v }
    init.flag(nil, "list", Bool, description: "List available scaffold templates") { |v| list_only = v }

    init.run do |_|
      if list_only
        scaffolds = CrystKit::Builder::Scaffold::Resolver.new.list_available
        if scaffolds.empty?
          puts "No scaffold templates found in scaffolds/ directory."
        else
          puts "Available scaffold templates:"
          scaffolds.each { |s| puts "  #{s.name.ljust(16)} #{s.description}" }
        end
        next
      end

      if interactive || (name.empty? && !ci_mode)
        interactive = true
        name = "my_app" if name.empty?
      end
      raise "Project name is required. Usage: crystkit init MyApp" if name.empty?

      CrystKit::Builder::Commands::Init.new(
        name, interactive: interactive,
        template_name: template.empty? ? nil : template
      ).run
    end
  end

  command.subcommand("info", "Show system information") do |info|
    info.run do |_|
      CrystKit::Builder::Commands::Info.new.run
    end
  end

  command.subcommand("doctor", "Check system requirements") do |doctor|
    doctor.run do |_|
      CrystKit::Builder::Commands::Doctor.new.run
    end
  end

  command.subcommand("icon", "Generate app icons from a source image") do |icon|
    source = ""
    output = "./icons"
    targets = "png"
    size = 128

    icon.positional("source", String, required: true, description: "Source image (PNG recommended)") { |v| source = v }
    icon.flag('o', "output", String, default: "./icons", description: "Output directory") { |v| output = v }
    icon.flag('t', "target", String, default: "png", description: "Target formats (comma-sep: png,ico,icns)") { |v| targets = v }
    icon.flag(nil, "size", Int32, default: 128, description: "Base icon size (32, 128, 256, 512)") { |v| size = v }

    icon.run do |_|
      CrystKit::Builder::Commands::Icon.new(
        source, output, targets.split(","), size
      ).run
    end
  end

  command.subcommand("build", "Build binary and bundle for distribution", aliases: ["b"]) do |build|
    config_path = ""
    project_dir = ""
    binary_path = "./bin/app"
    output_dir = "./dist"
    targets = [] of String
    release = true
    skip_frontend = false

    build.positional("project", String, required: false, description: "Project directory (looks for crystkit.json inside)") { |v| project_dir = v }
    build.flag('c', "config", String, env: "CRYSTKIT_CONFIG", description: "Path to crystkit.json") { |v| config_path = v }
    build.flag('t', "target", String,
      env: "CRYSTKIT_TARGETS",
      aliases: ["bundles"],
      description: "Bundle targets (comma-separated: dmg,deb,rpm,msi,nsis,appimage,portable)") { |v| targets = v.split(",") }
    build.flag('b', "binary", String, default: "./bin/app", description: "Path to compiled binary") { |v| binary_path = v }
    build.flag('o', "output", String, default: "./dist", description: "Output directory") { |v| output_dir = v }
    build.flag(nil, "no-release", Bool, description: "Build without --release flag") { |_| release = false }
    build.flag(nil, "skip-frontend", Bool, description: "Skip frontend build") { |_| skip_frontend = true }

    build.run do |_|
      resolved_config = if !config_path.empty?
                          config_path
                        elsif !project_dir.empty?
                          File.join(project_dir, "crystkit.json")
                        else
                          nil
                        end
      cfg = CrystKit::Builder::Config.load_or_default(resolved_config)
      builder = CrystKit::Builder::Build.new(cfg, output_dir: output_dir, release: release, skip_frontend: skip_frontend)
      manifest = builder.run
      Log.info { "Build complete: #{manifest.binary_path}" }

      bundler = CrystKit::Builder::Bundle::Bundler.new(cfg, manifest.binary_path, output_dir)
      results = bundler.bundle(targets.empty? ? nil : targets)
      Log.info { "Bundle artifacts:" }
      results.each { |target, path| Log.info { "  #{target}: #{path}" } }
    end
  end

  command.subcommand("bundle", "Bundle an existing binary into distributable packages", aliases: ["package"]) do |bundle|
    config_path = ""
    project_dir = ""
    binary_path = "./bin/app"
    output_dir = "./dist"
    targets = [] of String

    bundle.positional("project", String, required: false, description: "Project directory (looks for crystkit.json inside)") { |v| project_dir = v }
    bundle.flag('c', "config", String, env: "CRYSTKIT_CONFIG", description: "Path to crystkit.json") { |v| config_path = v }
    bundle.flag('t', "target", String,
      env: "CRYSTKIT_TARGETS",
      description: "Bundle targets (comma-separated: dmg,deb,rpm,msi,nsis,appimage,portable)") { |v| targets = v.split(",") }
    bundle.flag('b', "binary", String, default: "./bin/app", description: "Path to compiled binary") { |v| binary_path = v }
    bundle.flag('o', "output", String, default: "./dist", description: "Output directory") { |v| output_dir = v }

    bundle.run do |_|
      resolved_config = if !config_path.empty?
                          config_path
                        elsif !project_dir.empty?
                          File.join(project_dir, "crystkit.json")
                        else
                          nil
                        end
      cfg = CrystKit::Builder::Config.load_or_default(resolved_config)
      CrystKit::Builder::Bundle::Bundler.new(cfg, binary_path, output_dir).bundle(targets.empty? ? nil : targets)
    end
  end

  command.subcommand("dev", "Start dev server with hot reload") do |dev|
    config_path = ""
    project_dir = ""

    dev.positional("project", String, required: false, description: "Project directory (looks for crystkit.json inside)") { |v| project_dir = v }
    dev.flag('c', "config", String, env: "CRYSTKIT_CONFIG", description: "Path to crystkit.json") { |v| config_path = v }

    dev.run do |_|
      resolved_config = if !config_path.empty?
                          config_path
                        elsif !project_dir.empty?
                          File.join(project_dir, "crystkit.json")
                        else
                          nil
                        end
      cfg = CrystKit::Builder::Config.load_or_default(resolved_config)
      dev_cmd = CrystKit::Builder::Commands::Dev.new(config: cfg)
      dev_cmd.ci_mode = ci_mode
      dev_cmd.run
    end
  end

  command.subcommand("plugin", "Plugin SDK: scaffold, build, add, remove") do |plugin|
    plugin_name = ""
    output_dir = "."
    is_new = false
    should_build = false
    should_add = false
    should_remove = false

    plugin.flag('n', "name", String, description: "Plugin name") { |v| plugin_name = v }
    plugin.flag('o', "output", String, default: ".", description: "Output directory") { |v| output_dir = v }
    plugin.flag(nil, "new", Bool, description: "Create a new plugin scaffold") { |v| is_new = v }
    plugin.flag(nil, "build", Bool, description: "Build a plugin") { |v| should_build = v }
    plugin.flag(nil, "add", Bool, description: "Add a plugin to the project") { |v| should_add = v }
    plugin.flag(nil, "remove", Bool, description: "Remove a plugin from the project") { |v| should_remove = v }

    plugin.run do |_|
      if is_new
        raise "Plugin name is required. Usage: --name MyPlugin" if plugin_name.empty?
        CrystKit::Builder::Commands::PluginScaffold.new(plugin_name, output_dir).run
      elsif should_build
        CrystKit::Builder::Commands::PluginBuild.new(output_dir, output_dir).run
      elsif should_add
        raise "Plugin path is required. Usage: --add ../path/to/plugin" if plugin_name.empty?
        CrystKit::Builder::Commands::PluginAdd.new(plugin_name, output_dir).run
      elsif should_remove
        raise "Plugin name is required. Usage: --remove MyPlugin" if plugin_name.empty?
        CrystKit::Builder::Commands::PluginRemove.new(plugin_name, output_dir).run
      else
        puts plugin.help_string
      end
    end
  end

  command.subcommand("completion", "Generate shell completion scripts") do |completion|
    shell = ""

    completion.positional("shell", String, required: true, description: "Shell type (bash, zsh, fish, powershell)") do |v|
      shell = v
    end

    completion.run do |_|
      print command.generate_completion(shell)
    end
  end

  command.subcommand("schema", "Generate or print JSON Schema for config files") do |schema|
    output_dir = ""
    type = ""

    schema.flag('o', "output", String, description: "Output directory for schema files") { |v| output_dir = v }
    schema.flag(nil, "type", String, description: "Schema type to print (crystkit, capabilities)") { |v| type = v }

    schema.run do |_|
      CrystKit::Builder::Commands::Schema.new(
        output_dir: output_dir.empty? ? nil : output_dir,
        type: type.empty? ? nil : type,
      ).run
    end
  end
end

begin
  cmd.execute
rescue ex : CrystKit::Core::Error
  STDERR.puts "Error: #{ex.message}"
  STDERR.puts "  code: #{ex.code}" if ex.code
  exit 1
rescue ex : Exception
  STDERR.puts "Error: #{ex.message}"
  STDERR.puts ex.backtrace.join("\n") if ex.backtrace
  exit 1
end
