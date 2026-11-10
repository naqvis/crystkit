module CrystKit::Builder::Scaffold
  # The built-in `hello` project template, embedded at compile time.
  #
  # Renders the starter project files (Crystal entry point, frontend
  # HTML, `shard.yml`, `crystkit.json`, `capabilities.json`,
  # `.gitignore`, and a tray icon) from ECR templates. The default
  # scaffold used by `crystkit init` when no external template is
  # requested.
  module Hello
    # Binary contents of the default tray icon PNG, embedded at compile
    # time.
    TRAY_ICON_DATA = {{ read_file(__DIR__ + "/hello/tray_icon.png") }}

    # Renders the Crystal entry point (`src/main.cr`) from its ECR
    # template using the given project metadata.
    def self.render_main_cr(name, identifier, version, author)
      io = IO::Memory.new
      ECR.embed({{ __DIR__ + "/hello/src/main.cr.ecr" }}, io)
      io.to_s
    end

    # Renders the frontend `index.html` from its ECR template.
    def self.render_index_html(name, identifier, version, author)
      io = IO::Memory.new
      ECR.embed({{ __DIR__ + "/hello/frontend/index.html.ecr" }}, io)
      io.to_s
    end

    # Renders the `shard.yml` dependency manifest from its ECR template.
    def self.render_shard_yml(name, identifier, version, author)
      io = IO::Memory.new
      ECR.embed({{ __DIR__ + "/hello/shard.yml.ecr" }}, io)
      io.to_s
    end

    # Renders the `crystkit.json` project config from its ECR template.
    def self.render_crystkit_json(name, identifier, version, author)
      io = IO::Memory.new
      ECR.embed({{ __DIR__ + "/hello/crystkit.json.ecr" }}, io)
      io.to_s
    end

    # Renders the `capabilities.json` security manifest from its ECR
    # template.
    def self.render_capabilities(name, identifier, version, author)
      io = IO::Memory.new
      ECR.embed({{ __DIR__ + "/hello/capabilities.json.ecr" }}, io)
      io.to_s
    end

    # Renders the `.gitignore` file from its ECR template.
    def self.render_gitignore(name, identifier, version, author)
      io = IO::Memory.new
      ECR.embed({{ __DIR__ + "/hello/.gitignore.ecr" }}, io)
      io.to_s
    end

    # A rendered scaffold file: its relative destination *path* and
    # fully rendered *content*, ready to be written to disk.
    record FileEntry, path : String, content : String

    # Returns the full set of rendered files for a new project.
    #
    # Each entry is a `FileEntry` pairing a project-relative path
    # with its rendered content. The caller is responsible for
    # writing them to the target directory.
    def self.files(name : String, identifier : String, version : String, author : String) : Array(FileEntry)
      [
        FileEntry.new("src/main.cr", render_main_cr(name, identifier, version, author)),
        FileEntry.new("frontend/index.html", render_index_html(name, identifier, version, author)),
        FileEntry.new("shard.yml", render_shard_yml(name, identifier, version, author)),
        FileEntry.new("crystkit.json", render_crystkit_json(name, identifier, version, author)),
        FileEntry.new("capabilities.json", render_capabilities(name, identifier, version, author)),
        FileEntry.new(".gitignore", render_gitignore(name, identifier, version, author)),
      ]
    end
  end
end
