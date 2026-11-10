require "../../../../src/app/app"
require "../../../../src/plugins/builtins/http"

# Demonstrates the HTTP plugin and adds higher-level "sync" commands that
# wrap raw HTTP for the frontend. Showcases:
#
#   - Talking to a real REST endpoint (jsonplaceholder.typicode.com)
#   - Error handling: NetworkError → JS Promise rejection
#   - Long-running tasks emitting progress events
module Showcase
  module Commands
    module Sync
      extend self

      def setup(app : CrystKit::App) : Nil
        app.async "sync.fetch_todos", timeout: 20.seconds do
          http = app.find_plugin(CrystKit::Plugins::HTTP).client
          response = http.get("https://jsonplaceholder.typicode.com/todos?_limit=10")
          {
            "status" => response.status,
            "todos"  => JSON.parse(response.text),
          }
        end

        # Long-running with progress events.
        app.command "sync.bulk_fetch", Int32 do |count|
          http = app.find_plugin(CrystKit::Plugins::HTTP).client
          spawn do
            count.times do |i|
              response = http.get("https://jsonplaceholder.typicode.com/todos/#{i + 1}")
              app.emit("sync:progress", {
                "current" => i + 1,
                "total"   => count,
                "todo"    => JSON.parse(response.text),
              })
            end
            app.emit("sync:done", {"count" => count})
          end
          "started"
        end
      end
    end
  end
end
