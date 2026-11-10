require "../../src/app/app"
require "../../src/plugins/builtins"

# Note-taking app using the Store plugin (key-value persistence).
# Each note is keyed by a slug; the list of slugs is itself a stored value.

CrystKit::App.run do |app|
  app.plugin(CrystKit::Plugins::Store.new)

  app.window(
    title: "Notes",
    width: 800,
    height: 600,
    html: <<-HTML
      <!DOCTYPE html>
      <html><head><meta charset="UTF-8"><title>Notes</title>
      <style>
        * { box-sizing: border-box; }
        body { font-family: system-ui; margin: 0; display: flex; height: 100vh; }
        #side { width: 240px; background: #fafafa; border-right: 1px solid #ddd; padding: 12px; overflow-y: auto; }
        #side h2 { margin: 0 0 12px; font-size: 16px; }
        #list { list-style: none; padding: 0; margin: 0; }
        #list li { padding: 8px; border-radius: 4px; cursor: pointer; }
        #list li:hover { background: #eee; }
        #list li.active { background: #2563eb; color: white; }
        #main { flex: 1; padding: 16px; display: flex; flex-direction: column; gap: 8px; }
        #title { font-size: 18px; font-weight: bold; padding: 8px; border: 1px solid #ddd; border-radius: 4px; }
        #body { flex: 1; padding: 8px; font-family: inherit; border: 1px solid #ddd; border-radius: 4px; resize: none; }
        button { padding: 8px 12px; cursor: pointer; }
        .row { display: flex; gap: 8px; }
      </style></head>
      <body>
      <aside id="side">
        <h2>Notes</h2>
        <button onclick="newNote()" style="width:100%;margin-bottom:8px">+ New</button>
        <ul id="list"></ul>
      </aside>
      <main id="main">
        <input id="title" placeholder="Title">
        <textarea id="body" placeholder="Write your note…"></textarea>
        <div class="row">
          <button onclick="save()">Save</button>
          <button onclick="del()">Delete</button>
        </div>
      </main>
      <script>
        const ipc = window.__CRYSTKIT_IPC__;
        const NS = 'notes';
        let current = null;

        const slug = s => s.toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'') || 'note';

        async function getIndex() {
          const v = await ipc.invoke('store.get', [NS, '_index']);
          return v && Array.isArray(v) ? v : [];
        }
        async function setIndex(ids) {
          await ipc.invoke('store.set', [NS, '_index', ids]);
        }

        async function refresh() {
          const ids = await getIndex();
          const list = document.getElementById('list');
          list.innerHTML = '';
          for (const id of ids) {
            const note = await ipc.invoke('store.get', [NS, id]);
            const li = document.createElement('li');
            li.textContent = note.title || '(untitled)';
            if (id === current) li.classList.add('active');
            li.onclick = () => load(id);
            list.appendChild(li);
          }
        }

        async function load(id) {
          current = id;
          const note = await ipc.invoke('store.get', [NS, id]);
          document.getElementById('title').value = note.title || '';
          document.getElementById('body').value  = note.body  || '';
          refresh();
        }

        async function newNote() {
          current = 'note-' + Date.now();
          document.getElementById('title').value = '';
          document.getElementById('body').value  = '';
          refresh();
        }

        async function save() {
          if (!current) return;
          const title = document.getElementById('title').value;
          const body  = document.getElementById('body').value;
          await ipc.invoke('store.set', [NS, current, {title, body}]);
          const ids = await getIndex();
          if (!ids.includes(current)) { ids.push(current); await setIndex(ids); }
          refresh();
        }

        async function del() {
          if (!current) return;
          await ipc.invoke('store.delete', [NS, current]);
          const ids = (await getIndex()).filter(x => x !== current);
          await setIndex(ids);
          current = null;
          document.getElementById('title').value = '';
          document.getElementById('body').value  = '';
          refresh();
        }

        refresh();
      </script>
      </body></html>
    HTML
  )
end
