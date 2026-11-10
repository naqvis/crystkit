const ipc = window.__CRYSTKIT_IPC__;
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function fmtTime(iso) {
  if (!iso) return "";
  const d = new Date(iso + "Z");
  const now = new Date();
  const diff = now - d;
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return "now";
  if (mins < 60) return `${mins}m`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h`;
  const days = Math.floor(hrs / 24);
  if (days < 7) return `${days}d`;
  return d.toLocaleDateString();
}

function truncate(text, max = 100) {
  return text && text.length > max ? text.slice(0, max) + "\u2026" : text || "";
}

// ── Notifications ─────────────────────────────────────────────────────────

let toastTimer = null;

function toast(msg, kind = "info") {
  const t = $("toast");
  t.textContent = msg;
  t.className = `toast show ${kind}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.className = "toast"; }, 2000);
}

// ── IPC call ──────────────────────────────────────────────────────────────

async function call(cmd, args) {
  try {
    return await ipc.invoke(cmd, args);
  } catch (err) {
    const msg = (err && err.message) || String(err);
    toast(`${cmd}: ${msg}`, "err");
    throw err;
  }
}

let items = [];
let selectedIdx = 0;
let favOnly = false;
let searchQuery = "";

async function loadHistory() {
  try {
    items = await call("clipvault.history", [searchQuery || null, favOnly]) || [];
  } catch {
    items = [];
  }
  if (selectedIdx >= items.length) selectedIdx = items.length - 1;
  renderList();
}

// ── Image cache ──────────────────────────────────────────────────────────

const imageCache = new Map();

async function loadImage(id) {
  if (imageCache.has(id)) return imageCache.get(id);
  const res = await call("clipvault.image", id);
  const dataUrl = res?.data ? `data:image/png;base64,${res.data}` : null;
  imageCache.set(id, dataUrl);
  return dataUrl;
}

// ── List rendering ──────────────────────────────────────────────────────

function renderList() {
  const list = $("clipList");
  const empty = $("emptyState");
  const existing = list.querySelectorAll(".clip-item");
  for (let i = 0; i < existing.length; i++) { existing[i].remove(); }

  if (items.length === 0) {
    empty.style.display = "flex";
    return;
  }
  empty.style.display = "none";

  for (let idx = 0; idx < items.length; idx++) {
    const item = items[idx];
    const div = document.createElement("div");
    div.className = "clip-item" + (idx === selectedIdx ? " selected" : "");
    div.dataset.index = idx;
    div.dataset.id = item.id;

    const contentType = item.contentType || "text";
    const isFav = item.favorite === 1 || item.favorite === true;

    let contentHtml;
    if (contentType === "image") {
      const cached = imageCache.get(item.id);
      if (cached) {
        contentHtml = `<img src="${cached}" class="clip-item-thumb" />`;
      } else {
        contentHtml = `<span style="color:var(--muted);font-size:12px">\uD83D\uDDBC</span>`;
        loadImage(item.id).then((url) => { if (url) renderList(); });
      }
    } else {
      contentHtml = `<div class="clip-item-preview">${esc(item.preview || truncate(item.content, 100))}</div>`;
    }

    div.innerHTML = `
      ${isFav ? '<span class="clip-item-fav">\u2605</span>' : ''}
      <div class="clip-item-content">
        ${contentHtml}
        <div class="clip-item-meta">
          <span class="clip-item-type type-${esc(contentType)}">${esc(contentType.toUpperCase())}</span>
          <span>${fmtTime(item.lastCopiedAt)}</span>
          ${item.copyCount > 0 ? `<span class="clip-item-copy-count">\u00d7${item.copyCount}</span>` : ""}
        </div>
      </div>
      ${idx < 9 ? `<div class="clip-item-shortcut">\u2318${idx + 1}</div>` : ""}
    `;

    div.addEventListener("click", (e) => {
      selectItem(idx);
      copyItem(item);
    });

    list.appendChild(div);
  }

  const sel = list.querySelector(".clip-item.selected");
  if (sel) sel.scrollIntoView({ block: "nearest" });
}

function selectItem(idx) {
  const els = document.querySelectorAll(".clip-item");
  for (let i = 0; i < els.length; i++) { els[i].classList.remove("selected"); }
  selectedIdx = idx;
  const el = document.querySelector(`.clip-item[data-index="${idx}"]`);
  if (el) el.classList.add("selected");
}

async function copyItem(item) {
  try {
    await call("clipvault.skip_once");
    if (item.contentType === "image") {
      const res = await call("clipvault.image", item.id);
      if (!res?.data) { toast("Image not available", "err"); return; }
      await call("clipboard.write_image", res.data);
    } else {
      await call("clipboard.write_text", item.content);
    }
    item.copyCount = (item.copyCount || 0) + 1;
    call("clipvault.increment_copy", item.id);
    renderList();
    toast("Copied", "ok");
    ipc.emit("panel:hide", {});
  } catch (err) {
    toast("Copy failed", "err");
  }
}

async function toggleFav(item) {
  try {
    const res = await call("clipvault.favorite", item.id);
    item.favorite = res.favorite ? 1 : 0;
    renderList();
  } catch {}
}

async function deleteItem(item, idx) {
  try {
    await call("clipvault.delete", item.id);
    items.splice(idx, 1);
    if (selectedIdx >= items.length) selectedIdx = items.length - 1;
    renderList();
    toast("Deleted");
  } catch {}
}

async function clearAll() {
  try {
    const ok = await call("dialog.confirm", { title: "ClipVault", message: "Clear all history?" });
    if (!ok) return;
    await call("clipvault.clear");
    items = [];
    selectedIdx = -1;
    imageCache.clear();
    renderList();
    toast("History cleared", "ok");
  } catch {}
}

async function exportData() {
  try {
    const data = await call("clipvault.export");
    const blob = new Blob([JSON.stringify(data)], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `clipvault-${new Date().toISOString().slice(0, 10)}.json`;
    a.click();
    URL.revokeObjectURL(url);
    toast("Exported", "ok");
  } catch {}
}

async function importData() {
  const input = document.createElement("input");
  input.type = "file";
  input.accept = ".json";
  input.addEventListener("change", async () => {
    const file = input.files[0];
    if (!file) return;
    try {
      const text = await file.text();
      JSON.parse(text);
      const res = await call("clipvault.import", text);
      toast(`Imported ${res.imported} items`, "ok");
      loadHistory();
    } catch (err) {
      toast("Import failed", "err");
    }
  });
  input.click();
}

// ── Settings (Preferences) ────────────────────────────────────────────────

let settingsOpen = false;

function toggleSettings(open) {
  settingsOpen = open !== undefined ? open : !settingsOpen;
  $("settingsPanel").classList.toggle("open", settingsOpen);
}

$("panelClose").addEventListener("click", () => toggleSettings(false));

async function loadSettings() {
  try {
    const theme = await call("clipvault.setting", ["theme", null]);
    const maxItems = await call("clipvault.setting", ["max_items", null]);
    const shortcut = await call("clipvault.setting", ["shortcut", null]);
    $("themeSelect").value = theme.value || "dark";
    $("maxItemsInput").value = parseInt(maxItems.value || "500");
    $("shortcutInput").value = shortcut.value || "Meta+Shift+V";
  } catch {}
}

$("themeSelect").addEventListener("change", async () => {
  const val = $("themeSelect").value;
  await call("clipvault.setting", ["theme", val]);
  applyTheme(val);
});

$("maxItemsInput").addEventListener("change", async () => {
  const val = parseInt($("maxItemsInput").value);
  if (val >= 50 && val <= 5000) {
    await call("clipvault.setting", ["max_items", String(val)]);
    toast("Max items updated", "ok");
  }
});

// ── Shortcut key capture ────────────────────────────────────────────────

const SHORTCUT_KEY_MAP = {
  "ArrowLeft": "Left", "ArrowRight": "Right", "ArrowUp": "Up", "ArrowDown": "Down",
  " ": "Space", "Escape": "Escape", "Tab": "Tab", "Enter": "Enter",
  "Backspace": "Backspace", "Delete": "Delete", "Home": "Home", "End": "End",
  "PageUp": "PageUp", "PageDown": "PageDown",
};

function formatShortcut(e) {
  const parts = [];
  if (e.metaKey) parts.push("Meta");
  if (e.ctrlKey) parts.push("Ctrl");
  if (e.altKey) parts.push("Alt");
  if (e.shiftKey) parts.push("Shift");

  let key = e.key;
  if (key in SHORTCUT_KEY_MAP) key = SHORTCUT_KEY_MAP[key];

  // Skip bare modifier presses
  if (["Meta", "Shift", "Control", "Alt"].includes(key)) return null;

  parts.push(key);
  return parts.join("+");
}

let recordingShortcut = false;
const shortcutInput = $("shortcutInput");

shortcutInput.addEventListener("focus", () => {
  recordingShortcut = true;
  shortcutInput.classList.add("recording");
  shortcutInput.value = "";
  shortcutInput.placeholder = "press shortcut...";
});

shortcutInput.addEventListener("blur", () => {
  recordingShortcut = false;
  shortcutInput.classList.remove("recording");
  if (!shortcutInput.value) {
    // restore saved value
    loadSettings();
  }
});

shortcutInput.addEventListener("keydown", (e) => {
  if (!recordingShortcut) return;
  e.preventDefault();
  e.stopPropagation();

  const acc = formatShortcut(e);
  if (!acc) return;

  shortcutInput.value = acc;
  shortcutInput.placeholder = "";
});

shortcutInput.addEventListener("keyup", (e) => {
  if (!recordingShortcut) return;
  e.preventDefault();
  e.stopPropagation();

  if (e.key === "Enter" && shortcutInput.value) {
    const val = shortcutInput.value;
    recordingShortcut = false;
    shortcutInput.blur();
    call("clipvault.setting", ["shortcut", val]);
    call("shortcuts.unregister_all");
    call("shortcuts.register", val);
    toast("Shortcut updated", "ok");
  }
});

$("exportBtn").addEventListener("click", exportData);
$("importBtn").addEventListener("click", importData);

// ── Theme ───────────────────────────────────────────────────────────────

function applyTheme(theme) {
  const html = document.documentElement;
  if (theme === "system") {
    html.dataset.theme = window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  } else {
    html.dataset.theme = theme;
  }
}

async function initTheme() {
  try {
    const res = await call("clipvault.setting", ["theme", null]);
    applyTheme(res.value || "dark");
    $("themeSelect").value = res.value || "dark";
  } catch { applyTheme("dark"); }
}

window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if ($("themeSelect").value === "system") applyTheme("system");
});

// ── Footer buttons ─────────────────────────────────────────────────────

$("clearBtn").addEventListener("click", clearAll);

$("prefsBtn").addEventListener("click", () => {
  loadSettings();
  toggleSettings(true);
});

$("aboutBtn").addEventListener("click", () => {
  call("dialog.message", { title: "About ClipVault", message: "ClipVault 2.0.0\nA Crystal clipboard manager with NSPanel", kind: "info" });
});

$("quitBtn").addEventListener("click", () => {
  ipc.emit("clipvault:quit", {});
});

// ── Window resize ───────────────────────────────────────────────────────

window.addEventListener("resize", () => {
  ipc.emit("panel:resize", { width: window.innerWidth, height: window.innerHeight });
});

// ── Search ──────────────────────────────────────────────────────────────

let searchTimer = null;
$("searchInput").addEventListener("input", () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => {
    searchQuery = $("searchInput").value.trim();
    selectedIdx = 0;
    loadHistory();
  }, 150);
});

// ── Keyboard Navigation ─────────────────────────────────────────────────

document.addEventListener("keydown", (e) => {
  if (settingsOpen) {
    if (e.key === "Escape") { toggleSettings(false); return; }
    return;
  }
  if (items.length === 0 && e.key !== "Escape") return;

  if (e.key === "Escape") {
    ipc.emit("panel:hide", {});
    return;
  }

  if (e.key === "ArrowDown") {
    e.preventDefault();
    const next = Math.min(selectedIdx + 1, items.length - 1);
    selectItem(next);
    const el = document.querySelector(`.clip-item[data-index="${next}"]`);
    if (el) el.scrollIntoView({ block: "nearest" });
  } else if (e.key === "ArrowUp") {
    e.preventDefault();
    const prev = Math.max(selectedIdx - 1, 0);
    selectItem(prev);
    const el = document.querySelector(`.clip-item[data-index="${prev}"]`);
    if (el) el.scrollIntoView({ block: "nearest" });
  } else if (e.key === "Enter" && selectedIdx >= 0) {
    e.preventDefault();
    copyItem(items[selectedIdx]);
  } else if (e.key === "Delete" || e.key === "Backspace") {
    if (selectedIdx >= 0) { deleteItem(items[selectedIdx], selectedIdx); }
  } else if (e.key === "f" && (e.metaKey || e.ctrlKey)) {
    e.preventDefault();
    $("searchInput").focus();
    $("searchInput").select();
  }
});

// ── Backend Events ──────────────────────────────────────────────────────

ipc.listen("clipboard:new", (data) => {
  if (favOnly && !data.favorite) return;
  if (searchQuery && !(data.content || data.preview || "").toLowerCase().includes(searchQuery.toLowerCase())) return;

  const idx = items.findIndex(i => i.id === data.id);
  if (idx >= 0) {
    items[idx] = data;
    const item = items.splice(idx, 1)[0];
    items.unshift(item);
  } else {
    items.unshift(data);
    if (items.length > 500) items.pop();
  }
  renderList();
});

ipc.listen("menu:settings", () => {
  loadSettings();
  toggleSettings(true);
});

ipc.listen("menu:toggle_dark", async () => {
  const res = await call("clipvault.setting", ["theme", null]);
  const next = (res.value || "dark") === "dark" ? "light" : "dark";
  await call("clipvault.setting", ["theme", next]);
  $("themeSelect").value = next;
  applyTheme(next);
});

ipc.listen("shortcuts.triggered", () => {
  ipc.emit("panel:toggle", {});
});

ipc.listen("shortcut:focus", () => { $("searchInput").focus(); });

ipc.listen("shortcut:copy_index", async (data) => {
  if (items.length > data.index) {
    selectItem(data.index);
    await copyItem(items[data.index]);
  }
});

// ── Init ────────────────────────────────────────────────────────────────

initTheme();
loadHistory();
$("searchInput").focus();

// Register stored global shortcut via Shortcuts plugin
call("clipvault.setting", ["shortcut", null]).then((res) => {
  const acc = res.value || "Meta+Shift+V";
  call("shortcuts.register", acc).then(() => {
    call("shortcuts.start_listening");
  });
});
