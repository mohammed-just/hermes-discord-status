/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import type { HermesStatus, PollConfig } from "./types";

const MIN_INTERVAL_MS = 500;
const MAX_INTERVAL_MS = 60000;
const MAX_BACKOFF_MS = 30000;
const SNOWFLAKE_RE = /^\d{17,20}$/;

function isLoopbackHost(hostname: string): boolean {
    const host = hostname.toLowerCase();
    return host === "localhost" || host === "127.0.0.1" || host === "[::1]" || host === "::1";
}

function isSafeEpoch(value: number | null, now = Date.now()): boolean {
    if (value == null || !Number.isFinite(value)) return value === null;
    const epoch = normalizeEpochMs(value);
    return epoch != null && epoch >= 1_500_000_000_000 && epoch <= now + 300_000;
}

function isObject(value: unknown): value is Record<string, unknown> {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isNullableNumber(value: unknown): value is number | null {
    return value === null || typeof value === "number" && Number.isFinite(value);
}

function isNullableString(value: unknown): value is string | null {
    return value === null || typeof value === "string";
}

function isNonNegativeSafeInteger(value: unknown): value is number {
    return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

export function validateHermesStatus(value: unknown): HermesStatus | null {
    if (!isObject(value) || value.schema_version !== 1) return null;
    if (typeof value.session_id !== "string" || !value.session_id.trim()) return null;
    if (typeof value.model !== "string" || !value.model.trim()) return null;
    if (!isNullableNumber(value.context_used) || !isNullableNumber(value.context_max) || !isNullableNumber(value.context_percent)) return null;
    if (value.context_used != null && value.context_used < 0) return null;
    if (value.context_max != null && value.context_max <= 0) return null;
    if (value.context_percent != null && value.context_percent < 0) return null;
    const totalProcessedTokens = "total_processed_tokens" in value ? value.total_processed_tokens : null;
    if (totalProcessedTokens !== null && !isNonNegativeSafeInteger(totalProcessedTokens)) return null;
    if (!isSafeEpoch(typeof value.session_started_at === "number" ? value.session_started_at : null)) return null;
    if (!isSafeEpoch(isNullableNumber(value.turn_started_at) ? value.turn_started_at : null)) return null;
    if (typeof value.busy !== "boolean") return null;
    if (!isNullableString(value.active_tool)) return null;
    if (typeof value.tool_calls !== "number" || !Number.isSafeInteger(value.tool_calls) || value.tool_calls < 0) return null;
    const activeToolCalls = value.active_tool_calls ?? 0;
    const compressionCount = value.compression_count ?? 0;
    const activeSubagents = value.active_subagents ?? value.active_background_subagents ?? 0;
    const yolo = value.yolo ?? false;
    if (typeof activeToolCalls !== "number" || !Number.isSafeInteger(activeToolCalls) || activeToolCalls < 0) return null;
    if (typeof compressionCount !== "number" || !Number.isSafeInteger(compressionCount) || compressionCount < 0) return null;
    if (typeof activeSubagents !== "number" || !Number.isSafeInteger(activeSubagents) || activeSubagents < 0) return null;
    if (typeof yolo !== "boolean") return null;
    if (!isSafeEpoch(typeof value.updated_at === "number" ? value.updated_at : null)) return null;
    if (!isNullableString(value.error)) return null;

    return {
        ...(value as unknown as HermesStatus),
        active_tool_calls: activeToolCalls,
        compression_count: compressionCount,
        active_subagents: activeSubagents,
        total_processed_tokens: totalProcessedTokens,
        yolo
    };
}

export function getEnabledChannelIds(raw: string): Set<string> {
    return new Set(raw.split(/[,\s]+/).map(id => id.trim()).filter(id => SNOWFLAKE_RE.test(id)));
}

export function serializeEnabledChannelIds(ids: Iterable<string>): string {
    return [...new Set(ids)].filter(Boolean).sort().join(",");
}

export function setChannelEnabled(raw: string, channelId: string, enabled: boolean): string {
    const ids = getEnabledChannelIds(raw);
    if (enabled) ids.add(channelId);
    else ids.delete(channelId);
    return serializeEnabledChannelIds(ids);
}

export function normalizePollInterval(value: number): number {
    if (!Number.isFinite(value)) return 2000;
    return Math.min(MAX_INTERVAL_MS, Math.max(MIN_INTERVAL_MS, Math.round(value)));
}

export function nextBackoffMs(intervalMs: number, failureCount: number): number {
    return Math.min(MAX_BACKOFF_MS, normalizePollInterval(intervalMs) * Math.max(1, 2 ** Math.min(4, failureCount)));
}

export function normalizeEpochMs(value: number | null): number | null {
    if (value == null || !Number.isFinite(value)) return null;
    return value < 10_000_000_000 ? value * 1000 : value;
}

export function isStatusStale(status: HermesStatus, now = Date.now(), intervalMs = 2000, receivedAt: number | null = null): boolean {
    const reference = receivedAt ?? normalizeEpochMs(status.updated_at);
    if (reference == null) return true;
    return now - reference > Math.max(15000, normalizePollInterval(intervalMs) * 2.5);
}

export function buildStatusUrl(bridgeUrl: string, channelId: string): string | null {
    if (!SNOWFLAKE_RE.test(channelId)) return null;
    try {
        const url = new URL(bridgeUrl.trim());
        if (url.protocol !== "http:" || !isLoopbackHost(url.hostname)) return null;
        url.pathname = `${url.pathname.replace(/\/+$/, "")}/v1/status/discord/${channelId}`;
        url.search = "";
        url.hash = "";
        return url.toString();
    } catch {
        return null;
    }
}

export async function fetchHermesStatus(config: PollConfig, channelId: string, signal: AbortSignal): Promise<HermesStatus> {
    const url = buildStatusUrl(config.bridgeUrl, channelId);
    const bearerToken = config.bearerToken.trim();
    if (!url) throw new Error("Bridge URL must be HTTP on a loopback host");
    if (config.bearerTokenError) throw new Error(config.bearerTokenError);
    if (!bearerToken) throw new Error("Set the local Hermes bridge token");

    const res = await fetch(url, {
        method: "GET",
        headers: { Accept: "application/json", Authorization: `Bearer ${bearerToken}` },
        signal
    });

    if (!res.ok) throw new Error(`Bridge returned HTTP ${res.status}`);

    const status = validateHermesStatus(await res.json());
    if (!status) throw new Error("Bridge returned an invalid Hermes status payload");
    return status;
}
