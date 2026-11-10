require "../../../src/app/app"
require "../../../src/features/process"

# Terminal module — multi-session process streaming.
# Uses ProcessManager with shell: true for cross-platform PATH resolution.
# The framework's SpawnOptions handles the platform shell (cmd.exe / /bin/sh).
# Command history is kept in the in-memory DevStation::Store (non-persistent).
module DevStation::Terminal
  extend self

  alias Session = {child: CrystKit::Features::ChildProcess, cwd: String, started: Time, history_id: Int64}

  @@sessions = {} of String => Session

  def setup(app : CrystKit::App, store : DevStation::Store) : Nil
    manager = CrystKit::Features::ProcessManager.new(app.security)

    # ── Spawn a streaming session ─────────────────────────────────────────
    app.on("terminal:spawn") do |payload|
      h = payload.as_h
      session_id = h["session_id"].as_s
      command = h["command"].as_s
      args = h["args"]?.try(&.as_a.map(&.as_s)) || [] of String
      raw_cwd = h["cwd"]?.try(&.as_s) || ""
      home = ENV["HOME"]? || ENV["USERPROFILE"]? || Dir.current
      cwd = (!raw_cwd.empty? && Dir.exists?(raw_cwd)) ? raw_cwd : home

      begin
        opts = CrystKit::Features::SpawnOptions.new
        opts.shell = true # framework handles cmd.exe vs /bin/sh
        opts.working_dir = cwd

        child = manager.spawn(command, args, opts)
        started = Time.utc

        full_cmd = ([command] + args).join(" ")
        hist_id = store.record_command(full_cmd)

        @@sessions[session_id] = {child: child, cwd: cwd, started: started, history_id: hist_id}

        app.emit("terminal:started", {
          "session_id" => session_id,
          "pid"        => child.pid,
          "command"    => full_cmd,
          "cwd"        => cwd,
        })

        child.on_stdout { |chunk| app.emit("terminal:stdout", {"session_id" => session_id, "data" => chunk}) }
        child.on_stderr { |chunk| app.emit("terminal:stderr", {"session_id" => session_id, "data" => chunk}) }

        child.on_exit do |code|
          ms = (Time.utc - started).total_milliseconds.to_i
          store.update_command_exit(hist_id, code.to_i64, ms.to_i64)
          app.emit("terminal:exit", {"session_id" => session_id, "exit_code" => code, "duration_ms" => ms})
          @@sessions.delete(session_id)
        end

        spawn { child.wait }
      rescue ex : CrystKit::Core::SecurityError
        app.emit("terminal:error", {"session_id" => session_id, "message" => "Permission denied: #{ex.message}"})
      rescue ex
        app.emit("terminal:error", {"session_id" => session_id, "message" => ex.message.to_s})
      end
    end

    # ── Kill a session ────────────────────────────────────────────────────
    app.on("terminal:kill") do |payload|
      session_id = payload.as_h["session_id"].as_s
      if sess = @@sessions[session_id]?
        sess[:child].kill rescue nil
        @@sessions.delete(session_id)
        app.emit("terminal:killed", {"session_id" => session_id})
      end
    end

    # ── List sessions ─────────────────────────────────────────────────────
    app.command "terminal.sessions" do
      @@sessions.map { |id, sess|
        {"session_id" => id, "pid" => sess[:child].pid,
         "cwd" => sess[:cwd], "started" => sess[:started].to_rfc3339}
      }
    end

    # ── Synchronous one-shot run ──────────────────────────────────────────
    app.async "terminal.run_sync", String, String, JSON::Any do |command, cwd, args_json, _cancel|
      args = args_json.as_a?.try(&.map(&.as_s)) || [] of String
      home = ENV["HOME"]? || ENV["USERPROFILE"]? || Dir.current
      safe_cwd = (!cwd.empty? && Dir.exists?(cwd)) ? cwd : home

      opts = CrystKit::Features::SpawnOptions.new
      opts.shell = true
      opts.working_dir = safe_cwd

      started = Time.instant
      child = manager.spawn(command, args, opts)
      code = child.wait
      ms = (Time.instant - started).total_milliseconds.to_i
      full_cmd = ([command] + args).join(" ")

      store.record_command(full_cmd, code.to_i64, ms.to_i64)

      {"stdout" => child.stdout_output, "stderr" => child.stderr_output,
       "exit_code" => code, "duration_ms" => ms}
    end

    # ── History ───────────────────────────────────────────────────────────
    app.async "terminal.history", Int32 do |limit, _cancel|
      store.history(limit)
    end

    app.async "terminal.clear_history" do
      store.clear_history
      "ok"
    end
  end
end
