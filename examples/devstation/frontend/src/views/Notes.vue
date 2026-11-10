<template>
  <div class="view-area">
    <div class="topbar">
      <span class="topbar-title">Notes</span>
      <div class="search-wrap" style="flex: 1; max-width: 280px">
        <span class="search-ico">🔍</span>
        <input
          v-model="searchQuery"
          class="input"
          placeholder="Search notes…"
          @input="search"
        />
      </div>
      <label
        style="
          display: flex;
          align-items: center;
          gap: 6px;
          font-size: 12px;
          color: var(--text-1);
          cursor: pointer;
        "
      >
        <input type="checkbox" v-model="showArchived" @change="loadNotes" />
        Show archived
      </label>
      <button class="btn sm primary" @click="newNote">＋ New Note</button>
    </div>

    <div class="split" style="flex: 1">
      <!-- Notes list -->
      <div class="split-left">
        <div style="flex: 1; overflow-y: auto">
          <div
            v-for="n in displayList"
            :key="n.id"
            class="list-item"
            :class="{ active: current?.id === n.id }"
            @click="loadNote(n.id)"
            style="cursor: pointer"
          >
            <div
              style="display: flex; gap: 8px; align-items: flex-start; flex: 1"
            >
              <div
                :style="{
                  width: '10px',
                  height: '10px',
                  borderRadius: '50%',
                  background: n.color,
                  flexShrink: 0,
                  marginTop: '4px',
                }"
              ></div>
              <div style="min-width: 0">
                <div
                  style="
                    font-weight: 500;
                    white-space: nowrap;
                    overflow: hidden;
                    text-overflow: ellipsis;
                  "
                >
                  {{ n.title }}
                </div>
                <div class="meta">{{ fmtDate(n.updated_at) }}</div>
              </div>
            </div>
            <div class="actions">
              <button
                class="btn icon ghost sm"
                @click.stop="toggleArchive(n)"
                :title="n.archived ? 'Unarchive' : 'Archive'"
              >
                {{ n.archived ? "📤" : "📥" }}
              </button>
              <button
                class="btn icon ghost sm"
                @click.stop="deleteNote(n.id)"
                title="Delete"
              >
                🗑
              </button>
            </div>
          </div>
          <div v-if="!displayList.length" class="empty">
            <div class="icon">📝</div>
            <p>{{ searchQuery ? "No results" : "No notes yet" }}</p>
          </div>
        </div>

        <div class="card-foot" v-if="stats">
          <span class="muted"
            >{{ stats.total }} notes · {{ stats.archived }} archived</span
          >
        </div>
      </div>

      <!-- Note editor -->
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
          <!-- Meta -->
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
                placeholder="Note title…"
                style="font-size: 16px; font-weight: 600"
              />
              <div style="display: flex; gap: 4px">
                <button
                  v-for="c in colors"
                  :key="c"
                  :style="{
                    width: '18px',
                    height: '18px',
                    borderRadius: '50%',
                    background: c,
                    border:
                      editColor === c
                        ? '2px solid white'
                        : '2px solid transparent',
                    cursor: 'pointer',
                  }"
                  @click="editColor = c"
                ></button>
              </div>
            </div>
            <div class="row">
              <div style="flex: 1"></div>
              <button class="btn sm primary" @click="save" :disabled="saving">
                {{ saving ? "…" : "Save" }}
              </button>
              <button class="btn sm ghost" @click="copyContent">Copy</button>
              <button class="btn sm ghost" @click="cancelEdit">Cancel</button>
            </div>
          </div>

          <!-- Markdown editor -->
          <div style="flex: 1; overflow: hidden">
            <CodeEditor v-model="editContent" language="markdown" />
          </div>
        </div>

        <div v-else class="empty" style="flex: 1">
          <div class="icon">📝</div>
          <p>
            Select a note to edit it, or create a new one.<br />Markdown
            supported. Search matches titles and content.
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

const noteList = ref<any[]>([]);
const searchResults = ref<any[]>([]);
const searchQuery = ref("");
const showArchived = ref(false);
const current = ref<any>(null);
const editing = ref(false);
const saving = ref(false);
const stats = ref<any>(null);

const editTitle = ref("");
const editContent = ref("");
const editColor = ref("#3b82f6");

const colors = [
  "#3b82f6",
  "#10b981",
  "#f59e0b",
  "#ef4444",
  "#8b5cf6",
  "#ec4899",
  "#14b8a6",
];

const displayList = computed(() =>
  searchQuery.value ? searchResults.value : noteList.value,
);

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

async function loadNotes() {
  noteList.value = await invoke<any[]>("notes.list", showArchived.value).catch(() => []) ?? [];
}

async function search() {
  if (!searchQuery.value.trim()) {
    searchResults.value = [];
    return;
  }
  searchResults.value = await invoke<any[]>("notes.search", searchQuery.value).catch(() => []) ?? [];
}

async function loadNote(id: number) {
  current.value = await invoke<any>("notes.get", id) ?? null;
  if (!current.value) { appStore.toast("Note not found", "error"); return; }
  editTitle.value = current.value.title;
  editContent.value = current.value.content;
  editColor.value = current.value.color;
  editing.value = true;
}

function newNote() {
  current.value = null;
  editTitle.value = "Untitled Note";
  editContent.value = "";
  editColor.value = "#3b82f6";
  editing.value = true;
}

function cancelEdit() {
  editing.value = false;
  current.value = null;
}

async function save() {
  saving.value = true;
  try {
    if (current.value) {
      current.value = await invoke<any>("notes.update", [
        current.value.id,
        editTitle.value,
        editContent.value,
        editColor.value,
      ]);
    } else {
      current.value = await invoke<any>("notes.create", [
        editTitle.value,
        editContent.value,
        editColor.value,
      ]);
    }
    appStore.toast("Note saved", "ok");
    await loadNotes();
    await loadStats();
  } catch (e: any) {
    appStore.toast(e.message, "error");
  } finally {
    saving.value = false;
  }
}

async function deleteNote(id: number) {
  await invoke("notes.delete", id);
  if (current.value?.id === id) cancelEdit();
  appStore.toast("Deleted", "ok");
  loadNotes();
  loadStats();
}

async function toggleArchive(n: any) {
  await invoke("notes.toggle_archive", n.id);
  loadNotes();
}

async function copyContent() {
  if (!editContent.value) return;
  await invoke("app.clipboard_write", editContent.value);
  appStore.toast("Copied", "ok");
}

async function loadStats() {
  stats.value = await invoke<any>("notes.stats").catch(() => null);
}

onMounted(async () => {
  await loadNotes();
  await loadStats();
});
</script>
