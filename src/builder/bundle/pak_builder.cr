require "log"
require "file_utils"
require "virtualfs"

module CrystKit
  module Builder
    module Bundle
      class PakBuilder
        Log = ::Log.for(self)

        def self.build(dist_dir : String, out_path : String, *,
                       compress : Symbol = :deflate,
                       chunk_size : Int32 = 262_144,
                       package_id : String = "") : String?
          return nil unless Dir.exists?(dist_dir)

          Dir.mkdir_p(File.dirname(out_path))

          VirtualFs::PakFormat.build(out_path,
            package_id: package_id,
            chunk_size: chunk_size,
          ) do |b|
            b.add_dir(dist_dir)
            b.compress(compress) unless compress == :none
          end

          Log.info { "PakBuilder: wrote #{out_path} from #{dist_dir}" }
          out_path
        end
      end
    end
  end
end
