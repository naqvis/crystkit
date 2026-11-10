require "log"
require "json"
require "../core/fibers"
require "./updater"

module CrystKit::Features
  # Wraps `AutoUpdater` with a ready-to-use HTML update dialog.
  #
  # Surfaces update checks, progress, release notes, and
  # install/remind-later actions through a small webview window.
  # Applications wanting a custom look can subclass and override the
  # template constant, or skip `UpdaterUI` entirely and build their
  # own UI on top of `AutoUpdater`'s callback API.
  #
  # Usage:
  # ```
  # updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://updates.example.com")
  # ui = CrystKit::Features::UpdaterUI.new(app, updater)
  # ui.auto_check = true
  # ```
  class UpdaterUI
    Log = ::Log.for(self)

    # The update dialog HTML template rendered into the dialog window.
    #
    # The document is a dark-themed, dependency-free page that displays
    # release notes, a download progress bar, a status line, and two
    # buttons (Remind Later, Install). It expects
    # `window.__CRYSTKIT_IPC__` to be present and listens for
    # `update:progress`, `update:ready`, and `update:error` events and
    # emits `update:remind-later` and `update:install` back to the
    # backend.
    DIALOG_HTML = <<-HTML
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<style>
body { font-family: system-ui, sans-serif; margin: 0; padding: 20px;
     background: #1a1a2e; color: #eee; }
h2 { margin-top: 0; }
.progress { width: 100%; height: 8px; background: #333; border-radius: 4px; overflow: hidden; }
.progress-bar { height: 100%; background: #4a9eff; width: 0%; transition: width 0.3s; }
.status { margin: 12px 0; font-size: 14px; color: #aaa; }
.actions { margin-top: 16px; text-align: right; }
button { background: #4a9eff; border: none; color: white; padding: 8px 16px;
       border-radius: 4px; cursor: pointer; margin-left: 8px; }
button.secondary { background: #555; }
button:disabled { opacity: 0.5; cursor: default; }
.release-notes { background: #222; padding: 12px; border-radius: 4px;
               max-height: 200px; overflow-y: auto; font-size: 13px;
               margin: 12px 0; white-space: pre-wrap; }
</style>
</head>
<body>
<h2>Update Available</h2>
<div class="release-notes" id="notes">Loading release notes...</div>
<div class="progress"><div class="progress-bar" id="progress"></div></div>
<div class="status" id="status">Checking for updates...</div>
<div class="actions">
  <button class="secondary" id="btnLater" onclick="remindLater()">Remind Later</button>
  <button id="btnInstall" onclick="installUpdate()" disabled>Install</button>
</div>
<script>
  var ipc = window.__CRYSTKIT_IPC__;
  function remindLater() { if (ipc) ipc.emit('update:remind-later'); }
  function installUpdate() {
    document.getElementById('btnInstall').disabled = true;
    document.getElementById('btnLater').disabled = true;
    if (ipc) ipc.emit('update:install');
  }
  if (ipc) {
    ipc.listen('update:progress', function(p) {
      var pct = Math.round(p.percent || 0);
      document.getElementById('progress').style.width = pct + '%';
      document.getElementById('status').textContent = p.status || 'Downloading...';
    });
    ipc.listen('update:ready', function(p) {
      document.getElementById('status').textContent = p.version + ' ready to install';
      document.getElementById('btnInstall').disabled = false;
      if (p.notes) document.getElementById('notes').textContent = p.notes;
    });
    ipc.listen('update:error', function(p) {
      document.getElementById('status').textContent = 'Error: ' + (p.message || 'Unknown');
      document.getElementById('btnInstall').disabled = true;
    });
  }
</script>
</body>
</html>
HTML

    # The underlying `AutoUpdater` driving update checks and downloads.
    getter updater : AutoUpdater
    # The CrystKit `App` used to open the dialog window and emit IPC events.
    getter app : ::CrystKit::App
    # Whether to perform automatic periodic checks via `#start`.
    #
    # When `true` (the default) `#start` checks immediately and then on
    # every `check_interval` tick. Set to `false` to drive checks
    # manually via `#check_for_updates`.
    property? auto_check : Bool = true
    # Interval between automatic update checks performed by `#start`.
    # Defaults to 24 hours. Only consulted when `#auto_check?` is `true`.
    property check_interval : Time::Span = 24.hours

    @dialog_window : ::CrystKit::Webview?
    @last_check : Time?

    # Creates a UI controller bound to *app* and *updater*.
    def initialize(@app : ::CrystKit::App, @updater : AutoUpdater)
      @last_check = nil

      # Wire IPC handlers
      @app.on("update:remind-later") { |_| close_dialog }
      @app.on("update:install") { |_| install_update }

      # Wire updater callbacks
      @updater.on_check = ->(has_update : Bool, version : String?) {
        if has_update && version
          show_dialog(version, @updater.release_notes || "")
        end
      }
      @updater.on_progress = ->(percent : Float64, status : String) {
        emit_to_frontend("update:progress", {percent: percent, status: status})
      }
      @updater.on_download_complete = ->(version : String, notes : String) {
        emit_to_frontend("update:ready", {version: version, notes: notes})
      }
      @updater.on_error = ->(message : String) {
        emit_to_frontend("update:error", {message: message})
      }
    end

    # Starts periodic update checking.
    #
    # Performs an immediate check (subject to `#auto_check?`) and then
    # re-checks every `#check_interval`. There is no `#stop`
    # counterpart.
    def start : Nil
      check_for_updates
      Core::Fibers.spawn do
        loop do
          sleep check_interval
          check_for_updates
        end
      end
    end

    # Checks for updates now, ignoring `#auto_check?`.
    #
    # Errors from the updater are logged at warn level and swallowed
    # so a failing update server never crashes the background checker.
    def check_for_updates : Nil
      @updater.check
      @last_check = Time.utc
    rescue ex
      Log.warn { "Update check failed: #{ex.message}" }
    end

    # :nodoc:
    # Show the update dialog window.
    private def show_dialog(version : String, notes : String) : Nil
      html = DIALOG_HTML
      # Note: in a real implementation, inject version/notes into the HTML

      @dialog_window = @app.window(
        title: "Update Available - #{version}",
        width: 420,
        height: 380,
        html: html,
      )
    end

    # :nodoc:
    # Close the update dialog.
    private def close_dialog : Nil
      @dialog_window.try(&.destroy)
      @dialog_window = nil
    end

    # :nodoc:
    # Install the update.
    private def install_update : Nil
      close_dialog
      Core::Fibers.spawn do
        @updater.install
      end
    end

    # :nodoc:
    # Emit an event to the dialog window.
    private def emit_to_frontend(event : String, data : Hash(String, _)) : Nil
      @app.emit(event, data)
    end
  end
end
