require "log"
require "./asset_source"
require "../platform/icon_source"

module CrystKit
  module Features
    # Pure resolver mapping a caller's icon argument to an `IconSource`.
    #
    # Dispatch is on argument type:
    #   Path   -> VFS lookup (sync); falls back to File.read when no
    #             AssetSource is wired in (standalone controls).
    #   String -> if an AssetSource is wired in and has the file, VFS
    #             bytes; otherwise an OS theme icon name.
    #   URI    -> nil here; network URLs are fetched asynchronously by
    #             AssetFetcher, not resolved synchronously.
    module AssetResolution
      Log = ::Log.for(self)

      def self.resolve(arg : Path, source : AssetSource?) : Platform::IconSource?
        return resolve_from_vfs(arg.to_s, source) if source
        resolve_from_disk(arg.to_s)
      end

      def self.resolve(arg : String, source : AssetSource?) : Platform::IconSource?
        # The VFS is the authority: if an AssetSource is wired in and
        # it has the file, treat the string as a VFS path. Otherwise
        # it's an OS theme icon name.
        if source && source.exists?(arg)
          resolve_from_vfs(arg, source)
        else
          Platform::IconSource.name(arg)
        end
      end

      def self.resolve(arg : URI, source : AssetSource?) : Platform::IconSource?
        nil
      end

      # :nodoc:
      private def self.resolve_from_vfs(path : String, source : AssetSource?) : Platform::IconSource?
        return nil unless source && source.exists?(path)
        if bytes = source.read_bytes(path)
          Platform::IconSource.bytes(bytes, key: path)
        end
      end

      # :nodoc:
      private def self.resolve_from_disk(path : String) : Platform::IconSource?
        return nil unless File.exists?(path)
        Platform::IconSource.bytes(File.read(path).to_slice, key: path)
      rescue ex
        Log.warn { "AssetResolution: disk read failed for #{path}: #{ex.message}" }
        nil
      end
    end
  end
end
