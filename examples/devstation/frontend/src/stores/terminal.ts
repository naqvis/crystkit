import { defineStore } from 'pinia'
import { ref, reactive } from 'vue'
import { emit, invoke, listen } from '../ipc'

export interface TerminalSession {
    id: string
    title: string
    output: string
    exitCode: number | null
    running: boolean
    pid: number | null
    cwd: string
}

let sessionCounter = 0

export const useTerminalStore = defineStore('terminal', () => {
    const sessions = reactive<Record<string, TerminalSession>>({})
    const activeId = ref<string | null>(null)
    const history = ref<Array<{ command: string; exit_code: number | null; ran_at: string }>>([])

    const unsubFns: Array<() => void> = []

    function init() {
        unsubFns.push(
            listen<{ session_id: string; pid: number; command: string; cwd: string }>('terminal:started', ({ session_id, pid, command, cwd }) => {
                if (sessions[session_id]) {
                    sessions[session_id].pid = pid
                    sessions[session_id].running = true
                    sessions[session_id].cwd = cwd
                    sessions[session_id].output += `\x1b[32m$ ${command}\x1b[0m\r\n`
                }
            }),

            listen<{ session_id: string; data: string }>('terminal:stdout', ({ session_id, data }) => {
                if (sessions[session_id]) sessions[session_id].output += data
            }),

            listen<{ session_id: string; data: string }>('terminal:stderr', ({ session_id, data }) => {
                if (sessions[session_id]) sessions[session_id].output += `\x1b[31m${data}\x1b[0m`
            }),

            listen<{ session_id: string; exit_code: number; duration_ms: number }>('terminal:exit', ({ session_id, exit_code, duration_ms }) => {
                if (sessions[session_id]) {
                    sessions[session_id].running = false
                    sessions[session_id].exitCode = exit_code
                    const color = exit_code === 0 ? '\x1b[32m' : '\x1b[31m'
                    sessions[session_id].output += `\r\n${color}[exited ${exit_code} in ${duration_ms}ms]\x1b[0m\r\n`
                }
            }),

            listen<{ session_id: string; message: string }>('terminal:error', ({ session_id, message }) => {
                if (sessions[session_id]) {
                    sessions[session_id].output += `\x1b[31mError: ${message}\x1b[0m\r\n`
                    sessions[session_id].running = false
                }
            }),
        )
    }

    function spawnSession(command: string, args: string[] = [], cwd = ''): string {
        const session_id = `sess-${++sessionCounter}-${Date.now()}`
        const title = `${command} ${args.join(' ')}`.trim().slice(0, 30)

        sessions[session_id] = {
            id: session_id,
            title,
            output: '',
            exitCode: null,
            running: false,
            pid: null,
            cwd,
        }

        activeId.value = session_id
        emit('terminal:spawn', { session_id, command, args, cwd })
        return session_id
    }

    function killSession(session_id: string) {
        emit('terminal:kill', { session_id })
    }

    function closeSession(session_id: string) {
        killSession(session_id)
        delete sessions[session_id]
        const ids = Object.keys(sessions)
        activeId.value = ids.length > 0 ? ids[ids.length - 1] : null
    }

    async function runSync(command: string, args: string[] = [], cwd = '') {
        return invoke<{ stdout: string; stderr: string; exit_code: number; duration_ms: number }>(
            'terminal.run_sync', [command, cwd, args]
        )
    }

    async function loadHistory(limit = 100) {
        history.value = await invoke<typeof history.value>('terminal.history', limit)
    }

    function cleanup() {
        unsubFns.forEach(fn => fn())
    }

    return { sessions, activeId, history, init, spawnSession, killSession, closeSession, runSync, loadHistory, cleanup }
})
