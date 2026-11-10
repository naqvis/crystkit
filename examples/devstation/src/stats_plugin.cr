require "../../../src/app/app"
require "../../../src/plugins/base"

# StatsPlugin — tracks IPC command invocation counts by wrapping every
# handler registered through the Context. Demonstrates on_window_created
# JS injection and the full custom plugin lifecycle.
class StatsPlugin < CrystKit::Plugin::Base
  def identifier : String
    "stats"
  end

  def metadata : CrystKit::Plugin::Metadata
    CrystKit::Plugin::Metadata.new(
      identifier,
      commands: %w(stats.summary stats.command stats.reset),
      events: %w(stats:digest),
      frontend_events: %w(__stats:call__),
    )
  end

  @command_counts : Hash(String, Int32)
  @command_errors : Hash(String, Int32)
  @start_time : Time
  @store : DevStation::Store?
  @digest_stop : Channel(Nil)?
  @counts_lock : Mutex

  def initialize(@store : DevStation::Store? = nil)
    @start_time = Time.utc
    @command_counts = Hash(String, Int32).new(0)
    @command_errors = Hash(String, Int32).new(0)
    @digest_stop = nil
    @counts_lock = Mutex.new
  end

  def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
    # Hook the IPC core's invoke_command by overriding register_command_handler
    # at the App level: wrap every future handler in a counter closure.
    # We do this by listening to the "stats:track" event that we emit ourselves
    # from a JS-side hook injected via on_window_created.

    context.command "stats.summary" do
      @counts_lock.synchronize do
        uptime = (Time.utc - @start_time).total_seconds.to_i
        total = @command_counts.values.sum
        errors = @command_errors.values.sum
        top10 = @command_counts
          .to_a
          .sort_by { |_, v| -v }
          .first(10)
          .map { |cmd, count|
            {"command" => cmd, "calls" => count, "errors" => @command_errors[cmd]? || 0}
          }
        {
          "uptime_seconds"  => uptime,
          "total_calls"     => total,
          "total_errors"    => errors,
          "top_commands"    => top10,
          "unique_commands" => @command_counts.size,
        }
      end
    end

    context.command "stats.command", String do |cmd|
      @counts_lock.synchronize do
        {
          "command" => cmd,
          "calls"   => @command_counts[cmd]? || 0,
          "errors"  => @command_errors[cmd]? || 0,
        }
      end
    end

    context.command "stats.reset" do
      @counts_lock.synchronize do
        @command_counts.clear
        @command_errors.clear
        @start_time = Time.utc
      end
      "ok"
    end

    # Receive tracking pings from the JS-side wrapper injected by on_window_created
    context.listen("__stats:call__") do |payload|
      if h = payload.as_h?
        cmd = h["cmd"]?.try(&.as_s) || "unknown"
        ok = h["ok"]?.try(&.as_bool) != false
        @counts_lock.synchronize do
          @command_counts[cmd] += 1
          @command_errors[cmd] += 1 unless ok
        end
      end
    end

    # Digest broadcast every 15 s
    stop = Channel(Nil).new
    @digest_stop = stop
    spawn(name: "stats-digest") do
      stopped = false
      until context.app.running?
        if stopped?(stop, 100.milliseconds)
          stopped = true
          break
        end
      end
      next if stopped
      loop do
        break if stopped?(stop, 15.seconds)
        begin
          total, unique, uptime = @counts_lock.synchronize do
            {
              @command_counts.values.sum,
              @command_counts.size,
              (Time.utc - @start_time).total_seconds.to_i,
            }
          end
          context.emit("stats:digest", context.app.coerce_to_json({
            "total_calls"     => total,
            "unique_commands" => unique,
            "uptime_seconds"  => uptime,
          }))
        rescue
        end
      end
    end
  end

  # Inject a thin wrapper around ipc.invoke that emits __stats:call__ for
  # every invocation. This fires on the frontend — the event travels back
  # over the bus and is counted above.
  def on_window_created(window : CrystKit::Core::Window) : Nil
    window.init(<<-JS)
      (function() {
        if (!window.__CRYSTKIT_IPC__) return;
        const _orig = window.__CRYSTKIT_IPC__.invoke.bind(window.__CRYSTKIT_IPC__);
        window.__CRYSTKIT_IPC__.invoke = function(cmd) {
          const p = _orig.apply(this, arguments);
          p.then(function() {
            window.__CRYSTKIT_IPC__.emit('__stats:call__', { cmd: cmd, ok: true });
          }).catch(function() {
            window.__CRYSTKIT_IPC__.emit('__stats:call__', { cmd: cmd, ok: false });
          });
          return p;
        };
      })();
    JS
  end

  def cleanup_plugin : Nil
    @digest_stop.try(&.close)
    @digest_stop = nil
    unique, total, uptime = @counts_lock.synchronize do
      {
        @command_counts.size,
        @command_counts.values.sum,
        (Time.utc - @start_time).total_seconds.to_i,
      }
    end
    Log.info { "stats: #{unique} commands, #{total} total calls in #{uptime}s uptime" }
  rescue
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
