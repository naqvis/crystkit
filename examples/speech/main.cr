require "../../src/app/app"
require "../../src/plugins/builtins"
require "../../src/features/speech"

app = CrystKit::App.new
app.grant("speech:synth", "speech:recognize")
app.plugin(CrystKit::Plugins::Speech.new)

app.window(
  title: "CrystKit — Speech Demo",
  width: 700,
  height: 500,
  html: <<-HTML
    <!DOCTYPE html>
    <html><head><meta charset="UTF-8"><title>Speech Demo</title>
    <style>
      body { font-family: system-ui; max-width: 600px; margin: 40px auto; padding: 0 20px; }
      textarea { width: 100%; height: 100px; margin: 8px 0; padding: 8px; }
      button { margin: 4px; padding: 8px 16px; cursor: pointer; }
      select { padding: 8px; margin: 4px 0; }
      #status { margin-top: 12px; padding: 12px; border-radius: 4px; background: #f0f0f0; }
    </style></head>
    <body>
      <h1>🗣️ Speech Demo</h1>
      <h3>Text-to-Speech</h3>
      <textarea id="text">Hello from CrystKit! This is a test of the text to speech system.</textarea>
      <div>
        <button id="speak">Speak</button>
        <button id="stop">Stop</button>
        <button id="pause">Pause</button>
        <button id="resume">Resume</button>
      </div>
      <h3>Speech-to-Text</h3>
      <div>
        <select id="recognize-language">
          <option value="">Loading recognition languages…</option>
        </select>
        <button id="recognize-permission">Request microphone permission</button>
        <button id="recognize-start" disabled>Start listening</button>
        <button id="recognize-stop">Stop listening</button>
      </div>
      <textarea id="transcript" readonly placeholder="Native recognition results appear here"></textarea>
      <div id="status">Ready</div>
      <script>
        const ipc = window.__CRYSTKIT_IPC__;
        const status = document.getElementById('status');
        const text = document.getElementById('text');
        const transcript = document.getElementById('transcript');
        const recognitionLanguage = document.getElementById('recognize-language');
        const recognitionStart = document.getElementById('recognize-start');

        async function call(cmd, arg) {
          try {
            const r = await ipc.invoke(cmd, arg || {});
            status.textContent = JSON.stringify(r);
          } catch(e) {
            status.textContent = 'Error: ' + e.message;
          }
        }

        document.getElementById('speak').onclick  = () => call('speech.speak', [text.value, {}]);
        document.getElementById('stop').onclick   = () => call('speech.stop');
        document.getElementById('pause').onclick  = () => call('speech.pause');
        document.getElementById('resume').onclick = () => call('speech.resume');

        document.getElementById('recognize-permission').onclick =
          () => call('speech.recognize_request_permission');
        recognitionStart.onclick =
          () => call('speech.recognize_start', [recognitionLanguage.value, true]);
        document.getElementById('recognize-stop').onclick =
          () => call('speech.recognize_stop');

        ipc.invoke('speech.recognize_languages').then(({ languages }) => {
          recognitionLanguage.innerHTML = languages.map(language =>
            `<option value="${language}">${language}</option>`
          ).join('') || '<option value="">No recognition languages available</option>';
          if (languages.includes('en-US')) recognitionLanguage.value = 'en-US';
          recognitionLanguage.disabled = languages.length === 0;
          recognitionStart.disabled = languages.length === 0;
        }).catch(error => {
          recognitionLanguage.innerHTML = '<option value="">Unable to load recognition languages</option>';
          recognitionLanguage.disabled = true;
          recognitionStart.disabled = true;
          status.textContent = 'Language error: ' + error.message;
        });

        ipc.listen('speech.recognition_result', result => {
          transcript.value = result.transcript;
          status.textContent = result.final ? 'Final result' : 'Listening…';
        });
        ipc.listen('speech.recognition_error', error => {
          status.textContent = 'Recognition error: ' + error.message;
        });
        ipc.listen('speech.recognition_end', () => {
          status.textContent = 'Recognition ended';
        });
      </script>
    </body></html>
  HTML
)

app.run
