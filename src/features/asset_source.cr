require "log"
require "mime"
require "./mime_types"
require "virtualfs"

module CrystKit
  module Features
    abstract class AssetSource
      abstract def fetch(path : String) : {Bytes, String}?

      abstract def exists?(path : String) : Bool

      # Raw bytes for an asset at *path*, or nil if not found.
      #
      # Unlike `#fetch`, this performs an exact-path lookup with **no SPA
      # fallback** — extensionless paths do NOT resolve to `index.html`.
      # Intended for asset lookups (icons, fonts) where silent fallback
      # would mask a missing file.
      # Default returns nil; subclasses with a real backing store override.
      def read_bytes(path : String) : Bytes?
        nil
      end

      # Size in bytes of the asset at *path*, or nil if unknown / missing.
      #
      # Unlike `#fetch`, this performs an exact-path lookup with **no SPA
      # fallback** — extensionless paths do NOT resolve to `index.html`.
      # Default returns nil; subclasses with a real backing store override.
      def size(path : String) : Int64?
        nil
      end
    end

    class VfsAssetSource < AssetSource
      Log = ::Log.for(self)

      getter vfs : VirtualFs::Vfs

      @spa_fallback : Bool

      def initialize(@vfs : VirtualFs::Vfs, @spa_fallback : Bool = true)
      end

      def fetch(path : String) : {Bytes, String}?
        vpath = normalize(path)
        return read_with_mime(vpath) if @vfs.exists?(vpath)

        if @spa_fallback && spa_candidate?(vpath)
          idx = "index.html"
          return read_with_mime(idx) if @vfs.exists?(idx)
        end

        nil
      end

      def exists?(path : String) : Bool
        @vfs.exists?(normalize(path))
      end

      # Exact-path only: intentionally skips the SPA `index.html` fallback.
      def read_bytes(path : String) : Bytes?
        vpath = normalize(path)
        return nil unless @vfs.exists?(vpath)
        @vfs.read(vpath).to_slice
      rescue ex : VirtualFs::Error
        Log.debug { "VfsAssetSource#read_bytes: #{path}: #{ex.message}" }
        nil
      end

      # Exact-path only: intentionally skips the SPA `index.html` fallback.
      def size(path : String) : Int64?
        vpath = normalize(path)
        return nil unless @vfs.exists?(vpath)
        @vfs.size(vpath)
      rescue ex : VirtualFs::Error
        Log.debug { "VfsAssetSource#size: #{path}: #{ex.message}" }
        nil
      end

      private def normalize(path : String) : String
        path = path.lchop('/')
        path = "index.html" if path.empty?
        path
      end

      private def spa_candidate?(path : String) : Bool
        File.extname(path).empty?
      end

      private def read_with_mime(path : String) : {Bytes, String}?
        data = @vfs.read(path)
        mime = mime_for(path)
        {data.to_slice, mime}
      rescue ex : VirtualFs::Error
        Log.debug { "VfsAssetSource: read failed for #{path}: #{ex.message}" }
        nil
      end

      private def mime_for(path : String) : String
        stat = @vfs.stat(path)
        if stored = stat.mime
          return stored
        end
        MimeTypes.for_extension(File.extname(path))
      end
    end
  end
end
