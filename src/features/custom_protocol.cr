require "log"
require "uri"
require "file_utils"
require "http/headers"
require "./mime_types"
require "./asset_source"
require "../platform/backends/custom_protocol_backend"

module CrystKit::Features
  struct ProtocolOptions
    property scheme : String
    property? serve_assets : Bool = false
    property asset_root : Path?
    property resolver : Proc(String, HTTP::Headers, String?)?
    property asset_source : AssetSource?

    def initialize(
      @scheme = "app",
      @serve_assets = false,
      @asset_root = nil,
      @resolver : Proc(String, HTTP::Headers, String?)? = nil,
      @asset_source : AssetSource? = nil,
    )
    end
  end

  class CustomProtocol
    Log = ::Log.for(self)

    getter options : ProtocolOptions
    @registered : Bool = false

    def initialize(
      @options : ProtocolOptions,
      @backend : Platform::CustomProtocolBackend = Platform::CurrentCustomProtocolBackend.new,
    )
    end

    def setup : Nil
      ::CrystKit::Core::MainThread.dispatch_sync {
        @backend.setup(@options.scheme, build_resolver)
      }
    end

    def register(wv : T) : Nil forall T
      ::CrystKit::Core::MainThread.dispatch_sync {
        @backend.register(wv, @options.scheme, build_resolver)
      }
      @registered = true
      Log.info { "Registered custom protocol: #{@options.scheme}://" }
    end

    def resolve(uri : URI) : {Bytes, String}?
      path = uri.path || "/"
      path = "/index.html" if path == "/" || path.empty?
      resolve_path(path)
    end

    private def resolve_path(path : String) : {Bytes, String}?
      if custom_resolver = @options.resolver
        headers = HTTP::Headers.new
        if body = custom_resolver.call(path, headers)
          mime = MimeTypes.for_extension(File.extname(path))
          return {body.to_slice, mime}
        end
      end

      if asset_source = @options.asset_source
        if result = asset_source.fetch(path)
          return result
        end
      end

      if @options.serve_assets? && (asset_root = @options.asset_root)
        file_path = asset_root / path.lchop('/')
        if File.exists?(file_path)
          bytes = File.read(file_path).to_slice
          mime = MimeTypes.for_extension(File.extname(path))
          return {bytes, mime}
        end
      end

      nil
    end

    private def build_resolver : Proc(String, {Bytes, String}?)
      ->(url : String) : {Bytes, String}? {
        uri = URI.parse(url)
        path = uri.path || "/"
        path = "/index.html" if path == "/" || path.empty?
        resolve_path(path)
      }
    end
  end
end
