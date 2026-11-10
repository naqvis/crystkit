<template>
  <div class="view-area">
    <div class="topbar">
      <span class="topbar-title">System Dashboard</span>
      <span class="muted" v-if="snap">{{ timeStr }}</span>
      <div style="flex: 1"></div>
      <button
        class="btn sm ghost"
        @click="pingNative"
        title="Test bind_typed bridge"
      >
        ⚡ ping native
      </button>
      <button class="btn sm ghost" @click="openDevTools">DevTools</button>
    </div>

    <div
      style="
        flex: 1;
        overflow-y: auto;
        padding: 16px;
        display: flex;
        flex-direction: column;
        gap: 16px;
        background: var(--bg-0);
      "
    >
      <!-- ── Metric row ───────────────────────────────────────── -->
      <div class="grid-4">
        <MetricCard
          label="CPU Usage"
          :value="cpuPct.toFixed(1) + '%'"
          :sub="snap?.cpu.model ?? '…'"
          :pct="cpuPct"
          :color="gaugeColor(cpuPct)"
        />
        <MetricCard
          label="Memory"
          :value="memPct.toFixed(1) + '%'"
          :sub="
            fmtBytes(snap?.memory.used ?? 0) +
            ' / ' +
            fmtBytes(snap?.memory.total ?? 0)
          "
          :pct="memPct"
          :color="gaugeColor(memPct)"
        />
        <MetricCard
          label="Disk /"
          :value="diskPct.toFixed(1) + '%'"
          :sub="
            fmtBytes(snap?.disk.used ?? 0) +
            ' / ' +
            fmtBytes(snap?.disk.total ?? 0)
          "
          :pct="diskPct"
          :color="
            diskPct > 85
              ? 'var(--red)'
              : diskPct > 70
                ? 'var(--yellow)'
                : 'var(--accent)'
          "
        />
        <MetricCard
          :label="snap?.battery.present ? 'Battery' : 'Power'"
          :value="snap?.battery.present ? snap.battery.level + '%' : 'AC'"
          :sub="
            snap?.battery.present
              ? snap.battery.charging
                ? '⚡ charging'
                : '🔋 on battery'
              : 'no battery'
          "
          :pct="snap?.battery.present ? snap.battery.level : 100"
          :color="
            snap?.battery.present && snap.battery.level < 20
              ? 'var(--red)'
              : 'var(--green)'
          "
        />
      </div>

      <!-- ── Charts ──────────────────────────────────────────── -->
      <div class="grid-2">
        <div class="card">
          <div class="card-head">
            <h3>CPU History</h3>
            <span
              class="pill"
              :class="cpuPct > 80 ? 'error' : cpuPct > 60 ? 'warn' : 'ok'"
            >
              {{ cpuPct.toFixed(1) }}%
            </span>
          </div>
          <div style="height: 140px; background: var(--bg-0); overflow: hidden">
            <canvas
              ref="cpuCanvas"
              style="width: 100%; height: 140px; display: block"
            ></canvas>
          </div>
        </div>
        <div class="card">
          <div class="card-head">
            <h3>Memory History</h3>
            <span class="pill accent">{{
              fmtBytes(snap?.memory.used ?? 0)
            }}</span>
          </div>
          <div style="height: 140px; background: var(--bg-0); overflow: hidden">
            <canvas
              ref="memCanvas"
              style="width: 100%; height: 140px; display: block"
            ></canvas>
          </div>
        </div>
      </div>

      <!-- ── System info + displays/network ──────────────────── -->
      <div class="grid-2">
        <div class="card">
          <div class="card-head"><h3>Machine</h3></div>
          <table class="data-table" v-if="info">
            <tbody>
              <tr>
                <td class="muted">OS</td>
                <td>{{ info.os.name }} {{ info.os.version }}</td>
              </tr>
              <tr>
                <td class="muted">Architecture</td>
                <td>{{ info.arch }}</td>
              </tr>
              <tr>
                <td class="muted">Hostname</td>
                <td>{{ info.hostname }}</td>
              </tr>
              <tr>
                <td class="muted">CPU</td>
                <td>{{ info.cpu.model }}</td>
              </tr>
              <tr>
                <td class="muted">Cores / Threads</td>
                <td>{{ info.cpu.cores }} / {{ info.cpu.threads }}</td>
              </tr>
              <tr>
                <td class="muted">Frequency</td>
                <td>
                  {{ info.cpu.frequency ? info.cpu.frequency + " GHz" : "—" }}
                </td>
              </tr>
              <tr>
                <td class="muted">Locale</td>
                <td>{{ info.locale }}</td>
              </tr>
              <tr>
                <td class="muted">Idle</td>
                <td>{{ snap?.idle_seconds ?? 0 }}s</td>
              </tr>
              <tr>
                <td class="muted">Home</td>
                <td style="font-family: var(--font-mono); font-size: 11px">
                  {{ info.home_dir }}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="card">
          <div class="card-head"><h3>Displays &amp; Network</h3></div>
          <div style="padding: 12px 14px 8px">
            <div class="muted" style="margin-bottom: 6px">Displays</div>
            <div style="display: flex; flex-wrap: wrap; gap: 6px">
              <span class="pill accent" v-for="d in info?.displays" :key="d.id">
                {{ d.width }}×{{ d.height }} @{{ d.scale }}x{{
                  d.primary ? " ★" : ""
                }}
              </span>
            </div>
          </div>
          <div class="divider" style="margin: 0"></div>
          <table class="data-table">
            <thead>
              <tr>
                <th>Interface</th>
                <th>IP Address</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="n in info?.network?.filter((x) => x.ip)" :key="n.name">
                <td>{{ n.name }}</td>
                <td style="font-family: var(--font-mono)">{{ n.ip }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <!-- ── IPC stats + native bridge ───────────────────────── -->
      <div class="grid-2">
        <div class="card">
          <div class="card-head">
            <h3>IPC Command Stats</h3>
            <button class="btn sm ghost" @click="loadStats">↻</button>
          </div>
          <table class="data-table" v-if="statsData?.top_commands?.length">
            <thead>
              <tr>
                <th>Command</th>
                <th style="text-align: right">Calls</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="c in statsData.top_commands" :key="c.command">
                <td style="font-family: var(--font-mono); font-size: 11px">
                  {{ c.command }}
                </td>
                <td style="text-align: right; color: var(--accent)">
                  {{ c.calls }}
                </td>
              </tr>
            </tbody>
          </table>
          <div v-else class="empty" style="padding: 24px">
            <p>No stats yet</p>
          </div>
          <div class="card-foot" v-if="statsData">
            <span class="muted"
              >Total:
              <strong style="color: var(--text-1)">{{
                statsData.total_calls
              }}</strong></span
            >
            <span class="muted"
              >Uptime:
              <strong style="color: var(--text-1)">{{
                fmtUptime(statsData.uptime_seconds)
              }}</strong></span
            >
          </div>
        </div>

        <div class="card">
          <div class="card-head"><h3>Native Bridge (bind_typed)</h3></div>
          <div
            class="card-body"
            style="display: flex; flex-direction: column; gap: 12px"
          >
            <p class="muted" style="line-height: 1.6">
              Zero-overhead Crystal↔JS bridge via
              <code
                style="
                  color: var(--accent);
                  background: var(--accent-dim);
                  padding: 1px 5px;
                  border-radius: 3px;
                "
                >bind_typed</code
              >
              — a Crystal proc registered as a global JS function, bypassing the
              entire IPC command registry.
            </p>
            <div class="row">
              <input
                v-model="pingMsg"
                class="input grow mono"
                placeholder="message…"
                @keydown.enter="pingNative"
              />
              <button class="btn primary" @click="pingNative">⚡ Ping</button>
            </div>
            <pre
              v-if="pongResult"
              style="
                background: var(--bg-0);
                border: 1px solid var(--border);
                border-radius: var(--radius-sm);
                padding: 10px 12px;
                font-family: var(--font-mono);
                font-size: 11.5px;
                color: var(--green);
                line-height: 1.6;
                white-space: pre-wrap;
              "
              >{{ pongResult }}</pre
            >
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import {
  ref,
  computed,
  onMounted,
  onUnmounted,
  watch,
  defineComponent,
  h,
} from "vue";
import { useVitalsStore } from "../stores/vitals";
import { useAppStore } from "../stores/app";
import { invoke, ping } from "../ipc";

// ── Inline MetricCard component ──────────────────────────────────
const MetricCard = defineComponent({
  props: {
    label: String,
    value: String,
    sub: String,
    pct: Number,
    color: String,
  },
  setup(props) {
    return () =>
      h("div", { class: "metric-card" }, [
        h("div", { class: "metric-label" }, props.label),
        h(
          "div",
          { class: "metric-value", style: { color: props.color } },
          props.value,
        ),
        h("div", { class: "metric-sub" }, props.sub),
        h("div", { class: "progress-bar" }, [
          h("div", {
            class: "progress-fill",
            style: {
              width: Math.min(100, props.pct ?? 0) + "%",
              background: props.color,
            },
          }),
        ]),
      ]);
  },
});

const vitals = useVitalsStore();
const appStore = useAppStore();

const cpuCanvas = ref<HTMLCanvasElement | null>(null);
const memCanvas = ref<HTMLCanvasElement | null>(null);
const snap = computed(() => vitals.snapshot);
const info = computed(() => vitals.staticInfo);
const cpuPct = computed(() => vitals.cpuPct);
const memPct = computed(() => vitals.memPct);
const diskPct = computed(() => vitals.diskPct);
const cpuHistory = computed(() => vitals.cpuHistory);
const memHistory = computed(() => vitals.memHistory);
const timeStr = ref("");
const statsData = ref<any>(null);
const pingMsg = ref("hello");
const pongResult = ref("");

function gaugeColor(pct: number): string {
  if (pct > 85) return "var(--red)";
  if (pct > 65) return "var(--yellow)";
  return "var(--green)";
}

function fmtBytes(n: number): string {
  if (!n) return "0 B";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) {
    n /= 1024;
    i++;
  }
  return `${n.toFixed(i ? 1 : 0)} ${u[i]}`;
}

function fmtUptime(s: number): string {
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
}

function drawChart(
  canvas: HTMLCanvasElement | null,
  history: number[],
  stroke: string,
  fill: string,
) {
  if (!canvas) return;
  const dpr = window.devicePixelRatio || 1;
  const rect = canvas.getBoundingClientRect();
  const W = Math.floor(rect.width);
  const H = Math.floor(rect.height);
  if (W < 4 || H < 4) return;

  canvas.width = W * dpr;
  canvas.height = H * dpr;

  const ctx = canvas.getContext("2d")!;
  const w = canvas.width,
    h = canvas.height;
  ctx.clearRect(0, 0, w, h);

  if (history.length < 2) {
    const val = history.length === 1 ? history[0] : 0;
    const barH = (val / 100) * h * 0.88;
    ctx.fillStyle = fill;
    ctx.fillRect(0, h - barH, w, barH);
    ctx.strokeStyle = stroke;
    ctx.lineWidth = 2.5 * dpr;
    ctx.beginPath();
    ctx.moveTo(0, h - barH);
    ctx.lineTo(w, h - barH);
    ctx.stroke();
    ctx.fillStyle = stroke;
    ctx.font = `${Math.round(11 * dpr)}px -apple-system,sans-serif`;
    ctx.textAlign = "right";
    ctx.fillText(val.toFixed(1) + "%", w - 6, h - barH - 4 * dpr);
    return;
  }

  // Fixed 0–100% scale. Position shows absolute value.
  const toY = (v: number) =>
    h * 0.94 - (Math.min(100, Math.max(0, v)) / 100) * h * 0.88;

  // Grid lines at 25 / 50 / 75%
  ctx.lineWidth = dpr;
  [25, 50, 75].forEach((pct) => {
    const y = toY(pct);
    ctx.strokeStyle = "rgba(255,255,255,0.08)";
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(w, y);
    ctx.stroke();
    ctx.fillStyle = "rgba(255,255,255,0.35)";
    ctx.font = `${Math.round(9 * dpr)}px -apple-system,sans-serif`;
    ctx.textAlign = "left";
    ctx.fillText(pct + "%", 4 * dpr, y - 2 * dpr);
  });

  const step = w / (history.length - 1);

  // Filled area under the line
  ctx.beginPath();
  history.forEach((v, i) => {
    i === 0 ? ctx.moveTo(i * step, toY(v)) : ctx.lineTo(i * step, toY(v));
  });
  ctx.lineTo(w, h);
  ctx.lineTo(0, h);
  ctx.closePath();
  ctx.fillStyle = fill;
  ctx.fill();

  // Line
  ctx.beginPath();
  history.forEach((v, i) => {
    i === 0 ? ctx.moveTo(i * step, toY(v)) : ctx.lineTo(i * step, toY(v));
  });
  ctx.strokeStyle = stroke;
  ctx.lineWidth = 2 * dpr;
  ctx.lineJoin = "round";
  ctx.lineCap = "round";
  ctx.stroke();

  // Current value label
  const last = history[history.length - 1];
  const lastY = toY(last);
  ctx.fillStyle = stroke;
  ctx.globalAlpha = 0.95;
  ctx.font = `bold ${Math.round(11 * dpr)}px -apple-system,sans-serif`;
  ctx.textAlign = "right";
  ctx.fillText(
    last.toFixed(1) + "%",
    w - 6,
    Math.max(14 * dpr, lastY - 4 * dpr),
  );
  ctx.globalAlpha = 1;
}

// Redraw charts after every vitals tick — rAF ensures layout is complete
watch(snap, (s) => {
  if (s) timeStr.value = new Date(s.timestamp).toLocaleTimeString();
  requestAnimationFrame(() => {
    const cpu = cpuCanvas.value;
    const mem = memCanvas.value;
    console.log(
      "[chart] redraw, cpu canvas:",
      cpu?.offsetWidth,
      "x",
      cpu?.offsetHeight,
      "history:",
      cpuHistory.value.length,
      "vals:",
      cpuHistory.value.slice(-5),
    );
    drawChart(cpu, cpuHistory.value, "#58a6ff", "rgba(88,166,255,.25)");
    drawChart(mem, memHistory.value, "#d2a8ff", "rgba(210,168,255,.25)");
  });
});

// Also redraw when history is first loaded from the backend
watch(
  cpuHistory,
  () => {
    requestAnimationFrame(() => {
      drawChart(
        cpuCanvas.value,
        cpuHistory.value,
        "#58a6ff",
        "rgba(88,166,255,.25)",
      );
      drawChart(
        memCanvas.value,
        memHistory.value,
        "#d2a8ff",
        "rgba(210,168,255,.25)",
      );
    });
  },
  { deep: true },
);

async function loadStats() {
  statsData.value = await invoke("stats.summary").catch(() => null);
}

async function pingNative() {
  try {
    pongResult.value = await ping(pingMsg.value);
    appStore.toast(pongResult.value, "ok");
  } catch (e: any) {
    pongResult.value = e.message;
    appStore.toast(e.message, "error");
  }
}

async function openDevTools() {
  // Use the plugin's command directly — it resolves the native window pointer
  await invoke("devtools.toggle").catch(() =>
    invoke("app.devtools_toggle").catch(() => {}),
  );
}

let statsTimer: ReturnType<typeof setInterval>;
let ro: ResizeObserver | null = null;

onMounted(() => {
  loadStats();
  statsTimer = setInterval(loadStats, 10000);

  const redraw = () => {
    drawChart(
      cpuCanvas.value,
      cpuHistory.value,
      "#58a6ff",
      "rgba(88,166,255,.25)",
    );
    drawChart(
      memCanvas.value,
      memHistory.value,
      "#d2a8ff",
      "rgba(210,168,255,.25)",
    );
  };

  // Double rAF guarantees layout is complete before we read dimensions
  requestAnimationFrame(() => requestAnimationFrame(redraw));

  // Redraw whenever the panel is resized
  ro = new ResizeObserver(() => requestAnimationFrame(redraw));
  if (cpuCanvas.value?.parentElement) ro.observe(cpuCanvas.value.parentElement);
  if (memCanvas.value?.parentElement) ro.observe(memCanvas.value.parentElement);
});

onUnmounted(() => {
  clearInterval(statsTimer);
  ro?.disconnect();
});
</script>
