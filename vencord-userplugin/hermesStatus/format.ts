/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { normalizeEpochMs } from "./api";
import type { ConnectionState, HermesSnapshot, HermesStatus } from "./types";

export interface StatusField {
    id: string;
    value: string;
    tooltip: string;
    ariaLabel: string;
    className?: string;
}

const groupOnlyFieldClassNames = new Set(["hide-compact", "hide-narrow", "tool"]);

function classNames(parts: Array<string | null | undefined>, className: (name: string) => string): string {
    return parts.filter(Boolean).map(name => className(name!)).join(" ");
}

export function statusFieldClassName(field: StatusField, className: (name: string) => string = name => name): string {
    return classNames([
        "field",
        field.className && !groupOnlyFieldClassNames.has(field.className) ? field.className : null
    ], className);
}

export function statusFieldGroupClassName(field: StatusField, className: (name: string) => string = name => name): string {
    return classNames(["fieldGroup", `fieldGroup-${field.id}`, field.className], className);
}

export function formatCompactNumber(value: number | null): string {
    if (value == null || !Number.isFinite(value)) return "--";
    const abs = Math.abs(value);
    if (abs >= 1_000_000) return `${Math.round(value / 100_000) / 10}M`;
    if (abs >= 1_000) return `${Math.round(value / 1000)}K`;
    return `${Math.round(value)}`;
}

export function formatContext(used: number | null, max: number | null): string {
    return `${formatCompactNumber(used)}/${formatCompactNumber(max)}`;
}

export function clampPercent(value: number | null, used: number | null, max: number | null): number | null {
    const percent = value ?? (used != null && max != null && max > 0 ? used / max * 100 : null);
    if (percent == null || !Number.isFinite(percent)) return null;
    return Math.max(0, Math.min(100, percent));
}

export function formatPercent(value: number | null): string {
    if (value == null || !Number.isFinite(value)) return "--";
    return `${Math.round(value)}%`;
}

export function formatElapsedSince(epoch: number | null, now = Date.now()): string {
    const startedAt = normalizeEpochMs(epoch);
    if (startedAt == null) return "--:--";

    const totalSeconds = Math.max(0, Math.floor((now - startedAt) / 1000));
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor(totalSeconds % 3600 / 60);
    const seconds = totalSeconds % 60;

    if (hours > 0) return `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
    return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

export function formatCompactDurationMs(ms: number | null): string {
    if (ms == null || !Number.isFinite(ms)) return "--";
    const seconds = Math.max(0, Math.floor(ms / 1000));
    const days = seconds / 86400;
    if (days >= 1) return `${Math.round(days * 10) / 10}d`;
    const hours = Math.floor(seconds / 3600);
    if (hours > 0) return `${hours}h`;
    const minutes = Math.floor(seconds / 60);
    if (minutes > 0) return `${minutes}m`;
    return `${seconds}s`;
}

export function formatCompactElapsedSince(epoch: number | null, now = Date.now()): string {
    const startedAt = normalizeEpochMs(epoch);
    return startedAt == null ? "--" : formatCompactDurationMs(now - startedAt);
}

export function formatContextGauge(percent: number | null): string {
    const safe = clampPercent(percent, null, null) ?? 0;
    const filled = Math.round(safe / 10);
    return `[${"█".repeat(filled)}${"░".repeat(Math.max(0, 10 - filled))}]`;
}

export function formatFreshness(status: HermesStatus | null, state: ConnectionState, receivedAt: number | null, now = Date.now()): string {
    const reference = normalizeEpochMs(status?.updated_at ?? null) ?? receivedAt;
    const age = reference == null ? "--" : formatCompactDurationMs(now - reference);
    if (state === "connected") return `✓${age}`;
    if (state === "stale") return `stale ${age}`;
    if (state === "error") return `err ${age}`;
    if (state === "disconnected") return `off ${age}`;
    return `... ${age}`;
}

export function stateLabel(state: ConnectionState): string {
    switch (state) {
        case "connected": return "connected";
        case "connecting": return "connecting";
        case "stale": return "stale";
        case "error": return "error";
        case "disconnected": return "disconnected";
        default: return "idle";
    }
}

function wholeCount(value: number | null | undefined): number | null {
    if (value == null || !Number.isFinite(value)) return null;
    return Math.max(0, Math.round(value));
}

function field(id: string, value: string, tooltip: string, className?: string): StatusField {
    return {
        id,
        value,
        tooltip,
        ariaLabel: tooltip,
        className
    };
}

export function buildStatusFields(snapshot: HermesSnapshot, now = Date.now()): StatusField[] {
    const fields: StatusField[] = [];
    const { status } = snapshot;
    const connection = stateLabel(snapshot.connectionState);

    if (!status) {
        fields.push(field("model", "Hermes", "Model: unknown", "model"));
        fields.push(field("context", "--/--", "Context window: unknown", "context"));
        fields.push(field("gauge", `${formatContextGauge(null)} --`, "Context gauge: unknown", "gauge"));
        fields.push(field("session-elapsed", "--", "Session elapsed: unknown", "session"));
        fields.push(field("freshness", formatFreshness(null, snapshot.connectionState, snapshot.receivedAt, now), "State last changed: unknown", "freshness"));
        fields.push(field("connection", connection, snapshot.error ?? `Hermes bridge ${connection}`, "state"));
        return fields;
    }

    const percent = clampPercent(status.context_percent, status.context_used, status.context_max);
    const context = formatContext(status.context_used, status.context_max);
    const percentText = formatPercent(percent);
    const sessionElapsed = formatCompactElapsedSince(status.session_started_at, now);
    const freshness = formatFreshness(status, snapshot.connectionState, snapshot.receivedAt, now);
    const updatedAt = normalizeEpochMs(status.updated_at);
    const changedAgo = updatedAt == null ? "unknown" : `${formatCompactDurationMs(now - updatedAt)} ago`;
    const compressionCount = wholeCount(status.compression_count);
    const activeSubagents = wholeCount(status.active_subagents);
    const activeToolCalls = wholeCount(status.active_tool_calls);
    const toolCalls = wholeCount(status.tool_calls);
    const activeTool = status.active_tool?.trim() || null;

    fields.push(field("model", status.model || "Hermes", `Model: ${status.model || "unknown"}`, "model"));
    fields.push(field("context", context, `Context window: ${formatCompactNumber(status.context_used)} used of ${formatCompactNumber(status.context_max)} (${percentText})`, "context"));
    fields.push(field("gauge", `${formatContextGauge(percent)} ${percentText}`, `Context gauge: ${percentText} used`, "gauge"));

    if (compressionCount != null && compressionCount > 0) {
        fields.push(field("compression", `🗜️ ${compressionCount}`, `Compression count: ${compressionCount}`, "hide-compact"));
    }
    if (activeSubagents != null && activeSubagents > 0) {
        fields.push(field("active-subagents", `⛓️ ${activeSubagents}`, `Active subagents: ${activeSubagents}`, "hide-compact"));
    }

    fields.push(field("session-elapsed", sessionElapsed, `Session elapsed: ${sessionElapsed}`, "session"));

    if (status.busy) {
        const turnElapsed = formatCompactElapsedSince(status.turn_started_at, now);
        fields.push(field("current-turn", `⏲ ${turnElapsed}`, `Current turn elapsed: ${turnElapsed}`, "hide-narrow"));
    }

    fields.push(field("freshness", freshness, `State last changed: ${changedAgo}`, "freshness"));

    if (status.yolo) {
        fields.push(field("yolo", "⚠ YOLO", "YOLO mode: dangerous command approvals are bypassed", "yolo"));
    }
    if (activeTool) {
        fields.push(field("active-tool", activeTool, `Active tool: ${activeTool}`, "tool"));
    }
    if (activeToolCalls != null && activeToolCalls > 0) {
        fields.push(field("active-tool-count", `${activeToolCalls} active`, `Active tool calls: ${activeToolCalls}`, "hide-narrow"));
    } else if (toolCalls != null && toolCalls > 0 && activeTool) {
        fields.push(field("tool-count", `${toolCalls} calls`, `Tool call count: ${toolCalls}`, "hide-narrow"));
    }

    fields.push(field("connection", connection, snapshot.error ?? `Hermes bridge ${connection}`, "state"));
    return fields;
}
