/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

export const DEFAULT_POLL_INTERVAL_MS = 5000;
export const STATUS_STARTUP_DELAY_MS = 1000;

export interface DeferredStartScheduler {
    requestIdleCallback?: (callback: () => void, options: { timeout: number; }) => number;
    cancelIdleCallback?: (handle: number) => void;
    setTimeout: (callback: () => void, delay: number) => number;
    clearTimeout: (handle: number) => void;
}

function browserScheduler(): DeferredStartScheduler {
    const scope = globalThis as typeof globalThis & {
        requestIdleCallback?: (callback: () => void, options: { timeout: number; }) => number;
        cancelIdleCallback?: (handle: number) => void;
    };
    return {
        requestIdleCallback: scope.requestIdleCallback?.bind(scope),
        cancelIdleCallback: scope.cancelIdleCallback?.bind(scope),
        setTimeout: (callback, delay) => globalThis.setTimeout(callback, delay) as unknown as number,
        clearTimeout: handle => globalThis.clearTimeout(handle)
    };
}

/** Schedules non-critical status work after navigation has settled. */
export function scheduleDeferredStatusStart(start: () => void, scheduler = browserScheduler()): () => void {
    let cancelled = false;
    let handle: number | undefined;
    const run = () => {
        if (!cancelled) start();
    };

    if (scheduler.requestIdleCallback && scheduler.cancelIdleCallback) {
        handle = scheduler.requestIdleCallback(run, { timeout: STATUS_STARTUP_DELAY_MS });
        return () => {
            cancelled = true;
            if (handle != null) scheduler.cancelIdleCallback?.(handle);
        };
    }

    handle = scheduler.setTimeout(run, STATUS_STARTUP_DELAY_MS);
    return () => {
        cancelled = true;
        if (handle != null) scheduler.clearTimeout(handle);
    };
}
