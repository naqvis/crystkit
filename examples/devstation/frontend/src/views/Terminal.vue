<template>
  <div class="view-area">
    <div class="topbar">
      <span class="topbar-title">Terminal</span>
      <button class="btn sm primary" @click="newSession">＋ New Session</button>
      <button class="btn sm ghost" @click="showHistory = !showHistory">
        {{ showHistory ? "Hide History" : "History" }}
      </button>
      <button
        class="btn sm ghost"
        @click="killActive"
        :disabled="!activeSession?.running"
      >
        Kill
      </button>
    </div>

    <div class="tabs" v-if="sessionList.length">
      <div
        v-for="s in sessionList"
        :key="s.id"
        class="tab"
        :class="{ active: terminal.activeId === s.id }"
        @click="terminal.activeId = s.id"
        role="tab"
        :aria-selected="terminal.activeId === s.id"
      >
        <span
          :style="{
            color: s.running
              ? 'var(--green)'
              : s.exitCode === 0
                ? 'var(--text-2)'
                : 'var(--red)',
          }"
          >●</span
        >
        {{ s.title }}
        <span
          class="close"
          @click.stop="terminal.closeSession(s.id)"
          role="button"
          tabindex="0"
        >
          ✕
        </span>
      </div>
    </div>

    <div style="display: flex; flex: 1; overflow: hidden">
      <!-- Terminal output panel -->
      <div
        style="flex: 1; display: flex; flex-direction: column; overflow: hidden"
      >
        <!-- Command input -->
        <div
          style="
            padding: 8px 12px;
            background: var(--bg-1);
            border-bottom: 1px solid var(--border);
            display: flex;
            gap: 8px;
            align-items: center;
          "
        >
          <span
            style="
              color: var(--green);
              font-family: var(--font-mono);
              font-size: 13px;
            "
            >$</span
          >
          <input
            ref="cmdInput"
            v-model="cmdLine"
            class="input mono grow"
            placeholder="command to spawn…"
            @keydown.enter="spawn"
            @keydown.up="historyUp"
            @keydown.down="historyDown"
            style="
              background: transparent;
              border-color: transparent;
              height: 28px;
            "
          />
          <input
            v-model="cwdInput"
            class="input mono"
            placeholder="cwd (optional)"
            style="width: 220px; height: 28px"
          />
          <button class="btn sm primary" @click="spawn">▶ Spawn</button>
          <button class="btn sm ghost" @click="runSync">⚡ Sync</button>
        </div>

        <!-- Output -->
        <div
          v-if="activeSession"
          style="
            flex: 1;
            overflow: hidden;
            display: flex;
            flex-direction: column;
          "
        >
          <pre
            ref="outputEl"
            class="console"
            style="flex: 1; overflow-y: auto; padding: 12px 14px"
            v-html="ansiToHtml(activeSession.output)"
          ></pre>
          <div
            v-if="!activeSession.running && activeSession.exitCode !== null"
            style="
              padding: 4px 12px;
              background: var(--bg-2);
              font-size: 11px;
              display: flex;
              gap: 10px;
            "
          >
            <span
              :class="activeSession.exitCode === 0 ? 'pill ok' : 'pill error'"
            >
              exit {{ activeSession.exitCode }}
            </span>
            <span class="muted">{{ activeSession.cwd }}</span>
          </div>
        </div>

        <!-- Sync result -->
        <div
          v-else-if="syncResult"
          style="flex: 1; display: flex; flex-direction: column"
        >
          <div
            style="
              padding: 8px 12px;
              background: var(--bg-2);
              font-size: 11px;
              display: flex;
              gap: 10px;
              border-bottom: 1px solid var(--border);
            "
          >
            <span :class="syncResult.exit_code === 0 ? 'pill ok' : 'pill error'"
              >exit {{ syncResult.exit_code }}</span
            >
            <span class="muted">{{ syncResult.duration_ms }}ms</span>
          </div>
          <pre class="console" style="flex: 1; overflow-y: auto; padding: 12px"
            >{{ syncResult.stdout
            }}{{
              syncResult.stderr ? "\n— stderr —\n" + syncResult.stderr : ""
            }}</pre
          >
        </div>

        <div v-else class="empty" style="flex: 1">
          <div class="icon">🖥️</div>
          <p>
            Spawn a command to start a session.<br />Process output streams back
            in real time.
          </p>
        </div>
      </div>

      <!-- History panel -->
      <div
        v-if="showHistory"
        style="
          width: 300px;
          border-left: 1px solid var(--border);
          display: flex;
          flex-direction: column;
          overflow: hidden;
        "
      >
        <div class="card-head">
          <h3>Command History</h3>
          <button class="btn sm ghost" @click="clearHistory">clear</button>
        </div>
        <div style="flex: 1; overflow-y: auto">
          <div
            v-for="h in historyList"
            :key="h.id"
            class="list-item"
            @click="cmdLine = h.command"
            style="cursor: pointer"
          >
            <div>
              <span style="font-family: var(--font-mono); font-size: 12px">{{
                h.command
              }}</span>
              <div class="meta">{{ h.ran_at }}</div>
            </div>
            <span
              v-if="h.exit_code !== null"
              class="pill"
              :class="h.exit_code === 0 ? 'ok' : 'error'"
            >
              {{ h.exit_code }}
            </span>
          </div>
          <div v-if="!historyList.length" class="empty">
            <p>No history yet</p>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, nextTick, watch } from "vue";
import { useTerminalStore } from "../stores/terminal";
import { useAppStore } from "../stores/app";

const terminal = useTerminalStore();
const appStore = useAppStore();

const cmdInput = ref<HTMLInputElement | null>(null);
const outputEl = ref<HTMLPreElement | null>(null);
const cmdLine = ref("ls -la");
const cwdInput = ref("");
const showHistory = ref(false);
const syncResult = ref<any>(null);
const historyList = ref<any[]>([]);
const histIdx = ref(-1);

const sessionList = computed(() => Object.values(terminal.sessions));
const activeSession = computed(() =>
  terminal.activeId ? terminal.sessions[terminal.activeId] : null,
);

watch(
  activeSession,
  async () => {
    await nextTick();
    if (outputEl.value) outputEl.value.scrollTop = outputEl.value.scrollHeight;
  },
  { deep: true },
);

// Simple ANSI escape code renderer
function ansiToHtml(text: string): string {
  const map: Record<string, string> = {
    "30": "color:#656d76",
    "31": "color:#f85149",
    "32": "color:#3fb950",
    "33": "color:#d29922",
    "34": "color:#4a9eff",
    "35": "color:#bc8cff",
    "36": "color:#56d364",
    "37": "color:#e6edf3",
    "0": "",
    "1": "font-weight:bold",
  };
  // Escape HTML first
  let html = text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");

  // Replace ANSI codes — track open spans to close them properly
  let openSpans = 0;
  html = html.replace(/\x1b\[(\d+)m/g, (_, code) => {
    if (code === "0") {
      const close = openSpans > 0 ? "</span>".repeat(openSpans) : "";
      openSpans = 0;
      return close;
    }
    const style = map[code];
    if (style) {
      openSpans++;
      return `<span style="${style}">`;
    }
    return "";
  });
  if (openSpans > 0) html += "</span>".repeat(openSpans);

  // Handle carriage returns
  html = html.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  return html;
}

function spawn() {
  if (!cmdLine.value.trim()) return;
  const parts = cmdLine.value.trim().split(/\s+/);
  const command = parts[0];
  const args = parts.slice(1);
  terminal.spawnSession(command, args, cwdInput.value);
  syncResult.value = null;
  histIdx.value = -1;
}

async function runSync() {
  if (!cmdLine.value.trim()) return;
  const parts = cmdLine.value.trim().split(/\s+/);
  try {
    syncResult.value = await terminal.runSync(
      parts[0],
      parts.slice(1),
      cwdInput.value,
    );
  } catch (e: any) {
    appStore.toast(e.message, "error");
  }
}

function killActive() {
  if (terminal.activeId) terminal.killSession(terminal.activeId);
}

function newSession() {
  cmdInput.value?.focus();
}

function historyUp() {
  if (!historyList.value.length) return;
  histIdx.value = Math.min(histIdx.value + 1, historyList.value.length - 1);
  cmdLine.value = historyList.value[histIdx.value]?.command ?? cmdLine.value;
}

function historyDown() {
  if (histIdx.value <= 0) {
    histIdx.value = -1;
    cmdLine.value = "";
    return;
  }
  histIdx.value--;
  cmdLine.value = historyList.value[histIdx.value]?.command ?? "";
}

async function clearHistory() {
  await terminal.runSync("true", [], ""); // just to trigger
  const { invoke } = await import("../ipc");
  await invoke("terminal.clear_history");
  historyList.value = [];
  appStore.toast("History cleared", "ok");
}

onMounted(async () => {
  await terminal.loadHistory();
  historyList.value = terminal.history;
  cmdInput.value?.focus();
});
</script>
