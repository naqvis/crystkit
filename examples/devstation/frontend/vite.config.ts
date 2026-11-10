import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { resolve } from 'path'

export default defineConfig({
    plugins: [vue()],
    resolve: {
        alias: {
            '@': resolve(__dirname, 'src'),
        },
    },
    build: {
        outDir: 'dist',
        rollupOptions: {
            output: {
                manualChunks: {
                    'codemirror': [
                        'codemirror',
                        '@codemirror/state',
                        '@codemirror/view',
                        '@codemirror/commands',
                        '@codemirror/language',
                        '@codemirror/search',
                        '@codemirror/theme-one-dark',
                    ],
                    'cm-langs': [
                        '@codemirror/lang-javascript',
                        '@codemirror/lang-python',
                        '@codemirror/lang-rust',
                        '@codemirror/lang-html',
                        '@codemirror/lang-css',
                        '@codemirror/lang-json',
                        '@codemirror/lang-sql',
                        '@codemirror/lang-markdown',
                        '@codemirror/lang-xml',
                    ],
                },
            },
        },
    },
    server: {
        port: 5173,
    },
})
