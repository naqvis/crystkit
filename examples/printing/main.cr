require "../../src/app/app"
require "../../src/plugins/builtins"
require "../../src/features/printing"

app = CrystKit::App.new
app.grant("printing:print", "printing:pdf", "printing:info")
app.plugin(CrystKit::Plugins::Printing.new)

app.window(
  title: "CrystKit — Printing Demo",
  width: 800,
  height: 600,
  html: <<-HTML
    <!DOCTYPE html>
    <html><head><meta charset="UTF-8"><title>Printing Demo</title>
    <style>
      body { font-family: system-ui; max-width: 700px; margin: 40px auto; padding: 0 20px; }
      button { margin: 4px; padding: 10px 20px; font-size: 14px; cursor: pointer; }
      pre { background: #f4f4f4; padding: 12px; border-radius: 4px; }
      #result { margin-top: 12px; padding: 12px; border-radius: 4px; }
      .success { background: #d4edda; color: #155724; }
      .error { background: #f8d7da; color: #721c24; }
    </style></head>
    <body>
      <h1>🖨️ Printing Demo</h1>
      <p>This page content will be printed.</p>
      <div style="border:1px solid #ccc;padding:16px;margin:16px 0;border-radius:4px">
        <h2>Sample Document</h2>
        <p>Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.</p>
      </div>
      <button id="btn-print">Print</button>
      <button id="pdf">Export PDF</button>
      <button id="list">List Printers</button>
      <button id="dialog">Show Print Dialog</button>
      <div id="result"></div>
      <script>
        const ipc = window.__CRYSTKIT_IPC__;
        const out = document.getElementById('result');

        async function invoke(cmd, params) {
          out.className = '';
          try {
            const r = await ipc.invoke(cmd, params || {});
            out.textContent = JSON.stringify(r);
            out.className = r.success !== false ? 'success' : 'error';
          } catch(e) {
            out.textContent = 'Error: ' + e.message;
            out.className = 'error';
          }
        }

        document.getElementById('btn-print').onclick = () => invoke('printing.print', {});
        pdf.onclick    = () => invoke('printing.print_to_pdf', ['/tmp/demo.pdf', {}]);
        list.onclick   = () => invoke('printing.list_printers');
        dialog.onclick = () => invoke('printing.show_dialog', {});
      </script>
    </body></html>
  HTML
)

app.run
