require "http"
require "http/server"
require "../platform/host"
require "http/web_socket"
require "log"
require "../features/file_watcher"

module CrystKit
  module Features
    # Development server that serves static files and provides hot reload
    # via WebSocket push, with a polling fallback.
    #
    # ```
    # dev = CrystKit::Features::DevServer.new("./frontend", port: 3000)
    # dev.start # blocks
    # ```
    class DevServer
      # :nodoc:
      Log = ::Log.for(self)

      # The injected live-reload script. Connects via WebSocket first;
      # falls back to polling if the WS connection fails.
      LIVE_RELOAD_JS = <<-JS
<script>
(function() {
  var wsUrl = 'ws://' + location.host + '/__crystal_ws';
  var ws = null;
  var pollTimer = null;
  var lastModified = 0;

  function reload() { location.reload(); }

  function startPolling() {
    if (pollTimer) return;
    pollTimer = setInterval(function() {
      var xhr = new XMLHttpRequest();
      xhr.open('GET', '/__crystal_ping?t=' + Date.now(), true);
      xhr.onload = function() {
        var ts = parseInt(xhr.getResponseHeader('X-CrystKit-Modified') || '0', 10);
        if (lastModified > 0 && ts > lastModified) { reload(); }
        lastModified = ts;
      };
      xhr.send();
    }, 1000);
  }

  function connectWs() {
    try {
      ws = new WebSocket(wsUrl);
      ws.onmessage = function(e) {
        try {
          var msg = JSON.parse(e.data);
          if (msg.type === 'reload') { reload(); }
          if (msg.type === 'change') { reload(); }
        } catch(_) { reload(); }
      };
      ws.onclose = function() { ws = null; startPolling(); };
      ws.onerror = function() { ws = null; startPolling(); };
    } catch(_) { startPolling(); }
  }

  connectWs();
})();
</script>
JS

      # Root directory whose files are served as static assets.
      getter root : String

      # TCP port the HTTP server listens on.
      getter port : Int32

      # Whether the server is currently listening for requests.
      getter? running : Bool

      @watcher : FileWatcher?
      @watch_channel : Channel(WatchEvent)?
      @server : HTTP::Server?
      @ws_clients : Array(HTTP::WebSocket)
      @ws_mutex : Mutex
      @last_modified : Int64
      @running_fallback : Bool

      # Creates a dev server serving *root* on *port*.
      def initialize(@root : String, @port = 3000, watch : Bool = true)
        @running = false
        @last_modified = Time.utc.to_unix_ms
        @ws_clients = [] of HTTP::WebSocket
        @ws_mutex = Mutex.new
        @running_fallback = false
        @watcher = FileWatcher.new if watch
      end

      # Start the dev server (blocks until stopped).
      #
      # Errors are logged and `running?` is reset to `false`.
      def start : Nil
        Log.info { "Starting dev server on http://localhost:#{port}" }
        Log.info { "Serving files from: #{File.expand_path(root)}" }

        # Build handler chain: WebSocket upgrade first, then static files.
        ws_handler = HTTP::WebSocketHandler.new do |ws, _|
          @ws_mutex.synchronize { @ws_clients << ws }

          ws.on_close do |_, _|
            @ws_mutex.synchronize { @ws_clients.delete(ws) }
          end
        end

        server = HTTP::Server.new([
          ws_handler,
        ]) do |context|
          handle_http(context)
        end
        @server = server

        # Start native file watcher that broadcasts changes via WS
        if watcher = @watcher
          channel = watcher.watch(@root)
          @watch_channel = channel
          Core::Fibers.spawn(name: "dev-server-watcher") do
            loop do
              event = channel.receive
              @last_modified = Time.utc.to_unix_ms
              Log.debug { "Change detected: #{event.path}" }
              broadcast_reload
            end
          rescue Channel::ClosedError
          end
        end

        # Polling fallback if native watcher is not available
        unless native_watcher_available?
          @running_fallback = true
          Core::Fibers.spawn(name: "dev-server-polling") do
            polling_loop
          end
        end

        @running = true
        server.listen("127.0.0.1", port)
      rescue ex
        Log.error { "Dev server failed: #{ex.message}" }
        @running = false
      end

      # Stops the dev server. Safe to call from a signal handler.
      def stop : Nil
        @ws_mutex.synchronize do
          @ws_clients.each(&.close)
          @ws_clients.clear
        end
        @watch_channel.try(&.close)
        @watcher.try(&.close)
        @server.try(&.close)
        @running = false
        @running_fallback = false
        Log.info { "Dev server stopped" }
      end

      # :nodoc:
      private def broadcast_reload : Nil
        msg = %({"type":"reload"})
        @ws_mutex.synchronize do
          @ws_clients.reject! do |ws|
            begin
              ws.send(msg)
              false
            rescue
              true
            end
          end
        end
      end

      # :nodoc:
      private def native_watcher_available? : Bool
        Platform::Host.native_file_watcher_available?
      end

      # :nodoc:
      private def polling_loop : Nil
        snapshot = {} of String => Time
        update_snapshot(snapshot)

        while @running_fallback && @running
          sleep(0.5.seconds)

          snapshot.keys.each do |path|
            next unless File.exists?(path)
            mtime = File.info(path).modification_time
            if mtime != snapshot[path]
              snapshot[path] = mtime
              @last_modified = Time.utc.to_unix_ms
              broadcast_reload
            end
          rescue
            snapshot.delete(path)
            @last_modified = Time.utc.to_unix_ms
            broadcast_reload
          end

          update_snapshot(snapshot)
        end
      end

      # :nodoc:
      private def update_snapshot(snapshot : Hash(String, Time)) : Nil
        Dir.glob("#{root}/**/*").each do |path|
          next unless File.file?(path)
          unless snapshot.has_key?(path)
            snapshot[path] = File.info(path).modification_time
          end
        rescue
        end
      end

      # Handle an incoming HTTP request, routing the `/__crystal_ping`
      # polling endpoint and serving all other requests as static files.
      private def handle_http(context : HTTP::Server::Context) : Nil
        request = context.request
        response = context.response

        # Polling endpoint for live-reload fallback
        if request.path == "/__crystal_ping"
          response.headers["X-CrystKit-Modified"] = @last_modified.to_s
          response.content_type = "text/plain"
          response.print(@last_modified.to_s)
          return
        end

        serve_file(context)
      end

      # Serve a static file, injecting live-reload into HTML.
      private def serve_file(context : HTTP::Server::Context) : Nil
        request = context.request
        response = context.response

        path = request.path
        path = "/index.html" if path == "/"

        file_path = File.join(root, path)

        # Security: prevent directory traversal
        unless file_path.starts_with?(File.expand_path(root))
          response.respond_with_status(403)
          return
        end

        if File.exists?(file_path) && !File.directory?(file_path)
          content = File.read(file_path)

          # Inject live-reload script into HTML
          if file_path.ends_with?(".html") && !content.includes?("__crystal_ws")
            if content.includes?("</body>")
              content = content.gsub("</body>", "#{LIVE_RELOAD_JS}\n</body>")
            elsif content.includes?("</html>")
              content = content.gsub("</html>", "#{LIVE_RELOAD_JS}\n</html>")
            end
          end

          response.content_type = mime_type_for(File.extname(file_path))
          response.print(content)
        else
          # SPA fallback: serve index.html for non-file routes
          index_path = File.join(root, "index.html")
          if File.exists?(index_path)
            content = File.read(index_path)
            unless content.includes?("__crystal_ws")
              if content.includes?("</body>")
                content = content.gsub("</body>", "#{LIVE_RELOAD_JS}\n</body>")
              elsif content.includes?("</html>")
                content = content.gsub("</html>", "#{LIVE_RELOAD_JS}\n</html>")
              end
            end
            response.content_type = "text/html"
            response.print(content)
          else
            response.respond_with_status(404, "Not found: #{path}")
          end
        end
      end

      # Simple MIME type mapping for common web asset extensions.
      MIME_TYPES = {
        ".html"  => "text/html",
        ".css"   => "text/css",
        ".js"    => "application/javascript",
        ".json"  => "application/json",
        ".png"   => "image/png",
        ".jpg"   => "image/jpeg",
        ".jpeg"  => "image/jpeg",
        ".gif"   => "image/gif",
        ".svg"   => "image/svg+xml",
        ".ico"   => "image/x-icon",
        ".woff"  => "font/woff",
        ".woff2" => "font/woff2",
        ".ttf"   => "font/ttf",
        ".txt"   => "text/plain",
        ".xml"   => "application/xml",
        ".pdf"   => "application/pdf",
        ".map"   => "application/json",
      }

      # :nodoc:
      private def mime_type_for(ext : String) : String
        MIME_TYPES[ext]? || "application/octet-stream"
      end
    end
  end
end
