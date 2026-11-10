require "../../../src/app/app"
require "../../../src/features/system_info"

# Background fibers: periodic emitters that stream data to the frontend.
module Showcase
  module Background
    extend self

    def start(app : CrystKit::App) : Nil
      info = CrystKit::Features::SystemInfo.new

      # Live clock — every second
      spawn do
        # Wait until app is running before emitting events
        until app.running?
          sleep 100.milliseconds
        end
        loop do
          app.emit("clock:tick", {"now" => Time.utc.to_s})
          sleep 1.second
        end
      end

      # System stats — every 5 seconds
      spawn do
        # Wait until app is running before emitting events
        until app.running?
          sleep 100.milliseconds
        end
        loop do
          mem = info.memory_info
          app.emit("stats:tick", {
            "memory" => {
              "total"     => mem.total,
              "available" => mem.available,
              "used_pct"  => mem.total > 0 ? ((mem.total - mem.available) * 100 / mem.total).to_i : 0,
            },
          })
          sleep 5.seconds
        end
      end
    end
  end
end
