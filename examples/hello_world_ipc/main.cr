require "../../src/app/app"
require "../../src/plugins/builtins"

# Minimum-viable CrystKit::App.

app = CrystKit::App.new

class CounterState
  include JSON::Serializable

  property count : Int32

  def initialize(@count : Int32)
  end
end

counter = app.state("counter", CounterState) { CounterState.new(0) }

app.command "greet", String do |name|
  "Hello, #{name}! Greetings from Crystal."
end

app.command "get_time" do
  Time.utc.to_s
end

app.command "counter.increment" do
  counter.update do |state|
    state.count += 1
    state
  end
  counter.value.count
end

app.on("frontend:ping") do |payload|
  puts "Backend received ping: #{payload}"
  app.emit("server:tick", {"echo" => payload, "time" => Time.utc.to_s})
end

app.window(
  title: "Hello World — IPC Demo",
  width: 800,
  height: 600,
  html: <<-HTML
    <!DOCTYPE html>
    <html><head><meta charset="UTF-8"><title>Hello IPC</title>
    <style>
      body { font-family: system-ui; max-width: 600px; margin: 40px auto; padding: 0 20px; }
      button { margin: 4px; padding: 8px 16px; cursor: pointer; }
      #output, #events { margin-top: 12px; padding: 12px; border-radius: 4px; min-height: 40px; }
      #output { background: #f0f0f0; white-space: pre-wrap; }
      #events { background: #e8f4e8; }
    </style></head>
    <body>
      <h1>Hello World — IPC Demo</h1>
      <button id="greet">Greet</button>
      <button id="time">Server time</button>
      <button id="emit">Trigger backend event</button>
      <button id="increment">Increment reactive state</button>
      <h3>Result</h3><div id="output">Click a button…</div>
      <h3>Events</h3><div id="events">Waiting…</div>
      <h3>Reactive state</h3><div id="counter">Counter: …</div>
      <script>
        const ipc = window.__CRYSTKIT_IPC__;
        const out = document.getElementById('output');
        const events = document.getElementById('events');
        const counterEl = document.getElementById('counter');

        ipc.listen('server:tick', p => events.textContent = JSON.stringify(p));

        ipc.state('counter').then(counter => {
          const renderCounter = state => counterEl.textContent = 'Counter: ' + state.count;
          renderCounter(counter.value);
          counter.subscribe(renderCounter);
        });

        greet.onclick = async () => out.textContent = await ipc.invoke('greet', 'Developer');
        time.onclick  = async () => out.textContent = 'Server time: ' + await ipc.invoke('get_time', {});
        emit.onclick  = ()       => ipc.emit('frontend:ping', {message: 'ping from JS'});
        increment.onclick = async () => out.textContent = 'Counter incremented to ' + await ipc.invoke('counter.increment', {});
      </script>
    </body></html>
  HTML
)

app.run
