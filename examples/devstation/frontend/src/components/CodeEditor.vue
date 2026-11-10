<template>
  <div ref="editorEl" class="editor-wrap"></div>
</template>

<script setup lang="ts">
import { ref, watch, onMounted, onUnmounted, shallowRef } from "vue";
import { EditorView, basicSetup } from "codemirror";
import { EditorState } from "@codemirror/state";
import { oneDark } from "@codemirror/theme-one-dark";
import { javascript } from "@codemirror/lang-javascript";
import { python } from "@codemirror/lang-python";
import { rust } from "@codemirror/lang-rust";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { json } from "@codemirror/lang-json";
import { sql } from "@codemirror/lang-sql";
import { markdown } from "@codemirror/lang-markdown";
import { xml } from "@codemirror/lang-xml";
import { keymap } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { searchKeymap } from "@codemirror/search";

const props = defineProps<{
  modelValue: string;
  language?: string;
  minimal?: boolean;
}>();

const emit = defineEmits<{
  (e: "update:modelValue", value: string): void;
}>();

const editorEl = ref<HTMLElement | null>(null);
const view = shallowRef<EditorView | null>(null);
let ignoreUpdate = false;

function getLanguageExtension(lang: string) {
  switch (lang) {
    case "javascript":
    case "typescript":
      return javascript({ typescript: lang === "typescript", jsx: false });
    case "python":
      return python();
    case "rust":
      return rust();
    case "html":
      return html();
    case "css":
    case "scss":
      return css();
    case "json":
      return json();
    case "sql":
      return sql();
    case "markdown":
      return markdown();
    case "xml":
      return xml();
    default:
      return [];
  }
}

function createEditor() {
  if (!editorEl.value) return;

  const langExt = getLanguageExtension(props.language || "plaintext");

  const updateListener = EditorView.updateListener.of((update) => {
    if (update.docChanged && !ignoreUpdate) {
      emit("update:modelValue", update.state.doc.toString());
    }
  });

  const extensions = [
    props.minimal ? [] : basicSetup,
    oneDark,
    langExt,
    updateListener,
    EditorView.lineWrapping,
    keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap]),
    history(),
    EditorView.theme({
      "&": { height: "100%", background: "var(--bg-0)" },
      ".cm-scroller": { overflow: "auto", fontFamily: "var(--font-mono)" },
      ".cm-content": { caretColor: "var(--accent)" },
    }),
  ];

  const state = EditorState.create({
    doc: props.modelValue,
    extensions,
  });

  if (view.value) view.value.destroy();

  view.value = new EditorView({
    state,
    parent: editorEl.value,
  });
}

// Update editor content when prop changes externally
watch(
  () => props.modelValue,
  (newVal) => {
    const v = view.value;
    if (!v) return;
    const current = v.state.doc.toString();
    if (current !== newVal) {
      ignoreUpdate = true;
      v.dispatch({ changes: { from: 0, to: current.length, insert: newVal } });
      ignoreUpdate = false;
    }
  },
);

// Recreate editor when language changes
watch(
  () => props.language,
  () => {
    createEditor();
  },
);

onMounted(() => createEditor());
onUnmounted(() => {
  view.value?.destroy();
});
</script>
