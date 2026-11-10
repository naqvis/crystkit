require "log"
require "../../features/icon_manager"

module CrystKit
  module Builder
    module Commands
      # Implements `crystkit icon` — copies a source icon into an output
      # directory.
      #
      # Stages a source image (`.png`, `.ico`, or `.icns`) into an output
      # directory using the source's native format. Does not perform raster
      # resizing or format conversion; richer icon generation is handled
      # by the platform bundlers at packaging time.
      class Icon
        # :nodoc:
        Log = ::Log.for(self)

        # Creates an icon command.
        def initialize(
          @source : String,
          @output_dir : String = ".",
          @targets : Array(String) = ["png"],
          @size : Int32 = 128,
        )
        end

        # Runs the icon command, copying the source into the output directory.
        #
        # Raises if the source file does not exist. The destination file is
        # named `icon.<ext>` based on the source's detected MIME type.
        def run
          src = Path[@source]
          unless File.exists?(src.to_s)
            raise "Source icon not found: #{src}"
          end

          output = Path[@output_dir]
          Dir.mkdir_p(output.to_s)

          mime_type = case src.expand.extension.downcase
                      when ".ico"  then "ico"
                      when ".icns" then "icns"
                      else              "png"
                      end

          if @targets.includes?(mime_type) || @targets.includes?("png")
            dest = output / "icon.#{mime_type}"
            src_expanded = File.expand_path(src.to_s)
            dest_expanded = File.expand_path(dest.to_s)
            File.copy(src.to_s, dest.to_s) unless src_expanded == dest_expanded
            Log.info { "  #{dest}" }
          end
        end
      end
    end
  end
end
