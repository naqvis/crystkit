require "log"
require "json-schema"
require "../config"
require "../../security/manifest"

module CrystKit::Builder::Commands
  # Implements `crystkit schema` — emits JSON Schema documents for
  # CrystKit's configuration files.
  #
  # Wraps the schemas generated from the `JSON::Serializable` struct
  # definitions (`Builder::Config` and `Security::Manifest`) with Draft
  # 7 metadata (`$schema`, `title`, `description`).
  class Schema
    # :nodoc:
    Log = ::Log.for(self)

    # Default location for schema files when no `--output` is given,
    # resolved relative to the repository root.
    SCHEMA_DIR = Path[__DIR__].parent.parent.parent / "schemas"

    # Directory to write schema files to, or `nil` when printing to stdout.
    getter output_dir : String?
    # Schema type to print (`crystkit` or `capabilities`), or `nil` to
    # write all schemas to disk.
    getter type : String?

    # Creates a schema command.
    def initialize(@output_dir = nil, @type = nil)
    end

    # Runs the schema command.
    #
    # With `type == "crystkit"` or `"capabilities"`, prints that schema
    # to stdout. With no type, writes both schemas to the output
    # directory. Unknown types produce a stderr message.
    def run : Nil
      case type
      when "crystkit"
        puts wrap_schema("CrystKit Configuration", Builder::Config.json_schema).to_pretty_json
      when "capabilities"
        puts wrap_schema("CrystKit Capabilities Manifest", Security::Manifest.json_schema).to_pretty_json
      when nil
        write_all(output_dir || SCHEMA_DIR.to_s)
      else
        STDERR.puts "Unknown schema type '#{type}'. Use: crystkit, capabilities"
        exit 1
      end
    end

    # :nodoc:
    private def write_all(dir : String) : Nil
      path = Path[dir]
      Dir.mkdir_p(path.to_s)

      File.write((path / "crystkit.schema.json").to_s, wrap_schema("CrystKit Configuration", Builder::Config.json_schema).to_pretty_json)
      File.write((path / "capabilities.schema.json").to_s, wrap_schema("CrystKit Capabilities Manifest", Security::Manifest.json_schema).to_pretty_json)

      Log.info { "JSON schemas written to #{dir}" }
    end

    # :nodoc:
    private def wrap_schema(title : String, properties) : Hash(String, JSON::Any)
      parsed = JSON.parse(properties.to_json)
      schema = {
        "$schema"     => JSON::Any.new("http://json-schema.org/draft-07/schema#"),
        "title"       => JSON::Any.new(title),
        "description" => JSON::Any.new("Auto-generated from Crystal struct definitions. Do not edit manually."),
        "type"        => parsed["type"]? || JSON::Any.new("object"),
        "properties"  => parsed["properties"]? || JSON::Any.new({} of String => JSON::Any),
      }

      if required = parsed["required"]?
        schema["required"] = required
      end
      if additional = parsed["additionalProperties"]?
        schema["additionalProperties"] = additional
      end
      if items = parsed["items"]?
        schema["items"] = items
      end

      schema
    end
  end
end
