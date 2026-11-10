<template>
  <div class="view-area">
    <div class="topbar">
      <span class="topbar-title">Settings</span>
    </div>

    <div class="view-scroll" style="padding: 16px">
      <!-- ── Appearance ───────────────────────────────────────────────── -->
      <div class="card">
        <div class="card-head"><h3>🎨 Appearance</h3></div>
        <div
          class="card-body"
          style="display: flex; flex-direction: column; gap: 16px"
        >
          <div>
            <div
              class="muted"
              style="
                margin-bottom: 8px;
                font-size: 11px;
                text-transform: uppercase;
                letter-spacing: 0.06em;
              "
            >
              Theme
            </div>
            <div style="display: flex; gap: 8px">
              <button
                v-for="opt in themeOptions"
                :key="opt.value"
                class="theme-btn"
                :class="{ active: appStore.themeChoice === opt.value }"
                @click="appStore.setTheme(opt.value)"
              >
                <span class="theme-swatch" :data-swatch="opt.value"></span>
                <span>{{ opt.label }}</span>
                <span
                  v-if="appStore.themeChoice === opt.value"
                  class="theme-check"
                  >✓</span
                >
              </button>
            </div>
            <p class="muted" style="margin-top: 8px">
              <span v-if="appStore.themeChoice === 'system'">
                Following OS — currently
                <strong style="color: var(--text-0)">{{
                  appStore.theme
                }}</strong
                >. Changes automatically when your system theme changes.
              </span>
              <span v-else>
                Manually set to
                <strong style="color: var(--text-0)">{{
                  appStore.themeChoice
                }}</strong
                >. Switch to System to follow the OS automatically.
              </span>
            </p>
          </div>

          <!-- Live preview strip -->
          <div style="display: flex; gap: 10px; align-items: center">
            <div class="preview-strip dark">Dark</div>
            <div class="preview-strip light">Light</div>
            <span class="muted" style="font-size: 11px"
              >Active:
              <strong style="color: var(--accent)">{{
                appStore.theme
              }}</strong></span
            >
          </div>
        </div>
      </div>

      <!-- ── About ───────────────────────────────────────────────────── -->
      <div class="card">
        <div class="card-head"><h3>About CrystKit DevStation</h3></div>
        <div class="card-body">
          <table class="data-table">
            <tbody>
              <tr>
                <td class="muted">Version</td>
                <td>1.0.0</td>
              </tr>
              <tr>
                <td class="muted">Framework</td>
                <td>CrystKit (Crystal + WebView)</td>
              </tr>
              <tr>
                <td class="muted">Frontend</td>
                <td>Vue 3 + Vite + Pinia + Vue Router</td>
              </tr>
              <tr>
                <td class="muted">Code Editor</td>
                <td>CodeMirror 6</td>
              </tr>
              <tr>
                <td class="muted">Storage</td>
                <td>In-memory (non-persistent)</td>
              </tr>
              <tr v-if="staticInfo">
                <td class="muted">OS</td>
                <td>{{ staticInfo.os.name }} {{ staticInfo.os.version }}</td>
              </tr>
              <tr v-if="staticInfo">
                <td class="muted">Host</td>
                <td>{{ staticInfo.hostname }}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <div class="card-foot">
          <button class="btn sm ghost" @click="pingNative">
            ⚡ Test native bridge
          </button>
          <span
            v-if="pingResult"
            class="muted"
            style="
              margin-left: 10px;
              font-family: var(--font-mono);
              font-size: 11px;
            "
            >{{ pingResult }}</span
          >
        </div>
      </div>

      <!-- ── Secrets vault ───────────────────────────────────────────── -->
      <div class="card">
        <div class="card-head">
          <h3>🔑 Secrets Vault (OS Keychain)</h3>
          <button class="btn sm ghost" @click="loadSecrets">refresh</button>
        </div>
        <div
          class="card-body"
          style="display: flex; flex-direction: column; gap: 10px"
        >
          <p class="muted">
            Secrets are stored in the platform credential store. Raw values
            never leave the backend.
          </p>
          <div class="row">
            <input
              v-model="secretKey"
              class="input"
              placeholder="key"
              style="width: 180px"
            />
            <input
              v-model="secretVal"
              class="input mono grow"
              type="password"
              placeholder="value"
            />
            <button class="btn sm primary" @click="setSecret">Store</button>
          </div>
          <div style="display: flex; flex-direction: column; gap: 4px">
            <div
              v-for="s in secrets"
              :key="s.key"
              class="list-item"
              style="padding: 6px 8px"
            >
              <div>
                <span style="font-family: var(--font-mono); font-weight: 500">{{
                  s.key
                }}</span>
                <span
                  class="muted"
                  style="margin-left: 8px; font-family: var(--font-mono)"
                  >{{ s.preview }}</span
                >
              </div>
              <button class="btn icon ghost sm" @click="deleteSecret(s.key)">
                🗑
              </button>
            </div>
            <div v-if="!secrets.length" class="muted">No secrets stored.</div>
          </div>
        </div>
      </div>

      <!-- ── Global shortcuts ────────────────────────────────────────── -->
      <div class="card">
        <div class="card-head"><h3>Global Shortcuts</h3></div>
        <div class="card-body" style="padding: 0">
          <table class="data-table">
            <thead>
              <tr>
                <th>Shortcut</th>
                <th>Action</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td style="font-family: var(--font-mono)">Meta+Shift+D</td>
                <td>Focus DevStation window</td>
              </tr>
              <tr>
                <td style="font-family: var(--font-mono)">Meta+Shift+T</td>
                <td>New Terminal Session</td>
              </tr>
              <tr>
                <td style="font-family: var(--font-mono)">Meta+Shift+F</td>
                <td>File Search</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <!-- ── Notifications test ──────────────────────────────────────── -->
      <div class="card">
        <div class="card-head"><h3>Notifications</h3></div>
        <div class="card-body" style="display: flex; gap: 8px">
          <input
            v-model="notifTitle"
            class="input"
            placeholder="Title"
            style="width: 180px"
          />
          <input v-model="notifBody" class="input grow" placeholder="Body" />
          <button class="btn sm primary" @click="sendNotification">Send</button>
        </div>
      </div>

      <!-- ── Multi-window ────────────────────────────────────────────── -->
      <div class="card">
        <div class="card-head"><h3>Multi-Window</h3></div>
        <div class="card-body" style="display: flex; gap: 8px; flex-wrap: wrap">
          <button class="btn" @click="openTerminalWindow">
            Open Terminal Window
          </button>
        </div>
        <div class="card-foot">
          <span class="muted"
            >Each window is independent — new Crystal webview, same IPC/event
            bus.</span
          >
        </div>
      </div>

      <!-- ── DevTools ────────────────────────────────────────────────── -->
      <div class="card">
        <div class="card-head"><h3>Developer Tools</h3></div>
        <div
          class="card-body"
          style="display: flex; gap: 8px; flex-direction: column"
        >
          <p class="muted">
            Open the WebKit developer tools inspector for this window.
          </p>
          <div class="row">
            <button class="btn" @click="toggleDevTools">
              Toggle DevTools (Cmd+Alt+I)
            </button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted, computed } from "vue";
import { invoke, ping } from "../ipc";
import { useVitalsStore } from "../stores/vitals";
import { useAppStore } from "../stores/app";
import type { ThemeChoice } from "../stores/app";

const vitals = useVitalsStore();
const appStore = useAppStore();

const staticInfo = computed(() => vitals.staticInfo);

const themeOptions: Array<{ value: ThemeChoice; label: string }> = [
  { value: "system", label: "System" },
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
];

const secretKey = ref("");
const secretVal = ref("");
const secrets = ref<Array<{ key: string; preview: string }>>([]);
const pingResult = ref("");
const notifTitle = ref("DevStation");
const notifBody = ref("Hello from CrystKit!");

async function pingNative() {
  try {
    pingResult.value = await ping("settings ping");
    appStore.toast(pingResult.value, "ok");
  } catch (e: any) {
    pingResult.value = e.message;
  }
}

async function loadSecrets() {
  secrets.value = await invoke<typeof secrets.value>("app.secret_list").catch(
    () => [],
  ) ?? [];
}

async function setSecret() {
  if (!secretKey.value || !secretVal.value) return;
  await invoke("app.secret_set", [secretKey.value, secretVal.value]);
  secretKey.value = "";
  secretVal.value = "";
  appStore.toast("Secret stored", "ok");
  loadSecrets();
}

async function deleteSecret(key: string) {
  await invoke("app.secret_delete", key).catch(() => {});
  appStore.toast("Secret deleted", "ok");
  loadSecrets();
}

async function sendNotification() {
  await invoke("app.notify", [notifTitle.value, notifBody.value]);
  appStore.toast("Notification sent", "ok");
}

async function openTerminalWindow() {
  await invoke("app.open_terminal_window");
  appStore.toast("Opened terminal window", "ok");
}

async function toggleDevTools() {
  await invoke("app.devtools_toggle");
}

onMounted(() => {
  loadSecrets();
});
</script>

<style scoped>
.theme-btn {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 16px;
  border: 2px solid var(--border);
  border-radius: var(--radius);
  background: var(--bg-2);
  color: var(--text-0);
  cursor: pointer;
  font-size: 13px;
  font-family: var(--font-ui);
  font-weight: 500;
  transition:
    border-color 0.15s,
    background 0.15s;
  min-width: 100px;
}
.theme-btn:hover {
  background: var(--bg-3);
}
.theme-btn.active {
  border-color: var(--accent);
  background: var(--accent-dim);
  color: var(--accent);
}
.theme-check {
  margin-left: auto;
  font-size: 12px;
}

.theme-swatch {
  width: 20px;
  height: 20px;
  border-radius: 50%;
  border: 2px solid var(--border);
  flex-shrink: 0;
}
.theme-swatch[data-swatch="dark"] {
  background: #0d1117;
}
.theme-swatch[data-swatch="light"] {
  background: #f6f8fa;
}
.theme-swatch[data-swatch="system"] {
  background: linear-gradient(135deg, #0d1117 50%, #f6f8fa 50%);
}

.preview-strip {
  padding: 6px 14px;
  border-radius: var(--radius-sm);
  font-size: 11px;
  font-weight: 600;
  border: 1px solid;
}
.preview-strip.dark {
  background: #0d1117;
  color: #e6edf3;
  border-color: #30363d;
}
.preview-strip.light {
  background: #f6f8fa;
  color: #1f2328;
  border-color: #d0d7de;
}
</style>
