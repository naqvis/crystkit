const ipc = window.__CRYSTKIT_IPC__;

// ─── State ────────────────────────────────────────────────────────────────
let disks = [];
let scanData = null;
let currentDirEntry = null;
let scanning = false;
let scanPath = null;
let scanUsed = 0;
let deleteInProgress = false;
let ctxPath = null;
let dupGroups = [];
let dupPaths = new Set();        // full paths flagged as duplicates
const collected = new Map();   // path -> {name, path, size, type}
const nodeCache = new Map();   // path -> DirEntry (measured or list_dir result)
const measuringPaths = new Set(); // paths with an in-flight diskpie.measure call
let measureTimer = null;        // debounce handle for depth-1 background measure

// MIME coloring (by file extension / type)
const MIME = {
  video:   { c: "#ff5d6b", l: "Video" },
  image:   { c: "#f0a93b", l: "Images" },
  code:    { c: "#5b8def", l: "Code" },
  doc:     { c: "#3ddc97", l: "Documents" },
  archive: { c: "#8b5cf6", l: "Archives" },
  app:     { c: "#ec4899", l: "Apps" },
  system:  { c: "#64748b", l: "System" },
};
const DIR_PALETTE = ["#3a5a9f", "#5b8def", "#8b5cf6", "#3ddc97", "#f0a93b", "#ec4899", "#06b6d4", "#f97316"];

function mimeFor(name) {
  const lower = (name || "").toLowerCase();
  if (lower.endsWith(".mov") || lower.endsWith(".mp4") || lower.endsWith(".mkv") ||
      lower.endsWith(".avi") || lower.endsWith(".webm")) return "video";
  if (lower.endsWith(".png") || lower.endsWith(".jpg") || lower.endsWith(".jpeg") ||
      lower.endsWith(".gif") || lower.endsWith(".dng") || lower.endsWith(".raw") ||
      lower.endsWith(".heic")) return "image";
  if (lower.endsWith(".cr") || lower.endsWith(".js") || lower.endsWith(".ts") ||
      lower.endsWith(".rb") || lower.endsWith(".py") || lower.endsWith(".c") ||
      lower.endsWith(".h") || lower.endsWith(".rs") || lower.endsWith(".go")) return "code";
  if (lower.endsWith(".md") || lower.endsWith(".txt") || lower.endsWith(".pdf") ||
      lower.endsWith(".doc") || lower.endsWith(".pages")) return "doc";
  if (lower.endsWith(".zip") || lower.endsWith(".dmg") || lower.endsWith(".tar") ||
      lower.endsWith(".gz") || lower.endsWith(".7z") || lower.endsWith(".rar")) return "archive";
  if (lower.endsWith(".app") || lower.endsWith(".exe") || lower.endsWith(".dll")) return "app";
  return "system";
}

const FOLDER_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="#7aa7ff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7z" fill="rgba(122,167,255,.18)"/></svg>';
// Per-type glyphs keep the MIME color tint but use a recognizable shape.
const FILE_GLYPH = {
  video:    '<path d="M4 5h16v14H4z" fill="C22"/><path d="M10 9l5 3-5 3z" fill="C"/>',
  image:    '<rect x="4" y="5" width="16" height="14" rx="2" fill="C22"/><circle cx="9" cy="10" r="1.6" fill="C"/><path d="M5 17l4-4 3 3 3-3 4 4" fill="none"/>',
  code:     '<path d="M9 8l-4 4 4 4M15 8l4 4-4 4" fill="none"/>',
  doc:      '<path d="M6 3h8l4 4v14H6z" fill="C22"/><path d="M14 3v4h4"/><path d="M8 12h8M8 15h8M8 18h5" fill="none"/>',
  archive:  '<path d="M6 3h12v18H6z" fill="C22"/><path d="M9 3v3h6V3M9 21v-3h6v3M12 6v12" fill="none"/>',
  app:      '<path d="M6 3h12v18H6z" fill="C22"/><path d="M12 8v8M8 12h8" fill="none"/>',
  system:   '<path d="M6 3h12v18H6z" fill="C22"/><path d="M14 3v4h4" fill="none"/>',
};
function fileSvg(name) {
  const m = MIME[mimeFor(name)];
  const col = m ? m.c : "#8a93a6";
  const glyph = FILE_GLYPH[m ? m.l : "system"] || FILE_GLYPH.system;
  return '<svg viewBox="0 0 24 24" fill="none" stroke="' + col + '" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
    glyph.replace(/C22/g, col + "22").replace(/C/g, col) + '</svg>';
}
function iconFor(n, isDir) {
  return isDir ? FOLDER_SVG : fileSvg(n.name);
}

function formatSize(bytes) {
  if (bytes == null || bytes === 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.min(Math.floor(Math.log(Math.abs(bytes)) / Math.log(1024)), units.length - 1);
  return (bytes / Math.pow(1024, i)).toFixed(i ? 1 : 0) + " " + units[i];
}

function formatSizeFull(bytes) {
  if (!bytes) return "0 B";
  const gb = bytes / 1e9;
  const tb = bytes / 1e12;
  if (tb >= 1) return tb.toFixed(2) + " TB";
  if (gb >= 1) return gb.toFixed(1) + " GB";
  return formatSize(bytes);
}

function esc(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// ─── Top bar (built at runtime, kept out of index.html for clarity) ───
const topbar = document.createElement("div");
topbar.className = "topbar";
topbar.innerHTML =
  '<div class="brand" id="brand-home" title="Back to drives"><div class="mk"></div>DiskPie</div>' +
  '<div class="crumb" id="crumb" style="display:none"></div>' +
  '<button class="btn ghost" id="btn-rescan" style="display:none">&#8635; Rescan</button>' +
  '<button class="btn primary" id="btn-find-duplicates" style="display:none">Find Duplicates</button>';
document.body.insertBefore(topbar, document.body.firstChild);

// ─── Views ────────────────────────────────────────────────────────────
function showResults() {
  document.getElementById("launch").style.display = "none";
  document.getElementById("results").classList.add("on");
  document.getElementById("btn-rescan").style.display = "inline-flex";
  document.getElementById("btn-find-duplicates").style.display = "inline-flex";
  document.getElementById("crumb").style.display = "flex";
}
function showLaunch() {
  document.getElementById("launch").style.display = "block";
  document.getElementById("results").classList.remove("on");
  document.getElementById("btn-rescan").style.display = "none";
  document.getElementById("btn-find-duplicates").style.display = "none";
  document.getElementById("crumb").style.display = "none";
}

// ─── Disk List ──────────────────────────────────────────────────────────
async function loadDisks() {
  try {
    disks = await ipc.invoke("diskpie.list_mounts");
    renderDiskList();
  } catch (e) {
    console.error("Failed to list disks:", e);
  }
}

function renderDiskList() {
  const grid = document.getElementById("drive-grid");
  grid.innerHTML = "";
  disks.forEach((disk) => {
    const used = disk.total_space - disk.available_space;
    const usedPct = disk.total_space > 0 ? (used / disk.total_space) * 100 : 0;
    const warn = usedPct > 90 ? "full" : usedPct > 75 ? "warn" : "";
    const el = document.createElement("div");
    el.className = "card";
    const stroke = disk.removable ? "#f0a93b" : "#5b8def";
    el.innerHTML =
      '<div class="top">' +
        '<div class="ic"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="' + stroke + '" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="2.5"/><path d="M12 3v18M3 12h18"/></svg></div>' +
        '<div class="tinfo"><div class="nm">' + esc(disk.name) + '</div><div class="mp">' + esc(disk.mount_point) + '</div></div>' +
      '</div>' +
      (disk.removable ? '<span class="pill removable">REMOVABLE</span>' : '') +
      '<span class="pill pct">' + Math.round(usedPct) + '% USED</span>' +
      '<div class="usage"><span><b>' + formatSizeFull(used) + '</b> used</span><span>of ' + formatSizeFull(disk.total_space) + '</span></div>' +
      '<div class="bar ' + warn + '"><i style="width:' + usedPct + '%"></i></div>';
    el.addEventListener("click", () => startScan(disk.mount_point, used));
    grid.appendChild(el);
  });

  const fc = document.createElement("div");
  fc.className = "card folder";
  fc.innerHTML =
    '<svg width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 01-2 2H4a2 2 0 01-2-2V5a2 2 0 012-2h5l2 3h9a2 2 0 012 2z"/></svg>' +
    '<div>Choose a folder<br><small>scan a specific directory</small></div>';
  fc.addEventListener("click", pickFolder);
  grid.appendChild(fc);
}

async function pickFolder() {
  try {
    const dir = await ipc.invoke("dialog.select_folder", { title: "Select a folder to scan" });
    if (dir) startScan(dir, 0);
  } catch (e) {
    console.error(e);
  }
}

// ─── Scan (lazy) ─────────────────────────────────────────────────────────
// Landing/drill-in is instant via `diskpie.list_dir` (direct children only).
// Folder cumulative sizes are then filled by a debounced depth-1 background
// `diskpie.measure` of the *current* view's child directories — cheap, and
// never walks branches the user hasn't opened.
async function startScan(path, usedBytes) {
  if (scanning) return;
  scanning = true;
  scanPath = path;
  scanUsed = usedBytes || 0;
  document.getElementById("scan-path").textContent = path;
  document.getElementById("scan-percent").textContent = "Reading…";
  const overlay = document.getElementById("scan-overlay");
  overlay.classList.add("on", "indeterminate");

  try {
    // Instant: direct children only. Directory sizes are 0 until measured.
    const node = await ipc.invoke("diskpie.list_dir", path);
    nodeCache.set(node.path, node);
    scanData = node;
    currentDirEntry = node;
    dupPaths.clear();
    dupGroups = [];
    overlay.classList.remove("on", "indeterminate");
    setWindowTitle();
    showResults();
    renderCrumb();
    renderAtlas();
    renderLegend();
    document.getElementById("dock").classList.remove("on");
    updateCollector();
  // Fill in the sizes of this view's folders in the background. We measure
  // the FULL subtree of the viewed node (bounded pool) — so sizes at this
  // level are real and comparable. Cost scales with what the user opened,
  // never with unexplored siblings.
  scheduleMeasure(node);
} catch (e) {
  overlay.classList.remove("on", "indeterminate");
  console.error("Scan failed:", e);
  showLaunch();
}
scanning = false;
}

// Debounced depth-2 (du -d 2) measure of the viewed node: fills the
// immediate sizes of its child folders cheaply, so the level the user is
// looking at shows real, comparable numbers without walking the whole
// subtree. Coalesced so rapid navigations don't spam the backend.
// The full-accurate subtree measure is the explicit "Measure folder" action.
function scheduleMeasure(node) {
  if (measureTimer) clearTimeout(measureTimer);
  measureTimer = setTimeout(() => {
    measureTimer = null;
    measureChildren(node, 2);
  }, 250);
}

// Drill into a directory tile. If already measured/cached, use it instantly;
// otherwise fetch its direct children via `list_dir` (instant) and kick off
// a background depth-1 measure to fill its child folder sizes.
async function drillInto(n) {
  const cached = nodeCache.get(n.path);
  if (cached && cached.children && cached.children.length) {
    currentDirEntry = cached;
    renderCrumb();
    renderAtlas();
    scheduleMeasure(cached);
    return;
  }
  document.getElementById("scan-path").textContent = n.path;
  document.getElementById("scan-percent").textContent = "Reading…";
  const overlay = document.getElementById("scan-overlay");
  overlay.classList.add("on", "indeterminate");
  try {
    const node = await ipc.invoke("diskpie.list_dir", n.path);
    nodeCache.set(node.path, node);
    currentDirEntry = node;
    renderCrumb();
    renderAtlas();
    setWindowTitle();
    scheduleMeasure(node);
  } catch (e) {
    console.error("drillInto failed:", e);
  } finally {
    overlay.classList.remove("on", "indeterminate");
  }
}

// Explicit opt-in: measure the FULL subtree of a folder (bounded-pool, with
// the progress overlay). Used by the "Measure folder" context action so
// power users can get a true total without drilling. Defaults to the
// currently-viewed folder.
async function measureSubtree(path) {
  const target = path || (currentDirEntry && currentDirEntry.path);
  if (!target) return;
  await measureChildren({ path: target, children: [] }, 1 << 20);
}

async function measureChildren(node, depth) {
  if (!node || !node.children) return;
  const dirs = node.children.filter((c) => c.type === "directory" && (!nodeCache.has(c.path) || nodeCache.get(c.path).size === 0));
  // A folder full of files (no subfolders) still needs its own cumulative
  // size filled — its cached size is 0 until measured. Proceed whenever
  // there are unmeasured subfolders OR the node's own size is still unknown.
  if (!dirs.length && (node.size || 0) > 0) return;
  // Show overlay only if a full subtree was requested (depth large); for the
  // normal depth-1 fill we stay quiet to avoid flicker on every navigation.
  const overlay = document.getElementById("scan-overlay");
  const showOverlay = depth > 1;
  if (showOverlay) {
    document.getElementById("scan-path").textContent = node.path;
    document.getElementById("scan-percent").textContent = "Measuring…";
    overlay.classList.add("on", "indeterminate");
  }
  dirs.forEach((d) => measuringPaths.add(d.path));
  renderAtlas(); // reflect the "measuring" state immediately
  try {
    const measured = await ipc.invoke("diskpie.measure", node.path, depth);
    nodeCache.set(measured.path, measured);
    // Propagate each measured child so a sibling/ancestor view can show its
    // known cumulative size without re-walking.
    (measured.children || []).forEach((c) => nodeCache.set(c.path, c));
    // Swap the current view if it's still this node (user hasn't navigated).
    if (currentDirEntry && currentDirEntry.path === measured.path) {
      currentDirEntry = measured;
      if (scanData && scanData.path === measured.path) scanData = measured;
      renderAtlas();
      renderLegend();
      setWindowTitle();
    }
  } catch (e) {
    console.error("Measure failed:", e);
  } finally {
    dirs.forEach((d) => measuringPaths.delete(d.path));
    renderAtlas();
    if (showOverlay) overlay.classList.remove("on", "indeterminate");
  }
}

// ─── Scan state progress ───────────────────────────────────────────────
let scanState = null;
async function initScanState() {
  try {
    scanState = await ipc.state("scan_status");
    scanState.subscribe((v) => {
      const overlay = document.getElementById("scan-overlay");
      if (v.status !== "scanning") return;
      // backend reports files_scanned only (no total), so show a live
      // counter with an indeterminate sweep rather than a fake percentage.
      overlay.classList.add("indeterminate");
      const files = v.files_scanned || 0;
      const where = v.current_path ? " · " + v.current_path : "";
      document.getElementById("scan-percent").textContent =
        files.toLocaleString() + " files scanned" + where;
    });
  } catch (e) {}
}

// ─── Window title ───────────────────────────────────────────────────────
function setWindowTitle(path) {
  if (path) {
    document.title = "DiskPie - " + path;
  } else if (scanData && currentDirEntry) {
    document.title = "DiskPie - " + currentDirEntry.path;
  } else if (scanData) {
    document.title = "DiskPie - " + scanData.path;
  } else {
    document.title = "DiskPie";
  }
}

// ─── Breadcrumb ─────────────────────────────────────────────────────────
function pathParts(path) {
  const out = [];
  const segs = (path || "").split("/").filter(Boolean);
  out.push({ name: scanData ? scanData.name : "Disk", path: "/" });
  let a = "/";
  segs.forEach((s) => {
    a = a === "/" ? "/" + s : a + "/" + s;
    out.push({ name: s, path: a });
  });
  return out;
}
function findNode(node, path) {
  if (!node) return null;
  if (node.path === path) return node;
  if (!node.children) return null;
  for (const c of node.children) {
    const f = findNode(c, path);
    if (f) return f;
  }
  return null;
}
function renderCrumb() {
  const parts = pathParts(currentDirEntry ? currentDirEntry.path : "/");
  const c = document.getElementById("crumb");
  c.innerHTML = "";
  parts.forEach((p, i) => {
    if (i > 0) {
      const sep = document.createElement("span");
      sep.className = "x";
      sep.textContent = "›";
      c.appendChild(sep);
    }
    const seg = document.createElement("span");
    seg.className = "s" + (i === parts.length - 1 ? " cur" : "");
    seg.textContent = p.name;
    seg.addEventListener("click", () => {
      const n = findNode(scanData, p.path);
      if (n) { currentDirEntry = n; renderCrumb(); renderAtlas(); }
    });
    c.appendChild(seg);
  });
}

// ─── Results view: sorted list ───────────────────────────────────────
// The treemap/burst were removed: for a one-level (lazy) browse the
// honest, readable depiction is a sorted list of this folder's children
// (files AND folders, both visible). Unmeasured folders show a
// shimmering bar with "measuring…".
function renderAtlas() {
  const atlas = document.getElementById("atlas");
  atlas.innerHTML = "";
  const root = currentDirEntry || scanData;
  if (!root) return;

  // Merge cached sizes: a child folder already measured/cached elsewhere keeps
  // its real cumulative size here, so navigating back up shows known totals.
  const kids = (root.children || []).map((c) => {
    const hit = nodeCache.get(c.path);
    if (hit && (hit.size || 0) > 0) return hit;
    return c;
  }).sort((a, b) => (b.size || 0) - (a.size || 0));
  // The folder's own size isn't known from list_dir (dirs report 0). Sum the
  // sizes we already know — files are exact, measured subfolders contribute
  // their cached cumulative size. This is the honest "known so far" total and
  // doesn't depend on the async measure round-trip completing first.
  const knownSize = kids.reduce((a, c) => a + (c.size || 0), 0);
  document.getElementById("hud-meta").innerHTML =
    "<b>" + esc(root.name) + "</b> &middot; " + formatSizeFull(knownSize) +
    " &middot; " + kids.length + " items";

  if (!kids.length) {
    atlas.innerHTML = '<div class="empty">Empty folder</div>';
    return;
  }

  kids.forEach((n) => {
    const isDir = n.type === "directory" || (n.children && n.children.length);
    const unmeasured = isDir && (n.size || 0) === 0;
    const measuring = unmeasured && measuringPaths.has(n.path);
    const pct = root.size > 0 ? (n.size || 0) / root.size * 100 : 0;
    const row = document.createElement("div");
    row.className = "row" + (isDir ? " dir" : " file") + (dupPaths.has(n.path) ? " dup" : "") + (measuring ? " measuring" : "");
    row.setAttribute("data-path", n.path);
    row.innerHTML =
      '<div class="ic ' + (isDir ? "dir" : "file") + '">' + iconFor(n, isDir) + '</div>' +
      '<div class="nm">' + esc(n.name) + (isDir ? ' <span class="ic-dir">▸</span>' : '') + '</div>' +
      '<div class="sz">' + (measuring ? "measuring…" : unmeasured ? "unknown" : formatSize(n.size)) + '</div>' +
      '<div class="pc">' + (unmeasured ? "—" : pct.toFixed(1) + "%") + '</div>';
    row.title = (measuring ? "measuring…" : unmeasured ? "size not yet calculated" : formatSize(n.size)) + (root.size > 0 && !unmeasured ? " · " + Math.round(pct) + "% of " + root.name : "");
    row.addEventListener("click", () => {
      if (isDir) drillInto(n);
      else if (dupPaths.has(n.path)) openDuplicates();
    });
    atlas.appendChild(row);
  });
}

function renderLegend() {
  const l = document.getElementById("legend");
  l.style.display = "flex";
  l.innerHTML = "";
  const folder = document.createElement("div");
  folder.className = "lg";
  folder.innerHTML = FOLDER_SVG + "Folder";
  l.appendChild(folder);
  Object.values(MIME).forEach((m) => {
    const d = document.createElement("div");
    d.className = "lg";
    d.innerHTML = '<span class="dt" style="background:' + m.c + '"></span>' + m.l;
    l.appendChild(d);
  });
}

// ─── Duplicate finder ──────────────────────────────────────────────────
async function findDuplicates() {
  if (!scanPath) return;
  const status = document.getElementById("dup-cnt");
  status.textContent = "Scanning...";
  try {
    const groups = await ipc.invoke("diskpie.find_duplicates", scanPath);
    dupGroups = groups;
    dupPaths.clear();
    groups.forEach((g) => g.files.forEach((f) => dupPaths.add(f)));
    renderAtlas(); // re-render to mark dup tiles
    if (groups.length === 0) {
      status.textContent = "No duplicates found";
      return;
    }
    const wasted = groups.reduce((s, g) => s + g.size * (g.files.length - 1), 0);
    status.textContent = groups.length + " sets · " + formatSizeFull(wasted) + " recoverable";
    renderDuplicates(groups);
    document.getElementById("dock").classList.add("on");
  } catch (e) {
    status.textContent = "Error: " + (e.message || e);
  }
}

function renderDuplicates(groups) {
  const list = document.getElementById("dup-list");
  list.innerHTML = "";
  groups.forEach((group, gi) => {
    const box = document.createElement("div");
    box.className = "dg";
    box.innerHTML =
      '<div class="gh"><div class="gf">' + esc(group.files[0].split("/").pop()) + '</div>' +
      '<div class="gs">' + formatSize(group.size) + " each &middot; " + group.files.length + " copies</div></div>";
    group.files.forEach((f, fi) => {
      const keep = fi === 0;
      const row = document.createElement("div");
      row.className = "df";
      row.innerHTML =
        '<span class="chk ' + (!keep ? "on" : "") + '" data-path="' + esc(f) + '">' + checkSvg() + '</span>' +
        '<span class="fp" title="' + esc(f) + '">' + esc(f) + '</span>' +
        '<span class="fs">' + formatSize(group.size) + '</span>' +
        (keep ? '<span class="keep">keep</span>' : '<span class="gs">will trash</span>');
      const chk = row.querySelector(".chk");
      chk.addEventListener("click", () => {
        const on = chk.classList.toggle("on");
        chk.parentElement.querySelector(".gs").textContent = on ? "will trash" : "kept";
        syncCollectorFromDups();
      });
      box.appendChild(row);
    });
    list.appendChild(box);
  });
}

function checkSvg() {
  return '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6L9 17l-5-5"/></svg>';
}

function syncCollectorFromDups() {
  collected.clear();
  const boxes = document.getElementById("dup-list").querySelectorAll(".dg");
  boxes.forEach((box) => {
    box.querySelectorAll(".df").forEach((row) => {
      const chk = row.querySelector(".chk");
      if (chk.classList.contains("on")) {
        const p = chk.dataset.path;
        if (!collected.has(p)) {
          collected.set(p, { name: p.split("/").pop(), path: p, size: dupSizeFor(p), type: "file" });
        }
      }
    });
  });
  updateCollector();
}
function dupSizeFor(path) {
  for (const g of dupGroups) {
    if (g.files.includes(path)) return g.size;
  }
  return 0;
}

// ─── Collector ──────────────────────────────────────────────────────────
function updateCollector() {
  const c = document.getElementById("collector");
  const n = collected.size;
  if (n === 0) { c.classList.add("hide"); return; }
  c.classList.remove("hide");
  const total = Array.from(collected.values()).reduce((s, v) => s + (v.size || 0), 0);
  document.getElementById("col-count").textContent = n;
  document.getElementById("col-size").textContent = formatSizeFull(total);
  const chips = document.getElementById("chips");
  chips.innerHTML = "";
  collected.forEach((v, p) => {
    const ch = document.createElement("div");
    ch.className = "chip" + (dupPaths.has(p) ? " dup" : "");
    ch.innerHTML = esc(v.name) + '<span class="x" data-path="' + esc(p) + '">×</span>';
    ch.querySelector(".x").addEventListener("click", () => {
      collected.delete(p);
      // uncheck if it came from a dup row
      document.querySelectorAll('#dup-list .chk[data-path="' + cssEsc(p) + '"]').forEach((cb) => cb.classList.remove("on"));
      updateCollector();
    });
    chips.appendChild(ch);
  });
}
function cssEsc(s) { return String(s).replace(/"/g, '\\"'); }

document.getElementById("btn-collector-clear").addEventListener("click", () => {
  collected.clear();
  document.querySelectorAll("#dup-list .chk.on").forEach((cb) => cb.classList.remove("on"));
  updateCollector();
});
document.getElementById("btn-collector-delete").addEventListener("click", async () => {
  if (collected.size === 0 || deleteInProgress) return;
  deleteInProgress = true;
  try {
    const confirmed = await ipc.invoke("dialog.confirm", {
      title: "Delete " + collected.size + " items?",
      message: "Move " + collected.size + " items to Trash?",
    });
    if (!confirmed) { deleteInProgress = false; updateCollector(); return; }
  } catch (e) { deleteInProgress = false; updateCollector(); return; }

  try {
    const result = await ipc.invoke("diskpie.trash_paths", Array.from(collected.keys()));
    if (result.failed && result.failed.length > 0) {
      await ipc.invoke("dialog.message", { title: "Trash Failed", message: result.failed.join(", "), kind: "error" });
    }
    collected.clear();
    dupPaths.clear();
    dupGroups = [];
    document.getElementById("dock").classList.remove("on");
    updateCollector();
    if (scanPath) startScan(scanPath, scanUsed);
  } catch (e) {
    console.error(e);
  }
  deleteInProgress = false;
});

document.getElementById("btn-dup-close").addEventListener("click", () => {
  document.getElementById("dock").classList.remove("on");
});

// ─── Context menu ───────────────────────────────────────────────────────
ipc.listen("contextmenu.action", async (data) => {
  const path = ctxPath;
  if (!path) return;
  try {
    switch (data.item_id) {
      case "ctx-show-in-folder": {
        const dir = path.replace(/\/[^\/]*$/, "") || "/";
        await ipc.invoke("external.open_path", dir);
        break;
      }
      case "ctx-open": {
        await ipc.invoke("external.open_path", path);
        break;
      }
      case "ctx-copy-path": {
        if (navigator.clipboard) await navigator.clipboard.writeText(path);
        break;
      }
      case "ctx-delete": {
        const entry = currentDirEntry && currentDirEntry.children
          ? currentDirEntry.children.filter((c) => c.path === path)[0]
          : null;
        const label = entry ? entry.name : path;
        if (!(await ipc.invoke("dialog.confirm", { title: "Move to Trash", message: "Move " + label + " to Trash?" }))) break;
        const result = await ipc.invoke("diskpie.trash_paths", [path]);
        if (result.failed && result.failed.length > 0) {
          await ipc.invoke("dialog.message", { title: "Trash Failed", message: result.failed.join(", "), kind: "error" });
        }
        if (result.trashed && result.trashed.length > 0 && currentDirEntry) {
          currentDirEntry.children = (currentDirEntry.children || []).filter((c) => c.path !== path);
          currentDirEntry.size = (currentDirEntry.children || []).reduce((a, c) => a + (c.size || 0), 0);
          renderAtlas();
          renderCrumb();
          if (scanPath) startScan(scanPath, scanUsed);
        }
        break;
      }
      case "ctx-zoom-in": {
        const node = findNode(scanData, path);
        if (node && node.children && node.children.length) { currentDirEntry = node; renderCrumb(); renderAtlas(); }
        break;
      }
      case "ctx-rescan": { if (scanPath) startScan(scanPath, scanUsed); break; }
      case "ctx-measure": { await measureSubtree(path); break; }
      case "ctx-select-folder": { pickFolder(); break; }
      case "ctx-rescan-all": { loadDisks(); break; }
    }
  } catch (e) {
    console.error("Context menu action failed:", e);
  }
});

// ─── Keyboard ──────────────────────────────────────────────────────────
document.addEventListener("keydown", (e) => {
  if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") return;
  if ((e.key === "Backspace" || e.key === "Escape") && currentDirEntry && currentDirEntry !== scanData) {
    const parentPath = currentDirEntry.path.replace(/\/[^\/]*$/, "") || "/";
    const parent = findNode(scanData, parentPath);
    if (parent) { currentDirEntry = parent; renderCrumb(); renderAtlas(); }
  }
});

window.addEventListener("resize", () => { if (scanData) renderAtlas(); });

// ─── Menu & tray ──────────────────────────────────────────────────────
const MENU = [
  {
    label: "DiskPie", id: "app", items: [
      { label: "About DiskPie", id: "about" },
      { type: "separator" },
      { label: "Preferences...", id: "preferences", accelerator: "Cmd+," },
      { type: "separator" },
      { label: "Hide DiskPie", id: "hide", accelerator: "Cmd+H" },
      { label: "Hide Others", id: "hide-others", accelerator: "Cmd+Alt+H" },
      { label: "Show All", id: "show-all" },
      { type: "separator" },
      { label: "Quit DiskPie", id: "quit", accelerator: "Cmd+Q" },
    ],
  },
  {
    label: "File", id: "file", items: [
      { label: "Select Folder...", id: "select-folder", accelerator: "Cmd+O" },
      { label: "Find Duplicates", id: "find-duplicates", accelerator: "Cmd+F" },
      { label: "Rescan Current", id: "rescan-current", accelerator: "Cmd+R" },
      { type: "separator" },
      { label: "Close Window", id: "close", accelerator: "Cmd+W" },
    ],
  },
  {
    label: "Edit", id: "edit", items: [
      { label: "Copy Path", id: "copy-path", accelerator: "Cmd+Shift+C" },
    ],
  },
  {
    label: "View", id: "view", items: [
      { label: "Show Disk List", id: "show-disks", accelerator: "Cmd+1" },
      { type: "separator" },
      { label: "Toggle Developer Tools", id: "devtools", accelerator: "Cmd+Alt+I" },
      { label: "Toggle Fullscreen", id: "fullscreen", accelerator: "Cmd+Ctrl+F" },
    ],
  },
  {
    label: "Help", id: "help", items: [
      { label: "Check for Updates...", id: "check-updates" },
      { type: "separator" },
      { label: "DiskPie Website", id: "website" },
    ],
  },
];

async function setupMenu() {
  try { await ipc.invoke("menu.build", MENU); } catch (e) { console.error("Failed to set up menus:", e); }
}
function setupMenuListeners() {
  ipc.listen("menu.click", (data) => handleMenuAction(data.item_id));
  ipc.listen("tray.action", (data) => handleMenuAction(data.action));
}
function handleMenuAction(itemId) {
  switch (itemId) {
    case "select-folder": pickFolder(); break;
    case "find-duplicates": findDuplicates(); break;
    case "rescan-current": if (scanPath) startScan(scanPath, scanUsed); break;
    case "close": ipc.invoke("window.close", "main").catch(() => {}); break;
    case "quit": ipc.invoke("app.quit").catch(() => {}); break;
    case "devtools": ipc.invoke("devtools.toggle").catch(() => {}); break;
    case "fullscreen": ipc.invoke("window.set_fullscreen", "main", true).catch(() => {}); break;
    case "about":
      ipc.invoke("dialog.message", {
        title: "About DiskPie",
        message: "DiskPie v1.0.0\n\nA disk usage analyzer built with CrystKit.\nVisualize your disk space as an interactive map.\n\nBuilt with CrystKit\n© 2026 CrystKit Contributors\n\nhttps://github.com/crystkit/crystkit",
        kind: "info",
      }).catch(() => {});
      break;
    case "show":
    case "show-disks": showLaunch(); setWindowTitle(); break;
    case "preferences":
      ipc.invoke("dialog.message", { title: "Preferences", message: "Preferences coming soon.", kind: "info" }).catch(() => {});
      break;
    case "hide": ipc.invoke("window.hide", "main").catch(() => {}); break;
    case "hide-others": ipc.invoke("window.hide_others").catch(() => {}); break;
    case "show-all": ipc.invoke("window.show_all").catch(() => {}); break;
    case "copy-path": if (scanPath) navigator.clipboard.writeText(scanPath).catch(() => {}); break;
    case "check-updates":
      ipc.invoke("dialog.message", { title: "Check for Updates", message: "You are running the latest version of DiskPie.", kind: "info" }).catch(() => {});
      break;
    case "website": ipc.invoke("external.open_url", "https://github.com/crystkit/crystkit").catch(() => {}); break;
  }
}

// ─── Top-bar buttons ──────────────────────────────────────────────────
document.getElementById("brand-home").addEventListener("click", () => { showLaunch(); setWindowTitle(); });
document.getElementById("btn-rescan").addEventListener("click", () => { if (scanPath) startScan(scanPath, scanUsed); });
document.getElementById("btn-find-duplicates").addEventListener("click", findDuplicates);

// ─── Scan overlay back button ───────────────────────────────────────
document.getElementById("btn-scan-back").addEventListener("click", () => {
  document.getElementById("scan-overlay").classList.remove("on");
  showLaunch();
  setWindowTitle();
});

// ─── Init ─────────────────────────────────────────────────────────────
async function init() {
  try {
    const ver = await ipc.invoke("system_info.app");
    const fv = document.getElementById("footer-version");
    if (fv) fv.textContent = "v" + (ver.version || "1.0.0");
  } catch (_) {}

  await setupMenu();
  setupMenuListeners();
  await initScanState();
  await loadDisks();
  setWindowTitle();
  showLaunch();
  setInterval(loadDisks, 5000);
}

document.addEventListener("DOMContentLoaded", init);
