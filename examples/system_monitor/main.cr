require "../../src/app/app"
require "../../src/plugins/builtins"

# System monitor: SystemInfo plugin + a periodic backend event.

CrystKit::App.run do |app|
  app.plugin(CrystKit::Plugins::SystemInfo.new)

  # Clock ticks are fire-and-forget events (no frontend state to mirror),
  # so app.emit is the right tool. For continuous state that the frontend
  # should track, see app.state slice pattern instead.
  # App#emit auto-bridges to any open window.
  spawn do
    loop do
      app.emit("system:tick", {"now" => Time.utc.to_s})
      sleep 1.second
    end
  end

  app.window(
    title: "System Monitor",
    width: 720,
    height: 540,
    html: <<-HTML
      <!DOCTYPE html>
      <html><head><meta charset="UTF-8"><title>System Monitor</title>
      <style>
        body { font-family: system-ui; max-width: 720px; margin: 24px auto; padding: 0 24px; }
        .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
        .card { background: #f7f8fa; border-radius: 8px; padding: 16px; }
        .card h3 { margin: 0 0 8px; color: #555; font-size: 13px; text-transform: uppercase; }
        .card .v { font-size: 22px; font-weight: bold; }
        .clock { text-align: center; font-size: 28px; margin: 16px 0; color: #2563eb; }
      </style></head>
      <body>
      <h1>System Monitor</h1>
      <div class="clock" id="clock">—</div>
      <div class="grid">
        <div class="card"><h3>OS</h3><div class="v" id="os">…</div></div>
        <div class="card"><h3>Architecture</h3><div class="v" id="arch">…</div></div>
        <div class="card"><h3>Hostname</h3><div class="v" id="host">…</div></div>
        <div class="card"><h3>CPU</h3><div class="v" id="cpu">…</div></div>
        <div class="card"><h3>Memory</h3><div class="v" id="mem">…</div></div>
        <div class="card"><h3>Home</h3><div class="v" id="home" style="font-size:14px;">…</div></div>
      </div>
      <script>
        const ipc = window.__CRYSTKIT_IPC__;

        async function load() {
          const [os, arch, host, cpu, mem, home] = await Promise.all([
            ipc.invoke('system_info.os', {}),
            ipc.invoke('system_info.arch', {}),
            ipc.invoke('system_info.hostname', {}),
            ipc.invoke('system_info.cpu', {}),
            ipc.invoke('system_info.memory', {}),
            ipc.invoke('system_info.home_dir', {}),
          ]);
          document.getElementById('os').textContent = os.name + ' ' + os.version;
          document.getElementById('arch').textContent = arch;
          document.getElementById('host').textContent = host;
          document.getElementById('cpu').textContent = cpu.cores + ' cores · ' + cpu.model;
          document.getElementById('mem').textContent = (mem.total / 1024 / 1024 / 1024).toFixed(1) + ' GB';
          document.getElementById('home').textContent = home;
        }

        ipc.listen('system:tick', p => document.getElementById('clock').textContent = p.now);
        load();
      </script>
      </body></html>
    HTML
  )
end
