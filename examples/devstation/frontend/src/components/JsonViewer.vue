<template>
  <div
    class="json-viewer"
    style="
      overflow-y: auto;
      padding: 12px;
      flex: 1;
      font-family: var(--font-mono);
      font-size: 12px;
      line-height: 1.8;
    "
  >
    <JsonNode :data="data" :depth="0" />
  </div>
</template>

<script setup lang="ts">
import JsonNode from "./JsonNode.vue";

defineProps<{ data: unknown }>();
</script>
