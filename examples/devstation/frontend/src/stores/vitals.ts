import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import { invoke, state, StateRef } from '../ipc'

export interface VitalsSnapshot {
    timestamp: number
    cpu: { cores: number; model: string; usage_pct: number; frequency: number | null }
    memory: { total: number; used: number; free: number; used_pct: number }
    disk: { total: number; used: number; free: number; used_pct: number }
    battery: { present: boolean; level: number; charging: boolean }
    idle_seconds: number
    cpu_history: number[]
    mem_history: number[]
}

export interface StaticInfo {
    os: { name: string; version: string }
    arch: string
    hostname: string
    cpu: { model: string; cores: number; threads: number; frequency: number | null }
    locale: string
    language: string
    home_dir: string
    data_dir: string
    config_dir: string
    cache_dir: string
    app_version: string
    displays: Array<{ id: string; width: number; height: number; scale: number; primary: boolean }>
    network: Array<{ name: string; ip: string; mac: string }>
}

export const useVitalsStore = defineStore('vitals', () => {
    const snapshot = ref<VitalsSnapshot | null>(null)
    const staticInfo = ref<StaticInfo | null>(null)

    const cpuPct = computed(() => snapshot.value?.cpu.usage_pct ?? 0)
    const memPct = computed(() => snapshot.value?.memory.used_pct ?? 0)
    const diskPct = computed(() => snapshot.value?.disk.used_pct ?? 0)
    const cpuHistory = computed(() => snapshot.value?.cpu_history ?? [])
    const memHistory = computed(() => snapshot.value?.mem_history ?? [])

    function applyVitals(v: VitalsSnapshot) {
        snapshot.value = v
    }

    async function loadStatic() {
        staticInfo.value = await invoke<StaticInfo>('vitals.static')
    }

    async function init() {
        await loadStatic().catch(() => {})
        // Attach to the backend-owned reactive state slice.
        // The backend updates it every 2s; we receive JSON Patch diffs
        // automatically — no `vitals:tick` event, no `vitals.snapshot`
        // or `vitals.history` commands, no manual history bookkeeping.
        try {
            const ref = await state<VitalsSnapshot>('vitals')
            applyVitals(ref.value)
            ref.subscribe(applyVitals)
        } catch (e) {
            console.warn('[vitals] state attach failed, falling back to null:', e)
        }
    }

    return {
        snapshot, staticInfo, cpuHistory, memHistory,
        cpuPct, memPct, diskPct,
        init,
    }
})
