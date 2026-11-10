// ─── Shared helpers ────────────────────────────────────────────────────────

const ipc = window.__CRYSTKIT_IPC__;

const $ = (id) => document.getElementById(id);
const escape = (s) => String(s).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
}[c]));

const toast = (msg, kind = 'info') => {
    console.log(`[${kind}] ${msg}`);
    const el = document.createElement('div');
    el.className = `toast ${kind}`;
    el.textContent = msg;
    document.getElementById('toast-container').appendChild(el);
    const ttl = kind === 'error' ? 10000 : 3500;
    setTimeout(() => { el.classList.add('fade'); setTimeout(() => el.remove(), 300); }, ttl);
};

const handle = async (label, fn) => {
    try { return await fn(); }
    catch (err) { toast(`${label} failed: ${err.message}`, 'error'); console.error(label, err); }
};

// ─── Tab routing ────────────────────────────────────────────────────────────

document.querySelectorAll('.tab').forEach(btn => {
    btn.onclick = () => {
        document.querySelectorAll('.tab').forEach(b => b.classList.remove('active'));
        document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
        btn.classList.add('active');
        document.querySelector(`.panel[data-panel="${btn.dataset.tab}"]`).classList.add('active');

        if (btn.dataset.tab === 'system') api.loadSystem();
        if (btn.dataset.tab === 'recents') recents.refresh();
        if (btn.dataset.tab === 'shortcuts') shortcutsDemo.refresh();
        if (btn.dataset.tab === 'autostart') autostartDemo.refresh();
        if (btn.dataset.tab === 'screen') screenDemo.refresh();
        if (btn.dataset.tab === 'window') {
            windowDemo.refresh();
            kioskDemo.refresh();
        }
        if (btn.dataset.tab === 'permissions') perms.refresh?.();
        if (btn.dataset.tab === 'effects') effects.refresh?.();
        if (btn.dataset.tab === 'positioning') positioning.displayInfo();
        if (btn.dataset.tab === 'speech') speech.initialize();
        if (btn.dataset.tab === 'display') displayDemo.info();
    };
});

// ─── Live status (clock + memory + ws state) ───────────────────────────────

ipc.listen('clock:tick', (p) => $('clock').textContent = p.now);
ipc.listen('stats:tick', (p) => {
    const used = p.memory.used_pct;
    const totalGB = (p.memory.total / 1e9).toFixed(1);
    $('memory').textContent = `mem: ${used}% of ${totalGB} GB`;
});

// ─── Generic API namespace (overview tab + helpers) ────────────────────────

const api = {
    notify: (title, body) => handle('notify', () => ipc.invoke('ui.notify', [title, body])),
    openLogFolder: async () => {
        const home = await ipc.invoke('system_info.home_dir');
        await ipc.invoke('external.open_path', home);
    },
    loadSystem: async () => {
        const [os, arch, host, cpu, mem, home] = await Promise.all([
            ipc.invoke('system_info.os'),
            ipc.invoke('system_info.arch'),
            ipc.invoke('system_info.hostname'),
            ipc.invoke('system_info.cpu'),
            ipc.invoke('system_info.memory'),
            ipc.invoke('system_info.home_dir'),
        ]);
        $('system-grid').innerHTML = `
      <div class="card"><h3>OS</h3><div class="v">${escape(os.name + ' ' + os.version)}</div></div>
      <div class="card"><h3>Architecture</h3><div class="v">${escape(arch)}</div></div>
      <div class="card"><h3>Hostname</h3><div class="v">${escape(host)}</div></div>
      <div class="card"><h3>CPU</h3><div class="v">${escape(cpu.cores + ' cores · ' + cpu.model)}</div></div>
      <div class="card"><h3>Memory</h3><div class="v">${(mem.total / 1e9).toFixed(1)} GB</div></div>
      <div class="card"><h3>Home</h3><div class="v">${escape(home)}</div></div>`;
    },
};

// ─── Files ──────────────────────────────────────────────────────────────────

let currentFile = null;
const files = {
    list: () => handle('list', async () => {
        const path = $('file-path').value;
        const entries = await ipc.invoke('fs.list_dir', { path });
        const tbody = $('file-rows');
        tbody.innerHTML = '';
        entries.forEach(e => {
            const tr = document.createElement('tr');
            tr.innerHTML = `<td>${escape(e.name)}</td><td>${escape(e.type)}</td><td>${e.size}</td><td>${escape(e.modified_at)}</td>`;
            tr.onclick = () => e.type === 'directory' ? ($('file-path').value = e.path, files.list()) : files.open(e.path);
            tbody.appendChild(tr);
        });
    }),
    open: async (path) => handle('open', async () => {
        const text = await ipc.invoke('fs.read_text', { path });
        currentFile = path;
        $('file-editor').value = text;
        ipc.emit('recents:track', { path });
    }),
    openDialog: () => handle('open_dialog', async () => {
        const result = await ipc.invoke('dialog.open_file', {});
        if (result) {
            currentFile = result;
            $('file-editor').value = await ipc.invoke('fs.read_text', { path: result });
        }
    }),
    save: () => handle('save', async () => {
        if (!currentFile) return toast('No file selected', 'warn');
        await ipc.invoke('fs.write_text', { path: currentFile, content: $('file-editor').value });
        toast('Saved');
    }),
};

// ─── Clipboard ──────────────────────────────────────────────────────────────

let lastClipVersion = 0n;
const clip = {
    write: () => handle('clip', () => ipc.invoke('clipboard.write_text', $('clip-text').value).then(() => { toast('Copied'); clip.pollVersion(); })),
    read: () => handle('clip', async () => {
        const t = await ipc.invoke('clipboard.read_text');
        $('clip-out').textContent = t;
    }),
    pollVersion: async () => {
        try {
            const r = await ipc.invoke('clipboard.version');
            const ver = BigInt(r.version);
            const el = $('clip-version');
            if (el) {
                if (lastClipVersion > 0n && ver !== lastClipVersion) {
                    el.style.background = '#ff6';
                    setTimeout(() => el.style.background = '', 1500);
                }
                lastClipVersion = ver;
                el.textContent = `change #${ver}`;
            }
        } catch { }
    },
};

// ─── Dialogs ────────────────────────────────────────────────────────────────

const dialogs = {
    open: () => handle('dialog:open', async () => $('dialog-out').textContent = await ipc.invoke('dialog.open_file', { title: 'Open', default_path: '' })),
    save: () => handle('dialog:save', async () => $('dialog-out').textContent = await ipc.invoke('dialog.save_file', { title: 'Save', default_name: 'untitled.txt', default_path: '' })),
    folder: () => handle('dialog:folder', async () => $('dialog-out').textContent = await ipc.invoke('dialog.select_folder', { title: 'Folder', default_path: '' })),
};

// ─── HTTP ───────────────────────────────────────────────────────────────────

const http = {
    fetchOnce: () => handle('http', async () => {
        const r = await ipc.invoke('sync.fetch_todos');
        $('http-out').textContent = JSON.stringify(r, null, 2);
    }),
    bulkFetch: () => handle('bulk_http', async () => {
        $('http-progress').value = 0;
        $('http-out').textContent = 'starting…';
        await ipc.invoke('sync.bulk_fetch', 5);
    }),
    loadTlsInfo: async () => {
        try {
            const r = await ipc.invoke('tls.info');
            const el = $('tls-info');
            if (el) el.textContent = r.tls_enabled ? `TLS enabled — cert at ${r.cert_path}` : 'TLS not available (no cert file)';
        } catch { }
    },
};
ipc.listen('sync:progress', (p) => {
    $('http-progress').value = (p.current / p.total) * 100;
    $('http-out').textContent = `${p.current}/${p.total}: ${JSON.stringify(p.todo)}`;
});
ipc.listen('sync:done', (p) => toast(`Bulk fetch done (${p.count})`));

// ─── WebSocket ──────────────────────────────────────────────────────────────

const ws = {
    connect: () => handle('ws:connect', () => ipc.invoke('ws.connect', $('ws-url').value)),
    disconnect: () => handle('ws:disconnect', () => ipc.invoke('ws.disconnect')),
    send: () => handle('ws:send', () => ipc.invoke('ws.send', $('ws-msg').value)),
};
const wsLog = (msg) => $('ws-log').textContent += msg + '\n';
ipc.listen('ws:status', (p) => { $('ws-status').textContent = `ws: ${p.connected ? 'connected' : 'disconnected'}`; wsLog(`status: ${JSON.stringify(p)}`); });
ipc.listen('ws.message', (p) => wsLog(`recv: ${p.text}`));
ipc.listen('ws.error', (p) => wsLog(`error: ${p.message}`));

// ─── Processes ──────────────────────────────────────────────────────────────

const proc = {
    pids: new Set(),
    run: (cmd, args) => handle('process', async () => {
        const r = await ipc.invoke('process.spawn', [cmd, args]);
        proc.pids.add(r.pid);
        $('proc-out').textContent += `\n[spawned pid=${r.pid}]\n`;
    }),
    killAll: () => handle('kill', async () => {
        for (const pid of proc.pids) await ipc.invoke('process.kill', pid);
        proc.pids.clear();
        $('proc-out').textContent += '\n[killed all]\n';
    }),
};
ipc.listen('process:stdout', (p) => $('proc-out').textContent += p.data);
ipc.listen('process:exit', (p) => $('proc-out').textContent += `\n[exit pid=${p.pid} code=${p.code}]\n`);

// ─── Shell ──────────────────────────────────────────────────────────────────

const shell = {
    run: () => handle('shell', async () => {
        const cmd = $('shell-cmd').value;
        const args = $('shell-args').value.split(/\s+/).filter(Boolean);
        const r = await ipc.invoke('shell.run', [cmd, args, 5000]);
        $('shell-out').textContent = `exit ${r.exit_code}\n--- stdout ---\n${r.stdout}\n--- stderr ---\n${r.stderr}`;
    }),
};

// ─── Recents ────────────────────────────────────────────────────────────────

const recents = {
    refresh: () => handle('recents', async () => {
        const list = await ipc.invoke('recents.list');
        const ul = $('recents-list');
        ul.innerHTML = '';
        if (list.length === 0) {
            const li = document.createElement('li');
            li.textContent = 'No recent files yet — open one from the Files tab.';
            li.style.color = 'var(--muted)';
            li.style.cursor = 'default';
            ul.appendChild(li);
            return;
        }
        list.forEach(p => {
            const li = document.createElement('li');
            li.textContent = p;
            li.onclick = () => files.open(p).then(() => document.querySelector('.tab[data-tab="files"]').click());
            ul.appendChild(li);
        });
    }),
    clear: () => handle('clear', () => ipc.invoke('recents.clear').then(() => recents.refresh())),
};
ipc.listen('recents:changed', () => recents.refresh());

// ─── System Tray ────────────────────────────────────────────────────────────

const trayLog = (msg) => {
    const el = $('tray-log');
    if (el) el.textContent = msg + '\n' + el.textContent;
};

const trayDemo = {
    setTooltip: () => handle('tray:tooltip', async () => {
        const text = $('tray-tooltip').value;
        await ipc.invoke('tray.set_tooltip', text);
        trayLog(`Tooltip updated to: "${text}"`);
    }),
};

ipc.listen('tray.clicked', (p) => trayLog(`Tray clicked: ${p.button} button`));

// ─── Global Shortcuts ───────────────────────────────────────────────────────

const shortcutsLog = (msg) => {
    const el = $('shortcuts-log');
    if (el) el.textContent = msg + '\n' + el.textContent;
};

const shortcutsDemo = {
    refresh: () => handle('shortcuts:list', async () => {
        const list = await ipc.invoke('shortcuts.list');
        const ul = $('shortcuts-list');
        if (!ul) return;
        ul.innerHTML = '';
        if (list.length === 0) {
            const li = document.createElement('li');
            li.textContent = 'No shortcuts registered';
            li.style.color = 'var(--muted)';
            ul.appendChild(li);
            return;
        }
        list.forEach(acc => {
            const li = document.createElement('li');
            li.innerHTML = `<code>${escape(acc)}</code>`;
            ul.appendChild(li);
        });
    }),
    register: () => handle('shortcuts:register', async () => {
        const acc = $('shortcut-accelerator').value;
        await ipc.invoke('shortcuts.register', acc);
        shortcutsLog(`Registered: ${acc}`);
        shortcutsDemo.refresh();
    }),
    unregister: () => handle('shortcuts:unregister', async () => {
        const acc = $('shortcut-accelerator').value;
        await ipc.invoke('shortcuts.unregister', acc);
        shortcutsLog(`Unregistered: ${acc}`);
        shortcutsDemo.refresh();
    }),
};

ipc.listen('shortcut:triggered', (p) => {
    shortcutsLog(`Shortcut triggered: ${p.accelerator}${p.action ? ' → ' + p.action : ''}`);
});

// ─── Autostart ──────────────────────────────────────────────────────────────

const autostartDemo = {
    refresh: () => handle('autostart:status', async () => {
        const result = await ipc.invoke('autostart.status');
        const el = $('autostart-status');
        if (el) {
            el.textContent = result.enabled ? 'Enabled ✓' : 'Disabled';
            el.style.background = result.enabled ? 'var(--accent)' : 'var(--code-bg)';
            el.style.color = result.enabled ? 'white' : 'var(--text)';
        }
    }),
    enable: () => handle('autostart:enable', async () => {
        await ipc.invoke('autostart.enable');
        autostartDemo.refresh();
        toast('Autostart enabled');
    }),
    disable: () => handle('autostart:disable', async () => {
        await ipc.invoke('autostart.disable');
        autostartDemo.refresh();
        toast('Autostart disabled');
    }),
};

// ─── Screen / Positioning ──────────────────────────────────────────────────

const screenDemo = {
    refresh: async () => {
        const screensEl = $('screen-list');
        const cursorEl = $('cursor-pos');
        if (!screensEl) return;
        try {
            const result = await ipc.invoke('screen.list');
            screensEl.textContent = JSON.stringify(result.screens, null, 2);
        } catch { screensEl.textContent = 'Screen info not available'; }
        try {
            const cursor = await ipc.invoke('screen.cursor');
            if (cursorEl) cursorEl.textContent = `x: ${cursor.x}, y: ${cursor.y}`;
        } catch { if (cursorEl) cursorEl.textContent = '—'; }
    },
    updateCursor: async () => {
        try {
            const cursor = await ipc.invoke('screen.cursor');
            const el = $('cursor-pos');
            if (el) el.textContent = `x: ${cursor.x}, y: ${cursor.y}`;
        } catch { }
    },
};

ipc.listen('screen:changed', () => {
    const el = $('screen-events');
    if (el) {
        el.textContent = `Screen config changed at ${new Date().toLocaleTimeString()}\n` + el.textContent;
    }
    screenDemo.refresh();
});

// Poll cursor position every 2s
setInterval(() => screenDemo.updateCursor(), 2000);

// ─── Auto-Updater ──────────────────────────────────────────────────────────

const updaterLog = (msg) => {
    const el = $('updater-log');
    if (el) el.textContent = msg + '\n' + el.textContent;
};

const updaterDemo = {
    check: async () => {
        handle('updater:check', async () => {
            const r = await ipc.invoke('updater.check');
            if (r.available) {
                updaterLog(`Update available: v${r.version} — ${r.release_notes}`);
            } else {
                updaterLog('No update available (you are on the latest version).');
            }
        });
    },
    install: async () => {
        handle('updater:install', async () => {
            const r = await ipc.invoke('updater.install');
            updaterLog(`Install: ${r.status}`);
        });
    },
    rollback: async () => {
        handle('updater:rollback', async () => {
            const r = await ipc.invoke('updater.rollback');
            updaterLog(`Rollback: ${r.status}`);
        });
    },
};

// ─── Enhanced Window ───────────────────────────────────────────────────────

const windowDemo = {
    refresh: async () => {
        const el = $('window-info');
        if (!el) return;
        try {
            const info = await ipc.invoke('window.info');
            el.textContent = JSON.stringify(info, null, 2);
        } catch { el.textContent = 'Window info not available'; }
    },
    setAlwaysOnTop: (v) => handle('window:top', () => ipc.invoke('window.set_always_on_top', v).then(() => windowDemo.refresh())),
    setOpacity: () => handle('window:opacity', async () => {
        const val = parseFloat($('window-opacity')?.value || '1.0');
        await ipc.invoke('window.set_opacity', val);
        windowDemo.refresh();
    }),
    setFrameless: (v) => handle('window:frameless', () => ipc.invoke('window.set_frameless', v).then(() => windowDemo.refresh())),
};

// ─── Device (Theme, DPI, Power, Idle) ───────────────────────────────────────

const device = {
    refresh: async () => {
        try {
            const theme = await ipc.invoke('theme.current');
            $('theme-info').textContent = theme.theme;
        } catch { $('theme-info').textContent = '—'; }
        try {
            const dpi = await ipc.invoke('display.info');
            $('dpi-scale').textContent = `${dpi.scale}x`;
            $('device-display').textContent = JSON.stringify(dpi, null, 2);
        } catch { $('dpi-scale').textContent = '—'; }
        try {
            const [power, onBattery] = await Promise.all([
                ipc.invoke('power.battery_info'),
                ipc.invoke('power.on_battery'),
            ]);
            if (power) {
                $('power-info').textContent = `level: ${power.level} · ${power.charging ? 'charging' : 'not charging'}${onBattery.on_battery ? ' · on battery' : ''}`;
            } else {
                $('power-info').textContent = onBattery.on_battery ? 'on battery (no details)' : 'AC power (no battery)';
            }
        } catch { $('power-info').textContent = '—'; }
        try {
            const [idleTime, idleStatus] = await Promise.all([
                ipc.invoke('system.idle_time'),
                ipc.invoke('system.idle?'),
            ]);
            $('idle-info').textContent = `${idleTime.seconds}s · ${idleStatus.idle ? 'idle' : 'active'}`;
        } catch { $('idle-info').textContent = '—'; }
    },
};

// ─── Safe Storage ───────────────────────────────────────────────────────────

const storageDemo = {
    refresh: async () => {
        const service = $('storage-service')?.value || 'Showcase';
        try {
            const result = await ipc.invoke('safe_storage.list', service);
            const keys = result.keys || [];
            const ul = $('storage-list');
            ul.innerHTML = '';
            if (keys.length === 0) {
                const li = document.createElement('li');
                li.textContent = 'No stored keys for this service.';
                li.style.color = 'var(--muted)';
                li.style.cursor = 'default';
                ul.appendChild(li);
                return;
            }
            keys.forEach(k => {
                const li = document.createElement('li');
                li.textContent = k;
                li.onclick = async () => {
                    const val = await ipc.invoke('safe_storage.get', [k, service]);
                    $('storage-out').textContent = val !== null ? `${k} = ${val}` : `${k} = (not found)`;
                };
                ul.appendChild(li);
            });
        } catch { /* service not available */ }
    },
    set: async () => {
        const key = $('storage-key')?.value;
        const val = $('storage-value')?.value;
        const service = $('storage-service')?.value || 'Showcase';
        if (!key || !val) return toast('Enter key and value', 'warn');
        await ipc.invoke('safe_storage.set', [key, val, service]);
        toast(`Stored: ${key}`);
        storageDemo.refresh();
    },
    get: async () => {
        const key = $('storage-get-key')?.value;
        const service = $('storage-service')?.value || 'Showcase';
        if (!key) return toast('Enter a key', 'warn');
        const val = await ipc.invoke('safe_storage.get', [key, service]);
        $('storage-out').textContent = val !== null ? val : '(not found)';
    },
    delete: async () => {
        const key = $('storage-get-key')?.value;
        const service = $('storage-service')?.value || 'Showcase';
        if (!key) return toast('Enter a key', 'warn');
        await ipc.invoke('safe_storage.delete', [key, service]);
        toast(`Deleted: ${key}`);
        $('storage-out').textContent = '—';
        storageDemo.refresh();
    },
};

// ─── File Watcher ───────────────────────────────────────────────────────────

const watcherLog = (msg) => {
    const el = $('watcher-log');
    if (el) el.textContent = msg + '\n' + el.textContent;
};

const watcherDemo = {
    refresh: async () => {
        try {
            const result = await ipc.invoke('fs.watchers');
            const paths = result.paths || [];
            const ul = $('watcher-paths');
            ul.innerHTML = '';
            if (paths.length === 0) {
                const li = document.createElement('li');
                li.textContent = 'No watched paths';
                li.style.color = 'var(--muted)';
                li.style.cursor = 'default';
                ul.appendChild(li);
                return;
            }
            paths.forEach(p => {
                const li = document.createElement('li');
                li.textContent = p;
                ul.appendChild(li);
            });
        } catch { /* watcher not available */ }
    },
    watch: async () => {
        const path = $('watcher-path')?.value || '/tmp';
        const recursive = $('watcher-recursive')?.checked || false;
        await ipc.invoke('fs.watch', [path, recursive]);
        watcherLog(`Watching: ${path}${recursive ? ' (recursive)' : ''}`);
        watcherDemo.refresh();
    },
    unwatch: async () => {
        const path = $('watcher-path')?.value || '/tmp';
        await ipc.invoke('fs.unwatch', path);
        watcherLog(`Stopped watching: ${path}`);
        watcherDemo.refresh();
    },
    clear: () => {
        const el = $('watcher-log');
        if (el) el.textContent = 'No events yet. Watch a directory to start.';
    },
};

ipc.listen('fs.changed', (p) => {
    watcherLog(`${p.type}: ${p.path}`);
});

// ─── Taskbar Progress ──────────────────────────────────────────────────────

const taskbarDemo = {
    setProgress: async () => {
        const val = parseFloat($('taskbar-progress')?.value || '0.5');
        await ipc.invoke('taskbar.set_progress', val);
        toast(`Progress set to ${val}`);
    },
    clearProgress: async () => {
        await ipc.invoke('taskbar.clear_progress');
        toast('Progress cleared');
    },
    setBadge: async () => {
        const text = $('taskbar-badge')?.value || '';
        await ipc.invoke('taskbar.set_badge', text);
        toast('Badge set');
    },
    clearBadge: async () => {
        await ipc.invoke('taskbar.set_badge', '');
        toast('Badge cleared');
    },
    setState: async () => {
        const state = $('taskbar-state')?.value || 'none';
        await ipc.invoke('taskbar.set_progress_state', state);
        toast(`Progress state: ${state}`);
    },
};

// ─── Hardware ────────────────────────────────────────────────────────────

const hardware = {
    enumerate: async (type, btn) => {
        document.querySelectorAll('[data-enum-btn]').forEach(b => b.classList.remove('active'));
        if (btn) btn.classList.add('active');
        try {
            const result = await ipc.invoke('hardware.enumerate', type);
            if (result && result.error) throw new Error(result.error);
            const devices = (result && result.devices) || [];
            const tbody = $('device-list');
            $('device-count').textContent = devices.length;
            if (devices.length === 0) {
                tbody.innerHTML = '<tr><td colspan="6">No devices found.</td></tr>';
            } else {
                tbody.innerHTML = devices.map(d =>
                    `<tr><td>${esc(d.name)}</td><td>${esc(d.id)}</td><td>${esc(d.vendor_id)}</td><td>${esc(d.product_id)}</td><td>${esc(d.api_type)}</td><td>${d.connected ? '✓' : '✗'}</td></tr>`
                ).join('');
            }
            toast(`Found ${devices.length} ${type} device(s)`);
        } catch (e) {
            $('device-list').innerHTML = `<tr><td colspan="6">Error: ${esc(e.message)}</td></tr>`;
            toast(`Hardware enumerate failed: ${e.message}`);
        }
    },
};

function esc(s) {
    if (!s) return '—';
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// ─── Permissions ──────────────────────────────────────────────────────────

const perms = {
    refresh: async () => {
        const cap = $('perm-capability').value;
        try {
            const result = await ipc.invoke('permissions.status', [cap, 'app://showcase']);
            $('perm-status').textContent = JSON.stringify(result, null, 2);
        } catch (e) {
            $('perm-status').textContent = `Error: ${e.message}`;
        }
    },
    request: async () => {
        const cap = $('perm-capability').value;
        try {
            const result = await ipc.invoke('permissions.request', [cap, 'app://showcase']);
            $('perm-status').textContent = JSON.stringify(result, null, 2);
            toast(`Permission "${cap}": ${result.state || result.status} (state tracking only, no OS prompt)`);
        } catch (e) {
            $('perm-status').textContent = `Error: ${e.message}`;
            toast(`Permission request failed: ${e.message}`);
        }
    },
    grant: async () => {
        const cap = $('perm-capability').value;
        try {
            await ipc.invoke('permissions.set_default', [cap, 'granted']);
            await perms.refresh();
            toast(`Permission "${cap}" set to Granted (default)`);
        } catch (e) { toast(`Grant failed: ${e.message}`); }
    },
    deny: async () => {
        const cap = $('perm-capability').value;
        try {
            await ipc.invoke('permissions.set_default', [cap, 'denied']);
            await perms.refresh();
            toast(`Permission "${cap}" set to Denied (default)`);
        } catch (e) { toast(`Deny failed: ${e.message}`); }
    },

    _mediaStream: null,

    testCamera: async () => {
        try {
            const diag = `location: ${location.href} | secure: ${window.isSecureContext} | mediaDevices: ${typeof navigator.mediaDevices}`;
            $('perm-live-status').textContent = diag;
            $('perm-video').style.display = 'none';
            if (perms._mediaStream) { perms.stopMedia(); }
            if (typeof navigator.mediaDevices === 'undefined') {
                throw new Error(`navigator.mediaDevices is undefined — page not in a secure context. ${diag}`);
            }
            const devices = await navigator.mediaDevices.enumerateDevices();
            const cams = devices.filter(d => d.kind === 'videoinput');
            if (cams.length === 0) {
                throw new Error('No camera device found on this system');
            }
            const stream = await navigator.mediaDevices.getUserMedia({ video: true });
            perms._mediaStream = stream;
            const video = $('perm-video');
            video.srcObject = stream;
            video.style.display = 'block';
            video.onloadedmetadata = () => video.play();
            $('perm-live-status').textContent = 'Camera active — OS permission granted.';
            toast('Camera stream started (OS dialog shown if first time)');
        } catch (e) {
            const msg = e.name === 'NotAllowedError' ? 'Camera permission denied by user or system' :
                e.name === 'NotFoundError' ? 'No camera device found on this system' :
                    e.message === 'Invalid constraint' ? `No camera found or invalid resolution` :
                        e.message;
            $('perm-live-status').textContent = `Camera failed: ${msg}`;
            toast(`Camera error: ${msg}`);
        }
    },

    testMic: async () => {
        try {
            $('perm-live-status').textContent = 'Requesting microphone...';
            $('perm-video').style.display = 'none';
            if (perms._mediaStream) { perms.stopMedia(); }
            const devices = await navigator.mediaDevices.enumerateDevices();
            const mics = devices.filter(d => d.kind === 'audioinput');
            if (mics.length === 0) {
                throw new Error('No microphone found on this system');
            }
            const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
            perms._mediaStream = stream;
            $('perm-live-status').textContent = 'Microphone active — OS permission granted.';
            toast('Microphone stream started (OS dialog shown if first time)');
        } catch (e) {
            const msg = e.name === 'NotAllowedError' ? 'Microphone permission denied by user or system' :
                e.name === 'NotFoundError' ? 'No microphone found on this system' :
                    e.message;
            $('perm-live-status').textContent = `Microphone failed: ${msg}`;
            toast(`Microphone error: ${msg}`);
        }
    },

    stopMedia: () => {
        if (perms._mediaStream) {
            perms._mediaStream.getTracks().forEach(t => t.stop());
            perms._mediaStream = null;
        }
        $('perm-video').srcObject = null;
        $('perm-video').style.display = 'none';
        $('perm-live-status').textContent = '';
    },
};

// ─── Window Effects ───────────────────────────────────────────────────────

const effects = {
    setVibrancy: async () => {
        try {
            await ipc.invoke('we.vibrancy', null);
            $('effects-status').textContent = 'Vibrancy';
            toast('Vibrancy effect applied');
        } catch (e) { toast(`Vibrancy failed: ${e.message}`); }
    },
    setMica: async () => {
        try {
            await ipc.invoke('we.mica');
            $('effects-status').textContent = 'Mica';
            toast('Mica effect applied');
        } catch (e) { toast(`Mica failed: ${e.message}`); }
    },
    setAcrylic: async () => {
        try {
            await ipc.invoke('we.acrylic');
            $('effects-status').textContent = 'Acrylic';
            toast('Acrylic effect applied');
        } catch (e) { toast(`Acrylic failed: ${e.message}`); }
    },
    setBlur: async () => {
        try {
            await ipc.invoke('we.blur');
            $('effects-status').textContent = 'Blur';
            toast('Blur effect applied');
        } catch (e) { toast(`Blur failed: ${e.message}`); }
    },
    clear: async () => {
        try {
            await ipc.invoke('we.clear');
            $('effects-status').textContent = 'None';
            toast('Effects cleared');
        } catch (e) { toast(`Clear failed: ${e.message}`); }
    },
};

// ─── Positioning ──────────────────────────────────────────────────────────

const positioning = {
    snap: async (corner) => {
        try {
            await ipc.invoke('positioning.snap', corner);
            toast(`Snapped to ${corner}`);
        } catch (e) { toast(`Snap failed: ${e.message}`); }
    },
    maximize: async () => {
        try {
            await ipc.invoke('positioning.maximize');
            toast('Maximized');
        } catch (e) { toast(`Maximize failed: ${e.message}`); }
    },
    displayInfo: async () => {
        try {
            const info = await ipc.invoke('positioning.display_count');
            const screen = await ipc.invoke('positioning.screen_info', 0);
            $('positioning-info').textContent = JSON.stringify(
                { count: info.count, screen0: screen }, null, 2
            );
        } catch (e) { toast(`Display info failed: ${e.message}`); }
    },
};

// ─── Kiosk Mode ─────────────────────────────────────────────────────────────

const kioskDemo = {
    refresh: async () => {
        try {
            const status = await ipc.invoke('window.is_kiosk');
            const el = $('kiosk-status');
            if (el) {
                el.textContent = status.kiosk ? 'active' : 'inactive';
                el.style.background = status.kiosk ? 'var(--accent)' : 'var(--code-bg)';
                el.style.color = status.kiosk ? 'white' : 'var(--text)';
            }
        } catch { }
    },
    enter: async () => {
        await ipc.invoke('window.enter_kiosk');
        kioskDemo.refresh();
        toast('Kiosk mode entered');
    },
    exit: async () => {
        await ipc.invoke('window.exit_kiosk');
        kioskDemo.refresh();
        toast('Kiosk mode exited');
    },
};

// ─── Speech ─────────────────────────────────────────────────────────────────

const speech = {
    voicesLoaded: false,
    voicesLoading: null,
    recognitionLanguagesLoaded: false,
    recognitionLanguagesLoading: null,
    initialized: false,
    initialize: async () => {
        speech.listVoices();
        speech.listRecognitionLanguages();
        if (speech.initialized) return;
        speech.initialized = true;
        try {
            const result = await ipc.invoke('speech.recognize_available');
            $('speech-recognition-status').textContent = result.available
                ? 'Native recognizer available'
                : 'Native recognition is unavailable on this system';
        } catch (e) {
            $('speech-recognition-status').textContent = `Availability error: ${e.message}`;
        }
    },
    listVoices: async (refresh = false) => {
        const el = $('speech-voice');
        if (!el) return;
        if (speech.voicesLoaded && !refresh) return;
        if (speech.voicesLoading) return speech.voicesLoading;

        speech.voicesLoading = (async () => {
            try {
                const result = await ipc.invoke('speech.list_voices');
                const voices = (result.voices || []).slice().sort((a, b) =>
                    `${a.name}\0${a.lang}\0${a.variant || ''}`.localeCompare(
                        `${b.name}\0${b.lang}\0${b.variant || ''}`,
                        undefined,
                        { sensitivity: 'base' },
                    )
                );
                const duplicateCounts = voices.reduce((counts, voice) => {
                    const key = `${voice.name}\0${voice.lang}`;
                    counts.set(key, (counts.get(key) || 0) + 1);
                    return counts;
                }, new Map());
                el.innerHTML = voices.map(v => {
                    const duplicate = duplicateCounts.get(`${v.name}\0${v.lang}`) > 1;
                    const variant = v.variant || (duplicate ? 'default' : '');
                    const details = [v.lang, variant && variant[0].toUpperCase() + variant.slice(1)].filter(Boolean);
                    return `<option value="${esc(v.id)}">${esc(v.name)} — ${esc(details.join(' · '))}</option>`;
                }).join('') || '<option value="">No voices available</option>';
                speech.voicesLoaded = true;
                toast(`Found ${voices.length} voices`);
            } catch (e) {
                toast(`List voices failed: ${e.message}`);
            } finally {
                speech.voicesLoading = null;
            }
        })();
        return speech.voicesLoading;
    },
    listRecognitionLanguages: async (refresh = false) => {
        const el = $('speech-recognition-language');
        const start = $('speech-recognition-start');
        if (!el) return;
        if (speech.recognitionLanguagesLoaded && !refresh) return;
        if (speech.recognitionLanguagesLoading) return speech.recognitionLanguagesLoading;

        const previous = el.value || 'en-US';
        el.disabled = true;
        if (start) start.disabled = true;
        speech.recognitionLanguagesLoading = (async () => {
            try {
                const result = await ipc.invoke('speech.recognize_languages');
                const languages = [...new Set(result.languages || [])].sort((a, b) =>
                    a.localeCompare(b, undefined, { sensitivity: 'base' })
                );
                el.innerHTML = languages.map(language =>
                    `<option value="${esc(language)}">${esc(language)}</option>`
                ).join('') || '<option value="">No recognition languages available</option>';

                const selected = languages.includes(previous)
                    ? previous
                    : languages.includes('en-US') ? 'en-US' : languages[0];
                if (selected) el.value = selected;
                el.disabled = languages.length === 0;
                if (start) start.disabled = languages.length === 0;
                speech.recognitionLanguagesLoaded = true;
                toast(`Found ${languages.length} recognition languages`);
            } catch (e) {
                el.innerHTML = '<option value="">Unable to load recognition languages</option>';
                el.disabled = true;
                if (start) start.disabled = true;
                toast(`List recognition languages failed: ${e.message}`);
            } finally {
                speech.recognitionLanguagesLoading = null;
            }
        })();
        return speech.recognitionLanguagesLoading;
    },
    speak: async () => {
        const text = $('speech-text')?.value;
        if (!text) return toast('Enter text to speak', 'warn');
        const voice = $('speech-voice')?.value;
        const rate = parseFloat($('speech-rate')?.value || '1.0');
        const pitch = parseFloat($('speech-pitch')?.value || '1.0');
        const volume = parseFloat($('speech-volume')?.value || '1.0');
        try {
            await ipc.invoke('speech.speak', [text, {
                voice: voice || '',
                rate,
                pitch,
                volume,
            }]);
            $('speech-status').textContent = 'Speaking…';
            toast('Speaking');
        } catch (e) {
            $('speech-status').textContent = `Error: ${e.message}`;
            toast(`Speech error: ${e.message}`);
        }
    },
    stop: async () => {
        try {
            await ipc.invoke('speech.stop');
            $('speech-status').textContent = 'Stopped';
            toast('Speech stopped');
        } catch (e) { toast(`Stop failed: ${e.message}`); }
    },
    requestRecognitionPermission: async () => {
        try {
            const result = await ipc.invoke('speech.recognize_request_permission');
            $('speech-recognition-status').textContent = `Permission: ${result.permission}`;
        } catch (e) {
            $('speech-recognition-status').textContent = `Permission error: ${e.message}`;
        }
    },
    startRecognition: async () => {
        const language = $('speech-recognition-language')?.value;
        if (!language) return toast('No recognition language is available', 'warn');
        try {
            await ipc.invoke('speech.recognize_start', [language, true]);
            $('speech-recognition-status').textContent = 'Listening…';
        } catch (e) {
            $('speech-recognition-status').textContent = `Start error: ${e.message}`;
        }
    },
    stopRecognition: async () => {
        try {
            await ipc.invoke('speech.recognize_stop');
            $('speech-recognition-status').textContent = 'Finishing…';
        } catch (e) {
            $('speech-recognition-status').textContent = `Stop error: ${e.message}`;
        }
    },
};

ipc.listen('speech.recognition_result', (result) => {
    $('speech-transcript').value = result.transcript;
    $('speech-recognition-status').textContent = result.final ? 'Final result' : 'Listening…';
});
ipc.listen('speech.recognition_error', (error) => {
    $('speech-recognition-status').textContent = `Recognition error: ${error.message}`;
});
ipc.listen('speech.recognition_end', () => {
    $('speech-recognition-status').textContent = 'Recognition ended';
});

// ─── Toolbar ─────────────────────────────────────────────────────────────────

const toolbarDemo = {
    initialize: () => handle('toolbar initialization', async () => {
        const {items} = await ipc.invoke('toolbar.items');
        if (items?.length) {
            toolbarDemo.render(items);
            return;
        }

        await ipc.invoke('toolbar.add_item', ['showcase-home', 'Overview', 'house']);
        await ipc.invoke('toolbar.add_item', ['showcase-notify', 'Notify', 'bell']);
        await ipc.invoke('toolbar.add_separator');
        await ipc.invoke('toolbar.add_toggle', ['showcase-active', 'Active', null, true]);
        await ipc.invoke('toolbar.add_dropdown', ['showcase-size', 'Size', null, ['Small', 'Medium', 'Large'], 1]);
        await toolbarDemo.listItems();
    }),
    addItem: () => handle('tb', async () => {
        const id = $('tb-id').value, label = $('tb-label').value, icon = $('tb-icon').value || null;
        await ipc.invoke('toolbar.add_item', [id, label, icon]);
        $('toolbar-out').textContent = `Added button: ${id}`;
    }),
    addToggle: () => handle('tb', async () => {
        const id = $('tb-toggle-id').value, label = $('tb-toggle-label').value, checked = $('tb-toggle-checked').checked;
        await ipc.invoke('toolbar.add_toggle', [id, label, null, checked]);
        $('toolbar-out').textContent = `Added toggle: ${id} (${checked ? 'on' : 'off'})`;
    }),
    addDropdown: () => handle('tb', async () => {
        const id = $('tb-dd-id').value, label = $('tb-dd-label').value;
        const opts = $('tb-dd-opts').value.split(',').map(s => s.trim()).filter(Boolean);
        await ipc.invoke('toolbar.add_dropdown', [id, label, null, opts, 0]);
        $('toolbar-out').textContent = `Added dropdown: ${id} [${opts.join(', ')}]`;
    }),
    addSep: () => handle('tb', async () => {
        await ipc.invoke('toolbar.add_separator');
        $('toolbar-out').textContent = 'Separator added';
    }),
    removeItem: () => handle('tb', async () => {
        await ipc.invoke('toolbar.remove_item', $('tb-remove').value);
        $('toolbar-out').textContent = `Removed: ${$('tb-remove').value}`;
    }),
    clear: () => handle('tb', async () => {
        await ipc.invoke('toolbar.clear');
        $('toolbar-out').textContent = 'Cleared';
    }),
    listItems: () => handle('tb', async () => {
        const {items} = await ipc.invoke('toolbar.items');
        toolbarDemo.render(items);
    }),
    render: (items) => {
        if (!items || items.length === 0) {
            $('toolbar-out').textContent = '(empty)';
            return;
        }
        const lines = items.map((item, i) => {
            let line = `${i + 1}. [${item.type}] ${item.id} "${item.label}"`;
            if (item.type === 'toggle') line += ` checked=${item.checked}`;
            if (item.type === 'dropdown') line += ` options=[${item.options.join(',')}] selected=${item.selected_index}`;
            if (!item.enabled) line += ' (disabled)';
            return line;
        });
        $('toolbar-out').textContent = lines.join('\n');
    },
};

ipc.listen('toolbar.click', ({item_id}) => {
    if (item_id === 'showcase-home') {
        document.querySelector('.tab[data-tab="overview"]')?.click();
    } else if (item_id === 'showcase-notify') {
        api.notify('Showcase toolbar', 'Native toolbar action received');
    }
    toast(`Toolbar clicked: ${item_id}`);
});

ipc.listen('toolbar.dropdown_selected', ({item_id}) => {
    toast(`Toolbar dropdown selected: ${item_id}`);
});

// ─── Cookies ──────────────────────────────────────────────────────────────────

const cookieDemo = {
    set: () => handle('cookie', async () => {
        await ipc.invoke('cookie.set', [$('ck-key').value, $('ck-val').value]);
        $('cookie-out').textContent = `Set: ${$('ck-key').value}`;
    }),
    get: () => handle('cookie', async () => {
        const v = await ipc.invoke('cookie.get', $('ck-key').value);
        $('cookie-out').textContent = `${$('ck-key').value} = ${v ?? '(not found)'}`;
    }),
    delete: () => handle('cookie', async () => {
        await ipc.invoke('cookie.delete', $('ck-key').value);
        $('cookie-out').textContent = `Deleted: ${$('ck-key').value}`;
    }),
    all: () => handle('cookie', async () => {
        const r = await ipc.invoke('cookie.all');
        $('cookie-out').textContent = JSON.stringify(r, null, 2);
    }),
};

// ─── Printing ─────────────────────────────────────────────────────────────────

const printingDemo = {
    print: () => handle('print', () => ipc.invoke('printing.print', [{}]).then(() => $('printing-out').textContent = 'Print dialog closed')),
    toPdf: () => handle('print', async () => {
        const r = await ipc.invoke('printing.print_to_pdf', ['/tmp/demo.pdf', {}]);
        $('printing-out').textContent = r.path ? `PDF saved: ${r.path}` : JSON.stringify(r);
    }),
    listPrinters: () => handle('print', async () => {
        const r = await ipc.invoke('printing.list_printers');
        $('printing-out').textContent = JSON.stringify(r, null, 2);
    }),
    showDialog: () => handle('print', async () => {
        const r = await ipc.invoke('printing.show_dialog', [{}]);
        $('printing-out').textContent = JSON.stringify(r, null, 2);
    }),
};

// ─── Display ──────────────────────────────────────────────────────────────────

const displayDemo = {
    info: () => handle('display', async () => {
        const [list, count, primary] = await Promise.all([
            ipc.invoke('display.list'),
            ipc.invoke('display.count'),
            ipc.invoke('display.primary'),
        ]);
        $('display-out').textContent = JSON.stringify({ count, primary, displays: list }, null, 2);
    }),
};

// ─── Resources ────────────────────────────────────────────────────────────────

const resourcesDemo = {
    getDir: () => handle('resources', async () => {
        const r = await ipc.invoke('resources.get_dir');
        $('resources-out').textContent = r.dir || JSON.stringify(r);
    }),
    resolve: () => handle('resources', async () => {
        const r = await ipc.invoke('resources.resolve', 'app.js');
        $('resources-out').textContent = r.path || JSON.stringify(r);
    }),
};

// ─── Draggable Region ─────────────────────────────────────────────────────────

const draggableDemo = {
    enable: () => handle('drag', () => ipc.invoke('window.enable_drag_region').then(() => $('draggable-out').textContent = 'Drag region enabled')),
    disable: () => handle('drag', () => ipc.invoke('window.disable_drag_region').then(() => $('draggable-out').textContent = 'Drag region disabled')),
};

// ─── Navigation ───────────────────────────────────────────────────────────────

const navDemo = {
    setHandler: () => handle('nav', async () => {
        const url = $('nav-url').value;
        await ipc.invoke('window.set_navigation_handler', url);
        $('navigation-out').textContent = `Handler set for: ${url}`;
    }),
    clearHandler: () => handle('nav', () => ipc.invoke('window.clear_navigation_handler').then(() => $('navigation-out').textContent = 'Handler cleared')),
};

// ─── Sidecar ──────────────────────────────────────────────────────────────────

const sidecarDemo = {
    execute: () => handle('sidecar', async () => {
        const name = $('sidecar-name').value;
        const r = await ipc.invoke('sidecar.execute', [name, {}]);
        $('sidecar-out').textContent = JSON.stringify(r, null, 2);
    }),
    list: () => handle('sidecar', async () => {
        const r = await ipc.invoke('sidecar.list');
        $('sidecar-out').textContent = JSON.stringify(r, null, 2);
    }),
};

// ─── Drag Source ──────────────────────────────────────────────────────────────

const dragSourceDemo = {
    startText: (event) => handle('ds', async () => {
        dragSourceDemo.begin(event);
        const text = $('ds-text').value;
        const r = await ipc.invoke('drag_source.start_text', text);
        dragSourceDemo.report('text', text, r);
    }),
    startFile: (event) => handle('ds', async () => {
        dragSourceDemo.begin(event);
        const path = $('ds-file').value;
        const r = await ipc.invoke('drag_source.start_file', path);
        dragSourceDemo.report('file', path, r);
    }),
    startUrl: (event) => handle('ds', async () => {
        dragSourceDemo.begin(event);
        const url = $('ds-url').value;
        const r = await ipc.invoke('drag_source.start_url', url);
        dragSourceDemo.report('url', url, r);
    }),
    begin: (event) => {
        event?.preventDefault();
        $('dragsource-out').textContent = 'Starting native drag... keep holding the mouse button and move the pointer.';
    },
    report: (type, value, result) => {
        $('dragsource-out').textContent = JSON.stringify({ type, value, ...result }, null, 2);
    },
};

// ─── DevTools ─────────────────────────────────────────────────────────────────

const devtoolsDemo = {
    open: () => handle('devtools', async () => {
        const r = await ipc.invoke('devtools.open');
        $('devtools-out').textContent = r.status || 'opened';
    }),
    close: () => handle('devtools', async () => {
        const r = await ipc.invoke('devtools.close');
        $('devtools-out').textContent = r.status || 'closed';
    }),
    toggle: () => handle('devtools', async () => {
        const r = await ipc.invoke('devtools.toggle');
        $('devtools-out').textContent = r.status || 'toggled';
    }),
    status: () => handle('devtools', async () => {
        const r = await ipc.invoke('devtools.status');
        $('devtools-out').textContent = JSON.stringify(r, null, 2);
    }),
};

// ─── Window State ─────────────────────────────────────────────────────────────

const wsDemo = {
    save: () => handle('ws', async () => {
        const key = $('ws-key').value;
        const r = await ipc.invoke('ws.save', key);
        $('ws-out').textContent = JSON.stringify(r, null, 2);
    }),
    restore: () => handle('ws', async () => {
        const key = $('ws-key').value;
        const r = await ipc.invoke('ws.restore', key);
        $('ws-out').textContent = JSON.stringify(r, null, 2);
    }),
    saveAll: () => handle('ws', async () => {
        const r = await ipc.invoke('ws.save_all');
        $('ws-out').textContent = JSON.stringify(r, null, 2);
    }),
};

// ─── Drag Drop (event log) ───────────────────────────────────────────────────

const dragDropDemo = {
    overCount: 0,
    clear: () => {
        dragDropDemo.overCount = 0;
        $('dragdrop-over').textContent = 'No drag in progress.';
        $('dragdrop-log').textContent = 'No events yet.';
    },
    updateOver: (p) => {
        dragDropDemo.overCount += 1;
        const files = p.files?.length ? `${p.files.length} file(s)` : 'no files';
        const text = p.text ? 'text available' : 'text pending';
        $('dragdrop-over').textContent = `over #${dragDropDemo.overCount}: ${files}, ${text}`;
    },
    logDrop: (p) => {
        const el = $('dragdrop-log');
        const current = el.textContent === 'No events yet.' ? '' : el.textContent;
        el.textContent = `drop: ${JSON.stringify(p)}\n${current}`;
    },
};

ipc.listen('drag.over', (p) => {
    if ($('dragdrop-over')) dragDropDemo.updateOver(p);
});
ipc.listen('drag.drop', (p) => {
    if ($('dragdrop-log')) dragDropDemo.logDrop(p);
});

// ─── Boot ───────────────────────────────────────────────────────────────────

api.loadSystem();
files.list();
recents.refresh();

// Load shortcuts list on startup
setTimeout(() => shortcutsDemo.refresh(), 500);

// Load autostart status on startup
setTimeout(() => autostartDemo.refresh(), 600);

// Populate the plugin-owned native toolbar after the frontend bridge is ready.
setTimeout(() => toolbarDemo.initialize(), 700);
