/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { useEffect, useState } from "@webpack/common";

import { fetchHermesStatus, isStatusStale, nextBackoffMs, normalizePollInterval } from "../api";
import type { HermesSnapshot, PollConfig } from "../types";

const REQUEST_TIMEOUT_MS = 10_000;

const EMPTY_SNAPSHOT: HermesSnapshot = {
    channelId: null,
    status: null,
    connectionState: "idle",
    error: null,
    receivedAt: null
};

export function useHermesStatus(channelId: string | null, enabled: boolean, config: PollConfig): HermesSnapshot {
    const [snapshot, setSnapshot] = useState<HermesSnapshot>(EMPTY_SNAPSHOT);

    useEffect(() => {
        if (!enabled || !channelId) {
            setSnapshot(EMPTY_SNAPSHOT);
            return;
        }

        let cancelled = false;
        let timeout: ReturnType<typeof setTimeout> | undefined;
        let requestTimeout: ReturnType<typeof setTimeout> | undefined;
        let controller: AbortController | undefined;
        let failures = 0;
        const intervalMs = normalizePollInterval(config.pollingIntervalMs);

        const schedule = (delay: number) => {
            timeout = setTimeout(poll, delay);
        };

        const poll = async () => {
            controller?.abort();
            controller = new AbortController();
            let timedOut = false;
            requestTimeout = setTimeout(() => {
                timedOut = true;
                controller?.abort();
            }, REQUEST_TIMEOUT_MS);

            setSnapshot(previous => ({
                ...previous,
                channelId,
                connectionState: previous.status && previous.channelId === channelId ? previous.connectionState : "connecting",
                error: null
            }));

            try {
                const status = await fetchHermesStatus(config, channelId, controller.signal);
                if (cancelled) return;

                const receivedAt = Date.now();
                failures = 0;
                setSnapshot({
                    channelId,
                    status,
                    connectionState: isStatusStale(status, receivedAt, intervalMs, receivedAt) ? "stale" : status.error ? "error" : "connected",
                    error: status.error,
                    receivedAt
                });
                schedule(intervalMs);
            } catch (err) {
                if (cancelled || controller.signal.aborted && !timedOut) return;

                failures++;
                setSnapshot(previous => ({
                    channelId,
                    status: previous.channelId === channelId ? previous.status : null,
                    connectionState: previous.channelId === channelId && previous.status ? "stale" : "disconnected",
                    error: timedOut ? "Hermes bridge request timed out" : err instanceof Error ? err.message : "Failed to reach Hermes bridge",
                    receivedAt: previous.channelId === channelId ? previous.receivedAt : null
                }));
                schedule(nextBackoffMs(intervalMs, failures));
            } finally {
                if (requestTimeout) clearTimeout(requestTimeout);
                requestTimeout = undefined;
            }
        };

        poll();

        return () => {
            cancelled = true;
            if (timeout) clearTimeout(timeout);
            if (requestTimeout) clearTimeout(requestTimeout);
            controller?.abort();
        };
    }, [channelId, enabled, config.bridgeUrl, config.bearerToken, config.bearerTokenError, config.pollingIntervalMs]);

    useEffect(() => {
        if (!snapshot.status || !enabled) return;

        const timeout = setInterval(() => {
            setSnapshot(previous => {
                if (!previous.status || previous.connectionState !== "connected") return previous;
                if (!isStatusStale(previous.status, Date.now(), config.pollingIntervalMs, previous.receivedAt)) return previous;

                return {
                    ...previous,
                    connectionState: "stale"
                };
            });
        }, 1000);

        return () => clearInterval(timeout);
    }, [snapshot.status, enabled, config.pollingIntervalMs]);

    return snapshot;
}
