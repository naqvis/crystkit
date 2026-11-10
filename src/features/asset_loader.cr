require "log"
require "file_utils"
require "./asset_source"
require "virtualfs"

module CrystKit
  module Features
    class AssetLoader
      Log = ::Log.for(self)

      def self.load(*, frontend_dir : String? = nil, package_name : String? = nil) : VfsAssetSource?
        pak_path = resolve_pak_path(package_name)

        vfs = VirtualFs::Vfs.new

        if pak_path && File.exists?(pak_path)
          Log.info { "AssetLoader: mounting #{pak_path}" }
          vfs.mount(VirtualFs::Pak.new(pak_path), "/", priority: 0)
          mount_overlay(vfs, pak_path)
          return VfsAssetSource.new(vfs)
        end

        dev_dir = frontend_dir || ENV["CRYSTKIT_FRONTEND_DIR"]?
        if dev_dir && Dir.exists?(dev_dir)
          Log.info { "AssetLoader: no pak found, mounting OsDir #{dev_dir}" }
          vfs.mount(dev_dir, "/", priority: 0)
          return VfsAssetSource.new(vfs)
        end

        Log.warn { "AssetLoader: no assets.vpak and no frontend dir found" }
        nil
      end

      private def self.resolve_pak_path(package_name : String?) : String?
        if env = ENV["CRYSTKIT_ASSETS_PAK"]?
          return env unless env.empty?
        end

        exe_dir = current_exe_dir

        candidates = [
          File.join(exe_dir, "assets.vpak"),
          File.join(exe_dir, "resources", "assets.vpak"),
        ]

        {% if flag?(:darwin) %}
          candidates << File.join(exe_dir, "..", "Resources", "assets.vpak")
        {% end %}

        {% if flag?(:linux) %}
          if pkg = package_name
            candidates << File.join(exe_dir, "..", "share", pkg, "assets.vpak")
          end
        {% end %}

        candidates.each do |c|
          expanded = File.expand_path(c)
          return expanded if File.exists?(expanded)
        end

        nil
      end

      private def self.mount_overlay(vfs : VirtualFs::Vfs, pak_path : String) : Nil
        patch_path = File.join(File.dirname(pak_path), "assets.patch.vpak")
        return unless File.exists?(patch_path)
        Log.info { "AssetLoader: mounting overlay #{patch_path}" }
        vfs.mount(VirtualFs::Pak.new(patch_path), "/", priority: 10)
      end

      private def self.current_exe_dir : String
        path = Process.executable_path || Dir.current
        File.dirname(File.expand_path(path))
      end
    end
  end
end
