// IPC bridge — thin typed wrapper around window.__CRYSTKIT_IPC__
// All backend calls go through here so TypeScript stays happy.
//
// The CrystKit JS bridge (`window.__CRYSTKIT_IPC__`) handles both sync
// (`app.command`) and async (`app.async`) backend commands transparently —
// the frontend API is identical regardless of which variant the backend used.
// Errors arrive as rejected Promises carrying `Error` objects with `.code`
// and `.details` properties set by the bridge's `handleEnvelope`.

interface WebviewIPC {
    /** Framework version string. */
    version: string
    /** Invoke a backend command. Works for both sync and async commands. */
    invoke<T = unknown>(cmd: string, args?: unknown): Promise<T>
    /** Listen for a backend event. Returns an unsubscribe function. */
    listen(event: string, cb: (payload: unknown) => void): () => void
    /** Emit an event to the backend event bus. */
    emit(event: string, payload?: unknown): void
    /** Open a streaming channel by ID. */
    channel(channelId: string): {
        onData(fn: (data: unknown) => void): unknown
        onEnd(fn: () => void): unknown
        onError(fn: (error: string) => void): unknown
        close(): void
    }
    /** Attach to a backend-owned reactive state slice. */
    state<T = unknown>(name: string): Promise<StateRef<T>>
}

export interface StateRef<T> {
    readonly name: string
    readonly value: T
    get(): T
    subscribe(handler: (value: T) => void): () => void
}

function getIPC(): WebviewIPC {
    const w = window as unknown as { __CRYSTKIT_IPC__?: WebviewIPC }
    if (!w.__CRYSTKIT_IPC__) {
        // Provide a stub during Vite dev server HMR (no backend attached)
        console.warn('[devstation] IPC not available — using stub')
        return {
            version: '0.0.0-stub',
            invoke: async <T = unknown>() => null as T,
            emit: (event) => console.debug(`[ipc stub] emit: ${event}`),
            listen: () => () => { },
            channel: () => ({
                onData: () => null,
                onEnd: () => null,
                onError: () => null,
                close: () => { },
            }),
            state: async <T = unknown>() => ({ name: '', value: null as T, get: () => null as T, subscribe: () => () => {} }),
        }
    }
    return w.__CRYSTKIT_IPC__
}

export const ipc = getIPC()

/**
 * Typed invoke helper.
 *
 * The bridge's `handleEnvelope` already unwraps successful responses and
 * throws structured `Error` objects (with `.code` and `.details`) on failure,
 * so this function is a thin type-narrowing wrapper — no manual error
 * checking is needed.
 */
export async function invoke<T = unknown>(cmd: string, args?: unknown): Promise<T> {
    return ipc.invoke<T>(cmd, args)
}

/** Fire-and-forget emit. */
export function emit(event: string, payload?: unknown): void {
    ipc.emit(event, payload)
}

/** Subscribe to a backend event; returns an unsubscribe function. */
export function listen<T = unknown>(event: string, cb: (payload: T) => void): () => void {
    return ipc.listen(event, cb as (payload: unknown) => void)
}

/** Framework version string from the bridge. */
export const version: string = ipc.version

/** Attach to a backend-owned reactive state slice. */
export function state<T = unknown>(name: string): Promise<StateRef<T>> {
    return ipc.state<T>(name)
}

// Direct bind_typed bridge (zero-overhead, registered via main.cr)
export function ping(msg: string): Promise<string> {
    const w = window as unknown as { devstation_ping?: (msg: string) => Promise<string> }
    return w.devstation_ping ? w.devstation_ping(msg) : Promise.resolve(`${msg} → (no native bridge)`)
}
