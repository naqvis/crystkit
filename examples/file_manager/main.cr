require "../../src/app/app"
require "../../src/plugins/builtins"

CrystKit::App.run do |app|
  demo_root = Path.home

  app
    .grant("fs:read", "fs:write", "fs:delete", "dialog:open", "dialog:save",
      "clipboard:read", "clipboard:write")
    .plugin(CrystKit::Plugins::FS.new)
    .plugin(CrystKit::Plugins::Dialog.new)
    .plugin(CrystKit::Plugins::Clipboard.new)

  app.scopes.persist(demo_root, CrystKit::Security::Permission::Write)

  app.window(
    title: "File Manager",
    width: 1100,
    height: 750,
    debug: true,
    html: <<-HTML
      <!DOCTYPE html>
      <html><head><meta charset="UTF-8"><title>File Manager</title>
      <style>
        :root {
          --bg: #1e1e2e; --bg-surface: #181825; --bg-overlay: #313244;
          --text: #cdd6f4; --text-dim: #a6adc8; --text-faint: #585b70;
          --primary: #89b4fa; --primary-hover: #74c7ec;
          --green: #a6e3a1; --red: #f38ba8; --yellow: #f9e2af; --peach: #fab387;
          --border: #45475a; --radius: 6px;
          --sidebar-w: 220px; --toolbar-h: 44px; --status-h: 28px;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; font-size: 13px; color: var(--text); background: var(--bg); display: flex; height: 100vh; overflow: hidden; user-select: none; }
        a { color: var(--primary); text-decoration: none; }
        a:hover { color: var(--primary-hover); }
        button { font-family: inherit; font-size: 12px; padding: 5px 10px; border: 1px solid var(--border); border-radius: var(--radius); background: var(--bg-overlay); color: var(--text); cursor: pointer; display: inline-flex; align-items: center; gap: 4px; }
        button:hover { background: var(--border); }
        button.primary { background: var(--primary); color: var(--bg); border-color: var(--primary); }
        button.primary:hover { opacity: 0.9; }
        button.danger { color: var(--red); }
        button.danger:hover { background: rgba(243,139,168,0.15); }
        button:disabled { opacity: 0.4; cursor: default; }

        /* Sidebar */
        #sidebar { width: var(--sidebar-w); background: var(--bg-surface); border-right: 1px solid var(--border); display: flex; flex-direction: column; flex-shrink: 0; }
        #sidebar h3 { font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; color: var(--text-faint); padding: 14px 16px 6px; font-weight: 600; }
        #sidebar ul { list-style: none; }
        #sidebar li { display: flex; align-items: center; gap: 8px; padding: 6px 16px; cursor: pointer; color: var(--text-dim); font-size: 13px; border-left: 2px solid transparent; }
        #sidebar li:hover { background: var(--bg-overlay); color: var(--text); }
        #sidebar li.active { background: rgba(137,180,250,0.08); color: var(--primary); border-left-color: var(--primary); }
        #sidebar .sep { height: 1px; background: var(--border); margin: 8px 16px; }

        /* Content area */
        #content { flex: 1; display: flex; flex-direction: column; min-width: 0; }

        /* Toolbar */
        #toolbar { height: var(--toolbar-h); display: flex; align-items: center; gap: 6px; padding: 0 12px; border-bottom: 1px solid var(--border); background: var(--bg-surface); flex-shrink: 0; }
        #toolbar .sep { width: 1px; height: 20px; background: var(--border); margin: 0 4px; }

        /* Breadcrumb */
        #breadcrumb { display: flex; align-items: center; gap: 2px; padding: 0 12px; height: 34px; border-bottom: 1px solid var(--border); background: var(--bg-surface); flex-shrink: 0; font-size: 13px; overflow-x: auto; white-space: nowrap; }
        .crumb { padding: 3px 6px; border-radius: 4px; cursor: pointer; color: var(--text-dim); }
        .crumb:hover { background: var(--bg-overlay); color: var(--text); }
        .crumb:last-child { color: var(--text); font-weight: 500; }
        .crumb-sep { color: var(--text-faint); margin: 0 1px; }

        /* File table */
        #file-list { flex: 1; overflow-y: auto; }
        table { width: 100%; border-collapse: collapse; }
        thead th { position: sticky; top: 0; background: var(--bg-surface); padding: 8px 12px; text-align: left; font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; color: var(--text-faint); font-weight: 600; border-bottom: 1px solid var(--border); }
        tbody tr { cursor: pointer; border-bottom: 1px solid rgba(69,71,90,0.4); }
        tbody tr:hover { background: rgba(137,180,250,0.06); }
        tbody tr.selected { background: rgba(137,180,250,0.12); }
        td { padding: 7px 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        td.name { display: flex; align-items: center; gap: 8px; max-width: 400px; }
        .icon { width: 18px; text-align: center; flex-shrink: 0; font-size: 14px; }
        .icon.dir { color: var(--primary); }
        .icon.file { color: var(--text-dim); }
        .icon.img { color: var(--peach); }
        .icon.code { color: var(--green); }
        .icon.doc { color: var(--yellow); }
        .size { color: var(--text-dim); text-align: right; font-variant-numeric: tabular-nums; }
        .date { color: var(--text-dim); font-variant-numeric: tabular-nums; }
        .empty-msg { text-align: center; padding: 48px 16px; color: var(--text-faint); }

        /* Editor panel */
        #editor-wrap { border-top: 1px solid var(--border); display: none; flex-direction: column; }
        #editor-wrap.open { display: flex; }
        #editor-header { display: flex; align-items: center; justify-content: space-between; padding: 6px 12px; background: var(--bg-surface); border-bottom: 1px solid var(--border); }
        #editor-header span { color: var(--text-dim); font-size: 12px; }
        #editor { width: 100%; height: 200px; background: var(--bg); color: var(--text); border: none; padding: 10px 14px; font-family: "SF Mono", "Fira Code", "Cascadia Code", monospace; font-size: 13px; line-height: 1.5; resize: vertical; outline: none; }
        #editor:focus { box-shadow: inset 0 0 0 1px var(--primary); }

        /* Status bar */
        #status { height: var(--status-h); display: flex; align-items: center; justify-content: space-between; padding: 0 14px; background: var(--bg-surface); border-top: 1px solid var(--border); font-size: 11px; color: var(--text-faint); flex-shrink: 0; }

        /* Toasts */
        #toasts { position: fixed; bottom: 40px; right: 16px; display: flex; flex-direction: column-reverse; gap: 6px; z-index: 999; pointer-events: none; }
        .toast { padding: 8px 14px; border-radius: var(--radius); font-size: 12px; background: var(--bg-overlay); color: var(--text); border: 1px solid var(--border); animation: slideIn 0.2s ease; pointer-events: auto; }
        .toast.error { border-color: var(--red); background: rgba(243,139,168,0.12); }
        @keyframes slideIn { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: translateY(0); } }
      </style></head>
      <body>
      <nav id="sidebar">
        <h3>Favorites</h3>
        <ul id="favs"></ul>
        <div class="sep"></div>
        <h3>Devices</h3>
        <ul>
          <li onclick="navigate('/')" data-path="/"><span class="icon dir">/</span> Root</li>
        </ul>
      </nav>
      <div id="content">
        <div id="toolbar">
          <button onclick="goUp()" title="Backspace">^ Up</button>
          <button onclick="refresh()" title="Ctrl+R">Refresh</button>
          <div class="sep"></div>
          <button onclick="copyPath()" title="Ctrl+C">Copy Path</button>
          <div class="sep"></div>
          <button class="danger" onclick="deleteSelected()" title="Delete">Delete</button>
        </div>
        <div id="breadcrumb"></div>
        <div id="file-list">
          <table><thead><tr>
            <th>Name</th><th class="size">Size</th><th>Modified</th>
          </tr></thead><tbody id="rows"></tbody></table>
        </div>
        <div id="editor-wrap">
          <div id="editor-header">
            <span id="editor-path"></span>
            <button class="primary" onclick="saveFile()">Save</button>
          </div>
          <textarea id="editor" spellcheck="false"></textarea>
        </div>
        <div id="status"><span id="status-left"></span><span id="status-right"></span></div>
      </div>
      <div id="toasts"></div>

      <script>
        const ipc = window.__CRYSTKIT_IPC__;
        const DEMO_ROOT = #{demo_root.to_s.to_json};

        let cwd = DEMO_ROOT;
        let selected = null;
        let entries = [];

        // -- Helpers --
        const $ = id => document.getElementById(id);

        function toast(msg, error) {
          const el = document.createElement('div');
          el.className = 'toast' + (error ? ' error' : '');
          el.textContent = msg;
          $('toasts').appendChild(el);
          setTimeout(() => el.remove(), 2500);
        }

        function formatSize(bytes) {
          if (bytes == null) return '';
          if (bytes === 0) return '0 B';
          const units = ['B', 'KB', 'MB', 'GB', 'TB'];
          const i = Math.floor(Math.log(bytes) / Math.log(1024));
          return (bytes / Math.pow(1024, i)).toFixed(i ? 1 : 0) + ' ' + units[i];
        }

        function formatDate(iso) {
          if (!iso) return '';
          const d = new Date(iso);
          if (isNaN(d)) return iso;
          const now = new Date();
          const diff = now - d;
          if (diff < 60000) return 'just now';
          if (diff < 3600000) return Math.floor(diff / 60000) + 'm ago';
          if (diff < 86400000) return Math.floor(diff / 3600000) + 'h ago';
          if (diff < 172800000) return 'yesterday';
          return d.toLocaleDateString();
        }

        function fileIcon(name, type) {
          if (type === 'directory') return '<span class="icon dir">&#128193;</span>';
          const ext = name.split('.').pop().toLowerCase();
          if (['png','jpg','jpeg','gif','svg','webp','ico','bmp'].includes(ext))
            return '<span class="icon img">&#127912;</span>';
          if (['cr','rb','py','js','ts','go','rs','c','cpp','h','sh','json','yaml','yml','toml','xml'].includes(ext))
            return '<span class="icon code">&#60;/&#62;</span>';
          if (['md','txt','pdf','doc','docx','rtf'].includes(ext))
            return '<span class="icon doc">&#128196;</span>';
          return '<span class="icon file">&#128196;</span>';
        }

        // -- Sidebar --
        function buildSidebar() {
          const favs = $('favs');
          const paths = [
            { label: 'Home', path: DEMO_ROOT },
          ];
          favs.innerHTML = '';
          for (const f of paths) {
            const li = document.createElement('li');
            li.dataset.path = f.path;
            li.innerHTML = '<span class="icon dir">&#127968;</span> ' + f.label;
            li.onclick = () => navigate(f.path);
            favs.appendChild(li);
          }
        }

        function updateSidebarActive() {
          document.querySelectorAll('#sidebar li').forEach(li => {
            li.classList.toggle('active', li.dataset.path === cwd);
          });
        }

        // -- Breadcrumb --
        function renderBreadcrumb() {
          const bc = $('breadcrumb');
          const parts = cwd.split('/').filter(Boolean);
          bc.innerHTML = '';
          const root = document.createElement('span');
          root.className = 'crumb';
          root.textContent = '\u2630';
          root.dataset.nav = '/';
          bc.appendChild(root);
          let accumulated = '';
          for (let i = 0; i < parts.length; i++) {
            accumulated += '/' + parts[i];
            const sep = document.createElement('span');
            sep.className = 'crumb-sep';
            sep.textContent = '/';
            bc.appendChild(sep);
            const crumb = document.createElement('span');
            crumb.className = 'crumb';
            crumb.textContent = parts[i];
            crumb.dataset.nav = accumulated;
            bc.appendChild(crumb);
          }
          bc.scrollLeft = bc.scrollWidth;
        }

        $('breadcrumb').addEventListener('click', e => {
          const target = e.target.closest('[data-nav]');
          if (target) navigate(target.dataset.nav);
        });

        // -- File listing --
        async function list() {
          try {
            entries = await ipc.invoke('fs.list_dir', { path: cwd });
            entries.sort((a, b) => {
              if (a.type === 'directory' && b.type !== 'directory') return -1;
              if (a.type !== 'directory' && b.type === 'directory') return 1;
              return a.name.localeCompare(b.name);
            });
            renderEntries();
            updateSidebarActive();
            renderBreadcrumb();
            $('status-left').textContent = entries.length + ' item' + (entries.length !== 1 ? 's' : '');
            $('status-right').textContent = cwd;
          } catch (err) {
            toast('Cannot list directory: ' + err.message, true);
          }
        }

        function renderEntries() {
          const rows = $('rows');
          if (!entries.length) {
            rows.innerHTML = '<tr><td colspan="3" class="empty-msg">Empty directory</td></tr>';
            return;
          }
          rows.innerHTML = '';
          for (const e of entries) {
            const tr = document.createElement('tr');
            tr.dataset.path = e.path;
            tr.dataset.type = e.type;
            if (selected === e.path) tr.classList.add('selected');
            tr.innerHTML =
              '<td class="name">' + fileIcon(e.name, e.type) +
              '<span style="overflow:hidden;text-overflow:ellipsis">' + esc(e.name) + '</span></td>' +
              '<td class="size">' + (e.type === 'directory' ? '' : formatSize(e.size)) + '</td>' +
              '<td class="date">' + formatDate(e.modified_at) + '</td>';
            tr.onclick = () => selectRow(tr, e);
            tr.ondblclick = () => {
              if (e.type === 'directory') navigate(e.path);
              else openFile(e.path);
            };
            rows.appendChild(tr);
          }
        }

        function esc(s) {
          return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
        }

        function selectRow(tr, entry) {
          document.querySelectorAll('tr.selected').forEach(r => r.classList.remove('selected'));
          tr.classList.add('selected');
          selected = entry.path;
          if (entry.type !== 'directory') openFile(entry.path);
        }

        // -- Navigation --
        function navigate(path) {
          cwd = path;
          selected = null;
          closeEditor();
          list();
        }

        function goUp() {
          const parts = cwd.split('/').filter(Boolean);
          if (parts.length > 1) {
            parts.pop();
            navigate('/' + parts.join('/'));
          } else if (parts.length === 1) {
            navigate('/');
          }
        }

        function refresh() { list(); toast('Refreshed'); }

        // -- Editor --
        async function openFile(path) {
          try {
            const text = await ipc.invoke('fs.read_text', { path });
            $('editor').value = text;
            $('editor-path').textContent = path;
            $('editor-wrap').classList.add('open');
            selected = path;
          } catch (err) {
            toast('Cannot read file: ' + err.message, true);
          }
        }

        function closeEditor() {
          $('editor-wrap').classList.remove('open');
          $('editor').value = '';
          $('editor-path').textContent = '';
        }

        async function saveFile() {
          if (!selected) return;
          try {
            await ipc.invoke('fs.write_text', { path: selected, content: $('editor').value });
            toast('Saved');
            notify('File Manager', 'Saved ' + selected.split('/').pop());
          } catch (err) {
            toast('Save failed: ' + err.message, true);
          }
        }

        // -- File operations --
        function copyPath() {
          if (!selected) return toast('No file selected', true);
          try {
            ipc.invoke('clipboard.write_text', selected);
            toast('Path copied');
          } catch {
            toast('Copy failed', true);
          }
        }

        async function deleteSelected() {
          if (!selected) return toast('No file selected', true);
          const entry = entries.find(e => e.path === selected);
          if (!entry) return;
          const kind = entry.type === 'directory' ? 'folder' : 'file';
          const ok = await ipc.invoke('dialog.confirm', { title: 'Delete ' + kind, message: 'Delete "' + entry.name + '"?' });
          if (!ok) return;
          try {
            if (entry.type === 'directory') {
              await ipc.invoke('fs.remove_dir', { path: selected, recursive: true });
            } else {
              await ipc.invoke('fs.remove_file', { path: selected });
            }
            toast('Deleted ' + entry.name);
            selected = null;
            closeEditor();
            list();
          } catch (err) {
            toast('Delete failed: ' + err.message, true);
          }
        }

        // -- Keyboard shortcuts --
        document.addEventListener('keydown', e => {
          if (e.target.tagName === 'TEXTAREA' || e.target.tagName === 'INPUT') return;
          if (e.key === 'Backspace') { e.preventDefault(); goUp(); }
          if (e.key === 'Delete') { e.preventDefault(); deleteSelected(); }
          if ((e.ctrlKey || e.metaKey) && e.key === 'c') { e.preventDefault(); copyPath(); }
          if ((e.ctrlKey || e.metaKey) && e.key === 'r') { e.preventDefault(); refresh(); }
        });

        // -- Init --
        buildSidebar();
        list();
      </script>
      </body></html>
    HTML
  )
end
