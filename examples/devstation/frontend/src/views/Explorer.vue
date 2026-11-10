<template>
  <div class="view-area">
    <div class="topbar">
      <span class="topbar-title">File Explorer</span>
      <button class="btn sm ghost" @click="openFolder">📂 Open Folder…</button>
      <button class="btn sm ghost" @click="openFile">📄 Open File…</button>
      <div class="search-wrap" style="flex: 1; max-width: 260px">
        <span class="search-ico">🔍</span>
        <input
          v-model="fileSearch"
          class="input"
          placeholder="Search files…"
          @input="searchFiles"
        />
      </div>
      <button
        class="btn sm ghost"
        @click="toggleWatch"
        :class="{ primary: watching }"
      >
        {{ watching ? "👁 Watching" : "👁 Watch" }}
      </button>
    </div>

    <div style="flex: 1; display: flex; overflow: hidden">
      <!-- File tree -->
      <div
        style="
          width: 260px;
          min-width: 200px;
          border-right: 1px solid var(--border);
          display: flex;
          flex-direction: column;
          overflow: hidden;
        "
      >
        <!-- Breadcrumb -->
        <div
          style="
            padding: 6px 10px;
            background: var(--bg-2);
            border-bottom: 1px solid var(--border);
            display: flex;
            align-items: center;
            gap: 4px;
            flex-wrap: wrap;
          "
        >
          <button
            v-for="(part, i) in breadcrumb"
            :key="i"
            class="btn sm ghost"
            style="
              padding: 2px 5px;
              font-size: 11px;
              font-family: var(--font-mono);
            "
            @click="navigateTo(part.path)"
          >
            {{ part.label }}{{ i < breadcrumb.length - 1 ? " /" : "" }}
          </button>
        </div>

        <div v-if="fileSearch" style="flex: 1; overflow-y: auto">
          <div
            v-for="r in searchResults"
            :key="r.path"
            class="list-item"
            @click="openEntry(r)"
            style="cursor: pointer"
          >
            <div>
              <span style="font-size: 12px; font-family: var(--font-mono)">{{
                r.name
              }}</span>
              <div class="meta" style="font-family: var(--font-mono)">
                {{ r.path.replace(cwd, ".") }}
              </div>
            </div>
            <span class="muted">{{ fmtBytes(r.size) }}</span>
          </div>
        </div>

        <div v-else style="flex: 1; overflow-y: auto">
          <!-- Up button -->
          <div
            v-if="cwd !== '/'"
            class="list-item"
            @click="navigateUp"
            style="cursor: pointer; color: var(--accent)"
          >
            <span>📁 ..</span>
          </div>

          <div
            v-for="e in entries"
            :key="e.path"
            class="list-item"
            @click="openEntry(e)"
            style="cursor: pointer"
          >
            <div
              style="
                display: flex;
                gap: 6px;
                align-items: center;
                min-width: 0;
                flex: 1;
              "
            >
              <span>{{ e.type === "directory" ? "📁" : getIcon(e.name) }}</span>
              <span
                style="
                  overflow: hidden;
                  text-overflow: ellipsis;
                  white-space: nowrap;
                  font-size: 12px;
                "
                >{{ e.name }}</span
              >
            </div>
            <span class="muted" v-if="e.type !== 'directory'">{{
              fmtBytes(e.size)
            }}</span>
          </div>

          <div v-if="!entries.length && !loading" class="empty">
            <p>Empty directory</p>
          </div>
        </div>
      </div>

      <!-- File editor / preview -->
      <div
        style="flex: 1; display: flex; flex-direction: column; overflow: hidden"
      >
        <div
          v-if="openedFile"
          style="
            flex: 1;
            display: flex;
            flex-direction: column;
            overflow: hidden;
          "
        >
          <!-- File toolbar -->
          <div
            style="
              padding: 6px 12px;
              background: var(--bg-1);
              border-bottom: 1px solid var(--border);
              display: flex;
              gap: 8px;
              align-items: center;
            "
          >
            <span
              style="
                font-family: var(--font-mono);
                font-size: 12px;
                color: var(--accent);
              "
              >{{ openedFile.name }}</span
            >
            <span class="lang-chip">{{ openedFile.language }}</span>
            <span class="muted">{{ fmtBytes(openedFile.size) }}</span>
            <div style="flex: 1"></div>
            <button
              class="btn sm primary"
              @click="saveFile"
              :disabled="!modified"
            >
              Save
            </button>
            <button class="btn sm ghost" @click="copyFilePath">
              Copy Path
            </button>
            <button class="btn sm ghost" @click="openExternal">
              Open External
            </button>
            <button class="btn icon ghost" @click="closeFile">✕</button>
          </div>

          <!-- Editor -->
          <div style="flex: 1; overflow: hidden">
            <CodeEditor
              v-model="fileContent"
              :language="openedFile.language"
              @update:modelValue="modified = true"
            />
          </div>

          <!-- Status bar -->
          <div class="statusbar">
            <span>{{ openedFile.path }}</span>
            <span class="sep">|</span>
            <span>{{ openedFile.language }}</span>
            <span class="sep">|</span>
            <span>{{ lineCount }} lines</span>
            <span
              v-if="modified"
              style="margin-left: auto; color: var(--yellow)"
              >● Unsaved changes</span
            >
          </div>
        </div>

        <div v-else class="empty" style="flex: 1">
          <div class="icon">📁</div>
          <p>
            Click a file to open it in the editor.<br />Changes can be saved
            back to disk. File watching emits live change events.
          </p>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from "vue";
import { invoke, listen } from "../ipc";
import { useAppStore } from "../stores/app";
import CodeEditor from "../components/CodeEditor.vue";

const appStore = useAppStore();

const cwd = ref(
  typeof window !== "undefined" ? (window as any).__HOME__ || "/" : "/",
);
const entries = ref<any[]>([]);
const openedFile = ref<any>(null);
const fileContent = ref("");
const modified = ref(false);
const loading = ref(false);
const watching = ref(false);
const fileSearch = ref("");
const searchResults = ref<any[]>([]);

const lineCount = computed(() => fileContent.value.split("\n").length);

const breadcrumb = computed(() => {
  if (!cwd.value) return [];
  const parts = cwd.value.split("/").filter(Boolean);
  return [
    { label: "/", path: "/" },
    ...parts.map((p: string, i: number) => ({
      label: p,
      path: "/" + parts.slice(0, i + 1).join("/"),
    })),
  ];
});

function fmtBytes(n: number): string {
  if (!n) return "0 B";
  const u = ["B", "KB", "MB", "GB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) {
    n /= 1024;
    i++;
  }
  return `${n.toFixed(i ? 1 : 0)} ${u[i]}`;
}

function getIcon(name: string): string {
  const ext = name.split(".").pop()?.toLowerCase();
  const icons: Record<string, string> = {
    cr: "💎",
    rb: "💎",
    py: "🐍",
    js: "🟨",
    ts: "🔷",
    vue: "🟢",
    html: "🌐",
    css: "🎨",
    json: "📋",
    md: "📝",
    sql: "🗄️",
    sh: "🔧",
    bash: "🔧",
    git: "🌿",
    png: "🖼",
    jpg: "🖼",
    svg: "🖼",
    pdf: "📕",
    zip: "📦",
    tar: "📦",
  };
  return icons[ext ?? ""] ?? "📄";
}

async function listDir(path: string) {
  loading.value = true;
  const res = await invoke<{ path: string; entries: any[] }>("explorer.list", path).catch(() => null);
  if (res) {
    cwd.value = res.path;
    entries.value = res.entries;
    if (watching.value) {
      await invoke("explorer.watch", ["explorer-main", res.path]).catch(() => null);
    }
  }
  loading.value = false;
}

function openEntry(e: any) {
  if (e.type === "directory") {
    listDir(e.path);
    fileSearch.value = "";
    searchResults.value = [];
  } else {
    openFileByPath(e.path);
  }
}

async function openFileByPath(path: string) {
  const res = await invoke<any>("explorer.read", path);
  if (res.ok) {
    openedFile.value = {
      path,
      name: path.split("/").pop(),
      language: res.language,
      size: res.size,
    };
    fileContent.value = res.content;
    modified.value = false;
  } else {
    appStore.toast(res.error ?? "Cannot read file", "error");
  }
}

async function saveFile() {
  if (!openedFile.value) return;
  await invoke("explorer.write", [openedFile.value.path, fileContent.value]);
  modified.value = false;
  appStore.toast("Saved", "ok");
}

function closeFile() {
  openedFile.value = null;
  modified.value = false;
}

function navigateUp() {
  const parts = cwd.value.split("/").filter(Boolean);
  parts.pop();
  listDir(parts.length ? "/" + parts.join("/") : "/");
}

function navigateTo(path: string) {
  listDir(path);
}

async function openFolder() {
  const res = await invoke<{ path: string; picked: boolean }>(
    "explorer.open_folder",
    "Open Folder",
  );
  if (res.picked) listDir(res.path);
}

async function openFile() {
  const res = await invoke<{ path: string; picked: boolean }>(
    "explorer.open_dialog",
    "Open File",
  );
  if (res.picked) openFileByPath(res.path);
}

async function searchFiles() {
  if (!fileSearch.value.trim() || !cwd.value) {
    searchResults.value = [];
    return;
  }
  searchResults.value = await invoke<any[]>("explorer.search_files", [
    cwd.value,
    fileSearch.value,
  ]).catch(() => []) ?? [];
}

async function toggleWatch() {
  if (watching.value) {
    await invoke("explorer.unwatch", "explorer-main");
    watching.value = false;
    appStore.toast("Stopped watching", "info");
  } else {
    await invoke("explorer.watch", ["explorer-main", cwd.value]);
    watching.value = true;
    appStore.toast(`Watching: ${cwd.value}`, "ok");
  }
}

async function copyFilePath() {
  if (!openedFile.value) return;
  await invoke("app.clipboard_write", openedFile.value.path);
  appStore.toast("Path copied", "ok");
}

async function openExternal() {
  if (!openedFile.value) return;
  await invoke("app.open_url", `file://${openedFile.value.path}`);
}

const unsubWatch = listen<{
  watch_id: string;
  path: string;
  old_path?: string | null;
  kind: string;
}>(
  "explorer:change",
  ({ path, old_path, kind }) => {
    const name = path.split(/[\\/]/).pop();
    const oldName = old_path?.split(/[\\/]/).pop();
    const detail = kind === "renamed" && oldName
      ? `${oldName} → ${name}`
      : name;
    appStore.toast(`${kind}: ${detail}`, "info", 1500);
    // Refresh directory listing
    listDir(cwd.value);
  },
);

onMounted(async () => {
  // Start in home directory
  const info = await invoke<any>("vitals.static").catch(() => null);
  const home = info?.home_dir || "/";
  cwd.value = home;
  await listDir(home);
});

onUnmounted(() => {
  unsubWatch();
  invoke("explorer.unwatch", "explorer-main").catch(() => {});
});
</script>
