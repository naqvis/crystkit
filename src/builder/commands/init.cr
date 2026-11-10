require "log"
require "file_utils"
require "../dependencies"
require "../scaffold/embedded"
require "../scaffold/scaffold"

module CrystKit
  module Builder
    module Commands
      # Implements `crystkit init` — scaffolds a new CrystKit project.
      #
      # Creates a project directory, copies either the embedded `Hello`
      # template or an external scaffold (resolved by
      # `Scaffold::Resolver`), initializes a git repository, and
      # optionally installs shard dependencies. In interactive mode it
      # prompts for the project name, identifier, and author.
      class Init
        # :nodoc:
        Log = ::Log.for(self)

        # Sanitized project name (non-alphanumeric characters become `_`).
        getter name : String
        # Base directory under which the project directory is created.
        getter path : String
        # Whether interactive prompting is enabled.
        getter? interactive : Bool
        # Reverse-domain application identifier (e.g. `com.myapp.app`).
        getter identifier : String
        # Author string embedded in generated metadata.
        getter author : String
        # Optional external template name/path/URL, or `nil` for the embedded
        # `Hello` template.
        getter template_name : String?

        # Creates an init command.
        #
        # *name* is sanitized to filesystem-safe characters. The default
        # *identifier* is derived from the lowercased name. When
        # *interactive* is true, `run` prompts for overrides before
        # scaffolding.
        def initialize(
          @name : String,
          @path = ".",
          @interactive = false,
          @identifier = "",
          @author = "",
          @template_name = nil,
        )
          @name = name.gsub(/[^a-zA-Z0-9_-]/, "_")
          @identifier = "com.#{@name.downcase}.app" if @identifier.empty?
        end

        # Scaffolds the project, raising if the target directory already exists.
        def run : Nil
          project_dir = Path[path] / name

          if Dir.exists?(project_dir.to_s)
            raise "Directory '#{project_dir}' already exists"
          end

          if interactive?
            interactive_setup
          end

          Dir.mkdir_p((project_dir / "icons").to_s)

          if template_name
            copy_external_template(project_dir)
          else
            copy_embedded_template(project_dir)
          end

          git_init(project_dir)
          Log.info { "Created CrystKit project '#{name}' at #{project_dir}" }
          install_dependencies(project_dir)
          Log.info { "Next steps:" }
          Log.info { "  cd #{project_dir}" }
          Log.info { "  shards build && bin/#{name}" }
        end

        # :nodoc:
        private def interactive_setup
          @name = prompt("Project name", default: @name)
          @name = @name.gsub(/[^a-zA-Z0-9_-]/, "_")
          @identifier = prompt("App identifier (e.g. com.example.app)", default: "com.#{@name.downcase}.app")
          @author = prompt("Author", default: @author)
        end

        # :nodoc:
        private def prompt(label : String, default : String = "") : String
          print "#{label} "
          print "[#{default}] " unless default.empty?
          print ": "
          STDOUT.flush
          line = STDIN.gets
          input = line ? line.strip : ""
          input.empty? ? default : input
        end

        # :nodoc:
        private def copy_embedded_template(dir : Path) : Nil
          Scaffold::Hello.files(name, identifier, "0.1.0", author).each do |entry|
            target = dir / entry.path
            Dir.mkdir_p(File.dirname(target.to_s))
            File.write(target.to_s, entry.content)
          end
          icon_path = (dir / "icons" / "tray_icon.png").to_s
          File.write(icon_path, Scaffold::Hello::TRAY_ICON_DATA.to_slice)
        end

        # :nodoc:
        private def copy_external_template(dir : Path) : Nil
          resolver = Scaffold::Resolver.new
          begin
            source = resolver.resolve(template_name.to_s)
            raise "Scaffold '#{template_name}' not found" unless source
            resolver.copy_external(source, dir.to_s, name, identifier, "0.1.0", author)
          ensure
            resolver.cleanup
          end
        end

        # :nodoc:
        private def install_dependencies(dir : Path) : Nil
          CrystalDependencies.install(dir, required: false)
        end

        # :nodoc:
        private def git_init(dir : Path) : Nil
          result = Process.run("git", ["init"], chdir: dir.to_s,
            output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
          if result.success?
            Log.info { "Initialized git repository" }
          else
            Log.warn { "Could not initialize git repository. Is git installed?" }
          end
        end
      end
    end
  end
end
