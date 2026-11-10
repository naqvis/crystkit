<template>
  <div class="view-area">
    <div class="topbar">
      <span class="topbar-title">Snippets</span>
      <div class="search-wrap" style="flex: 1; max-width: 320px">
        <span class="search-ico">🔍</span>
        <input
          v-model="searchQuery"
          class="input"
          placeholder="Search snippets…"
          @input="search"
        />
      </div>
      <select
        v-model="langFilter"
        class="input"
        style="width: 130px; height: 28px"
        @change="loadList"
      >
        <option value="">All Languages</option>
        <option v-for="l in languages" :key="l">{{ l }}</option>
      </select>
      <button class="btn sm primary" @click="newSnippet">＋ New Snippet</button>
    </div>

    <div class="split" style="flex: 1">
      <!-- List -->
      <div class="split-left">
        <div style="flex: 1; overflow-y: auto">
          <div
            v-for="s in displayList"
            :key="s.id"
            class="list-item"
            :class="{ active: current?.id === s.id }"
            @click="loadSnippet(s.id)"
            style="cursor: pointer"
          >
            <div style="min-width: 0; flex: 1">
              <div style="display: flex; gap: 6px; align-items: center">
                <span v-if="s.pinned" title="Pinned">📌</span>
                <span
                  style="
                    font-weight: 500;
                    overflow: hidden;
                    text-overflow: ellipsis;
                    white-space: nowrap;
                  "
                  >{{ s.title }}</span
                >
              </div>
              <div
                style="
                  display: flex;
                  gap: 6px;
                  margin-top: 4px;
                  flex-wrap: wrap;
                "
              >
                <span class="lang-chip">{{ s.language }}</span>
                <span class="tag" v-for="tag in parseTags(s.tags)" :key="tag">{{
                  tag
                }}</span>
              </div>
              <div class="meta">{{ fmtDate(s.updated_at) }}</div>
            </div>
            <div class="actions">
              <button
                class="btn icon ghost sm"
                @click.stop="togglePin(s)"
                title="Pin"
              >
                📌
              </button>
              <button
                class="btn icon ghost sm"
                @click.stop="deleteSnippet(s.id)"
                title="Delete"
              >
                🗑
              </button>
            </div>
          </div>
          <div v-if="!displayList.length" class="empty">
            <div class="icon">📎</div>
            <p>{{ searchQuery ? "No results" : "No snippets yet" }}</p>
          </div>
        </div>

        <div class="card-foot" v-if="stats">
          <span class="muted"
            >{{ stats.total }} snippets · {{ stats.pinned }} pinned</span
          >
        </div>
      </div>

      <!-- Editor -->
      <div class="split-right">
        <div
          v-if="editing"
          style="
            flex: 1;
            display: flex;
            flex-direction: column;
            overflow: hidden;
          "
        >
          <!-- Meta row -->
          <div
            style="
              padding: 10px 14px;
              background: var(--bg-1);
              border-bottom: 1px solid var(--border);
              display: flex;
              flex-direction: column;
              gap: 8px;
            "
          >
            <div class="row">
              <input
                v-model="editTitle"
                class="input grow"
                placeholder="Snippet title…"
                style="font-weight: 600; font-size: 14px"
              />
              <select v-model="editLang" class="input" style="width: 130px">
                <option v-for="l in allLangs" :key="l" :value="l">
                  {{ l }}
                </option>
              </select>
            </div>
            <div class="row">
              <input
                v-model="editTags"
                class="input grow"
                placeholder="tags: comma,separated,tags"
              />
              <button class="btn sm primary" @click="save" :disabled="saving">
                {{ saving ? "…" : "Save" }}
              </button>
              <button
                v-if="current"
                class="btn sm ghost"
                @click="copyToClipboard"
              >
                Copy
              </button>
              <button class="btn sm ghost" @click="cancelEdit">Cancel</button>
            </div>
          </div>

          <!-- Code editor -->
          <div style="flex: 1; overflow: hidden">
            <CodeEditor v-model="editContent" :language="editLang" />
          </div>
        </div>

        <div v-else class="empty" style="flex: 1">
          <div class="icon">📎</div>
          <p>
            Select a snippet to view/edit, or create a new one.<br />Full-text
            search over titles, content, and tags.
          </p>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from "vue";
import { invoke } from "../ipc";
import { useAppStore } from "../stores/app";
import CodeEditor from "../components/CodeEditor.vue";

const appStore = useAppStore();

const snippetList = ref<any[]>([]);
const searchResults = ref<any[]>([]);
const searchQuery = ref("");
const langFilter = ref("");
const current = ref<any>(null);
const editing = ref(false);
const saving = ref(false);
const stats = ref<any>(null);
const languages = ref<string[]>([]);
const editTitle = ref("");
const editLang = ref("plaintext");
const editContent = ref("");
const editTags = ref("");

const allLangs = [
  "plaintext",
  "crystal",
  "ruby",
  "python",
  "javascript",
  "typescript",
  "rust",
  "go",
  "html",
  "css",
  "json",
  "sql",
  "markdown",
  "shell",
  "xml",
];

const displayList = computed(() =>
  searchQuery.value ? searchResults.value : snippetList.value,
);

function parseTags(t: string): string[] {
  return t
    ? t
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean)
    : [];
}

function fmtDate(d: string): string {
  return d
    ? new Date(d).toLocaleDateString(undefined, {
        month: "short",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
      })
    : "";
}

async function loadList() {
  snippetList.value = await invoke<any[]>("snippets.list", langFilter.value).catch(() => []) ?? [];
}

async function search() {
  if (!searchQuery.value.trim()) {
    searchResults.value = [];
    return;
  }
  searchResults.value = await invoke<any[]>("snippets.search", searchQuery.value).catch(() => []) ?? [];
}

async function loadSnippet(id: number) {
  current.value = await invoke<any>("snippets.get", id) ?? null;
  if (!current.value) { appStore.toast("Snippet not found", "error"); return; }
  editTitle.value = current.value.title;
  editLang.value = current.value.language;
  editContent.value = current.value.content;
  editTags.value = current.value.tags;
  editing.value = true;
}

function newSnippet() {
  current.value = null;
  editTitle.value = "Untitled Snippet";
  editLang.value = "plaintext";
  editContent.value = "";
  editTags.value = "";
  editing.value = true;
}

function cancelEdit() {
  editing.value = false;
  current.value = null;
}

async function save() {
  if (!editTitle.value.trim()) return;
  saving.value = true;
  try {
    if (current.value) {
      current.value = await invoke<any>("snippets.update", [
        current.value.id,
        editTitle.value,
        editLang.value,
        editContent.value,
        editTags.value,
      ]);
    } else {
      current.value = await invoke<any>("snippets.create", [
        editTitle.value,
        editLang.value,
        editContent.value,
        editTags.value,
      ]);
    }
    appStore.toast("Saved", "ok");
    await loadList();
    await loadStats();
  } catch (e: any) {
    appStore.toast(e.message, "error");
  } finally {
    saving.value = false;
  }
}

async function deleteSnippet(id: number) {
  await invoke("snippets.delete", id);
  if (current.value?.id === id) cancelEdit();
  appStore.toast("Deleted", "ok");
  loadList();
  loadStats();
}

async function togglePin(s: any) {
  await invoke("snippets.toggle_pin", s.id);
  loadList();
}

async function copyToClipboard() {
  if (!editContent.value) return;
  await invoke("app.clipboard_write", editContent.value);
  appStore.toast("Copied to clipboard", "ok");
}

async function loadStats() {
  stats.value = await invoke<any>("snippets.stats").catch(() => null);
}

onMounted(async () => {
  await loadList();
  languages.value = await invoke<string[]>("snippets.languages").catch(
    () => [],
  ) ?? [];
  await loadStats();
});
</script>
