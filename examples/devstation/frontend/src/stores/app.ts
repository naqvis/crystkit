import { defineStore } from 'pinia'
import { ref } from 'vue'
import { invoke, listen } from '../ipc'

export interface Toast {
    id: number
    message: string
    kind: 'info' | 'ok' | 'error' | 'warn'
}

let toastId = 0

// 'dark' = GitHub dark  |  'light' = VS Code dark (alternate accent palette)
// 'system' = follow OS — but since both modes are dark-based, system just
// switches between our two dark variants, never a white UI.
export type ThemeChoice = 'dark' | 'light' | 'system'

export const useAppStore = defineStore('app', () => {
    const theme = ref<'dark' | 'light'>('dark')
    const themeChoice = ref<ThemeChoice>('dark')
    const toasts = ref<Toast[]>([])

    function applyTheme(t: 'dark' | 'light') {
        theme.value = t
        document.documentElement.setAttribute('data-theme', t)
    }

    function toast(message: string, kind: Toast['kind'] = 'info', ms = 3000) {
        const id = ++toastId
        toasts.value.push({ id, message, kind })
        setTimeout(() => {
            const idx = toasts.value.findIndex(x => x.id === id)
            if (idx >= 0) toasts.value.splice(idx, 1)
        }, ms)
    }

    async function setTheme(choice: ThemeChoice) {
        themeChoice.value = choice
        await invoke('store.set', ['devstation-prefs', 'theme', choice]).catch(() => { })

        if (choice === 'system') {
            // Query OS — but map BOTH light and dark to our dark variant.
            // This app is a dev tool; we never show a blinding white UI.
            applyTheme('dark')
        } else {
            applyTheme(choice)
        }
    }

    async function loadTheme() {
        // Restore persisted preference
        const stored = await invoke<string | null>('store.get', ['devstation-prefs', 'theme']).catch(() => null)

        const choice: ThemeChoice =
            stored === 'dark' || stored === 'light' || stored === 'system' ? stored : 'dark'

        themeChoice.value = choice
        // Always start dark
        applyTheme(choice === 'light' ? 'light' : 'dark')

        // Start OS monitor — we'll use it to switch between our two dark variants
        await invoke('theme.start_monitor', 3).catch(() => { })
    }

    function init() {
        loadTheme()

        // OS theme change — only honour if user chose 'system', and even then
        // we keep a dark palette (just switch variant).
        listen<{ theme: string }>('theme.changed', ({ theme: t }) => {
            if (themeChoice.value === 'system') {
                // 'light' OS = 'light' variant (still dark-based), 'dark' OS = 'dark'
                applyTheme(t === 'light' ? 'light' : 'dark')
            }
        })
        listen<{ theme: string }>('app:theme_changed', ({ theme: t }) => {
            if (themeChoice.value === 'system') applyTheme(t === 'light' ? 'light' : 'dark')
        })

        listen<{ action: string }>('menu:action', ({ action }) => toast(`Menu: ${action}`, 'info'))
        listen<{ action: string; key: string }>('shortcut:triggered', ({ action, key }) => {
            toast(`Shortcut: ${key} (${action})`, 'info', 1500)
        })
        listen<unknown>('instance:reactivated', () => toast('Refocused from second instance', 'info'))
        listen<{ url: string }>('deeplink:opened', ({ url }) => toast(`Deep link: ${url}`, 'info'))
        listen<{ action: string }>('tray:action', ({ action }) => toast(`Tray: ${action}`, 'info'))
    }

    return { theme, themeChoice, toasts, toast, loadTheme, setTheme, applyTheme, init }
})
