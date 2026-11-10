# System Monitor

Reads OS-level information through the `Plugins::SystemInfo` plugin and streams a live clock to the frontend via a periodic backend event.

## Run

```bash
crystal run examples/system_monitor/main.cr
```

## What you'll see

A 720×540 window with:

- A live UTC clock at the top, updated every second
- Six cards: OS name/version, architecture, hostname, CPU, memory, home directory

The clock comes from a backend `spawn` loop that emits a `system:tick` event every second. The frontend's `ipc.listen("system:tick", ...)` handler updates the DOM.

The system info cards are populated once at page load by calling each of the `SystemInfo` plugin's commands in parallel.

## What's wired

```crystal
app.plugin(CrystKit::Plugins::SystemInfo.new)

spawn do
  loop do
    app.emit("system:tick", {"now" => Time.utc.to_s})
    sleep 1.second
  end
end
```

That's the complete backend. No custom commands. The plugin auto-registers `system_info:os`, `system_info:arch`, `system_info:hostname`, `system_info:cpu`, `system_info:memory`, `system_info:home_dir`.

## Frontend pattern

```js
const [os, arch, host, cpu, mem, home] = await Promise.all([
  ipc.invoke("system_info.os"),
  ipc.invoke("system_info.arch"),
  ipc.invoke("system_info.hostname"),
  ipc.invoke("system_info.cpu"),
  ipc.invoke("system_info.memory"),
  ipc.invoke("system_info.home_dir"),
]);

ipc.listen("system:tick", (payload) => (clock.textContent = payload.now));
```

## Why no capability grants?

`Plugins::SystemInfo` exposes read-only metadata that doesn't reveal file contents, network state, or user data. The framework treats it as non-sensitive — no `app.grant(...)` is needed.

## See also

- [`Plugins::SystemInfo`](../../docs/plugins.md#webviewpluginssysteminfo) — full command list
- [`docs/ipc.md`](../../docs/ipc.md) — events and the periodic-emit pattern
