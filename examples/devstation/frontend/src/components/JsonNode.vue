<template>
  <span>
    <!-- null -->
    <span v-if="data === null" style="color: #6e7781">null</span>

    <!-- boolean -->
    <span v-else-if="typeof data === 'boolean'" style="color: #79c0ff">{{
      data
    }}</span>

    <!-- number -->
    <span v-else-if="typeof data === 'number'" style="color: #79c0ff">{{
      data
    }}</span>

    <!-- string -->
    <span v-else-if="typeof data === 'string'">
      <span style="color: #a5d6ff">"</span>
      <span style="color: #a5d6ff">{{ truncate(data) }}</span>
      <span style="color: #a5d6ff">"</span>
    </span>

    <!-- array -->
    <span v-else-if="Array.isArray(data)">
      <button v-if="data.length" class="toggle" @click="open = !open">
        {{ open ? "▾" : "▸" }}
      </button>
      <span style="color: #e6edf3">[</span>
      <span v-if="!open || !data.length">
        <span v-if="data.length" style="color: #656d76">
          … {{ data.length }} items
        </span>
      </span>
      <span v-else>
        <div
          v-for="(item, i) in data"
          :key="i"
          :style="{ paddingLeft: (depth + 1) * 16 + 'px' }"
        >
          <JsonNode :data="item" :depth="depth + 1" />
          <span style="color: #656d76" v-if="i < data.length - 1">,</span>
        </div>
        <div :style="{ paddingLeft: depth * 16 + 'px' }"></div>
      </span>
      <span style="color: #e6edf3">]</span>
    </span>

    <!-- object -->
    <span v-else-if="typeof data === 'object' && data !== null">
      <button v-if="keys.length" class="toggle" @click="open = !open">
        {{ open ? "▾" : "▸" }}
      </button>
      <span style="color: #e6edf3">{</span>
      <span v-if="!open || !keys.length">
        <span v-if="keys.length" style="color: #656d76">
          … {{ keys.length }} keys
        </span>
      </span>
      <span v-else>
        <div
          v-for="(key, i) in keys"
          :key="key"
          :style="{ paddingLeft: (depth + 1) * 16 + 'px' }"
        >
          <span style="color: #ff7b72">"{{ key }}"</span>
          <span style="color: #e6edf3">: </span>
          <JsonNode
            :data="(data as Record<string, unknown>)[key]"
            :depth="depth + 1"
          />
          <span style="color: #656d76" v-if="i < keys.length - 1">,</span>
        </div>
        <div :style="{ paddingLeft: depth * 16 + 'px' }"></div>
      </span>
      <span style="color: #e6edf3">}</span>
    </span>
  </span>
</template>

<script setup lang="ts">
import { ref, computed } from "vue";

const props = defineProps<{ data: unknown; depth: number }>();
const open = ref(props.depth < 2);

const keys = computed(() => {
  if (
    typeof props.data === "object" &&
    props.data !== null &&
    !Array.isArray(props.data)
  ) {
    return Object.keys(props.data as object);
  }
  return [];
});

function truncate(s: string): string {
  return s.length > 200 ? s.slice(0, 200) + "…" : s;
}
</script>

<style scoped>
.toggle {
  background: none;
  border: none;
  color: var(--text-2);
  cursor: pointer;
  font-size: 10px;
  padding: 0 2px;
  line-height: 1;
  vertical-align: middle;
}
.toggle:hover {
  color: var(--accent);
}
</style>
