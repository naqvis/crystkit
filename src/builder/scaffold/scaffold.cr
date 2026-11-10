require "log"
require "yaml"
require "json"
require "file_utils"

module CrystKit
  module Builder
    # Project scaffolding support for `crystkit init`.
    #
    # The `Scaffold` namespace contains the embedded `Hello` template and
    # the `Resolver`, which locates external templates from the local
    # `scaffolds/` directory, an explicit path, or a remote Git URL.
    module Scaffold
      # :nodoc:
      Log = ::Log.for(self)

      # Metadata describing a discoverable scaffold template.
      record ScaffoldInfo, name : String, description : String, path : String

      # Locates and materializes scaffold templates.
      #
      # Searches, in order: the project's `scaffolds/` directory, an
      # explicit filesystem path, and a remote Git URL (HTTPS,
      # `github:`, SSH, or `file://`). ECR placeholders (`<%= name %>`,
      # `<%= identifier %>`, `<%= version %>`, `<%= author %>`) in `.ecr`
      # files are rendered during copy.
      class Resolver
        @temp_dirs = [] of String

        # Lists templates found in the local `scaffolds/` directory.
        #
        # Each subdirectory containing a `template.yml` is returned as a
        # `ScaffoldInfo`. Returns an empty array when the directory is
        # absent.
        def list_available : Array(ScaffoldInfo)
          scaffolds = [] of ScaffoldInfo
          dir = File.join(Dir.current, "scaffolds")
          return scaffolds unless Dir.exists?(dir)

          Dir.children(dir).each do |name|
            manifest_path = File.join(dir, name, "template.yml")
            next unless File.exists?(manifest_path)
            manifest = YAML.parse(File.read(manifest_path))
            desc = manifest["description"]?.try(&.as_s) || ""
            scaffolds << ScaffoldInfo.new(name, desc, File.join(dir, name))
          end
          scaffolds
        end

        # Resolves *name* to a template directory path, or returns `nil`.
        #
        # Checks `./scaffolds/<name>`, then *name* as a literal path,
        # then (for remote URLs) clones the repository and returns the
        # temp path. The caller should invoke `cleanup` afterwards.
        def resolve(name : String) : String?
          cwd_path = File.join(Dir.current, "scaffolds", name)
          return cwd_path if Dir.exists?(cwd_path)
          return name if Dir.exists?(name)
          return clone_remote(name) if remote?(name)
          nil
        end

        # Copies an external template from *source_dir* into *target_dir*,
        # rendering ECR placeholders with the given project metadata.
        #
        # `.ecr` files are rendered and stripped of the `.ecr` extension;
        # other files are copied verbatim.
        def copy_external(source_dir : String, target_dir : String, name : String, identifier : String, version : String, author : String) : Nil
          Dir.mkdir_p(target_dir)
          copy_entries(source_dir, target_dir, name, identifier, version, author)
        end

        # Removes all temp directories created by remote clones.
        #
        # Safe to call multiple times; intended for use in an `ensure`
        # block around `resolve`/`copy_external`.
        def cleanup : Nil
          @temp_dirs.each do |dir|
            FileUtils.rm_rf(dir) if Dir.exists?(dir)
          end
          @temp_dirs.clear
        end

        # :nodoc:
        private def render_ecr(template : String, name : String, identifier : String, version : String, author : String) : String
          # Detect unsupported control-flow tags (<% %>) that this
          # runtime renderer cannot evaluate. Only <%= expr %> output
          # tags are supported for external templates.
          if template =~ /<%(?!=)/
            raise "Scaffold template contains <% %> control-flow tags, which are not supported by the external template renderer. Only <%= expression %> output tags are allowed."
          end
          template.gsub(/<%=\s*(.*?)\s*%>/) do
            expression = $1? || ""
            case expression
            when "name"
              name
            when "identifier"
              identifier
            when "version"
              version
            when "author"
              author
            when "author.empty? ? \"\" : author.to_json"
              author.empty? ? "" : author.to_json
            else
              raise "Unknown ECR placeholder in scaffold template: '<%= #{expression} %>'. Supported: name, identifier, version, author"
            end
          end
        end

        # :nodoc:
        private def copy_entries(source_dir : String, target_dir : String, name : String, identifier : String, version : String, author : String) : Nil
          Dir.children(source_dir).each do |entry_name|
            next if entry_name == ".git"

            source_path = File.join(source_dir, entry_name)
            target_path = File.join(target_dir, entry_name)

            if File.directory?(source_path)
              Dir.mkdir_p(target_path)
              copy_entries(source_path, target_path, name, identifier, version, author)
            elsif entry_name.ends_with?(".ecr")
              rendered = render_ecr(File.read(source_path), name, identifier, version, author)
              File.write(target_path.sub(/\.ecr$/, ""), rendered)
            else
              Dir.mkdir_p(File.dirname(target_path))
              File.copy(source_path, target_path)
            end
          end
        end

        # :nodoc:
        private def remote?(template : String) : Bool
          template.starts_with?("https://github.com/") ||
            template.starts_with?("http://github.com/") ||
            template.starts_with?("git@github.com:") ||
            template.starts_with?("github:") ||
            template.starts_with?("file://")
        end

        # :nodoc:
        private def clone_remote(template : String) : String?
          clone_url, ref, subdir = parse_remote(template)
          dir = File.tempname("crystkit-scaffold")
          File.delete(dir) if File.exists?(dir)

          args = ["clone", "--depth", "1"]
          if ref
            args += ["--branch", ref]
          end
          args += [clone_url, dir]

          status = Process.run("git", args,
            output: Process::Redirect::Close,
            error: Process::Redirect::Close)
          return nil unless status.success?

          @temp_dirs << dir
          path = subdir ? File.join(dir, subdir) : dir
          Dir.exists?(path) ? path : nil
        end

        # :nodoc:
        private def parse_remote(template : String) : {String, String?, String?}
          ref = nil
          subdir = nil
          remote = template

          if hash_index = remote.index('#')
            fragment = remote[(hash_index + 1)..]
            remote = remote[0...hash_index]

            fragment.split('&').each do |part|
              pieces = part.split('=', 2)
              key = pieces[0]
              value = pieces[1]?
              case key
              when "ref"
                ref = value
              when "path"
                subdir = value
              else
                subdir = part unless part.empty?
              end
            end
          end

          if remote.starts_with?("github:")
            repo = remote["github:".size..]
            remote = "https://github.com/#{repo}.git"
          elsif remote.starts_with?("https://github.com/") || remote.starts_with?("http://github.com/")
            remote = "#{remote}.git" unless remote.ends_with?(".git")
          end

          {remote, ref, subdir}
        end
      end
    end
  end
end
