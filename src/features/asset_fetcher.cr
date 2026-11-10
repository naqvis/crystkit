require "log"
require "uri"
require "./http"
require "../platform/icon_source"
require "../core/main_thread"

module CrystKit
  module Features
    # Async HTTP fetcher for network-icon assets, with a bounded LRU cache.
    #
    # The cache is keyed by URL string; repeated `fetch_async` calls with
    # the same URL skip the network. Cache is process-lifetime and cleared
    # on `#clear` (called by `App#shutdown`).
    #
    # `fetch_async` returns immediately and invokes *on_ready* on the
    # webview's main thread (via `Core::MainThread.dispatch`) when bytes
    # arrive — the UI thread never blocks on a network call. Cache hits
    # invoke *on_ready* synchronously on the calling thread (no fiber
    # spawned) since the bytes are already in hand.
    class AssetFetcher
      Log = ::Log.for(self)

      @cache : Hash(String, Bytes)
      @order : Array(String)
      @mutex : Mutex
      @http_client : ::CrystKit::Features::HTTPClient?
      @http_client_factory : Proc(::CrystKit::Features::HTTPClient)

      # *http_client_factory* is called lazily on the first network fetch
      # to create an `HTTPClient`. This avoids holding a client (and its
      # security context / mutex) alive for the entire app lifetime when
      # no network icons are ever requested.
      def initialize(@http_client_factory : Proc(::CrystKit::Features::HTTPClient),
                     @cache_max : Int32 = 32)
        @cache = {} of String => Bytes
        @order = [] of String
        @mutex = Mutex.new
        @http_client = nil
      end

      # Fetch *url* on a fiber. *on_ready* is invoked with an
      # `IconSource.bytes` (key = url.to_s) on the main thread when the
      # bytes land, or *on_error* on failure. Cache hits invoke *on_ready*
      # synchronously on the calling thread (no fiber spawned).
      def fetch_async(url : URI,
                      on_ready : Proc(Platform::IconSource, Nil),
                      on_error : Proc(Exception, Nil)? = nil,
                      timeout : Time::Span = 10.seconds) : Nil
        key = url.to_s
        if cached = cache_lookup(key)
          on_ready.call(Platform::IconSource.bytes(cached, key: key))
          return
        end

        spawn do
          begin
            client = @http_client ||= @http_client_factory.call
            bytes = client.get_bytes(url.to_s, timeout: timeout)
            cache_store(key, bytes)
            icon = Platform::IconSource.bytes(bytes, key: key)
            ::CrystKit::Core::MainThread.dispatch { on_ready.call(icon) }
          rescue ex
            Log.warn { "AssetFetcher: fetch failed for #{url}: #{ex.message}" }
            on_error.try { |cb| ::CrystKit::Core::MainThread.dispatch { cb.call(ex) } }
          end
        end
      end

      # Clear the cache. Safe to call from any thread.
      def clear : Nil
        @mutex.synchronize do
          @cache.clear
          @order.clear
        end
      end

      private def cache_lookup(key : String) : Bytes?
        @mutex.synchronize { @cache[key]? }
      end

      private def cache_store(key : String, bytes : Bytes) : Nil
        @mutex.synchronize do
          if @cache.has_key?(key)
            @order.delete(key)
          elsif @cache.size >= @cache_max
            evicted = @order.shift?
            @cache.delete(evicted) if evicted
          end
          @cache[key] = bytes
          @order << key
        end
      end
    end
  end
end
