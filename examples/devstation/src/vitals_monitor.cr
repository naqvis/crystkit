require "../../../src/app/app"
require "../../../src/features/system_info"
require "../../../src/features/power_monitor"
require "../../../src/features/idle_monitor"
require "../../../src/features/cpu_monitor"

module DevStation::VitalsMonitor
  extend self

  HISTORY_SIZE = 120

  # Backend-owned reactive state. The frontend subscribes via
  # `ipc.state("vitals")` and receives JSON Patch diffs on every update —
  # no `vitals:tick` event, no `vitals.snapshot` / `vitals.history`
  # commands, no frontend glue combining the three.
  class VitalsState
    include JSON::Serializable

    property timestamp : Int64
    property cpu : CpuState
    property memory : MemState
    property disk : DiskState
    property battery : BattState
    property idle_seconds : Int64
    property cpu_history : Array(Float64)
    property mem_history : Array(Float64)

    def initialize(
      @timestamp : Int64 = 0_i64,
      @cpu : CpuState = CpuState.new,
      @memory : MemState = MemState.new,
      @disk : DiskState = DiskState.new,
      @battery : BattState = BattState.new,
      @idle_seconds : Int64 = 0_i64,
      @cpu_history : Array(Float64) = [] of Float64,
      @mem_history : Array(Float64) = [] of Float64,
    )
    end
  end

  class CpuState
    include JSON::Serializable

    def initialize(@cores : Int32 = 0, @model : String = "", @usage_pct : Float64 = 0.0, @frequency : Float64 = 0.0)
    end

    property cores : Int32 = 0
    property model : String = ""
    property usage_pct : Float64 = 0.0
    property frequency : Float64 = 0.0
  end

  class MemState
    include JSON::Serializable

    def initialize(@total : Int64 = 0_i64, @used : Int64 = 0_i64, @free : Int64 = 0_i64, @used_pct : Float64 = 0.0)
    end

    property total : Int64 = 0_i64
    property used : Int64 = 0_i64
    property free : Int64 = 0_i64
    property used_pct : Float64 = 0.0
  end

  class DiskState
    include JSON::Serializable

    def initialize(@total : Int64 = 0_i64, @used : Int64 = 0_i64, @free : Int64 = 0_i64, @used_pct : Float64 = 0.0)
    end

    property total : Int64 = 0_i64
    property used : Int64 = 0_i64
    property free : Int64 = 0_i64
    property used_pct : Float64 = 0.0
  end

  class BattState
    include JSON::Serializable

    def initialize(@present : Bool = false, @level : Int32 = 0, @charging : Bool = false)
    end

    property present : Bool = false
    property level : Int32 = 0
    property charging : Bool = false
  end

  def setup(app : CrystKit::App, store : DevStation::Store, on_tick : Proc(VitalsState, Nil)? = nil) : Nil
    info = CrystKit::Features::SystemInfo.new
    power = CrystKit::Features::PowerMonitor.new
    idle = CrystKit::Features::IdleMonitor.new
    cpu_tick = CrystKit::Features::CpuMonitor.new

    # Static info is one-shot data that never changes — stays as a command.
    app.async "vitals.static" do
      cpu_info = info.cpu_info
      os = info.os_info
      dirs = info.app_data_directories
      locale = info.locale_info
      appi = info.app_info
      {
        "os"       => {"name" => os.name, "version" => os.version},
        "arch"     => info.architecture.to_s,
        "hostname" => info.hostname,
        "cpu"      => {
          "model"     => cpu_info.model,
          "cores"     => cpu_info.cores,
          "threads"   => cpu_info.cores * 2,
          "frequency" => cpu_info.frequency_ghz,
        },
        "locale"      => locale.name,
        "language"    => locale.language,
        "home_dir"    => info.home_directory,
        "data_dir"    => dirs.data,
        "config_dir"  => dirs.config,
        "cache_dir"   => dirs.cache,
        "app_version" => appi.version,
        "displays"    => info.display_info.map { |d|
          {"id" => d.id, "width" => d.width, "height" => d.height,
           "scale" => d.scale_factor, "primary" => d.primary?}
        },
        "network" => info.network_interfaces.map { |n|
          {"name" => n.name, "ip" => n.address, "mac" => n.mac_address}
        },
      }
    end

    # Live vitals as a reactive state slice. The backend owns the state;
    # the frontend subscribes and gets JSON Patch diffs every tick.
    vitals = app.state("vitals", VitalsState) { VitalsState.new }
    stop = Channel(Nil).new
    app.on_shutdown { stop.close }

    spawn(name: "vitals-monitor") do
      stopped = false
      until app.running?
        if stopped?(stop, 100.milliseconds)
          stopped = true
          break
        end
      end
      next if stopped
      next if stopped?(stop, 2.seconds)
      loop do
        begin
          mem = info.memory_info
          disk = info.disk_info("/")
          batt = power.battery_info

          mem_total = mem.total.to_f64
          mem_used = mem.used.to_f64
          mem_pct = mem_total > 0 ? ((mem_used / mem_total) * 100.0).round(1) : 0.0

          disk_total = disk.total.to_f64
          disk_used = disk.used.to_f64
          disk_pct = disk_total > 0 ? ((disk_used / disk_total) * 100.0).round(1) : 0.0

          cpu_pct = cpu_tick.usage_pct
          cpu_info = info.cpu_info

          batt_level = batt ? (batt.level * 100.0).round(0).to_i : 0
          batt_charging = batt ? batt.charging? : false
          batt_present = !batt.nil?

          # Single update block — CrystKit computes the diff and pushes
          # only the changed fields to the frontend.
          vitals.update do |s|
            s.timestamp = Time.utc.to_unix_ms
            s.cpu.cores = cpu_info.cores
            s.cpu.model = cpu_info.model
            s.cpu.usage_pct = cpu_pct
            s.cpu.frequency = cpu_info.frequency_ghz
            s.memory.total = mem.total
            s.memory.used = mem.used
            s.memory.free = mem.available
            s.memory.used_pct = mem_pct
            s.disk.total = disk.total
            s.disk.used = disk.used
            s.disk.free = disk.available
            s.disk.used_pct = disk_pct
            s.battery.present = batt_present
            s.battery.level = batt_level
            s.battery.charging = batt_charging
            s.idle_seconds = idle.idle_seconds.to_i64

            s.cpu_history << cpu_pct
            s.cpu_history.shift if s.cpu_history.size > HISTORY_SIZE
            s.mem_history << mem_pct
            s.mem_history.shift if s.mem_history.size > HISTORY_SIZE
            s
          end
          on_tick.try(&.call(vitals.value))
        rescue ex
          Log.warn { "vitals tick error: #{ex.message}" }
        end
        break if stopped?(stop, 2.seconds)
      end
    end
  end

  private def stopped?(stop : Channel(Nil), delay : Time::Span) : Bool
    select
    when stop.receive?
      true
    when timeout(delay)
      false
    end
  end
end
