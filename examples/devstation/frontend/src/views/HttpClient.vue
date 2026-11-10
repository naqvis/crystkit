<template>
  <div class="view-area">
    <div class="topbar">
      <span class="topbar-title">HTTP Client</span>
      <select
        v-model="activeCollection"
        class="input"
        style="width: 160px; height: 28px"
      >
        <option value="">All Collections</option>
        <option v-for="c in collections" :key="c">{{ c }}</option>
      </select>
      <button class="btn sm ghost" @click="newRequest">✕ Clear</button>
      <button class="btn sm primary" @click="saveRequest">Save…</button>
    </div>

    <div class="split" style="flex: 1">
      <!-- ── Sidebar ─────────────────────────────────────────── -->
      <div class="split-left">
        <div class="card-head" style="background: var(--bg-1)">
          <h3>Saved Requests</h3>
          <button class="btn icon ghost" @click="loadRequests" title="Refresh">
            ↻
          </button>
        </div>

        <div style="flex: 1; overflow-y: auto">
          <div
            v-for="r in filteredRequests"
            :key="r.id"
            class="list-item"
            :class="{ active: selectedRequest?.id === r.id }"
            style="cursor: pointer"
            @click="loadSavedRequest(r.id)"
            :title="r.url"
          >
            <div style="min-width: 0; flex: 1">
              <div style="display: flex; align-items: center; gap: 6px">
                <span class="method" :class="r.method">{{ r.method }}</span>
                <span
                  style="
                    font-size: 12px;
                    font-weight: 500;
                    overflow: hidden;
                    text-overflow: ellipsis;
                    white-space: nowrap;
                  "
                >
                  {{ r.name || truncUrl(r.url) }}
                </span>
              </div>
              <div class="meta">{{ r.collection }}</div>
            </div>
            <button
              class="btn icon ghost sm"
              @click.stop="deleteRequest(r.id)"
              title="Delete"
            >
              🗑
            </button>
          </div>
          <div
            v-if="!filteredRequests.length"
            class="empty"
            style="padding: 20px"
          >
            <p>No saved requests.</p>
          </div>
        </div>

        <!-- History — clicking restores the request into the editor -->
        <div
          style="
            border-top: 1px solid var(--border);
            display: flex;
            flex-direction: column;
          "
        >
          <div class="card-head" style="background: var(--bg-1)">
            <h3>Recent History</h3>
            <button class="btn sm ghost" @click="loadRecent">↻</button>
          </div>
          <div style="max-height: 220px; overflow-y: auto">
            <div
              v-for="h in recentHistory"
              :key="h.id"
              class="list-item"
              style="cursor: pointer"
              @click="loadHistoryRequest(h.id)"
              :title="'Click to load ' + h.method + ' ' + h.url"
            >
              <div style="min-width: 0; flex: 1">
                <div style="display: flex; gap: 6px; align-items: center">
                  <span class="method" :class="h.method">{{ h.method }}</span>
                  <span
                    style="
                      font-size: 11px;
                      overflow: hidden;
                      text-overflow: ellipsis;
                      white-space: nowrap;
                    "
                    >{{ truncUrl(h.url) }}</span
                  >
                </div>
                <div class="meta">
                  {{ h.responded_at ? fmtDate(h.responded_at) : "pending" }}
                </div>
              </div>
              <!-- Status as plain text, not interactive -->
              <span
                v-if="h.status"
                style="font-size: 11px; font-weight: 700; flex-shrink: 0"
                :style="{
                  color:
                    h.status >= 200 && h.status < 300
                      ? 'var(--green)'
                      : h.status >= 400
                        ? 'var(--red)'
                        : 'var(--yellow)',
                }"
                >{{ h.status }}</span
              >
            </div>
            <div
              v-if="!recentHistory.length"
              style="padding: 12px 14px"
              class="muted"
            >
              No history yet.
            </div>
          </div>
        </div>
      </div>

      <!-- ── Editor + Response ──────────────────────────────── -->
      <div class="split-right">
        <!-- URL bar -->
        <div
          style="
            padding: 10px 12px;
            background: var(--bg-1);
            border-bottom: 1px solid var(--border);
            display: flex;
            gap: 8px;
          "
        >
          <select
            v-model="method"
            class="input"
            style="width: 100px; height: 32px; flex-shrink: 0"
          >
            <option>GET</option>
            <option>POST</option>
            <option>PUT</option>
            <option>PATCH</option>
            <option>DELETE</option>
          </select>
          <input
            v-model="url"
            class="input mono grow"
            placeholder="https://api.example.com/endpoint"
            style="height: 32px"
            @keydown.enter="send"
          />
          <button
            class="btn primary"
            @click="send"
            :disabled="sending"
            style="height: 32px"
          >
            {{ sending ? "…" : "▶ Send" }}
          </button>
        </div>

        <!-- Request tabs -->
        <div class="tabs">
          <button
            class="tab"
            :class="{ active: reqTab === 'headers' }"
            @click="reqTab = 'headers'"
          >
            Headers
            <span
              v-if="activeHeaders.length"
              style="color: var(--accent); margin-left: 3px"
              >{{ activeHeaders.length }}</span
            >
          </button>
          <button
            class="tab"
            :class="{ active: reqTab === 'body' }"
            @click="reqTab = 'body'"
          >
            Body
          </button>
          <button
            class="tab"
            :class="{ active: reqTab === 'vars' }"
            @click="reqTab = 'vars'"
          >
            Variables
          </button>
        </div>

        <div
          style="
            height: 160px;
            overflow: hidden;
            display: flex;
            flex-direction: column;
          "
        >
          <!-- Headers -->
          <div
            v-if="reqTab === 'headers'"
            style="
              flex: 1;
              overflow-y: auto;
              padding: 8px 12px;
              display: flex;
              flex-direction: column;
              gap: 5px;
            "
          >
            <div v-for="(h, i) in headers" :key="i" class="row">
              <input
                v-model="h.enabled"
                type="checkbox"
                style="flex-shrink: 0; width: 14px; cursor: pointer"
                title="Enable/disable"
              />
              <input
                v-model="h.key"
                class="input mono"
                placeholder="Header-Name"
                style="width: 190px"
              />
              <input
                v-model="h.value"
                class="input mono grow"
                placeholder="value"
              />
              <button class="btn icon ghost sm" @click="headers.splice(i, 1)">
                ✕
              </button>
            </div>
            <button
              class="btn sm ghost"
              @click="headers.push({ key: '', value: '', enabled: true })"
              style="align-self: flex-start; margin-top: 2px"
            >
              ＋ Add Header
            </button>
          </div>

          <!-- Body -->
          <div
            v-if="reqTab === 'body'"
            style="
              flex: 1;
              overflow: hidden;
              display: flex;
              flex-direction: column;
            "
          >
            <div
              style="
                padding: 5px 12px;
                display: flex;
                gap: 8px;
                align-items: center;
                border-bottom: 1px solid var(--border);
                flex-shrink: 0;
              "
            >
              <select
                v-model="bodyType"
                class="input"
                style="width: 150px; height: 26px"
              >
                <option value="none">No Body</option>
                <option value="json">JSON</option>
                <option value="text">Plain Text</option>
              </select>
              <button
                v-if="bodyType === 'json'"
                class="btn sm ghost"
                @click="prettifyJson"
              >
                Prettify
              </button>
            </div>
            <textarea
              v-if="bodyType !== 'none'"
              v-model="body"
              class="input mono"
              style="
                flex: 1;
                resize: none;
                border: none;
                border-radius: 0;
                height: auto;
                font-size: 12px;
                background: var(--bg-0);
              "
              :placeholder="bodyPlaceholder"
            ></textarea>
            <div
              v-else
              style="
                flex: 1;
                display: flex;
                align-items: center;
                justify-content: center;
              "
              class="muted"
            >
              No body for this request.
            </div>
          </div>

          <!-- Variables -->
          <div
            v-if="reqTab === 'vars'"
            style="
              flex: 1;
              overflow-y: auto;
              padding: 8px 12px;
              display: flex;
              flex-direction: column;
              gap: 6px;
            "
          >
            <p class="muted">
              Use
              <code
                v-pre
                style="
                  color: var(--accent);
                  background: var(--accent-dim);
                  padding: 1px 4px;
                  border-radius: 3px;
                "
                >{{ name }}</code
              >
              in URL or header values.
            </p>
            <div v-for="(v, i) in variables" :key="i" class="row">
              <input
                v-model="v.key"
                class="input mono"
                placeholder="variable name"
                style="width: 160px"
              />
              <input
                v-model="v.value"
                class="input mono grow"
                placeholder="value"
              />
              <button class="btn icon ghost sm" @click="variables.splice(i, 1)">
                ✕
              </button>
            </div>
            <button
              class="btn sm ghost"
              @click="variables.push({ key: '', value: '' })"
              style="align-self: flex-start"
            >
              ＋ Add Variable
            </button>
          </div>
        </div>

        <!-- Response -->
        <div
          style="
            flex: 1;
            overflow: hidden;
            display: flex;
            flex-direction: column;
            border-top: 1px solid var(--border);
          "
        >
          <div
            v-if="response"
            style="
              flex: 1;
              display: flex;
              flex-direction: column;
              overflow: hidden;
            "
          >
            <div
              style="
                padding: 6px 14px;
                background: var(--bg-2);
                border-bottom: 1px solid var(--border);
                display: flex;
                gap: 12px;
                align-items: center;
                flex-shrink: 0;
              "
            >
              <span
                style="font-size: 13px; font-weight: 700"
                :style="{
                  color: response.success ? 'var(--green)' : 'var(--red)',
                }"
                >{{ response.status }}</span
              >
              <span class="muted">{{ response.duration_ms }}ms</span>
              <span class="muted">{{ fmtBytes(response.size_bytes) }}</span>
              <div style="flex: 1"></div>
              <button class="btn sm ghost" @click="copyResponse">Copy</button>
              <button
                class="tab sm"
                :class="{ active: resTab === 'pretty' }"
                @click="resTab = 'pretty'"
                style="padding: 3px 10px; font-size: 11px"
              >
                Pretty
              </button>
              <button
                class="tab sm"
                :class="{ active: resTab === 'raw' }"
                @click="resTab = 'raw'"
                style="padding: 3px 10px; font-size: 11px"
              >
                Raw
              </button>
            </div>
            <div v-if="resTab === 'pretty'" style="flex: 1; overflow: auto">
              <JsonViewer v-if="parsedResponse" :data="parsedResponse" />
              <pre v-else class="console" style="flex: 1">{{
                response.body
              }}</pre>
            </div>
            <pre v-else class="console" style="flex: 1; overflow-y: auto">{{
              response.body
            }}</pre>
          </div>
          <div
            v-else-if="sendError"
            style="
              flex: 1;
              padding: 16px;
              display: flex;
              flex-direction: column;
              gap: 10px;
            "
          >
            <div style="display: flex; align-items: center; gap: 8px">
              <span style="color: var(--red); font-weight: 700; font-size: 13px"
                >Request Failed</span
              >
            </div>
            <pre
              style="
                background: var(--red-dim);
                border: 1px solid var(--red);
                border-radius: var(--radius);
                padding: 12px 14px;
                font-family: var(--font-mono);
                font-size: 12px;
                color: var(--red);
                white-space: pre-wrap;
                word-break: break-all;
                line-height: 1.6;
              "
              >{{ sendError }}</pre
            >
            <p class="muted">
              Check the app logs for more detail. Common causes: network error,
              capability denied, invalid URL, SSL certificate.
            </p>
          </div>
          <div v-else class="empty" style="flex: 1">
            <div class="icon">🌐</div>
            <p>
              Send a request to see the response here.<br />Requests and
              responses are saved to the in-memory store automatically.
            </p>
          </div>
        </div>
      </div>
    </div>

    <!-- Save modal -->
    <div
      v-if="showSaveModal"
      style="
        position: fixed;
        inset: 0;
        background: rgba(0, 0, 0, 0.65);
        display: flex;
        align-items: center;
        justify-content: center;
        z-index: 1000;
      "
      @click.self="showSaveModal = false"
    >
      <div class="card" style="width: 380px">
        <div class="card-head"><h3>Save Request</h3></div>
        <div
          class="card-body"
          style="display: flex; flex-direction: column; gap: 10px"
        >
          <input
            v-model="saveName"
            class="input"
            placeholder="Request name (optional)"
          />
          <input
            v-model="saveCollection"
            class="input"
            placeholder="Collection"
          />
        </div>
        <div
          class="card-foot"
          style="display: flex; gap: 8px; justify-content: flex-end"
        >
          <button class="btn ghost" @click="showSaveModal = false">
            Cancel
          </button>
          <button class="btn primary" @click="confirmSave">Save</button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from "vue";
import { invoke } from "../ipc";
import { useAppStore } from "../stores/app";
import JsonViewer from "../components/JsonViewer.vue";

const appStore = useAppStore();

const method = ref("GET");
const url = ref("https://jsonplaceholder.typicode.com/posts/1");
const headers = ref<Array<{ key: string; value: string; enabled: boolean }>>([
  { key: "Accept", value: "application/json", enabled: true },
]);
const body = ref("");
const bodyType = ref("none");
const variables = ref<Array<{ key: string; value: string }>>([]);
const reqTab = ref("headers");
const resTab = ref("pretty");
const sending = ref(false);
const response = ref<any>(null);
const parsedResponse = ref<any>(null);
const sendError = ref<string | null>(null);
const savedRequests = ref<any[]>([]);
const recentHistory = ref<any[]>([]);
const collections = ref<string[]>([]);
const activeCollection = ref("");
const selectedRequest = ref<any>(null);
const showSaveModal = ref(false);
const saveName = ref("");
const saveCollection = ref("Default");

const filteredRequests = computed(() =>
  activeCollection.value
    ? savedRequests.value.filter((r) => r.collection === activeCollection.value)
    : savedRequests.value,
);

// Only count enabled headers with a key
const activeHeaders = computed(() =>
  headers.value.filter((h) => h.key && h.enabled),
);

const bodyPlaceholder = computed(() =>
  bodyType.value === "json" ? '{\n  "key": "value"\n}' : "Request body…",
);

function truncUrl(u: string): string {
  try {
    const parsed = new URL(u);
    const p = parsed.pathname.slice(0, 35);
    return p && p !== "/" ? p : parsed.hostname;
  } catch {
    return u.slice(0, 35);
  }
}

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

function fmtDate(d: string): string {
  try {
    return new Date(d).toLocaleTimeString();
  } catch {
    return d;
  }
}

function interpolate(s: string): string {
  return variables.value.reduce(
    (acc, v) =>
      v.key
        ? acc.replace(new RegExp(`\\{\\{${v.key}\\}\\}`, "g"), v.value)
        : acc,
    s,
  );
}

function applyRequest(data: {
  method?: string;
  url?: string;
  headers?: string | Record<string, string>;
  body?: string;
}) {
  // Force uppercase and validate against known methods
  const knownMethods = ["GET", "POST", "PUT", "PATCH", "DELETE"];
  const m = String(data.method || "GET").toUpperCase();
  method.value = knownMethods.includes(m) ? m : "GET";

  url.value = String(data.url || "");

  // Parse stored headers (JSON string from DB)
  if (data.headers) {
    try {
      const h =
        typeof data.headers === "string"
          ? JSON.parse(data.headers)
          : data.headers;
      headers.value = Object.entries(h).map(([key, value]) => ({
        key,
        value: String(value),
        enabled: true,
      }));
      if (headers.value.length === 0) {
        headers.value = [
          { key: "Accept", value: "application/json", enabled: true },
        ];
      }
    } catch {
      headers.value = [
        { key: "Accept", value: "application/json", enabled: true },
      ];
    }
  }

  if (data.body && data.body.trim()) {
    body.value = data.body;
    bodyType.value =
      data.body.trim().startsWith("{") || data.body.trim().startsWith("[")
        ? "json"
        : "text";
  } else {
    body.value = "";
    bodyType.value = "none";
  }

  response.value = null;
  parsedResponse.value = null;
}

async function loadSavedRequest(id: number) {
  try {
    const full = await invoke<any>("http_client.get_request", id);
    console.log(
      "[http] get_request id=" + id + " result:",
      JSON.stringify(full),
    );
    if (!full) {
      appStore.toast("Request not found", "error");
      return;
    }
    selectedRequest.value = full;
    method.value = String(full.method || "GET").toUpperCase();
    url.value = String(full.url || "");
    console.log("[http] set method=" + method.value + " url=" + url.value);
    applyRequest(full);
    appStore.toast(
      `Loaded: ${full.name || truncUrl(String(full.url || ""))}`,
      "info",
      1200,
    );
  } catch (e: any) {
    console.error("[http] loadSavedRequest error:", e);
    appStore.toast(e.message, "error");
  }
}

async function loadHistoryRequest(historyId: number) {
  // Find the request from history and populate the editor
  const h = recentHistory.value.find((r) => r.id === historyId);
  if (!h) return;
  // Load the full saved request to get headers/body
  try {
    const full = await invoke<any>("http_client.get_request", h.id);
    if (full) {
      applyRequest(full);
    } else {
      // Fallback: at least fill method+url from history row
      applyRequest({ method: h.method, url: h.url });
    }
    appStore.toast(`Loaded from history`, "info", 1000);
  } catch {
    applyRequest({ method: h.method, url: h.url });
    appStore.toast(`Loaded from history`, "info", 1000);
  }
}

async function send() {
  if (!url.value.trim()) return;
  sending.value = true;
  response.value = null;
  parsedResponse.value = null;
  sendError.value = null;

  const hdrs: Record<string, string> = {};
  headers.value
    .filter((h) => h.key && h.enabled)
    .forEach((h) => {
      hdrs[h.key] = h.value;
    });

  if (bodyType.value === "json" && !hdrs["Content-Type"]) {
    hdrs["Content-Type"] = "application/json";
  }

  const finalUrl = interpolate(url.value);
  const finalBody = bodyType.value === "none" ? "" : interpolate(body.value);

  try {
    response.value = await invoke<any>("http_client.send", [
      method.value,
      finalUrl,
      hdrs,
      finalBody,
    ]);
    try {
      parsedResponse.value = JSON.parse(response.value.body);
    } catch {}
  } catch (e: any) {
    const msg = e?.message || String(e);
    sendError.value = msg;
    console.error(
      "[http:send] error:",
      msg,
      "\nURL:",
      finalUrl,
      "\nMethod:",
      method.value,
    );
  } finally {
    sending.value = false;
    loadRecent();
  }
}

async function loadRequests() {
  savedRequests.value = await invoke<any[]>("http_client.list_requests", activeCollection.value).catch(() => []) ?? [];
}

async function loadRecent() {
  recentHistory.value = await invoke<any[]>("http_client.recent", 30).catch(() => []) ?? [];
}

async function loadCollections() {
  collections.value = await invoke<string[]>("http_client.collections").catch(
    () => [],
  ) ?? [];
}

async function deleteRequest(id: number) {
  await invoke("http_client.delete_request", id);
  appStore.toast("Deleted", "ok");
  if (selectedRequest.value?.id === id) newRequest();
  loadRequests();
}

function newRequest() {
  method.value = "GET";
  url.value = "";
  body.value = "";
  bodyType.value = "none";
  headers.value = [{ key: "Accept", value: "application/json", enabled: true }];
  response.value = null;
  parsedResponse.value = null;
  sendError.value = null;
  selectedRequest.value = null;
}

function saveRequest() {
  saveName.value = selectedRequest.value?.name || "";
  saveCollection.value = selectedRequest.value?.collection || "Default";
  showSaveModal.value = true;
}

async function confirmSave() {
  const hdrs: Record<string, string> = {};
  headers.value
    .filter((h) => h.key && h.enabled)
    .forEach((h) => {
      hdrs[h.key] = h.value;
    });

  await invoke("http_client.save_request", [
    saveName.value,
    method.value,
    url.value,
    hdrs,
    body.value,
    saveCollection.value || "Default",
  ]);
  showSaveModal.value = false;
  appStore.toast("Request saved", "ok");
  loadRequests();
  loadCollections();
}

function prettifyJson() {
  try {
    body.value = JSON.stringify(JSON.parse(body.value), null, 2);
  } catch {}
}

async function copyResponse() {
  if (!response.value) return;
  await invoke("app.clipboard_write", response.value.body);
  appStore.toast("Copied to clipboard", "ok");
}

onMounted(() => {
  loadRequests();
  loadRecent();
  loadCollections();
});
</script>
