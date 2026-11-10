module CrystKit
  module Platform
    # Immutable asset reference passed to native backends in place of a
    # file-path string. Exactly one of `bytes`/`name` is set.
    #
    # `bytes` is populated for VFS-path and network-URL resolutions; `key`
    # carries the original VFS path or URL so the Linux temp-file cache
    # (which needs a stable filename) can reuse one file across repeated
    # `update_icon` calls. `name` is populated for OS theme-icon names and
    # is resolved by each platform backend to SF Symbol / `IDI_*` /
    # icon-theme name.
    struct IconSource
      getter bytes : Bytes?
      getter name : String?
      getter key : String?

      def self.bytes(b : Bytes, key : String? = nil) : IconSource
        new(bytes: b, name: nil, key: key)
      end

      def self.name(n : String) : IconSource
        new(bytes: nil, name: n, key: nil)
      end

      def bytes? : Bool
        !@bytes.nil?
      end

      def name? : Bool
        !@name.nil?
      end

      # There is no `path` variant; this always returns false. Exists so
      # callers can pattern-match exhaustively across all possible
      # IconSource shapes without hitting `undefined method 'path?'`.
      def path? : Bool
        false
      end

      private def initialize(@bytes : Bytes?, @name : String?, @key : String?)
      end
    end
  end
end
