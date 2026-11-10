<template>
  <div class="shell">
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-icon">⚡</div>
        <div class="brand-text">
          <strong>DevStation</strong>
          <span>{{ staticInfo?.hostname ?? "…" }}</span>
        </div>
      </div>

      <nav class="nav">
        <div class="nav-section">Monitor</div>
        <RouterLink
          class="nav-item"
          to="/"
          :class="{ active: route.path === '/' }"
        >
          <span class="ico">📊</span> Dashboard
        </RouterLink>

        <div class="nav-section">Dev Tools</div>
        <RouterLink
          class="nav-item"
          to="/terminal"
          :class="{ active: route.path === '/terminal' }"
        >
          <span class="ico">⌨️</span> Terminal
          <span v-if="activeSessionCount" class="nav-badge">{{
            activeSessionCount
          }}</span>
        </RouterLink>
        <RouterLink
          class="nav-item"
          to="/http"
          :class="{ active: route.path === '/http' }"
        >
          <span class="ico">🌐</span> HTTP Client
        </RouterLink>
        <RouterLink
          class="nav-item"
          to="/explorer"
          :class="{ active: route.path === '/explorer' }"
        >
          <span class="ico">📁</span> Explorer
        </RouterLink>

        <div class="nav-section">Workspace</div>
        <RouterLink
          class="nav-item"
          to="/snippets"
          :class="{ active: route.path === '/snippets' }"
        >
          <span class="ico">📎</span> Snippets
        </RouterLink>
        <RouterLink
          class="nav-item"
          to="/notes"
          :class="{ active: route.path === '/notes' }"
        >
          <span class="ico">📝</span> Notes
        </RouterLink>
        <RouterLink
          class="nav-item"
          to="/settings"
          :class="{ active: route.path === '/settings' }"
        >
          <span class="ico">⚙️</span> Settings
        </RouterLink>
      </nav>

      <div class="sidebar-foot">
        <div class="stat-mini">
          <span>CPU</span>
          <strong :style="{ color: gaugeColor(cpuPct) }"
            >{{ cpuPct.toFixed(1) }}%</strong
          >
        </div>
        <div class="stat-mini">
          <span>MEM</span>
          <strong :style="{ color: gaugeColor(memPct) }"
            >{{ memPct.toFixed(1) }}%</strong
          >
        </div>
        <div class="stat-mini">
          <span
            ><span class="conn-dot" :class="{ live: connected }"></span
            >{{ connected ? "live" : "connecting" }}</span
          >
          <span style="font-size: 10px; color: var(--text-3)">{{
            appStore.theme
          }}</span>
        </div>
      </div>
    </aside>

    <div class="main-area">
      <RouterView />
    </div>
  </div>

  <div class="toasts">
    <TransitionGroup name="toast">
      <div v-for="t in toasts" :key="t.id" class="toast-item" :class="t.kind">
        {{ t.message }}
      </div>
    </TransitionGroup>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from "vue";
import { RouterLink, RouterView, useRoute } from "vue-router";
import { useVitalsStore } from "./stores/vitals";
import { useTerminalStore } from "./stores/terminal";
import { useAppStore } from "./stores/app";

const route = useRoute();
const vitals = useVitalsStore();
const terminal = useTerminalStore();
const appStore = useAppStore();

const connected = ref(false);

const staticInfo = computed(() => vitals.staticInfo);
const cpuPct = computed(() => vitals.cpuPct);
const memPct = computed(() => vitals.memPct);
const toasts = computed(() => appStore.toasts);

const activeSessionCount = computed(
  () => Object.values(terminal.sessions).filter((s) => s.running).length,
);

function gaugeColor(pct: number): string {
  if (pct > 85) return "var(--red)";
  if (pct > 65) return "var(--yellow)";
  return "var(--green)";
}

onMounted(async () => {
  appStore.init();
  terminal.init();
  await vitals.init();
  connected.value = true;
});
</script>
